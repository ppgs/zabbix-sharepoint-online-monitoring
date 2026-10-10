// Autor: Pablo Pires de Godoi Silva · Licença MIT
// SharePoint Online - maiores arquivos e maiores historicos de versoes de todos os sites (site, pasta, versoes)
// (Pesquisa do Microsoft 365 + versoes via Graph $batch). Permissao: Sites.Read.All (aplicativo).
// Parametros: tenant_id, client_id, client_secret, proxy, min_mb, max, include_onedrive (1/0), region (vazio = automatico),
//             versions_min_mb, versions_scan (quantos dos maiores arquivos tem as versoes medidas)
var p = JSON.parse(value);
var out = { error: '', warning: '', region: '', total: 0, files: [] };
// Parametros efetivos (valores das macros), publicados para o Grafana exibir nas descricoes
out.config = {
    min_mb: Number(p.min_mb) || 200,
    max: Math.min(Math.max(Number(p.max) || 50, 1), 500),
    versions_min_mb: Number(p.versions_min_mb) || 50,
    versions_scan: 0
};
out.config.versions_scan = Math.min(Math.max(Number(p.versions_scan) || 500, out.config.max), 2000);

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

// FNV-1a 32 bits (dois passes) para gerar um ID curto e estavel a partir da URL
function hash(s) {
    var h1 = 0x811c9dc5, h2 = 0x01000193, i, c;
    for (i = 0; i < s.length; i++) {
        c = s.charCodeAt(i);
        h1 ^= c; h1 = (h1 * 16777619) >>> 0;
        h2 ^= (c + i) & 0xffff; h2 = (h2 * 16777619) >>> 0;
    }
    return ('00000000' + h1.toString(16)).slice(-8) + ('00000000' + h2.toString(16)).slice(-8);
}

// URL pronta para link: cada trecho do caminho codificado (espaco, acento, #, %, ? e & nao quebram o link)
function linkUrl(url) {
    var m = String(url || '').match(/^(https?:\/\/[^\/]+)(\/.*)?$/i);
    if (!m) { return String(url || ''); }
    var parts = (m[2] || '').split('/'), i, seg;
    for (i = 0; i < parts.length; i++) {
        seg = parts[i];
        try { seg = decodeURIComponent(seg); } catch (e) { }
        parts[i] = encodeURIComponent(seg);
    }
    return m[1] + parts.join('/');
}

function splitUrl(url) {
    var s = String(url || '');
    try { s = decodeURIComponent(s); } catch (e) { }
    s = s.replace(/^https?:\/\/[^\/]+/i, '');
    var m = s.match(/^\/(sites|teams|personal)\/([^\/]+)\/(.*)$/i), site, rest;
    if (m) { site = '/' + m[1] + '/' + m[2]; rest = m[3]; } else { site = '(raiz)'; rest = s.replace(/^\/+/, ''); }
    var parts = rest.split('/');
    parts.pop();
    return { site: site, folder: parts.join('/') };
}

// Rotulo do item: "arquivo | site | pasta" com no maximo 200 caracteres (nome de item do Zabbix: 255)
function label(name, site, folder) {
    var base = name + ' | ' + site + ' | ';
    var room = 200 - base.length;
    if (room < 10) { return (base + folder).substring(0, 200); }
    if (folder.length > room) { folder = '...' + folder.slice(-(room - 3)); }
    return base + folder;
}

