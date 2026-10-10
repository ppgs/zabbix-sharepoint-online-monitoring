#Requires -Version 7.2
<#
.SYNOPSIS
    Testa se um app SOMENTE LEITURA com certificado consegue ler as lixeiras (1º e 2º estágio)
    de TODOS os sites, como o Zabbix vai precisar. Nada é excluído, restaurado ou alterado.

.DESCRIPTION
    Rode no PowerShell 7 (pwsh), no mesmo computador onde o certificado foi criado.
    - Lista os sites pelo Graph com o app do Zabbix (pede o segredo dele).
    - Lê as lixeiras de cada site pela API do SharePoint com o app novo
      registrado para o Zabbix (certificado, permissão SharePoint Sites.FullControl.All de aplicativo).
    - Separa 1º e 2º estágio, soma GB e guarda os 200 maiores itens.

    Saídas em -OutDir: lixeira_app_sites_<data>.csv, lixeira_app_top200_<data>.csv, lixeira_app_erros_<data>.log
.NOTES
    Autor: Pablo Pires de Godoi Silva
    Licença: MIT
#>
param(
    [Parameter(Mandatory)] [string]$AppClientId,
    [Parameter(Mandatory)] [string]$CertThumbprint,
    [Parameter(Mandatory)] [string]$TenantId,
    [Parameter(Mandatory)] [string]$Tenant,
    [Parameter(Mandatory)] [string]$GraphClientId,
    [int]$Top = 200,
    [string]$OutDir = 'C:\Temp\SPO-Lixeira'
)

$ErrorActionPreference = 'Stop'
Import-Module PnP.PowerShell -ErrorAction Stop
$stamp = Get-Date -Format 'yyyyMMdd_HHmm'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$logFile = Join-Path $OutDir "lixeira_app_erros_$stamp.log"
function Write-Log([string]$Msg) {
    Add-Content -Path $logFile -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Msg)
    Write-Host "   $Msg" -ForegroundColor Red
}
function Format-GB([double]$Bytes) { [math]::Round($Bytes / 1GB, 2) }

$topList = [System.Collections.Generic.List[object]]::new()
function Add-Top($Obj) {
    $topList.Add($Obj)
    if ($topList.Count -ge ($Top * 3)) {
        $keep = @($topList | Sort-Object Bytes -Descending | Select-Object -First $Top)
        $topList.Clear(); foreach ($k in $keep) { $topList.Add($k) }
    }
}

# ---------- Lista de sites (Graph, app do Zabbix) ----------
$secure = Read-Host -Prompt 'Client secret do app do Zabbix (só para listar os sites)' -AsSecureString
$plain = ConvertFrom-SecureString -SecureString $secure -AsPlainText
try {
    $tok = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
        client_id = $GraphClientId; client_secret = $plain
        scope = 'https://graph.microsoft.com/.default'; grant_type = 'client_credentials'
    }
}
finally { Remove-Variable plain -ErrorAction SilentlyContinue }
$headers = @{ Authorization = "Bearer $($tok.access_token)" }
$sites = [System.Collections.Generic.List[string]]::new()
$url = 'https://graph.microsoft.com/v1.0/sites/getAllSites?$select=webUrl&$top=999'
while ($url) {
    $r = Invoke-RestMethod -Headers $headers -Uri $url
    foreach ($s in $r.value) { if ($s.webUrl -notmatch '-my\.sharepoint\.com') { $sites.Add($s.webUrl) } }
    $url = $r.'@odata.nextLink'
}
Write-Host ("Sites: {0}" -f $sites.Count) -ForegroundColor Cyan

