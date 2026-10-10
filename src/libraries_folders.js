// Autor: Pablo Pires de Godoi Silva · Licença MIT
// SharePoint Online - tamanho por biblioteca e por pasta de 1o nivel (Microsoft Graph, Sites.Read.All de aplicativo)
// Parametros: tenant_id, client_id, client_secret, proxy, sites (URLs separadas por virgula, detalhe por pasta),
//             max_folders, libraries_all (1 = bibliotecas de todos os sites), min_lib_mb
// Observacao: o tamanho do Graph considera a versao atual dos arquivos; o historico de versoes nao entra.
var p = JSON.parse(value);
var out = { error: '', warning: '', libraries: [], folders: [] };

function newReq() {
    var r = new HttpRequest();
    if (p.proxy && p.proxy !== '') {
        r.setProxy(p.proxy);
    }
    return r;
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

function graphGet(token, url) {
    var r = newReq();
    r.addHeader('Authorization: Bearer ' + token);
    r.addHeader('Accept: application/json');
    var resp = r.get(url);
    if (r.getStatus() !== 200) {
        throw 'Graph ' + url.replace('https://graph.microsoft.com/v1.0', '').split('?')[0] + ': HTTP ' + r.getStatus() + ' ' + String(resp).substring(0, 200);
    }
    return JSON.parse(resp);
}

function graphGetAll(token, url) {
    var items = [], pages = 0, j;
    while (url && pages < 50) {
        j = graphGet(token, url);
        items = items.concat(j.value || []);
        url = j['@odata.nextLink'] || null;
        pages++;
    }
    return items;
}

// Graph JSON batching: ate 20 requisicoes por chamada
function graphBatch(token, urls) {
    var res = {}, i, j, chunk, body, r, resp, data;
    for (i = 0; i < urls.length; i += 20) {
        chunk = [];
        for (j = i; j < Math.min(i + 20, urls.length); j++) {
            chunk.push({ id: String(j), method: 'GET', url: urls[j] });
        }
        r = newReq();
        r.addHeader('Authorization: Bearer ' + token);
        r.addHeader('Content-Type: application/json');
        resp = r.post('https://graph.microsoft.com/v1.0/$batch', JSON.stringify({ requests: chunk }));
        if (r.getStatus() !== 200) {
            throw 'Graph $batch: HTTP ' + r.getStatus() + ' ' + String(resp).substring(0, 200);
        }
        data = JSON.parse(resp).responses || [];
        for (j = 0; j < data.length; j++) {
            res[data[j].id] = data[j];
        }
    }
    return res;
}

// Caminho curto do site: "/sites/Financeiro" ou "(raiz)"
function sitePath(webUrl) {
    var p = String(webUrl || '').replace(/^https?:\/\/[^\/]+/i, '').replace(/\/+$/, '');
    return p === '' ? '(raiz)' : p;
}

function ts(v) {
    var t = Date.parse(v || '');
    return isNaN(t) ? 0 : Math.round(t / 1000);
}

try {
    var token = getToken();
    var seen = {};
    var minLib = (Number(p.min_lib_mb) || 0) * 1048576;

    if (String(p.libraries_all) === '1') {
        var all = graphGetAll(token, 'https://graph.microsoft.com/v1.0/sites/getAllSites'), sitesAll = [], a, b;
        for (a = 0; a < all.length; a++) {
            if (!all[a].isPersonalSite && all[a].id) {
                sitesAll.push(all[a]);
            }
        }
        var urlsDrives = [];
        for (a = 0; a < sitesAll.length; a++) {
            urlsDrives.push('/sites/' + encodeURIComponent(sitesAll[a].id) + '/drives?$select=id,name');
        }
        var resDrives = graphBatch(token, urlsDrives), driveList = [], skipped = 0;
        for (a = 0; a < sitesAll.length; a++) {
            var rd = resDrives[String(a)];
            if (!rd || rd.status !== 200 || !rd.body) {
                skipped++;
                continue;
            }
            for (b = 0; b < (rd.body.value || []).length; b++) {
                driveList.push({ site: sitesAll[a], drive: rd.body.value[b] });
            }
        }
        var urlsRoot = [];
        for (a = 0; a < driveList.length; a++) {
            urlsRoot.push('/drives/' + encodeURIComponent(driveList[a].drive.id) + '/root?$select=size,folder,lastModifiedDateTime');
        }
        var resRoot = graphBatch(token, urlsRoot), rootSkipped = 0;
        for (a = 0; a < driveList.length; a++) {
            var rr = resRoot[String(a)];
            if (!rr || rr.status !== 200 || !rr.body) {
                rootSkipped++;
                continue;
            }
            var sz = Number(rr.body.size) || 0;
            if (sz < minLib || seen[driveList[a].drive.id]) {
                continue;
            }
            seen[driveList[a].drive.id] = true;
            out.libraries.push({
                id: driveList[a].drive.id,
                site: driveList[a].site.webUrl,
                name: driveList[a].drive.name,
                path: sitePath(driveList[a].site.webUrl) + ' / ' + driveList[a].drive.name,
                size: sz,
                items: rr.body.folder ? Number(rr.body.folder.childCount) || 0 : 0,
                modified: ts(rr.body.lastModifiedDateTime)
            });
        }
        out.sites_scanned = sitesAll.length;
        out.sites_skipped = skipped;
        if (skipped + rootSkipped > 0) {
            out.warning = skipped + ' site(s) e ' + rootSkipped + ' biblioteca(s) sem leitura (sem permissao, arquivados ou throttling).';
        }
    }

    var list = String(p.sites || '').split(',');
    var maxFolders = Number(p.max_folders) || 200;
    var i, j, k;
    for (i = 0; i < list.length; i++) {
        var siteUrl = list[i].replace(/^\s+|\s+$/g, '');
        if (siteUrl === '') {
            continue;
        }
        var noProto = siteUrl.replace(/^https?:\/\//i, '').replace(/\/+$/, '');
        var slash = noProto.indexOf('/');
        var host = slash === -1 ? noProto : noProto.substring(0, slash);
        var path = slash === -1 ? '' : noProto.substring(slash);
        var site = graphGet(token, 'https://graph.microsoft.com/v1.0/sites/' + host + (path ? ':' + encodeURI(path) : '') + '?$select=id,webUrl,displayName');
        var drives = graphGetAll(token, 'https://graph.microsoft.com/v1.0/sites/' + encodeURIComponent(site.id) + '/drives?$select=id,name,webUrl');
        for (j = 0; j < drives.length; j++) {
            var d = drives[j];
            if (!seen[d.id]) {
                var root = graphGet(token, 'https://graph.microsoft.com/v1.0/drives/' + encodeURIComponent(d.id) + '/root?$select=size,folder,lastModifiedDateTime');
                seen[d.id] = true;
                out.libraries.push({
                    id: d.id,
                    site: site.webUrl,
                    name: d.name,
                    path: sitePath(site.webUrl) + ' / ' + d.name,
                    size: Number(root.size) || 0,
                    items: root.folder ? Number(root.folder.childCount) || 0 : 0,
                    modified: ts(root.lastModifiedDateTime)
                });
            }
            var children = graphGetAll(token, 'https://graph.microsoft.com/v1.0/drives/' + encodeURIComponent(d.id) + '/root/children?$select=id,name,size,folder,createdDateTime,lastModifiedDateTime&$top=999');
            for (k = 0; k < children.length; k++) {
                var c = children[k];
                if (!c.folder) {
                    continue;
                }
                out.folders.push({
                    id: d.id + '|' + c.id,
                    site: site.webUrl,
                    library: d.name,
                    path: d.name + '/' + c.name,
                    size: Number(c.size) || 0,
                    items: Number(c.folder.childCount) || 0,
                    created: ts(c.createdDateTime),
                    modified: ts(c.lastModifiedDateTime)
                });
            }
        }
    }
    out.folders.sort(function (a, b) { return b.size - a.size; });
    out.folders_total = out.folders.length;
    if (out.folders.length > maxFolders) {
        out.folders = out.folders.slice(0, maxFolders);
    }
    var total = 0;
    for (i = 0; i < out.libraries.length; i++) {
        total += out.libraries[i].size;
    }
    out.libraries_size = total;
    out.libraries.sort(function (x, y) { return y.size - x.size; });
    out.libraries_count = out.libraries.length;
}
catch (e) {
    out.error = String(e).substring(0, 500);
}

return JSON.stringify(out);
