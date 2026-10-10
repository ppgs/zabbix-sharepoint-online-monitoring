#Requires -Version 7.4
<#
.SYNOPSIS
    Mantém só as N versões mais recentes de um ou vários arquivos do SharePoint Online
    e remove as demais (lixeira ou exclusão permanente).

.DESCRIPTION
    Rode no PowerShell 7 (pwsh) com o módulo PnP.PowerShell.

    SEGURANÇA
    - Por padrão só SIMULA: lê os arquivos, mostra o que sairia e grava o plano em CSV. Nada é alterado.
    - Só altera com -Execute, depois de você digitar a palavra de confirmação.
    - Por padrão MOVE as versões para a LIXEIRA do site (podem ser restauradas por até 93 dias).
      Com -Permanent exclui de vez (IRREVERSÍVEL).
    - Pula arquivos de sites com Biblioteca de Retenção para Preservação (política de retenção/hold):
      nesses sites as versões seriam preservadas e o espaço não seria liberado.
    - Pula arquivos em check-out.
    - Grava um log CSV de cada versão: simulada, movida para a lixeira, excluída ou com erro.

    "Manter N" conta a versão atual: -Keep 5 mantém a atual e as 4 versões anteriores mais recentes.

    O espaço só volta para a cota quando as versões saem da lixeira (1º e 2º estágio).

    AUTENTICAÇÃO
    - Interativa (padrão): seu login, com o app do PnP.PowerShell (-ClientId). Você precisa ser
      administrador do conjunto de sites dos arquivos.
    - Aplicativo (certificado): -ClientId, -Thumbprint e -Tenant, com o certificado no repositório do
      Windows e permissão SharePoint Sites.FullControl.All no app.

.PARAMETER FileUrl
    URL completa de um ou mais arquivos, por exemplo copiada do link do arquivo no painel do Grafana.

.PARAMETER CsvPath
    CSV com uma coluna de URL (Url, URL, url ou Link), uma URL de arquivo por linha.
    Aceita separador ; ou ,.

.PARAMETER Keep
    Quantas versões manter por arquivo, contando a atual. Padrão: 5.

.PARAMETER Execute
    Aplica a remoção. Sem este parâmetro o script só simula.

.PARAMETER Permanent
    Exclui permanentemente em vez de mover para a lixeira. IRREVERSÍVEL.

.PARAMETER Force
    Não pede a palavra de confirmação (use só em automação conhecida).

.EXAMPLE
    # Simular um arquivo
    pwsh -NoProfile -File .\Remove-SPOFileVersions.ps1 -ClientId <id-do-app-pnp> -FileUrl "https://contoso.sharepoint.com/Shared%20Documents/Manual.pptx"

.EXAMPLE
    # Simular vários arquivos de um CSV
    pwsh -NoProfile -File .\Remove-SPOFileVersions.ps1 -ClientId <id-do-app-pnp> -CsvPath C:\Temp\arquivos.csv

.EXAMPLE
    # Executar (mover para a lixeira) depois de conferir a simulação
    pwsh -NoProfile -File .\Remove-SPOFileVersions.ps1 -ClientId <id-do-app-pnp> -CsvPath C:\Temp\arquivos.csv -Execute

.NOTES
    Autor: Pablo Pires de Godoi Silva
    Licença: MIT
#>
[CmdletBinding(DefaultParameterSetName = 'Urls')]
param(
    [Parameter(ParameterSetName = 'Urls', Mandatory)] [string[]]$FileUrl,
    [Parameter(ParameterSetName = 'Csv', Mandatory)] [string]$CsvPath,
    [ValidateRange(1, 500)] [int]$Keep = 5,
    [Parameter(Mandatory)] [string]$ClientId,
    [string]$Thumbprint,
    [string]$Tenant,
    [switch]$Execute,
    [switch]$Permanent,
    [switch]$Force,
    [string]$LogDir = 'C:\Temp\SPO-Versoes'
)

$ErrorActionPreference = 'Stop'
Import-Module PnP.PowerShell -ErrorAction Stop
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$planCsv = Join-Path $LogDir "versoes_plano_$stamp.csv"
$logCsv = Join-Path $LogDir "versoes_execucao_$stamp.csv"
if ($Thumbprint -and -not $Tenant) { throw 'Com -Thumbprint informe também -Tenant (ex.: contoso.onmicrosoft.com).' }

function Format-GB([double]$Bytes) { [math]::Round($Bytes / 1GB, 2) }
function Get-VersionBytes($v) {
    $len = $null
    try { $len = $v.Length } catch { }
    if ($len -and [int64]$len -gt 0) { return [int64]$len }
    try { return [int64]$v.Size } catch { return [int64]0 }
}

