#Requires -Version 7.2
<#
.SYNOPSIS
    Lê as lixeiras (1º e 2º estágio) de TODOS os sites do SharePoint. SOMENTE LEITURA.

.DESCRIPTION
    Rode no PowerShell 7 (pwsh). Nada é excluído, restaurado ou alterado.

    1. Lista todos os sites pelo Graph (/sites/getAllSites, app do Zabbix). OneDrives pessoais
       ficam de fora (não contam na cota do SharePoint), a não ser com -IncludeOneDrive.
    2. Graph beta /sites/{id}/recycleBin/items em cada site (app do Zabbix): quantidade e tamanho.
    3. PnP Get-PnPRecycleBinItem -FirstStage / -SecondStage em cada site (seu login, app
       "PnP PowerShell"): referência separada por estágio.

    Comparando 2 e 3 sabemos se o Graph traz os dois estágios juntos ou só o 1º e se os
    tamanhos batem. Isso decide como o Zabbix vai coletar.

    Saídas em -OutDir (fora do OneDrive):
      lixeira_sites_<data>.csv     Resumo por site (Graph x PnP 1º/2º estágio)
      lixeira_top200_<data>.csv    200 maiores itens das lixeiras de todos os sites (PnP, com estágio)
      lixeira_erros_<data>.log     Sites que não puderam ser lidos

.PARAMETER MaxItems
    Limite de itens lidos por site no Graph (proteção para lixeiras muito grandes).

.PARAMETER SkipPnP
    Só a parte do Graph (mais rápido, sem login interativo, sem separar estágios).

.EXAMPLE
    pwsh -NoProfile -File .\Test-SPORecycleBin.ps1 -TenantId <id-do-locatario> -ClientId <id-do-app> -PnPClientId <id-do-app-pnp>

.EXAMPLE
    pwsh -NoProfile -File .\Test-SPORecycleBin.ps1 -TenantId <id-do-locatario> -ClientId <id-do-app> -SkipPnP
.NOTES
    Autor: Pablo Pires de Godoi Silva
    Licença: MIT
#>
param(
    [Parameter(Mandatory)] [string]$TenantId,
    [Parameter(Mandatory)] [string]$ClientId,
    [string]$PnPClientId = '',
    [int]$MaxItems = 50000,
    [int]$Top = 200,
    [switch]$SkipPnP,
    [switch]$IncludeOneDrive,
    [string]$OutDir = 'C:\Temp\SPO-Lixeira'
)

$ErrorActionPreference = 'Stop'
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$logFile = Join-Path $OutDir "lixeira_erros_$stamp.log"

function Write-Log([string]$Msg) {
    Add-Content -Path $logFile -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Msg)
    Write-Host "   $Msg" -ForegroundColor Red
}
function Get-ErrText($Err) { if ($Err.ErrorDetails.Message) { $Err.ErrorDetails.Message } else { $Err.Exception.Message } }
function Format-GB([double]$Bytes) { [math]::Round($Bytes / 1GB, 2) }

# Mantém só os N maiores itens (evita guardar centenas de milhares de itens na memória)
$topList = [System.Collections.Generic.List[object]]::new()
function Add-Top($Obj) {
    $topList.Add($Obj)
    if ($topList.Count -ge ($Top * 3)) {
        $keep = @($topList | Sort-Object Bytes -Descending | Select-Object -First $Top)
        $topList.Clear(); foreach ($k in $keep) { $topList.Add($k) }
    }
}

# ---------------- Token do app do Zabbix ----------------
$secure = Read-Host -Prompt 'Client secret (Valor do segredo do app do Zabbix)' -AsSecureString
$plain = ConvertFrom-SecureString -SecureString $secure -AsPlainText
try {
    $tok = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
        client_id = $ClientId; client_secret = $plain
        scope = 'https://graph.microsoft.com/.default'; grant_type = 'client_credentials'
    }
}
catch { Write-Host "Token: FALHOU $(Get-ErrText $_)" -ForegroundColor Red; return }
finally { Remove-Variable plain -ErrorAction SilentlyContinue }
$headers = @{ Authorization = "Bearer $($tok.access_token)" }
Write-Host 'Token: OK' -ForegroundColor Green

# ---------------- 1. Todos os sites ----------------
$sites = [System.Collections.Generic.List[object]]::new()
$url = 'https://graph.microsoft.com/v1.0/sites/getAllSites?$select=id,webUrl,displayName&$top=999'
while ($url) {
    $r = Invoke-RestMethod -Headers $headers -Uri $url
    foreach ($s in $r.value) {
        if (-not $IncludeOneDrive -and $s.webUrl -match '-my\.sharepoint\.com') { continue }
        $sites.Add($s)
    }
    $url = $r.'@odata.nextLink'
}
Write-Host ("1. Sites encontrados: {0}" -f $sites.Count) -ForegroundColor Cyan

