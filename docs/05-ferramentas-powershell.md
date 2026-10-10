# 5. Ferramentas PowerShell (validação, análise e limpeza)

Scripts em [tools/](../tools) para **validar as permissões antes de configurar o Zabbix** e para **analisar** o armazenamento com mais detalhe. Todos são **somente leitura**, exceto o `Remove-SPOFileVersions.ps1`, que só altera algo com `-Execute` e confirmação.

## Pré-requisitos

- **PowerShell 7.4 ou superior** (`pwsh`), exigido pelo PnP.PowerShell 3. Os scripts não rodam no Windows PowerShell 5.1.
- **Para os scripts com PnP:** o módulo PnP.PowerShell instalado para todos os usuários. Não instale módulos em pastas sincronizadas pelo OneDrive.
```powershell
Install-Module PnP.PowerShell -Scope AllUsers
```
- **App próprio para o PnP (login interativo):** desde 2024 o PnP não tem mais um app multi-tenant compartilhado, então é preciso registrar um app do PnP no seu tenant:
```powershell
Register-PnPEntraIDAppForInteractiveLogin -ApplicationName "PnP PowerShell" -Tenant contoso.onmicrosoft.com -Interactive
```
- **Arquivos baixados da internet:** desbloqueie antes de rodar.
```powershell
Unblock-File .\tools\*.ps1
```

Os scripts pedem o segredo do cliente com `Read-Host -AsSecureString`. Ele não fica salvo e não aparece na tela.

## Test-SPOBiggestFiles.ps1

Valida a **Pesquisa do Microsoft 365** e a leitura de **versões** com o mesmo app do Zabbix (Graph `Sites.Read.All`).

```powershell
pwsh -NoProfile -File .\tools\Test-SPOBiggestFiles.ps1 -TenantId <id-do-locatario> -ClientId <id-do-app> -MinMB 200 -Top 20
```

O script mostra os maiores arquivos com o tamanho, o peso das versões antigas e o site, e exporta `maiores_arquivos.csv` para `C:\Temp`, ou para `%TEMP%` se essa pasta não existir.

## Test-SPORecycleBin.ps1

Compara a lixeira lida pelo **Graph** (app do Zabbix) com a lida pelo **PnP** com **o seu login**, separando 1º e 2º estágio. Serve para entender o que cada caminho enxerga.

```powershell
pwsh -NoProfile -File .\tools\Test-SPORecycleBin.ps1 -TenantId <id-do-locatario> -ClientId <id-do-app> -PnPClientId <id-do-app-pnp>
```

- **Graph:** devolve **0 itens** com permissão de aplicativo. É esperado, e é o motivo de o template usar a API do SharePoint.
- **PnP:** só lê os sites em que **a sua conta** é administradora do conjunto de sites. Nos demais aparece "unauthorized".
- Use `-SkipPnP` para rodar só a parte do Graph.

## Test-SPORecycleBinApp.ps1

Valida o **módulo de lixeiras com certificado** antes de ativá-lo no Zabbix: lê o 1º e o 2º estágio de **todos** os sites como aplicativo.

1. Para usar no Windows o certificado gerado com OpenSSL, crie um PFX (bash) e importe no repositório do usuário (PowerShell 7):
```bash
openssl pkcs12 -export -inkey spo-lixeiras.key -in spo-lixeiras.crt -out spo-lixeiras.pfx
```
```powershell
Import-PfxCertificate -FilePath .\spo-lixeiras.pfx -CertStoreLocation Cert:\CurrentUser\My
```
2. Rode o teste:
```powershell
pwsh -NoProfile -File .\tools\Test-SPORecycleBinApp.ps1 -AppClientId <id-do-app> -CertThumbprint <impressao-digital> -TenantId <id-do-locatario> -Tenant contoso.onmicrosoft.com -GraphClientId <id-do-app>
```
3. **O que esperar:** `Sites_lidos_2_estagios` igual ao total de sites. Com "Access denied" no 2º estágio, falta `SharePoint → Sites.FullControl.All`.
4. Depois do teste, **remova** o certificado do repositório do Windows e apague o `.pfx`.

## Get-SPOTopVersoes.ps1

Relatório **exato** dos arquivos com maior histórico de versões, por biblioteca. Usa PnP com o seu login; você precisa ser administrador do conjunto de sites nos sites analisados.

```powershell
pwsh -NoProfile -File .\tools\Get-SPOTopVersoes.ps1 -TenantName contoso -ClientId <id-do-app-pnp>
```
```powershell
pwsh -NoProfile -File .\tools\Get-SPOTopVersoes.ps1 -TenantName contoso -ClientId <id-do-app-pnp> -AllSites -Top 50
```

Saídas em `C:\Temp\SPO-Versoes`:
- `top_versoes_<data>.csv`: o top N com o tamanho exato das versões;
- `bibliotecas_versoes_<data>.csv`: estimativa por biblioteca;
- `erros_<data>.log`: o que não pôde ser lido.

## Remove-SPOFileVersions.ps1

Mantém só as **N versões mais recentes** (padrão 5, contando a atual) de um ou vários arquivos. **Simula por padrão**; com `-Execute` move as versões excedentes para a lixeira do site, e com `-Permanent` exclui de vez (irreversível). Guia completo em [07-limpeza-de-versoes.md](07-limpeza-de-versoes.md).

```powershell
pwsh -NoProfile -File .\tools\Remove-SPOFileVersions.ps1 -ClientId <id-do-app-pnp> -FileUrl "https://contoso.sharepoint.com/sites/Financeiro/Shared%20Documents/Fechamento.xlsx"
```

> Os CSVs gerados têm nomes de arquivos e pastas internos. **Não** os coloque no repositório; o `.gitignore` já exclui `*.csv`.

---

<sub>Autor: Pablo Pires de Godoi Silva · Licença MIT</sub>