# ---------- 1. Lista de URLs ----------
$urls = @()
if ($PSCmdlet.ParameterSetName -eq 'Csv') {
    $first = Get-Content -Path $CsvPath -TotalCount 1
    $delim = if ($first -match ';') { ';' } else { ',' }
    $rows = Import-Csv -Path $CsvPath -Delimiter $delim
    $col = @('Url', 'URL', 'url', 'Link', 'link') | Where-Object { $rows -and $rows[0].PSObject.Properties.Name -contains $_ } | Select-Object -First 1
    if (-not $col) { throw "O CSV precisa de uma coluna Url (encontradas: $($rows[0].PSObject.Properties.Name -join ', '))." }
    $urls = $rows | ForEach-Object { $_.$col }
}
else {
    $urls = $FileUrl
}
$urls = $urls | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() } | Select-Object -Unique
if (-not $urls) { throw 'Nenhuma URL informada.' }

# ---------- 2. Conexões e retenção por site ----------
$conns = @{}
$holds = @{}
function Get-SiteConnection([string]$SiteUrl) {
    if (-not $conns.ContainsKey($SiteUrl)) {
        if ($Thumbprint) {
            $conns[$SiteUrl] = Connect-PnPOnline -Url $SiteUrl -ClientId $ClientId -Thumbprint $Thumbprint -Tenant $Tenant -ReturnConnection
        }
        else {
            $conns[$SiteUrl] = Connect-PnPOnline -Url $SiteUrl -ClientId $ClientId -Interactive -PersistLogin -ReturnConnection
        }
    }
    return $conns[$SiteUrl]
}
function Test-SiteHold([string]$SiteUrl, $Conn) {
    if (-not $holds.ContainsKey($SiteUrl)) {
        $lists = Get-PnPList -Connection $Conn -Includes RootFolder
        $holds[$SiteUrl] = [bool]($lists | Where-Object { $_.RootFolder.ServerRelativeUrl -match '/PreservationHoldLibrary$' })
    }
    return $holds[$SiteUrl]
}

# ---------- 3. Plano (somente leitura) ----------
$plan = [System.Collections.Generic.List[object]]::new()
$summary = [System.Collections.Generic.List[object]]::new()
$i = 0
foreach ($url in $urls) {
    $i++
    Write-Progress -Activity 'Lendo versões (simulação)' -Status $url -PercentComplete ($i / @($urls).Count * 100)
    $row = [ordered]@{ Arquivo = ''; Site = ''; VersaoAtual = ''; VersoesAntigas = 0; ARemover = 0; GB = 0; Retencao = $false; Status = ''; Url = $url }
    try {
        $u = [uri]$url
        if ($u.Host -notmatch '\.sharepoint\.com$') { throw 'Não é uma URL do SharePoint Online.' }
        $path = [uri]::UnescapeDataString($u.AbsolutePath)
        $path = $path -replace '^/:[a-z]+:/r(?=/)', ''
        $row.Arquivo = Split-Path -Path $path -Leaf
        $siteUrl = if ($path -match '^/(sites|teams)/[^/]+') { "https://$($u.Host)$($Matches[0])" } else { "https://$($u.Host)" }
        $row.Site = $siteUrl -replace '^https://[^/]+', ''
        if (-not $row.Site) { $row.Site = '(raiz)' }

        $c = Get-SiteConnection $siteUrl
        $file = Get-PnPFile -Url $path -AsFileObject -Connection $c
        $row.Arquivo = $file.Name
        $row.VersaoAtual = $file.UIVersionLabel
        $checkOut = 'None'
        try { $checkOut = [string]$file.CheckOutType } catch { }
        $row.Retencao = Test-SiteHold $siteUrl $c

        $versions = @(Get-PnPFileVersion -Url $path -Connection $c | Sort-Object { [int]$_.ID } -Descending)
        $remove = @($versions | Select-Object -Skip ($Keep - 1))
        $row.VersoesAntigas = $versions.Count
        $row.ARemover = $remove.Count
        $bytes = [int64]0
        foreach ($v in $remove) {
            $b = Get-VersionBytes $v
            $bytes += $b
            $plan.Add([pscustomobject]@{
                Data = (Get-Date -Format 's'); Usuario = $env:USERNAME; Arquivo = $file.Name; Site = $row.Site; Caminho = $path
                Versao = $v.VersionLabel; ID = $v.ID; Criada = $v.Created; Tamanho_MB = [math]::Round($b / 1MB, 1)
                Acao = 'Simulado'; Resultado = ''; Erro = ''; _site = $siteUrl
            })
        }
        $row.GB = Format-GB $bytes
        $row.Status = if ($row.Retencao) { 'PULADO: site com retenção' }
                      elseif ($checkOut -ne 'None') { 'PULADO: arquivo em check-out' }
                      elseif ($remove.Count -eq 0) { 'Nada a remover' }
                      else { 'OK' }
    }
    catch {
        $row.Status = "ERRO: $($_.Exception.Message)"
    }
    $summary.Add((New-Object -TypeName psobject -Property $row))
}
Write-Progress -Activity 'Lendo versões (simulação)' -Completed