# ---------- Lixeiras (app novo, certificado) ----------
$summary = [System.Collections.Generic.List[object]]::new()
$i = 0
$sw = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($site in $sites) {
    $i++
    Write-Progress -Activity 'Lendo lixeiras (app)' -Status "$site ($i de $($sites.Count))" -PercentComplete ($i / $sites.Count * 100)
    $rel = $site -replace '^https://[^/]+', ''
    if (-not $rel -or $rel -eq '/') { $rel = '(raiz)' }
    $row = [ordered]@{ Site = $rel; Est1_Itens = $null; Est1_GB = $null; Est2_Itens = $null; Est2_GB = $null; Erro = '' }
    try {
        $c = Connect-PnPOnline -Url $site -ClientId $AppClientId -Thumbprint $CertThumbprint -Tenant $Tenant -ReturnConnection
        foreach ($stage in 1, 2) {
            try {
                $items = if ($stage -eq 1) { @(Get-PnPRecycleBinItem -FirstStage -RowLimit 1000000 -Connection $c) }
                         else { @(Get-PnPRecycleBinItem -SecondStage -RowLimit 1000000 -Connection $c) }
                $bytes = [int64]0
                foreach ($it in $items) {
                    $bytes += [int64]$it.Size
                    Add-Top ([pscustomobject]@{
                        Estagio = $stage; Arquivo = $it.LeafName; Site = $rel; Pasta = $it.DirName
                        Tamanho_MB = [math]::Round([double]$it.Size / 1MB, 1); Bytes = [int64]$it.Size
                        Tipo = [string]$it.ItemType; ExcluidoEm = $it.DeletedDate
                    })
                }
                $row["Est$($stage)_Itens"] = $items.Count
                $row["Est$($stage)_GB"] = Format-GB $bytes
            }
            catch { $row.Erro = ($row.Erro + " Estágio $($stage): " + $_.Exception.Message).Trim(); Write-Log "$site estágio $($stage): $($_.Exception.Message)" }
        }
    }
    catch { $row.Erro = 'Conexão: ' + $_.Exception.Message; Write-Log "$site conexão: $($_.Exception.Message)" }
    $summary.Add([pscustomobject]$row)
}
Write-Progress -Activity 'Lendo lixeiras (app)' -Completed
$sw.Stop()

$csvSites = Join-Path $OutDir "lixeira_app_sites_$stamp.csv"
$csvTop = Join-Path $OutDir "lixeira_app_top200_$stamp.csv"
$summary | Sort-Object { [double]$_.Est1_GB + [double]$_.Est2_GB } -Descending | Export-Csv -Path $csvSites -Delimiter ';' -Encoding utf8BOM -NoTypeInformation
$topFinal = $topList | Sort-Object Bytes -Descending | Select-Object -First $Top
$topFinal | Select-Object Estagio, Arquivo, Site, Pasta, Tamanho_MB, Tipo, ExcluidoEm | Export-Csv -Path $csvTop -Delimiter ';' -Encoding utf8BOM -NoTypeInformation

function Sum([string]$Prop) { [math]::Round((($summary | Where-Object { $null -ne $_.$Prop } | Measure-Object -Property $Prop -Sum).Sum), 2) }
Write-Host ''
Write-Host '== RESUMO (me envie) ==' -ForegroundColor Cyan
[pscustomobject]@{
    Sites = $summary.Count
    Sites_lidos_2_estagios = @($summary | Where-Object { $null -ne $_.Est1_Itens -and $null -ne $_.Est2_Itens }).Count
    Sites_com_erro = @($summary | Where-Object Erro).Count
    Est1_Itens = Sum 'Est1_Itens'; Est1_GB = Sum 'Est1_GB'
    Est2_Itens = Sum 'Est2_Itens'; Est2_GB = Sum 'Est2_GB'
    Tempo_min = [math]::Round($sw.Elapsed.TotalMinutes, 1)
} | Format-List | Out-Host
$summary | Sort-Object { [double]$_.Est1_GB + [double]$_.Est2_GB } -Descending | Select-Object -First 15 |
    Format-Table Site, Est1_Itens, Est1_GB, Est2_Itens, Est2_GB -AutoSize | Out-Host
$errs = @($summary | Where-Object Erro | Select-Object -First 3)
if ($errs) { Write-Host 'Exemplos de erro:' -ForegroundColor Yellow; $errs | Format-Table Site, Erro -Wrap | Out-Host }
Write-Host "Resumo por site: $csvSites"
Write-Host "Top $Top itens:  $csvTop"
