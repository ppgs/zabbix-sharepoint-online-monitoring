# 2. Zabbix: template, host e macros

Testado no **Zabbix 7.4** (server e frontend em Docker). Todas as chamadas às APIs da Microsoft saem do **Zabbix server**, ou do **proxy** se o host for monitorado por proxy.

---

## 1. Pré-requisitos

- **Saída HTTPS (443)** do server/proxy para:
  - `login.microsoftonline.com` (tokens);
  - `graph.microsoft.com` (relatórios, sites, drives, pesquisa);
  - `*.office.com` (os relatórios de uso redirecionam o download do CSV para um domínio `*.office.com`);
  - `<tenant>.sharepoint.com` (lixeiras, se ativadas).
- **Proxy HTTP**, se a saída passar por um: preencha `{$SPO.PROXY}`, por exemplo `http://proxy.exemplo.local:3128`.
- **DNS e hora corretos** no server/proxy. Relógio errado invalida os tokens; use chrony/NTP.
- **Módulo de lixeiras:** o binário do Zabbix precisa ter suporte a criptografia (OpenSSL ou GnuTLS) para a função `sign()`. As imagens oficiais em Docker já têm.
- **Timeout:** os itens Script usam timeouts de até 600 s (macros `*.TIMEOUT`). O máximo do Zabbix 7.x para um item é 10 min.

## 2. Importar o template

1. **Coleta de dados → Modelos → Importar**.
2. Selecione `zabbix/template_sharepoint_online_graph.yaml`.
3. Marque **Criar novo** e **Atualizar existente** para *Modelos*, *Itens*, *Descoberta* e *Triggers*.
4. **Não marque "Excluir ausentes"** ao atualizar uma versão já em uso. Isso apagaria itens que você tenha criado à parte.
5. Clique em **Importar**. O template aparece como **SharePoint Online by Microsoft Graph**, no grupo *Templates/Applications*.

## 3. Criar o host

1. **Coleta de dados → Hosts → Criar host**.
2. **Nome do host:** por exemplo `SharePoint Online - contoso`. O painel do Grafana deixa escolher o host, então o nome pode ser qualquer um.
3. **Templates:** `SharePoint Online by Microsoft Graph`.
4. **Grupos de hosts:** por exemplo `Microsoft 365` (crie se não existir).
5. **Interfaces:** nenhuma. Os itens são Script e dependentes.
6. **Monitorado por:** *Servidor*, ou o *Proxy* que tem saída para a internet.
7. Na aba **Macros**, preencha as obrigatórias (próxima seção) e clique em **Adicionar**.

## 4. Macros

Defina as macros **no host**, não no template, para não perder os valores ao atualizar o template. As obrigatórias:

| Macro | Valor |
|---|---|
| `{$SPO.TENANT.ID}` | ID do diretório (locatário) do app. |
| `{$SPO.CLIENT.ID}` | ID do aplicativo (cliente). |
| `{$SPO.CLIENT.SECRET}` | Valor do segredo do cliente. Tipo **Texto secreto**. |
| `{$SPO.TENANT.QUOTA.GB}` | Cota total de armazenamento do tenant em GB. Veja como descobrir logo abaixo. |

**Como descobrir a cota:**
- No **Centro de administração do SharePoint**, menu *Sites → Sites ativos*, aparece o armazenamento total disponível.
- No PowerShell (módulo SharePoint Online, Windows PowerShell 5.1):
```powershell
Connect-SPOService -Url https://contoso-admin.sharepoint.com
```
```powershell
[math]::Round((Get-SPOTenant).StorageQuota / 1024)
```