$okFiles = @($summary | Where-Object Status -eq 'OK')
$okPaths = $okFiles | ForEach-Object { ([uri]::UnescapeDataString(([uri]$_.Url).AbsolutePath)) -replace '^/:[a-z]+:/r(?=/)', '' }
$toDo = @($plan | Where-Object { $okPaths -contains $_.Caminho } | Sort-Object Caminho, ID -Unique)
$plan | Select-Object Data, Usuario, Arquivo, Site, Caminho, Versao, ID, Criada, Tamanho_MB, Acao |
    Export-Csv -Path $planCsv -Delimiter ';' -Encoding utf8BOM -NoTypeInformation

Write-Host ''
Write-Host ("== PLANO: manter {0} versões (a atual + {1}) ==" -f $Keep, ($Keep - 1)) -ForegroundColor Cyan
$summary | Format-Table Arquivo, Site, VersaoAtual, VersoesAntigas, ARemover, GB, Status -AutoSize -Wrap | Out-Host
$totalGB = [math]::Round((($toDo | Measure-Object Tamanho_MB -Sum).Sum) / 1024, 2)
Write-Host ("Arquivos aptos: {0} de {1} | Versões a remover: {2} | Espaço: {3} GB" -f $okFiles.Count, @($urls).Count, $toDo.Count, $totalGB) -ForegroundColor Cyan
Write-Host "Plano detalhado: $planCsv"

if (-not $Execute) {
    Write-Host ''
    Write-Host 'SIMULAÇÃO: nada foi alterado. Para aplicar, rode de novo com -Execute.' -ForegroundColor Green
    return
}
if ($toDo.Count -eq 0) {
    Write-Host 'Nada a fazer.' -ForegroundColor Yellow
    return
}

# ---------- 4. Confirmação ----------
$word = if ($Permanent) { 'EXCLUIR' } else { 'LIXEIRA' }
if ($Permanent) {
    Write-Host ''
    Write-Host "ATENÇÃO: EXCLUSÃO PERMANENTE de $($toDo.Count) versões ($totalGB GB). NÃO há como desfazer." -ForegroundColor Red
}
else {
    Write-Host ''
    Write-Host "Mover $($toDo.Count) versões ($totalGB GB) para a LIXEIRA dos sites. Podem ser restauradas por até 93 dias." -ForegroundColor Yellow
}
if (-not $Force) {
    $answer = Read-Host "Para confirmar, digite $word"
    if ($answer -cne $word) {
        Write-Host 'Cancelado. Nada foi alterado.' -ForegroundColor Green
        return
    }
}

# ---------- 5. Execução (da versão mais antiga para a mais nova) ----------
$done = 0; $fail = 0; $freed = 0.0
$log = [System.Collections.Generic.List[object]]::new()
$n = 0
$activity = if ($Permanent) { 'Excluindo versões' } else { 'Movendo versões para a lixeira' }
foreach ($item in ($toDo | Sort-Object Caminho, { [int]$_.ID })) {
    $n++
    Write-Progress -Activity $activity -Status "$($item.Arquivo) v$($item.Versao)" -PercentComplete ($n / $toDo.Count * 100)
    $entry = $item | Select-Object Data, Usuario, Arquivo, Site, Caminho, Versao, ID, Criada, Tamanho_MB, Acao, Resultado, Erro
    $entry.Data = Get-Date -Format 's'
    $entry.Acao = if ($Permanent) { 'Excluido' } else { 'Lixeira' }
    try {
        $c = Get-SiteConnection $item._site
        if ($Permanent) { Remove-PnPFileVersion -Url $item.Caminho -Identity ([int]$item.ID) -Force -Connection $c }
        else { Remove-PnPFileVersion -Url $item.Caminho -Identity ([int]$item.ID) -Recycle -Force -Connection $c }
        $entry.Resultado = 'OK'; $done++; $freed += [double]$item.Tamanho_MB
    }
    catch {
        $entry.Resultado = 'ERRO'; $entry.Erro = $_.Exception.Message; $fail++
    }
    $log.Add($entry)
}
Write-Progress -Activity $activity -Completed
$log | Export-Csv -Path $logCsv -Delimiter ';' -Encoding utf8BOM -NoTypeInformation

Write-Host ''
Write-Host ("Concluído: {0} versões {1} ({2} GB) | Erros: {3}" -f $done, $(if ($Permanent) { 'excluídas' } else { 'movidas para a lixeira' }), [math]::Round($freed / 1024, 2), $fail) -ForegroundColor $(if ($fail) { 'Yellow' } else { 'Green' })
Write-Host "Log da execução: $logCsv"
if (-not $Permanent) {
    Write-Host 'Para desfazer: lixeira do site → selecionar as versões → Restaurar.'
    Write-Host 'O espaço só volta para a cota quando as versões saírem da lixeira (1º e 2º estágio).'
}
