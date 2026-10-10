// Autor: Pablo Pires de Godoi Silva · Licença MIT
// SharePoint Online - lixeiras de 1º e 2º estágio de todos os sites (quantidade e tamanho). SOMENTE LEITURA.
// Sites: Graph /sites/getAllSites (app do Zabbix, segredo). Lixeiras: API REST do SharePoint
// (/_api/site/RecycleBin), que exige token de aplicativo obtido com CERTIFICADO (JWT RS256 assinado com sign()).
// Parametros: enabled, tenant_id, client_id, client_secret, proxy, rb_client_id (vazio = client_id), rb_thumbprint, rb_private_key, site_min_mb
// Sem certificado tenta o segredo do cliente e, se o SharePoint recusar (401), explica o motivo no item de erro.
var p = JSON.parse(value);
var out = {
    error: '', warning: '', collected: Math.round(Date.now() / 1000),
    sites_total: 0, sites_read: 0, sites_partial: 0, sites_error: 0,
    stage1: { count: 0, size: 0 }, stage2: { count: 0, size: 0 }, sites: []
};

function newReq() {
    var r = new HttpRequest();
    if (p.proxy && p.proxy !== '') {
        r.setProxy(p.proxy);
    }
    return r;
}

// ---------- codificacao ----------
var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function b64urlBytes(bytes) {
    var s = '', i, n;
    for (i = 0; i < bytes.length; i += 3) {
        n = (bytes[i] << 16) | ((i + 1 < bytes.length ? bytes[i + 1] : 0) << 8) | (i + 2 < bytes.length ? bytes[i + 2] : 0);
        s += B64.charAt((n >> 18) & 63) + B64.charAt((n >> 12) & 63);
        s += i + 1 < bytes.length ? B64.charAt((n >> 6) & 63) : '';
        s += i + 2 < bytes.length ? B64.charAt(n & 63) : '';
    }
    return s.replace(/\+/g, '-').replace(/\//g, '_');
}
function hexToBytes(hex) {
    var b = [], i;
    hex = String(hex).replace(/[^0-9a-fA-F]/g, '');
    for (i = 0; i + 1 < hex.length; i += 2) {
        b.push(parseInt(hex.substr(i, 2), 16));
    }
    return b;
}
function asciiBytes(s) {
    var b = [], i;
    for (i = 0; i < s.length; i++) {
        b.push(s.charCodeAt(i) & 255);
    }
    return b;
}
function randomHex(n) {
    var s = '', i;
    for (i = 0; i < n; i++) {
        s += Math.floor(Math.random() * 16).toString(16);
    }
    return s;
}

// ---------- tokens ----------
function tokenRequest(body, what) {
    var r = newReq();
    r.addHeader('Content-Type: application/x-www-form-urlencoded');
    var resp = r.post('https://login.microsoftonline.com/' + encodeURIComponent(p.tenant_id) + '/oauth2/v2.0/token', body);
    if (r.getStatus() !== 200) {
        var msg = String(resp);
        try { msg = JSON.parse(resp).error_description || msg; } catch (e) { }
        throw 'Token ' + what + ': HTTP ' + r.getStatus() + ' ' + msg.substring(0, 300);
    }
    return JSON.parse(resp).access_token;
}

function graphToken() {
    return tokenRequest('client_id=' + encodeURIComponent(p.client_id) +
        '&client_secret=' + encodeURIComponent(p.client_secret) +
        '&scope=' + encodeURIComponent('https://graph.microsoft.com/.default') +
        '&grant_type=client_credentials', 'Graph');
}

// Token do SharePoint com certificado: client_assertion = JWT RS256 assinado com a chave privada
function sharepointToken(host) {
    var now = Math.round(Date.now() / 1000);
    var aud = 'https://login.microsoftonline.com/' + p.tenant_id + '/oauth2/v2.0/token';
    var header = { alg: 'RS256', typ: 'JWT', x5t: b64urlBytes(hexToBytes(p.rb_thumbprint)) };
    var claims = { aud: aud, iss: p.rb_client_id, sub: p.rb_client_id, jti: randomHex(32), nbf: now - 60, iat: now - 60, exp: now + 540 };
    var input = b64urlBytes(asciiBytes(JSON.stringify(header))) + '.' + b64urlBytes(asciiBytes(JSON.stringify(claims)));
    var sig;
    try {
        sig = sign('sha256', p.rb_private_key, input);
    }
    catch (e) {
        throw 'Chave privada (macro SPO.RB.PRIVATE.KEY) inválida: ' + String(e).substring(0, 200);
    }
    var jwt = input + '.' + b64urlBytes(hexToBytes(sig));
    return tokenRequest('client_id=' + encodeURIComponent(p.rb_client_id) +
        '&client_assertion_type=' + encodeURIComponent('urn:ietf:params:oauth:client-assertion-type:jwt-bearer') +
        '&client_assertion=' + encodeURIComponent(jwt) +
        '&scope=' + encodeURIComponent('https://' + host + '/.default') +
        '&grant_type=client_credentials', 'SharePoint (certificado)');
}

// Tentativa com segredo do cliente (sem certificado). O SharePoint costuma recusar este token (401).
function secretSharepointToken(host) {
    return tokenRequest('client_id=' + encodeURIComponent(p.rb_client_id) +
        '&client_secret=' + encodeURIComponent(p.client_secret) +
        '&scope=' + encodeURIComponent('https://' + host + '/.default') +
        '&grant_type=client_credentials', 'SharePoint (segredo)');
}

// ---------- coleta ----------
try {
    // Modulo opcional: exige app com certificado e SharePoint Sites.FullControl.All (macro SPO.RB.ENABLED = 1)
    if (String(p.enabled) !== '1') {
        return JSON.stringify({ disabled: 1, error: '', warning: 'Leitura das lixeiras desativada (macro SPO.RB.ENABLED = 0).' });
    }
    // App: macro SPO.RB.CLIENT.ID ou, se vazia, o mesmo app do Zabbix (SPO.CLIENT.ID)
    if (!p.rb_client_id) { p.rb_client_id = p.client_id; }
    var useCert = !!(p.rb_private_key && p.rb_thumbprint);
    var minBytes = (Number(p.site_min_mb) || 100) * 1048576;

    // 1) Todos os sites (Graph), sem OneDrives pessoais
    var g = newReq(), gtoken = graphToken(), urls = [], url, resp, data, i;
    g.addHeader('Authorization: Bearer ' + gtoken);
    url = 'https://graph.microsoft.com/v1.0/sites/getAllSites?$select=webUrl&$top=999';
    while (url) {
        resp = g.get(url);
        if (g.getStatus() !== 200) {
            throw 'Graph getAllSites: HTTP ' + g.getStatus() + ' ' + String(resp).substring(0, 200);
        }
        data = JSON.parse(resp);
        for (i = 0; i < (data.value || []).length; i++) {
            if (!/-my\.sharepoint\.com/i.test(data.value[i].webUrl || '')) {
                urls.push(String(data.value[i].webUrl).replace(/\/+$/, ''));
            }
        }
        url = data['@odata.nextLink'] || null;
    }
    out.sites_total = urls.length;
    if (!urls.length) {
        throw 'Nenhum site retornado pelo Graph.';
    }

    // 2) Token do SharePoint (certificado) e um unico HttpRequest reaproveitado (limite de objetos do Zabbix)
    var host = urls[0].match(/^https:\/\/([^\/]+)/i)[1];
    var sp = newReq();
    sp.addHeader('Authorization: Bearer ' + (useCert ? sharepointToken(host) : secretSharepointToken(host)));
    sp.addHeader('Accept: application/json;odata=nometadata');

    var readBin = function (base, scope) {
        var res = { s1c: 0, s1b: 0, s2c: 0, s2b: 0 }, u = base + '/_api/' + scope + '/RecycleBin?$select=Size,ItemState&$top=1000000', r, d, k, it;
        while (u) {
            r = sp.get(u);
            if (sp.getStatus() !== 200) {
                var m = String(r);
                try { m = JSON.parse(r)['odata.error'].message.value || m; } catch (e) { }
                return { status: sp.getStatus(), msg: m.substring(0, 200) };
            }
            d = JSON.parse(r);
            for (k = 0; k < (d.value || []).length; k++) {
                it = d.value[k];
                if (Number(it.ItemState) === 2) { res.s2c++; res.s2b += Number(it.Size) || 0; }
                else { res.s1c++; res.s1b += Number(it.Size) || 0; }
            }
            u = d['odata.nextLink'] || null;
        }
        return res;
    };

    var firstErr = '', partialErr = '';
    for (i = 0; i < urls.length; i++) {
        var rel = urls[i].replace(/^https:\/\/[^\/]+/i, '') || '(raiz)';
        var res = readBin(urls[i], 'site');
        if (!useCert && i === 0 && res.status === 401) {
            throw 'A API do SharePoint recusou o token obtido com segredo do cliente (HTTP 401, "Unsupported app only token"). '
                + 'Ela só aceita app com certificado: carregue o certificado no app e preencha as macros SPO.RB.CERT.THUMBPRINT e SPO.RB.PRIVATE.KEY.';
        }
        var partial = false;
        if (res.status === 401 || res.status === 403) {
            // sem acesso a lixeira do conjunto de sites (2º estagio): tenta so a lixeira do site (1º estagio)
            if (!partialErr) { partialErr = rel + ': ' + res.msg; }
            res = readBin(urls[i], 'web');
            partial = true;
        }
        if (res.status) {
            out.sites_error++;
            if (!firstErr) { firstErr = rel + ': HTTP ' + res.status + ' ' + res.msg; }
            continue;
        }
        out.sites_read++;
        if (partial) { out.sites_partial++; }
        out.stage1.count += res.s1c; out.stage1.size += res.s1b;
        out.stage2.count += res.s2c; out.stage2.size += res.s2b;
        if (res.s1b + res.s2b >= minBytes) {
            out.sites.push({ site: rel, s1_count: res.s1c, s1_size: res.s1b, s2_count: res.s2c, s2_size: res.s2b, partial: partial ? 1 : 0 });
        }
    }
    out.sites.sort(function (a, b) { return (b.s1_size + b.s2_size) - (a.s1_size + a.s2_size); });
    if (firstErr) {
        out.error = 'Sites sem leitura: ' + out.sites_error + '. Ex.: ' + firstErr;
    }
    if (out.sites_partial > 0) {
        out.warning = '2º estágio não lido em ' + out.sites_partial + ' site(s): o app precisa de SharePoint Sites.FullControl.All. Ex.: ' + partialErr;
    }
}
catch (e) {
    out.error = String(e).substring(0, 500);
}

return JSON.stringify(out);
