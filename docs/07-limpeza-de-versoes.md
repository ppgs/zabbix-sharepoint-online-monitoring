# 7. Limpeza de versões com PowerShell

O script [`tools/Remove-SPOFileVersions.ps1`](../tools/Remove-SPOFileVersions.ps1) mantém só as **N versões mais recentes** de **um arquivo** ou de **vários arquivos** e remove as demais. O template e o painel continuam **somente leitura**: eles mostram onde está o espaço, e quem limpa é o script, rodado por um administrador.

| Modo | Como rodar | O que acontece | Dá para desfazer? |
|---|---|---|---|
| **Simulação** (padrão) | sem `-Execute` | Lê os arquivos, mostra o que sairia e grava o plano em CSV. Nada é alterado. | Nada para desfazer |
| **Lixeira** | `-Execute` e digitar `LIXEIRA` | Move as versões excedentes para a **lixeira do site**. | **Sim**, pela lixeira do site, por até 93 dias |
| **Exclusão permanente** | `-Execute -Permanent` e digitar `EXCLUIR` | Exclui as versões de vez. | **Não. Irreversível.** |

- `-Keep 5` (padrão) **conta a versão atual**: mantém a atual e as 4 anteriores mais recentes.
- **O espaço não volta na hora.** No modo lixeira, ele só sai da cota quando as versões saem da lixeira: esvaziando o 1º e o 2º estágio, ou depois de 93 dias. Esvaziar a lixeira é irreversível e fica fora do script.
- O script **pula** arquivos de sites com **Biblioteca de Retenção para Preservação** (política de retenção ou hold), porque nesses sites as versões seriam preservadas e o espaço não seria liberado. Também pula arquivos em **check-out**.
- Toda execução grava um **log CSV** com cada versão: arquivo, versão, ID, data, tamanho, ação, resultado e erro.

## Pré-requisitos

- **PowerShell 7.4 ou superior** (`pwsh`) e o módulo **PnP.PowerShell**, instalado para todos os usuários e fora de pastas sincronizadas pelo OneDrive:
```powershell
Install-Module PnP.PowerShell -Scope AllUsers
```
- **App do PnP no seu tenant**, para o login interativo (veja a [seção de pré-requisitos das ferramentas](05-ferramentas-powershell.md#pré-requisitos)). Guarde o **ID do aplicativo (cliente)**: ele vai no `-ClientId`.
- **Permissão:**
  - **Login interativo (padrão):** a sua conta precisa ser **administradora do conjunto de sites** dos arquivos. Ser administrador do SharePoint não basta.
  - **Aplicativo com certificado:** `-Thumbprint` e `-Tenant`, com o certificado no repositório do Windows e a permissão **SharePoint `Sites.FullControl.All`** no app.
- **Desbloquear o arquivo** se ele veio da internet:
```powershell
Unblock-File .\tools\Remove-SPOFileVersions.ps1
```

## Onde pegar as URLs

- **Painel do Grafana**, tabela **Maiores históricos de versões**: clique com o botão direito no **nome do arquivo** → **Copiar endereço do link**.
- **SharePoint:** abra a pasta, clique nos **…** do arquivo → **Copiar link** do tipo "Pessoas com acesso existente", ou use **Detalhes → Caminho**.
- **Vários arquivos:** monte um CSV com uma coluna `Url`, um arquivo por linha. Separador `;` ou `,`.

```text
Url
https://contoso.sharepoint.com/sites/Financeiro/Shared%20Documents/Relatorios/Fechamento.xlsx
https://contoso.sharepoint.com/sites/Marketing/Shared%20Documents/Videos/Campanha.pptx
```

## Como usar

Todos os comandos rodam no **PowerShell 7**, na pasta do repositório.

1. **Simule um arquivo:**
```powershell
pwsh -NoProfile -File .\tools\Remove-SPOFileVersions.ps1 -ClientId <id-do-app-pnp> -FileUrl "https://contoso.sharepoint.com/sites/Financeiro/Shared%20Documents/Relatorios/Fechamento.xlsx"
```
2. **Ou simule vários arquivos:** passe várias URLs separadas por vírgula em `-FileUrl`, ou use o CSV:
```powershell
pwsh -NoProfile -File .\tools\Remove-SPOFileVersions.ps1 -ClientId <id-do-app-pnp> -CsvPath C:\Temp\arquivos.csv
```
3. **Confira o resultado:** a tabela mostra, por arquivo, a versão atual, as versões antigas, quantas sairiam, o espaço e o status (`OK`, `PULADO: site com retenção`, `PULADO: arquivo em check-out`, `Nada a remover` ou `ERRO`). O plano detalhado fica em `C:\Temp\SPO-Versoes\versoes_plano_<data>.csv`.
4. **Mova para a lixeira:** repita o mesmo comando com `-Execute` e digite `LIXEIRA` quando pedir.
```powershell
pwsh -NoProfile -File .\tools\Remove-SPOFileVersions.ps1 -ClientId <id-do-app-pnp> -CsvPath C:\Temp\arquivos.csv -Execute
```
5. **Confira o log:** `C:\Temp\SPO-Versoes\versoes_execucao_<data>.csv`. As linhas com `ERRO` mostram o motivo; rode de novo só esses arquivos.
6. O painel do Grafana se atualiza na próxima coleta, ou com **Executar agora** no item `SPO: Pesquisa dos maiores arquivos`.

**Outras opções:**

| Parâmetro | Uso |
|---|---|
| `-Keep 10` | Mantém 10 versões em vez de 5. |
| `-Permanent` | Exclui de vez em vez de mover para a lixeira. **Irreversível.** Pede a palavra `EXCLUIR`. |
| `-Thumbprint <impressao-digital> -Tenant contoso.onmicrosoft.com` | Roda como aplicativo, com certificado, em vez do seu login. |
| `-LogDir D:\Logs\SPO` | Outra pasta para o plano e o log. Padrão: `C:\Temp\SPO-Versoes`. |
| `-Force` | Não pede a palavra de confirmação. Use só em automação já testada. |

## Como desfazer (modo lixeira)

1. Abra a **lixeira do site** do arquivo: `https://<tenant>.sharepoint.com/sites/<site>/_layouts/15/RecycleBin.aspx`.
2. Filtre pelo nome do arquivo. As versões aparecem como itens separados.
3. Selecione → **Restaurar**. Se já saíram do 1º estágio, procure na **lixeira do segundo estágio**, no fim da página.

## Antes de usar em produção

- **Retenção:** verifique as políticas de retenção e os holds no Purview, por exemplo com `Get-RetentionCompliancePolicy` no Security & Compliance PowerShell. O script detecta a Biblioteca de Retenção para Preservação do site, mas uma política recém-criada pode ainda não ter gerado essa biblioteca.
- **Donos do conteúdo:** combine com as áreas donas dos arquivos antes de remover versões.
- **Teste pequeno primeiro:** rode em um arquivo, confira a lixeira do site e só depois passe para a lista.
- **Cópia de segurança:** se alguma versão antiga precisar ser guardada, baixe-a antes pelo **Histórico de versões** do arquivo.

---

<sub>Autor: Pablo Pires de Godoi Silva · Licença MIT</sub>
