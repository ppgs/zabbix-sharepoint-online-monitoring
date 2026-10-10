// Autor: Pablo Pires de Godoi Silva · Licença MIT
// SharePoint Online via Microsoft Graph Reports (somente leitura, Reports.Read.All de aplicativo)
// Parametros: tenant_id, client_id, client_secret, proxy, quota_gb
var p = JSON.parse(value);
var out = { error: '', warning: '' };

function newReq() {
    var r = new HttpRequest();
    if (p.proxy && p.proxy !== '') {
        r.setProxy(p.proxy);
    }
    return r;
}

function headerValue(headers, name) {
    var k;
    for (k in headers) {
        if (headers.hasOwnProperty(k) && k.toLowerCase() === name.toLowerCase()) {
            return headers[k];
        }
    }
    return null;
}

function getToken() {
    var r = newReq();
    r.addHeader('Content-Type: application/x-www-form-urlencoded');
    var body = 'client_id=' + encodeURIComponent(p.client_id) +
        '&client_secret=' + encodeURIComponent(p.client_secret) +
        '&scope=' + encodeURIComponent('https://graph.microsoft.com/.default') +
        '&grant_type=client_credentials';
    var resp = r.post('https://login.microsoftonline.com/' + encodeURIComponent(p.tenant_id) + '/oauth2/v2.0/token', body);
    if (r.getStatus() !== 200) {
        var msg = String(resp);
        try { msg = JSON.parse(resp).error_description || msg; } catch (e) { }
        throw 'Token: HTTP ' + r.getStatus() + ' ' + msg.substring(0, 300);
    }
    return JSON.parse(resp).access_token;
}

// O Graph responde 302 com Location para o CSV; trata os dois casos (com ou sem redirect automatico)
function getReportCsv(token, fn) {
    var r = newReq();
    r.addHeader('Authorization: Bearer ' + token);
    var resp = r.get('https://graph.microsoft.com/v1.0/reports/' + fn);
    var status = r.getStatus();
    if (status === 301 || status === 302) {
        var loc = headerValue(r.getHeaders(), 'Location');
        if (!loc) {
            throw 'Relatorio ' + fn + ': redirect sem Location';
        }
        var d = newReq();
        resp = d.get(loc);
        status = d.getStatus();
    }
    if (status !== 200) {
        throw 'Relatorio ' + fn + ': HTTP ' + status + ' ' + String(resp).substring(0, 300);
    }
    return String(resp);
}

// GET paginado no Graph (segue @odata.nextLink)
function graphGetAll(token, url, maxPages) {
    var items = [], pages = 0;
    while (url && pages < (maxPages || 50)) {
        var r = newReq();
        r.addHeader('Authorization: Bearer ' + token);
        r.addHeader('Accept: application/json');
        var resp = r.get(url);
        if (r.getStatus() !== 200) {
            throw 'Graph ' + url.split('?')[0].replace('https://graph.microsoft.com/v1.0', '') + ': HTTP ' + r.getStatus() + ' ' + String(resp).substring(0, 200);
        }
        var j = JSON.parse(resp);
        items = items.concat(j.value || []);
        url = j['@odata.nextLink'] || null;
        pages++;
    }
    return items;
}

// Mapa ID do conjunto de sites -> {url, name} (requer Sites.Read.All de aplicativo).
// O relatorio de uso nao traz mais a URL (problema conhecido da Microsoft, SP676147).
function siteMap(token) {
    var map = {}, all = graphGetAll(token, 'https://graph.microsoft.com/v1.0/sites/getAllSites', 100), i, parts;
    for (i = 0; i < all.length; i++) {
        parts = String(all[i].id || '').split(',');
        var info = { url: all[i].webUrl || '', name: all[i].displayName || '' };
        if (parts.length >= 2) { map[parts[1].toLowerCase()] = info; }
        if (parts.length >= 3 && !map[parts[2].toLowerCase()]) { map[parts[2].toLowerCase()] = info; }
    }
    return map;
}

