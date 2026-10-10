#Requires -Version 7.2
<#
.SYNOPSIS
    Top N arquivos com maior historico de versoes no SharePoint Online (somente leitura).

.DESCRIPTION
    Roda no PowerShell 7 com o modulo PnP.PowerShell. NAO altera nada no tenant.

    Fase 1 (rapida): le todas as bibliotecas de documentos de cada site em lotes de 2000 itens
    e estima o peso das versoes de cada arquivo pelos campos SMTotalSize (tamanho total do item,
    incluindo versoes) e File_x0020_Size (versao atual). Tambem usa tamanho atual x numero da
    versao como segunda estimativa, para nao perder arquivos em que SMTotalSize venha incoerente.

    Fase 2 (exata): para os N maiores candidatos, le as versoes de cada arquivo
    (Get-PnPFileVersion) e soma o tamanho real. O ranking final usa essa medida exata.

    Saidas em -OutDir (fora do OneDrive):
      top_versoes_<data>.csv        Top N exato
      bibliotecas_versoes_<data>.csv  Peso estimado de versoes por biblioteca
      erros_<data>.log              Sites/bibliotecas que nao puderam ser lidos

.PARAMETER Sites
    URLs dos sites a analisar. Padrao: site raiz (https://<TenantName>.sharepoint.com/).

.PARAMETER AllSites
    Analisa todos os sites do tenant com pelo menos -MinSiteMB de uso (exige acesso de admin
    ao Centro de administracao). Sites sem permissao vao para o log e a analise continua.

.EXAMPLE
    pwsh -NoProfile -File .\Get-SPOTopVersoes.ps1 -TenantName contoso -ClientId <id-do-app-pnp>

.EXAMPLE
    pwsh -NoProfile -File .\Get-SPOTopVersoes.ps1 -TenantName contoso -ClientId <id-do-app-pnp> -AllSites -Top 50
.NOTES
    Autor: Pablo Pires de Godoi Silva
    Licença: MIT
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$TenantName,
    [string[]]$Sites = @(),
    [switch]$AllSites,
    [string]$AdminUrl = '',
    [Parameter(Mandatory)] [string]$ClientId,
    [int]$Top = 50,
    [int]$Candidates = 300,
    [int]$MinSiteMB = 100,
    [string]$OutDir = 'C:\Temp\SPO-Versoes'
)

$ErrorActionPreference = 'Stop'
Import-Module PnP.PowerShell -ErrorAction Stop
if (-not $Sites -or $Sites.Count -eq 0) { $Sites = @("https://$TenantName.sharepoint.com/") }
if (-not $AdminUrl) { $AdminUrl = "https://$TenantName-admin.sharepoint.com" }

$stamp = Get-Date -Format 'yyyyMMdd_HHmm'
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$logFile = Join-Path $OutDir "erros_$stamp.log"
$conns = @{}

function Get-Conn([string]$Url) {
    if (-not $conns.ContainsKey($Url)) {
        $conns[$Url] = Connect-PnPOnline -Url $Url -ClientId $ClientId -Interactive -PersistLogin -ReturnConnection
    }
    return $conns[$Url]
}

function Write-Log([string]$Msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Msg
    Add-Content -Path $logFile -Value $line
    Write-Warning $Msg
}

function Get-Bytes($Value) {
    if ($null -eq $Value) { return [int64]0 }
    if ($Value.PSObject.Properties.Name -contains 'LookupId') { return [int64]$Value.LookupId }
    $n = [int64]0
    if ([int64]::TryParse([string]$Value, [ref]$n)) { return $n }
    return [int64]0
}

function Format-MB([int64]$Bytes) { [math]::Round($Bytes / 1MB, 1) }

# ---------- Lista de sites ----------
if ($AllSites) {
    Write-Host 'Lendo a lista de sites no Centro de administração...' -ForegroundColor Cyan
    $admin = Connect-PnPOnline -Url $AdminUrl -ClientId $ClientId -Interactive -PersistLogin -ReturnConnection
    $Sites = Get-PnPTenantSite -Connection $admin |
        Where-Object { $_.StorageUsageCurrent -ge $MinSiteMB -and $_.Template -notlike 'REDIRECT*' } |
        Sort-Object StorageUsageCurrent -Descending |
        Select-Object -ExpandProperty Url
    Write-Host ("{0} sites com {1} MB ou mais." -f $Sites.Count, $MinSiteMB) -ForegroundColor Cyan
}