Opcionais mais usadas:
- `{$SPO.FOLDERS.SITES}`: URLs de sites para detalhar as **pastas** de 1º nível, separadas por vírgula. Exemplo: `https://contoso.sharepoint.com/`.
- `{$SPO.LIBRARIES.ALL}` = `1` e `{$SPO.LIBRARIES.MIN_MB}`: tamanho de **todas as bibliotecas** de todos os sites, a partir de N MB.
- `{$SPO.BIGFILES.*}` e `{$SPO.VERSIONS.*}`: quantidade e tamanho mínimo dos maiores arquivos e dos maiores históricos de versões.
- `{$SPO.RB.*}`: módulo de lixeiras. Desativado por padrão; veja o [guia do Entra ID](01-microsoft-entra-id.md#5-certificado-para-a-leitura-das-lixeiras-opcional).

### Todas as macros

| Macro | Padrão | Obrigatória | Descrição |
|---|---|---|---|
| `{$SPO.BIGFILES.INTERVAL}` | `6h` | não | Intervalo da pesquisa dos maiores arquivos (inclui a leitura das versões). |
| `{$SPO.BIGFILES.MAX}` | `50` | não | Quantos dos maiores arquivos viram itens no Zabbix. Máximo 500. |
| `{$SPO.BIGFILES.MIN_MB}` | `200` | não | Tamanho mínimo (MB) para o arquivo entrar na pesquisa. |
| `{$SPO.BIGFILES.ONEDRIVE}` | `0` | não | 1 = inclui arquivos dos OneDrives pessoais; 0 = só SharePoint (é o que conta na cota do tenant). |
| `{$SPO.BIGFILES.TIMEOUT}` | `300s` | não | Timeout do item Script dos maiores arquivos e versões (máximo 600s). |
| `{$SPO.CLIENT.ID}` | — | **sim** | ID do aplicativo (cliente) do App Registration com Reports.Read.All (aplicativo). Defina no host. |
| `{$SPO.CLIENT.SECRET}` | — | **sim** (Texto secreto) | Segredo do cliente do App Registration. Defina no host. Anote a data de expiração. |
| `{$SPO.FOLDERS.INTERVAL}` | `3h` | não | Intervalo da coleta de bibliotecas e pastas. |
| `{$SPO.FOLDERS.MAX}` | `200` | não | Quantidade máxima de pastas de 1º nível (as maiores) que viram itens no Zabbix. |
| `{$SPO.FOLDERS.SITES}` | — | não | URLs dos sites para detalhar por biblioteca/pasta, separadas por vírgula. Ex.: https://contoso.sharepoint.com/. Vazio = não coleta. |
| `{$SPO.FOLDERS.TIMEOUT}` | `300s` | não | Timeout do item Script de bibliotecas e pastas (máximo 600s). |
| `{$SPO.GET_INTERVAL}` | `6h` | não | Intervalo da coleta. Os relatórios do Graph mudam uma vez por dia. |
| `{$SPO.LIBRARIES.ALL}` | `1` | não | 1 = coleta o tamanho das bibliotecas de todos os sites; 0 = só dos sites em {$SPO.FOLDERS.SITES}. |
| `{$SPO.LIBRARIES.MIN_MB}` | `100` | não | Bibliotecas menores que este tamanho (MB) não viram itens, para não poluir o Zabbix. |
| `{$SPO.LLD.URL.MATCHES}` | `.*` | não | Filtro: descobre apenas sites cuja URL casa com esta regex. |
| `{$SPO.LLD.URL.NOT_MATCHES}` | `CHANGE_IF_NEEDED` | não | Filtro: ignora sites cuja URL casa com esta regex. |
| `{$SPO.NODATA.TIMEOUT}` | `13h` | não | Tempo sem dados de armazenamento para alertar (pelo menos 2x o intervalo da coleta). |
| `{$SPO.PROXY}` | — | não | Proxy HTTP opcional para a saída do Zabbix, ex.: http://proxy.exemplo.local:3128. Vazio = sem proxy. |
| `{$SPO.RB.CERT.THUMBPRINT}` | — | não | Impressão digital (SHA-1, hexadecimal) do certificado carregado no app. Aparece em Certificados e segredos. |
| `{$SPO.RB.CLIENT.ID}` | — | não | ID do app com a permissão SharePoint Sites.FullControl.All (aplicativo) e o certificado. Vazio = usa o mesmo app ({$SPO.CLIENT.ID}). |
| `{$SPO.RB.ENABLED}` | `0` | não | Leitura das lixeiras (1º e 2º estágio): 1 = ativa, 0 = desativada. Exige certificado no app e a permissão SharePoint Sites.FullControl.All (aplicativo). Veja a documentação. |
| `{$SPO.RB.INTERVAL}` | `6h` | não | Intervalo da leitura das lixeiras. |
| `{$SPO.RB.NODATA}` | `13h` | não | Alerta se a leitura das lixeiras ficar sem dados nesse período. |
| `{$SPO.RB.PRIVATE.KEY}` | — | não (Texto secreto) | Chave privada do certificado em PEM (RSA 2048, PKCS#8 ou PKCS#1), pode ser colada em uma linha só. Máximo 2048 caracteres. |
| `{$SPO.RB.SITE.MIN_MB}` | `100` | não | Só viram itens por site as lixeiras (1º + 2º estágio) acima deste tamanho em MB. Os totais incluem todos os sites. |
| `{$SPO.RB.TIMEOUT}` | `600s` | não | Timeout do item de leitura das lixeiras (máximo 600s). |
| `{$SPO.REPORT.MAXAGE}` | `259200` | não | Idade máxima do relatório do Graph, em segundos (259200 = 3 dias). |
| `{$SPO.SCRIPT.TIMEOUT}` | `60s` | não | Timeout do item Script (token + 2 relatórios). |
| `{$SPO.SEARCH.REGION}` | — | não | Região da Pesquisa do Microsoft 365 (ex.: BRA). Vazio = detecta automaticamente. |
| `{$SPO.SITE.PUSED.HIGH}` | `95` | não | Percentual da cota do site para alerta High. |
| `{$SPO.SITE.PUSED.WARN}` | `85` | não | Percentual da cota do site para alerta Warning. |
| `{$SPO.TENANT.ID}` | — | **sim** | ID do diretório (locatário) do Entra ID. Defina no host. |
| `{$SPO.TENANT.PUSED.CRIT}` | `100` | não | Percentual da cota do tenant para alerta High (acima de 100% o SharePoint fica somente leitura). |
| `{$SPO.TENANT.PUSED.WARN}` | `90` | não | Percentual da cota do tenant para alerta Warning. |
| `{$SPO.TENANT.QUOTA.GB}` | `0` | **sim** | Cota total do tenant em GB: (Get-SPOTenant).StorageQuota / 1024. Defina no host. |
| `{$SPO.VERSIONS.MIN_MB}` | `50` | não | Tamanho mínimo (MB) do arquivo para entrar na análise de versões. |
| `{$SPO.VERSIONS.SCAN}` | `500` | não | Quantos dos maiores arquivos têm as versões medidas para achar os maiores históricos de versões (máximo 2000; cada 20 arquivos = 1 chamada $batch ao Graph). |

> **Importante para quem for mexer no código:** o Zabbix **substitui macros também dentro do script** dos itens Script. Nunca escreva `{$MACRO}` no corpo do JavaScript (nem em comentários ou mensagens). Passe valores somente pelos *Parâmetros* do item. Caso contrário, uma macro secreta, como a chave privada, pode acabar dentro do código ou do histórico.

## 5. Primeira coleta

Os itens rodam no intervalo configurado (3 a 6 h). Para ver dados na hora:

1. Abra **Monitoramento → Dados recentes** e filtre pelo host.
2. Selecione os itens **SPO: Coleta dos relatórios do Graph**, **SPO: Coleta de bibliotecas e pastas**, **SPO: Pesquisa dos maiores arquivos** e, se ativou, **SPO: Leitura das lixeiras**. Clique em **Executar agora**.
3. Espere de 1 a 5 minutos e clique em **Executar agora** **mais uma vez**. Na primeira execução as regras de descoberta (LLD) **criam** os itens por site, biblioteca, pasta e arquivo; os valores entram a partir da segunda.
4. Confira os itens de saúde. Todos devem estar **vazios** (vazio = OK):
   - `SPO: Erro na coleta`
   - `SPO: Erro na coleta de pastas`
   - `SPO: Erro na pesquisa dos maiores arquivos`
   - `SPO: Lixeiras – erro na coleta`

Se algum tiver texto, veja [04-solucao-de-problemas.md](04-solucao-de-problemas.md).

## 6. Itens

| Item | Chave | Tipo | Intervalo |
|---|---|---|---|
| SPO: Coleta dos relatórios do Graph | `spo.reports.get` | SCRIPT | {$SPO.GET_INTERVAL} |
| SPO: Erro na coleta | `spo.collect.error` | DEPENDENT | dependente |
| SPO: Aviso da coleta | `spo.collect.warning` | DEPENDENT | dependente |
| SPO: Tenant – armazenamento usado | `spo.tenant.used` | DEPENDENT | dependente |
| SPO: Tenant – cota total | `spo.tenant.quota` | DEPENDENT | dependente |
| SPO: Tenant – % da cota usada | `spo.tenant.pused` | DEPENDENT | dependente |
| SPO: Tenant – espaço livre | `spo.tenant.free` | DEPENDENT | dependente |
| SPO: Data do relatório | `spo.report.date` | DEPENDENT | dependente |
| SPO: Idade do relatório | `spo.report.age` | DEPENDENT | dependente |
| SPO: Sites ativos | `spo.sites.count` | DEPENDENT | dependente |
| SPO: Sites ativos – armazenamento usado | `spo.sites.used` | DEPENDENT | dependente |
| SPO: Sites excluídos (lixeira) | `spo.sites.deleted.count` | DEPENDENT | dependente |
| SPO: Sites excluídos – armazenamento usado | `spo.sites.deleted.used` | DEPENDENT | dependente |
| SPO: Coleta de bibliotecas e pastas | `spo.folders.get` | SCRIPT | {$SPO.FOLDERS.INTERVAL} |
| SPO: Erro na coleta de pastas | `spo.folders.error` | DEPENDENT | dependente |
| SPO: Aviso da coleta de pastas | `spo.folders.warning` | DEPENDENT | dependente |
| SPO: Sites varridos para bibliotecas | `spo.libraries.sites_scanned` | DEPENDENT | dependente |
| SPO: Bibliotecas monitoradas – tamanho total | `spo.libraries.size` | DEPENDENT | dependente |
| SPO: Bibliotecas monitoradas | `spo.libraries.count` | DEPENDENT | dependente |
| SPO: Pastas de 1º nível encontradas | `spo.folders.count` | DEPENDENT | dependente |
| SPO: Pesquisa dos maiores arquivos | `spo.bigfiles.get` | SCRIPT | {$SPO.BIGFILES.INTERVAL} |
| SPO: Erro na pesquisa dos maiores arquivos | `spo.bigfiles.error` | DEPENDENT | dependente |
| SPO: Aviso da pesquisa dos maiores arquivos | `spo.bigfiles.warning` | DEPENDENT | dependente |
| SPO: Arquivos acima do tamanho mínimo | `spo.bigfiles.total` | DEPENDENT | dependente |
| SPO: Maiores arquivos – tamanho somado | `spo.bigfiles.size_total` | DEPENDENT | dependente |
| SPO: Maiores históricos de versões – somados | `spo.bigfiles.versions_total` | DEPENDENT | dependente |
| SPO: Versões antigas – arquivos analisados | `spo.bigfiles.versions_scanned` | DEPENDENT | dependente |
| SPO: Versões antigas – total nos arquivos analisados | `spo.bigfiles.versions_scanned_size` | DEPENDENT | dependente |
| SPO: Região da pesquisa | `spo.bigfiles.region` | DEPENDENT | dependente |
| SPO: Config – tamanho mínimo dos maiores arquivos (MB) | `spo.config.bigfiles.min_mb` | DEPENDENT | dependente |
| SPO: Config – quantidade de maiores arquivos | `spo.config.bigfiles.max` | DEPENDENT | dependente |
| SPO: Config – tamanho mínimo na análise de versões (MB) | `spo.config.versions.min_mb` | DEPENDENT | dependente |
| SPO: Config – arquivos analisados nas versões | `spo.config.versions.scan` | DEPENDENT | dependente |
| SPO: Leitura das lixeiras | `spo.recyclebin.get` | SCRIPT | {$SPO.RB.INTERVAL} |
| SPO: Lixeira 1º estágio – tamanho | `spo.recycle.stage1.size` | DEPENDENT | dependente |
| SPO: Lixeira 1º estágio – itens | `spo.recycle.stage1.count` | DEPENDENT | dependente |
| SPO: Lixeira 2º estágio – tamanho | `spo.recycle.stage2.size` | DEPENDENT | dependente |
| SPO: Lixeira 2º estágio – itens | `spo.recycle.stage2.count` | DEPENDENT | dependente |
| SPO: Lixeiras – sites lidos | `spo.recycle.sites.read` | DEPENDENT | dependente |
| SPO: Lixeiras – sites só 1º estágio | `spo.recycle.sites.partial` | DEPENDENT | dependente |
| SPO: Lixeiras – sites com erro | `spo.recycle.sites.error` | DEPENDENT | dependente |
| SPO: Lixeiras – total de sites | `spo.recycle.sites.total` | DEPENDENT | dependente |
| SPO: Lixeiras – erro na coleta | `spo.recycle.error` | DEPENDENT | dependente |
| SPO: Lixeiras – aviso | `spo.recycle.warning` | DEPENDENT | dependente |

## 7. Descobertas (LLD)

| Regra | Chave | Protótipos de item |
|---|---|---|
| SPO: Descoberta de sites | `spo.sites.discovery` | Site {#SITE.URL}: armazenamento usado<br>Site {#SITE.URL}: cota do site<br>Site {#SITE.URL}: % da cota usada<br>Site {#SITE.URL}: arquivos<br>Site {#SITE.URL}: arquivos ativos (7 dias)<br>Site {#SITE.URL}: última atividade |
| SPO: Descoberta de bibliotecas | `spo.libraries.discovery` | Biblioteca {#LIB.PATH}: tamanho<br>Biblioteca {#LIB.PATH}: itens na raiz<br>Biblioteca {#LIB.PATH}: última modificação |
| SPO: Descoberta de pastas | `spo.folders.discovery` | Pasta {#FOLDER.PATH}: tamanho<br>Pasta {#FOLDER.PATH}: itens<br>Pasta {#FOLDER.PATH}: criada em<br>Pasta {#FOLDER.PATH}: última modificação |
| SPO: Descoberta dos maiores arquivos e históricos de versões | `spo.bigfiles.discovery` | Arquivo {#FILE.LABEL}: tamanho<br>Arquivo {#FILE.LABEL}: versões antigas<br>Arquivo {#FILE.LABEL}: qtd versões<br>Arquivo {#FILE.LABEL}: última alteração<br>Arquivo {#FILE.LABEL}: url<br>Arquivo {#FILE.LABEL}: url da pasta |
| SPO: Descoberta das lixeiras por site | `spo.recycle.sites.discovery` | Lixeira {#RB.SITE}: 1º estágio – tamanho<br>Lixeira {#RB.SITE}: 1º estágio – itens<br>Lixeira {#RB.SITE}: 2º estágio – tamanho<br>Lixeira {#RB.SITE}: 2º estágio – itens |

- Itens de **arquivos** que saem do top N são removidos depois de 3 dias.
- Itens de **sites** cuja lixeira cai abaixo do mínimo são removidos depois de 7 dias.

## 8. Triggers

| Trigger | Severidade |
|---|---|
| SPO: Falha na coleta dos relatórios do Graph | WARNING |
| SPO: Aviso na coleta dos relatórios do Graph | INFO |
| SPO: Sem dados de armazenamento há {$SPO.NODATA.TIMEOUT} | WARNING |
| SPO: Macro {$SPO.TENANT.QUOTA.GB} não definida | INFO |
| SPO: Tenant acima da cota de armazenamento (sites em somente leitura) | HIGH |
| SPO: Tenant acima de {$SPO.TENANT.PUSED.WARN}% da cota de armazenamento | WARNING |
| SPO: Relatório do Graph desatualizado | WARNING |
| SPO: Falha na coleta de bibliotecas e pastas | WARNING |
| SPO: Falha na pesquisa dos maiores arquivos | WARNING |
| SPO: Leitura das lixeiras sem dados há {$SPO.RB.NODATA} | WARNING |
| SPO: Lixeiras de {ITEM.LASTVALUE1} site(s) não puderam ser lidas | INFO |
| SPO: Falha na leitura das lixeiras | WARNING |
| SPO: {#SITE.URL} acima de {$SPO.SITE.PUSED.HIGH}% da cota do site (protótipo) | HIGH |
| SPO: {#SITE.URL} acima de {$SPO.SITE.PUSED.WARN}% da cota do site (protótipo) | WARNING |

## 9. Ajustes de desempenho

- **Tenants grandes** (milhares de sites ou bibliotecas): aumente `{$SPO.FOLDERS.TIMEOUT}` e `{$SPO.RB.TIMEOUT}` até `600s` e, se precisar, os intervalos.
- **Quantidade de itens:** `{$SPO.LIBRARIES.MIN_MB}`, `{$SPO.BIGFILES.MAX}` e `{$SPO.RB.SITE.MIN_MB}` controlam quantos itens as descobertas criam.
- **Limites da Microsoft:** cada 20 chamadas ao Graph vão em um único `$batch`. Se aparecer aviso de *throttling* (HTTP 429), aumente o intervalo da coleta afetada.
- **Proxy do Zabbix:** se o host for monitorado por proxy, o proxy é que precisa da saída HTTPS e do relógio certo.

---

<sub>Autor: Pablo Pires de Godoi Silva · Licença MIT</sub>
