#Requires -Version 7.2
<#
.SYNOPSIS
    Valida, com o app do Zabbix, a busca dos MAIORES arquivos do SharePoint (todos os sites)
    com site, pasta e peso do historico de versoes. Somente leitura.

.DESCRIPTION
    Rode no PowerShell 7 (pwsh). Pede so o segredo do cliente.
    1. Token do app registrado para o Zabbix.
    2. Pesquisa do Microsoft 365 (driveItem, região do tenant detectada automaticamente): arquivos acima de -MinMB,
       ordenados por tamanho (se a ordenacao por tamanho nao for aceita, ordena aqui).
    3. Para cada arquivo, le as versoes (/drives/{id}/items/{id}/versions) e soma o tamanho
       das versoes antigas.
.NOTES
    Autor: Pablo Pires de Godoi Silva
    Licença: MIT
#>
param(
    [Parameter(Mandatory)] [string]$TenantId,
    [Parameter(Mandatory)] [string]$ClientId,
    [string]$Region = '',
    [int]$MinMB = 500,
    [int]$Top = 10
)

$ErrorActionPreference = 'Stop'

function Show-GraphError($Err) {
    $msg = $Err.ErrorDetails.Message
    if (-not $msg) { $msg = $Err.Exception.Message }
    Write-Host "   ERRO: $msg" -ForegroundColor Red
}

function Split-SpoUrl([string]$Url) {
    $u = [uri]::UnescapeDataString($Url) -replace '^https?://[^/]+', ''
    if ($u -match '^/(sites|teams)/([^/]+)/(.*)$') { $site = "/$($Matches[1])/$($Matches[2])"; $rest = $Matches[3] }
    else { $site = '(raiz)'; $rest = $u.TrimStart('/') }
    $parts = $rest -split '/'
    $folder = if ($parts.Count -gt 1) { ($parts[0..($parts.Count - 2)] -join '/') } else { '' }
    [pscustomobject]@{ Site = $site; Pasta = $folder }
}

# ---------- 1. Token ----------
$secure = Read-Host -Prompt 'Client secret (Valor do segredo do app do Zabbix)' -AsSecureString
$plain = ConvertFrom-SecureString -SecureString $secure -AsPlainText
try {
    $tok = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
        client_id = $ClientId; client_secret = $plain
        scope = 'https://graph.microsoft.com/.default'; grant_type = 'client_credentials'
    }
}
catch { Write-Host '1. Token: FALHOU' -ForegroundColor Red; Show-GraphError $_; return }
finally { Remove-Variable plain -ErrorAction SilentlyContinue }
$headers = @{ Authorization = "Bearer $($tok.access_token)" }
Write-Host '1. Token: OK' -ForegroundColor Green

# ---------- 2. Pesquisa ----------
# Site raiz e região do tenant (a Pesquisa com permissão de aplicativo exige a região)
$root = Invoke-RestMethod -Headers $headers -Uri 'https://graph.microsoft.com/v1.0/sites/root?$select=webUrl,siteCollection'
if (-not $Region) { $Region = $root.siteCollection.dataLocationCode }
if (-not $Region) { $Region = 'NAM' }
$rootUrl = $root.webUrl.TrimEnd('/')
Write-Host "   Site raiz: $rootUrl | Região: $Region"
$kql = "IsDocument:true Size>$([int64]$MinMB * 1MB) path:""$rootUrl/"""
$fields = @('id', 'name', 'size', 'lastModifiedDateTime', 'webUrl', 'parentReference')

function Invoke-Search($SortName, [int]$PageSize) {
    $req = @{ entityTypes = @('driveItem'); query = @{ queryString = $kql }; region = $Region; from = 0; size = $PageSize; fields = $fields }
    if ($SortName) { $req.sortProperties = @(@{ name = $SortName; isDescending = $true }) }
    $body = @{ requests = @($req) } | ConvertTo-Json -Depth 6
    $r = Invoke-RestMethod -Method Post -Headers $headers -ContentType 'application/json' -Uri 'https://graph.microsoft.com/v1.0/search/query' -Body $body
    return $r.value[0].hitsContainers[0]
}

$sortMode = $null
foreach ($try in @('size', 'Size')) {
    try {
        Write-Host "2. Pesquisa ordenada por '$try' (desc): $kql"
        $c = Invoke-Search $try $Top
        $sortMode = "Graph ordena por '$try'"
        break
    }
    catch { Show-GraphError $_ }
}
if (-not $sortMode) {
    Write-Host '   Ordenação por tamanho não aceita. Buscando até 500 e ordenando aqui...' -ForegroundColor Yellow
    try { $c = Invoke-Search $null 500; $sortMode = 'ordenado no script (sem sort no Graph)' }
    catch { Show-GraphError $_; return }
}
Write-Host ("   OK: {0} arquivo(s) acima de {1} MB no total | {2}" -f $c.total, $MinMB, $sortMode) -ForegroundColor Green

$hits = $c.hits | ForEach-Object { $_.resource } | Sort-Object { [int64]$_.size } -Descending | Select-Object -First $Top
$first = $hits | Select-Object -First 1
Write-Host ("   Campos recebidos no 1º resultado: {0}" -f (($first.PSObject.Properties.Name) -join ', '))
Write-Host ("   driveId presente: {0} | id presente: {1}" -f [bool]$first.parentReference.driveId, [bool]$first.id)

# ---------- 3. Versões ----------
$rows = foreach ($h in $hits) {
    $loc = Split-SpoUrl $h.webUrl
    $qtd = $null; $verMB = $null
    if ($h.parentReference.driveId -and $h.id) {
        try {
            $v = Invoke-RestMethod -Headers $headers -Uri "https://graph.microsoft.com/v1.0/drives/$($h.parentReference.driveId)/items/$($h.id)/versions"
            $old = @($v.value | Select-Object -Skip 1)
            $qtd = $old.Count
            $verMB = [math]::Round((($old | Measure-Object -Property size -Sum).Sum) / 1MB, 1)
        }
        catch { $verMB = 'erro'; Show-GraphError $_ }
    }
    [pscustomobject]@{
        Arquivo           = $h.name
        Tamanho_MB        = [math]::Round([double]$h.size / 1MB, 1)
        Versoes_MB        = $verMB
        VersoesAntigas    = $qtd
        Site              = $loc.Site
        Pasta             = $loc.Pasta
    }
}
Write-Host "3. Top $Top maiores arquivos:" -ForegroundColor Cyan
$rows | Format-Table Arquivo, Tamanho_MB, Versoes_MB, VersoesAntigas, Site -AutoSize | Out-Host
$csv = Join-Path $env:TEMP 'maiores_arquivos.csv'
if (Test-Path 'C:\Temp') { $csv = 'C:\Temp\maiores_arquivos.csv' }
$rows | Export-Csv -Path $csv -Delimiter ';' -Encoding utf8BOM -NoTypeInformation
Write-Host "Tabela completa (com a pasta): $csv" -ForegroundColor Green