# ---------------- 2 e 3. Lixeiras por site ----------------
if (-not $SkipPnP) {
    if (-not $PnPClientId) { throw 'Informe -PnPClientId (app do PnP.PowerShell para login interativo) ou use -SkipPnP.' }
    Import-Module PnP.PowerShell -ErrorAction Stop
}
$summary = [System.Collections.Generic.List[object]]::new()
$i = 0
$swAll = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($s in $sites) {
    $i++
    Write-Progress -Activity 'Lendo lixeiras' -Status "$($s.webUrl) ($i de $($sites.Count))" -PercentComplete ($i / $sites.Count * 100)
    $row = [ordered]@{ Site = ($s.webUrl -replace '^https://[^/]+', ''); Graph_Itens = $null; Graph_GB = $null; Graph_Completo = $null
        PnP_1_Itens = $null; PnP_1_GB = $null; PnP_2_Itens = $null; PnP_2_GB = $null; Erro = '' }
    if (-not $row.Site) { $row.Site = '(raiz)' }

    # Graph beta
    $gCount = 0; $gBytes = [int64]0
    $url = "https://graph.microsoft.com/beta/sites/$($s.id)/recycleBin/items?`$top=999"
    try {
        while ($url -and $gCount -lt $MaxItems) {
            $r = Invoke-RestMethod -Headers $headers -Uri $url
            foreach ($v in $r.value) { $gCount++; $gBytes += [int64]$v.size }
            $url = $r.'@odata.nextLink'
        }
        $row.Graph_Itens = $gCount; $row.Graph_GB = Format-GB $gBytes; $row.Graph_Completo = (-not $url)
    }
    catch { $row.Erro = 'Graph: ' + (Get-ErrText $_); Write-Log "$($s.webUrl) Graph: $(Get-ErrText $_)" }

    # PnP (separa estágios)
    if (-not $SkipPnP) {
        try {
            $c = Connect-PnPOnline -Url $s.webUrl -ClientId $PnPClientId -Interactive -PersistLogin -ReturnConnection
            foreach ($stage in 1, 2) {
                $items = if ($stage -eq 1) { @(Get-PnPRecycleBinItem -FirstStage -Connection $c) } else { @(Get-PnPRecycleBinItem -SecondStage -Connection $c) }
                $bytes = [int64]0
                foreach ($it in $items) {
                    $bytes += [int64]$it.Size
                    Add-Top ([pscustomobject]@{
                        Estagio   = $stage
                        Arquivo   = $it.LeafName
                        Site      = $row.Site
                        Pasta     = $it.DirName
                        Tamanho_MB = [math]::Round([double]$it.Size / 1MB, 1)
                        Bytes     = [int64]$it.Size
                        Tipo      = [string]$it.ItemType
                        ExcluidoEm = $it.DeletedDate
                    })
                }
                if ($stage -eq 1) { $row.PnP_1_Itens = $items.Count; $row.PnP_1_GB = Format-GB $bytes }
                else { $row.PnP_2_Itens = $items.Count; $row.PnP_2_GB = Format-GB $bytes }
            }
        }
        catch { $row.Erro = ($row.Erro + ' PnP: ' + $_.Exception.Message).Trim(); Write-Log "$($s.webUrl) PnP: $($_.Exception.Message)" }
    }
    $summary.Add([pscustomobject]$row)
}
Write-Progress -Activity 'Lendo lixeiras' -Completed
$swAll.Stop()

# ---------------- Saídas ----------------
$csvSites = Join-Path $OutDir "lixeira_sites_$stamp.csv"
$csvTop = Join-Path $OutDir "lixeira_top200_$stamp.csv"
$summary | Sort-Object { [double]$_.Graph_GB } -Descending | Export-Csv -Path $csvSites -Delimiter ';' -Encoding utf8BOM -NoTypeInformation
$topFinal = $topList | Sort-Object Bytes -Descending | Select-Object -First $Top
$topFinal | Select-Object Estagio, Arquivo, Site, Pasta, Tamanho_MB, Tipo, ExcluidoEm |
    Export-Csv -Path $csvTop -Delimiter ';' -Encoding utf8BOM -NoTypeInformation

function Sum([string]$Prop) { [math]::Round((($summary | Where-Object { $null -ne $_.$Prop } | Measure-Object -Property $Prop -Sum).Sum), 2) }
Write-Host ''
Write-Host '== RESUMO GERAL (me envie esta parte) ==' -ForegroundColor Cyan
[pscustomobject]@{
    Sites               = $summary.Count
    Sites_com_erro      = @($summary | Where-Object Erro).Count
    Graph_Itens         = Sum 'Graph_Itens'
    Graph_GB            = Sum 'Graph_GB'
    Graph_sites_parciais = @($summary | Where-Object { $_.Graph_Completo -eq $false }).Count
    PnP_1_Itens         = Sum 'PnP_1_Itens'
    PnP_1_GB            = Sum 'PnP_1_GB'
    PnP_2_Itens         = Sum 'PnP_2_Itens'
    PnP_2_GB            = Sum 'PnP_2_GB'
    Tempo_min           = [math]::Round($swAll.Elapsed.TotalMinutes, 1)
} | Format-List | Out-Host

Write-Host '== 15 sites com mais lixeira ==' -ForegroundColor Cyan
$summary | Sort-Object { [double]$_.Graph_GB + [double]$_.PnP_2_GB } -Descending | Select-Object -First 15 |
    Format-Table Site, Graph_Itens, Graph_GB, PnP_1_Itens, PnP_1_GB, PnP_2_Itens, PnP_2_GB -AutoSize | Out-Host

if ($topFinal) {
    Write-Host '== 10 maiores itens das lixeiras ==' -ForegroundColor Cyan
    $topFinal | Select-Object -First 10 | Format-Table Estagio, Tamanho_MB, Arquivo, Site -AutoSize | Out-Host
}
Write-Host "Resumo por site: $csvSites"
Write-Host "Top $Top itens:  $csvTop"
if (Test-Path $logFile) { Write-Host "Erros:           $logFile" -ForegroundColor Yellow }