function parseCsv(text) {
    text = text.replace(/^\uFEFF/, '');
    var rows = [], row = [], field = '', inQ = false, i, c;
    for (i = 0; i < text.length; i++) {
        c = text.charAt(i);
        if (inQ) {
            if (c === '"') {
                if (text.charAt(i + 1) === '"') { field += '"'; i++; } else { inQ = false; }
            } else {
                field += c;
            }
        } else if (c === '"') {
            inQ = true;
        } else if (c === ',') {
            row.push(field); field = '';
        } else if (c === '\n') {
            row.push(field); rows.push(row); row = []; field = '';
        } else if (c !== '\r') {
            field += c;
        }
    }
    if (field !== '' || row.length) {
        row.push(field); rows.push(row);
    }
    if (rows.length === 0) {
        return [];
    }
    var head = rows[0], res = [], j, o;
    for (i = 1; i < rows.length; i++) {
        if (rows[i].length < 2) {
            continue;
        }
        o = {};
        for (j = 0; j < head.length; j++) {
            o[head[j]] = rows[i][j];
        }
        res.push(o);
    }
    return res;
}

function num(v) {
    var n = Number(v);
    return isNaN(n) ? 0 : n;
}

try {
    var token = getToken();
    var detail = parseCsv(getReportCsv(token, "getSharePointSiteUsageDetail(period='D7')"));
    var storage = parseCsv(getReportCsv(token, "getSharePointSiteUsageStorage(period='D7')"));

    var map = {};
    try {
        map = siteMap(token);
    } catch (e) {
        out.warning = 'Sem URL dos sites (verifique Sites.Read.All de aplicativo): ' + String(e).substring(0, 300);
    }

    // Sites ativos (nome e UPN do dono nao sao enviados ao Zabbix)
    var sites = [], deletedCount = 0, deletedBytes = 0, sumUsed = 0, refresh = '', i;
    for (i = 0; i < detail.length; i++) {
        var s = detail[i];
        var used = num(s['Storage Used (Byte)']);
        var alloc = num(s['Storage Allocated (Byte)']);
        if (!refresh) {
            refresh = s['Report Refresh Date'] || '';
        }
        if (String(s['Is Deleted']).toLowerCase() === 'true') {
            deletedCount++;
            deletedBytes += used;
            continue;
        }
        sumUsed += used;
        var sid = String(s['Site Id'] || '');
        var m = map[sid.toLowerCase()] || {};
        sites.push({
            id: sid,
            url: s['Site URL'] || m.url || ('site-' + sid),
            name: m.name || '',
            template: s['Root Web Template'] || '',
            used: used,
            allocated: alloc,
            pused: alloc > 0 ? Math.round(used / alloc * 10000) / 100 : 0,
            files: num(s['File Count']),
            active_files: num(s['Active File Count']),
            last_activity: s['Last Activity Date'] || ''
        });
    }

    // Tenant: dia mais recente do relatorio de armazenamento
    var latest = '', tenantUsed = 0, hasAll = false;
    for (i = 0; i < storage.length; i++) {
        if ((storage[i]['Report Date'] || '') > latest) {
            latest = storage[i]['Report Date'];
        }
    }
    for (i = 0; i < storage.length; i++) {
        if (storage[i]['Report Date'] === latest && String(storage[i]['Site Type']).toLowerCase() === 'all') {
            tenantUsed = num(storage[i]['Storage Used (Byte)']);
            hasAll = true;
        }
    }
    if (!hasAll) {
        for (i = 0; i < storage.length; i++) {
            if (storage[i]['Report Date'] === latest) {
                tenantUsed += num(storage[i]['Storage Used (Byte)']);
            }
        }
    }
    if (tenantUsed === 0) {
        tenantUsed = sumUsed + deletedBytes;
    }

    var quota = num(p.quota_gb) * 1073741824;
    out.tenant = { used: tenantUsed, report_date: latest, quota: quota };
    if (quota > 0) {
        out.tenant.pused = Math.round(tenantUsed / quota * 10000) / 100;
        out.tenant.free = quota - tenantUsed;
    }
    out.report_refresh_date = refresh;
    if (refresh) {
        out.report_age_s = Math.max(0, Math.round((Date.now() - Date.parse(refresh + 'T00:00:00Z')) / 1000));
    }
    out.sites_count = sites.length;
    out.sites_used = sumUsed;
    out.sites_deleted_count = deletedCount;
    out.sites_deleted_used = deletedBytes;
    out.sites = sites;
}
catch (e) {
    out.error = String(e).substring(0, 500);
}

return JSON.stringify(out);