# ---------- Fase 1: estimativa por biblioteca ----------
$cands = [System.Collections.Generic.List[object]]::new()
$libSummary = [System.Collections.Generic.List[object]]::new()
$s = 0
foreach ($site in $Sites) {
    $s++
    Write-Progress -Id 1 -Activity 'Fase 1: lendo bibliotecas' -Status "$site ($s de $($Sites.Count))" -PercentComplete ($s / $Sites.Count * 100)
    try {
        $c = Get-Conn $site
        $libs = Get-PnPList -Connection $c -Includes RootFolder, BaseTemplate, ItemCount |
            Where-Object { $_.BaseTemplate -eq 101 -and $_.ItemCount -gt 0 -and $_.RootFolder.ServerRelativeUrl -notmatch '/_catalogs/' }
    }
    catch {
        Write-Log "Site $site ignorado: $($_.Exception.Message)"
        continue
    }

    foreach ($lib in $libs) {
        $libCurrent = [int64]0; $libTotal = [int64]0; $libFiles = 0
        try {
            Get-PnPListItem -List $lib -PageSize 2000 -Connection $c `
                -Fields 'FileRef', 'FileLeafRef', 'File_x0020_Size', 'SMTotalSize', '_UIVersionString', 'Modified', 'FSObjType' |
            ForEach-Object {
                $f = $_.FieldValues
                if ([string]$f['FSObjType'] -ne '0') { return }
                $cur = Get-Bytes $f['File_x0020_Size']
                $tot = Get-Bytes $f['SMTotalSize']
                $libFiles++; $libCurrent += $cur
                if ($tot -gt $cur) { $libTotal += $tot } else { $libTotal += $cur }
                $major = 1
                [void][int]::TryParse(([string]$f['_UIVersionString']).Split('.')[0], [ref]$major)
                if ($major -le 1) { return }
                $est1 = [math]::Max([int64]0, $tot - $cur)
                $est2 = $cur * ($major - 1)
                $cands.Add([pscustomobject]@{
                    Site       = $site
                    Biblioteca = $lib.Title
                    FileRef    = [string]$f['FileRef']
                    Arquivo    = [string]$f['FileLeafRef']
                    Versao     = [string]$f['_UIVersionString']
                    Atual      = $cur
                    Estimativa = [math]::Max($est1, $est2)
                    Modificado = $f['Modified']
                })
            }
        }
        catch {
            Write-Log "Biblioteca '$($lib.Title)' em $site ignorada: $($_.Exception.Message)"
        }
        $libSummary.Add([pscustomobject]@{
            Site                   = $site
            Biblioteca             = $lib.Title
            Arquivos               = $libFiles
            ConteudoAtual_GB       = [math]::Round($libCurrent / 1GB, 2)
            TotalComVersoes_GB     = [math]::Round($libTotal / 1GB, 2)
            VersoesEstimadas_GB    = [math]::Round([math]::Max([int64]0, $libTotal - $libCurrent) / 1GB, 2)
        })
        Write-Host ("  {0} / {1}: {2} arquivos" -f $site, $lib.Title, $libFiles)
    }
}
Write-Progress -Id 1 -Activity 'Fase 1' -Completed
Write-Host ("Fase 1 concluída: {0} arquivos com mais de uma versão." -f $cands.Count) -ForegroundColor Cyan

# ---------- Fase 2: medida exata dos maiores candidatos ----------
$topCands = $cands | Sort-Object Estimativa -Descending | Select-Object -First $Candidates
$result = [System.Collections.Generic.List[object]]::new()
$i = 0
foreach ($cand in $topCands) {
    $i++
    Write-Progress -Id 2 -Activity 'Fase 2: medindo versões' -Status $cand.Arquivo -PercentComplete ($i / $topCands.Count * 100)
    try {
        $c = Get-Conn $cand.Site
        $vers = @(Get-PnPFileVersion -Url $cand.FileRef -Connection $c)
        $bytes = [int64]0
        foreach ($v in $vers) {
            $len = if ($v.PSObject.Properties.Name -contains 'Length' -and $v.Length) { [int64]$v.Length } else { [int64]$v.Size }
            $bytes += $len
        }
        $result.Add([pscustomobject]@{
            Site               = $cand.Site
            Biblioteca         = $cand.Biblioteca
            Arquivo            = $cand.Arquivo
            Caminho            = $cand.FileRef
            VersaoAtual        = $cand.Versao
            QtdVersoesAntigas  = $vers.Count
            TamanhoAtual_MB    = Format-MB $cand.Atual
            Versoes_MB         = Format-MB $bytes
            Total_MB           = Format-MB ($bytes + $cand.Atual)
            UltimaModificacao  = $cand.Modificado
        })
    }
    catch {
        Write-Log "Versões de $($cand.FileRef) não lidas: $($_.Exception.Message)"
    }
}
Write-Progress -Id 2 -Activity 'Fase 2' -Completed

# ---------- Saídas ----------
$final = $result | Sort-Object Versoes_MB -Descending | Select-Object -First $Top
$csvTop = Join-Path $OutDir "top_versoes_$stamp.csv"
$csvLib = Join-Path $OutDir "bibliotecas_versoes_$stamp.csv"
$final | Export-Csv -Path $csvTop -Delimiter ';' -Encoding utf8BOM -NoTypeInformation
$libSummary | Sort-Object VersoesEstimadas_GB -Descending | Export-Csv -Path $csvLib -Delimiter ';' -Encoding utf8BOM -NoTypeInformation

$sumTop = ($final | Measure-Object Versoes_MB -Sum).Sum
Write-Host ''
Write-Host ("Top {0}: {1:N1} GB em versões antigas." -f $final.Count, ($sumTop / 1024)) -ForegroundColor Green
$final | Select-Object -First 20 Arquivo, Biblioteca, QtdVersoesAntigas, TamanhoAtual_MB, Versoes_MB | Format-Table -AutoSize | Out-Host
Write-Host "Top completo:      $csvTop"
Write-Host "Por biblioteca:    $csvLib"
if (Test-Path $logFile) { Write-Host "Avisos e erros:    $logFile" -ForegroundColor Yellow }