function graphBatch(token, urls) {
    var res = {}, i, j, chunk, r, resp, data;
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

function shortPath(url, host) {
    var s = String(url || '');
    try { s = decodeURIComponent(s); } catch (e) { }
    s = s.replace(/^https?:\/\/[^\/]+/i, '');
    if (s.length > 180) {
        s = '...' + s.slice(-177);
    }
    return s;
}

try {
    var token = getToken();

    // site raiz: host do SharePoint e regiao (dataLocationCode)
    var rr = newReq();
    rr.addHeader('Authorization: Bearer ' + token);
    var rootResp = rr.get('https://graph.microsoft.com/v1.0/sites/root?$select=webUrl,siteCollection');
    if (rr.getStatus() !== 200) {
        throw 'Graph /sites/root: HTTP ' + rr.getStatus() + ' ' + String(rootResp).substring(0, 200);
    }
    var root = JSON.parse(rootResp);
    var rootUrl = String(root.webUrl || '').replace(/\/+$/, '');
    var region = p.region || (root.siteCollection && root.siteCollection.dataLocationCode) || 'NAM';

    var minBytes = out.config.min_mb * 1048576;
    var max = out.config.max;
    var vMinBytes = out.config.versions_min_mb * 1048576;
    var scan = out.config.versions_scan;
    var pathFilter = (String(p.include_onedrive) !== '1' && rootUrl) ? ' path:"' + rootUrl + '/"' : '';

    // Uma pagina da Pesquisa do Microsoft 365, ordenada por tamanho (desc)
    function search(kql, from, size) {
        var attempt, r, resp;
        for (attempt = 0; attempt < 2; attempt++) {
            r = newReq();
            r.addHeader('Authorization: Bearer ' + token);
            r.addHeader('Content-Type: application/json');
            resp = r.post('https://graph.microsoft.com/v1.0/search/query', JSON.stringify({
                requests: [{
                    entityTypes: ['driveItem'],
                    query: { queryString: kql },
                    region: region,
                    from: from,
                    size: size,
                    fields: ['id', 'name', 'size', 'lastModifiedDateTime', 'webUrl', 'parentReference'],
                    sortProperties: [{ name: 'size', isDescending: true }]
                }]
            }));
            if (r.getStatus() === 200) {
                var c = (JSON.parse(resp).value || [{}])[0].hitsContainers || [];
                return {
                    total: c.length ? Number(c[0].total) || 0 : 0,
                    more: c.length ? !!c[0].moreResultsAvailable : false,
                    hits: c.length ? (c[0].hits || []) : []
                };
            }
            // regiao invalida: a propria resposta informa a regiao valida
            var m = String(resp).match(/Only valid regions are ([A-Z]{3})/);
            if (r.getStatus() === 400 && m && attempt === 0) {
                region = m[1];
                continue;
            }
            throw 'Graph search: HTTP ' + r.getStatus() + ' ' + String(resp).substring(0, 300);
        }
        throw 'Graph search: regiao invalida';
    }

    // 1) Maiores arquivos acima de min_mb (lista por tamanho e total de arquivos acima do minimo)
    var s1 = search('IsDocument:true Size>' + minBytes + pathFilter, 0, max);
    out.total = s1.total;
    out.region = region;

    // 2) Universo para medir versoes: os "scan" maiores arquivos acima de versions_min_mb
    var pool = [], seen = {}, i, page, from = 0;
    function addHit(h) {
        var f = h.resource || {};
        var url = String(f.webUrl || '');
        var id = hash(url);
        if (!url || seen[id]) { return; }
        seen[id] = true;
        pool.push(f);
    }
    for (i = 0; i < s1.hits.length; i++) { addHit(s1.hits[i]); }
    while (from < scan) {
        page = search('IsDocument:true Size>' + vMinBytes + pathFilter, from, Math.min(200, scan - from));
        for (i = 0; i < page.hits.length; i++) { addHit(page.hits[i]); }
        if (!page.more || page.hits.length === 0) { break; }
        from += page.hits.length;
    }

    var files = [], vurls = [], vidx = [];
    for (i = 0; i < pool.length; i++) {
        var f = pool[i];
        var url = String(f.webUrl || '');
        var t = Date.parse(f.lastModifiedDateTime || '');
        var loc = splitUrl(url);
        files.push({
            id: hash(url),
            name: String(f.name || ''),
            site: loc.site,
            folder: loc.folder,
            label: label(String(f.name || ''), loc.site, loc.folder),
            size: Number(f.size) || 0,
            modified: isNaN(t) ? 0 : Math.round(t / 1000),
            versions_count: 0,
            versions_size: 0,
            url: linkUrl(url),
            folder_url: linkUrl(url.substring(0, url.lastIndexOf('/')))
        });
        if (f.id && f.parentReference && f.parentReference.driveId) {
            vurls.push('/drives/' + encodeURIComponent(f.parentReference.driveId) + '/items/' + encodeURIComponent(f.id) + '/versions?$select=id,size');
            vidx.push(files.length - 1);
        }
    }

    // Versoes: a primeira da lista e a atual; as demais sao o historico que ocupa a cota
    var vres = graphBatch(token, vurls), vfail = 0, scannedSize = 0;
    for (i = 0; i < vidx.length; i++) {
        var vr = vres[String(i)];
        if (!vr || vr.status !== 200 || !vr.body) {
            vfail++;
            continue;
        }
        var vals = vr.body.value || [], vsum = 0, k;
        for (k = 1; k < vals.length; k++) {
            vsum += Number(vals[k].size) || 0;
        }
        files[vidx[i]].versions_count = Math.max(vals.length - 1, 0);
        files[vidx[i]].versions_size = vsum;
        scannedSize += vsum;
    }
    if (vfail > 0) {
        out.warning = 'Versoes nao lidas em ' + vfail + ' arquivo(s) (throttling ou permissao).';
    }

    // Saida: uniao dos "max" maiores por tamanho e dos "max" maiores por versoes antigas
    var bySize = files.slice().sort(function (a, b) { return b.size - a.size; }).slice(0, max);
    var byVer = files.filter(function (x) { return x.versions_size > 0; })
        .sort(function (a, b) { return b.versions_size - a.versions_size; }).slice(0, max);
    var keep = {}, sizeTotal = 0, verTotal = 0;
    for (i = 0; i < bySize.length; i++) { keep[bySize[i].id] = bySize[i]; sizeTotal += bySize[i].size; }
    for (i = 0; i < byVer.length; i++) { keep[byVer[i].id] = byVer[i]; verTotal += byVer[i].versions_size; }
    for (i in keep) {
        if (keep.hasOwnProperty(i)) { out.files.push(keep[i]); }
    }
    out.count = out.files.length;
    out.size_total = sizeTotal;
    out.versions_total = verTotal;
    out.versions_scanned = files.length;
    out.versions_scanned_size = scannedSize;
}
catch (e) {
    out.error = String(e).substring(0, 500);
}

return JSON.stringify(out);
