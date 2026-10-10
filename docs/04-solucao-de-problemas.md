# 4. Solução de problemas

Primeiro passo sempre: em **Monitoramento → Dados recentes**, veja os itens de saúde do host:

- `SPO: Erro na coleta`
- `SPO: Erro na coleta de pastas`
- `SPO: Erro na pesquisa dos maiores arquivos`
- `SPO: Lixeiras – erro na coleta`
- `SPO: Lixeiras – aviso`

Vazio = OK. O texto, quando existe, vem direto da resposta da Microsoft.

## Microsoft Entra ID e tokens

| Sintoma | Causa provável | Como resolver |
|---|---|---|
| `Token: HTTP 401 … AADSTS7000215: Invalid client secret` | Foi usado o **ID** do segredo, não o **Valor**, ou o segredo expirou. | Crie um novo segredo e copie o **Valor**. |
| `Token: HTTP 400 … AADSTS700016` | `{$SPO.CLIENT.ID}` errado ou app em outro locatário. | Confira o ID do aplicativo e o `{$SPO.TENANT.ID}`. |
| `HTTP 403` nos relatórios | Falta `Reports.Read.All` (aplicativo) ou o consentimento. | Adicione a permissão do **Microsoft Graph** do tipo **Aplicativo** e conceda o consentimento do administrador. Permissões delegadas ou da API do SharePoint não servem para os relatórios. |
| `HTTP 403` em `getAllSites`, `drives` ou na pesquisa | Falta Graph `Sites.Read.All` (aplicativo). | Adicione a permissão e conceda o consentimento. |
| Erro de token após funcionar por meses | Segredo ou certificado expirou. | Renove a credencial e atualize a macro. Veja [06-seguranca.md](06-seguranca.md). |

## Relatórios de uso

| Sintoma | Causa provável | Como resolver |
|---|---|---|
| Sites aparecem como `site-<id>` em vez da URL | Nomes ocultos nos relatórios, ou um problema conhecido da Microsoft em que a URL vem vazia. | Desmarque a opção de nomes ocultos ([guia do Entra](01-microsoft-entra-id.md#4-nomes-de-sites-nos-relatórios)). O template já busca a URL pelo ID do site quando pode. |
| Data do relatório de 2 a 3 dias atrás | Atraso normal dos relatórios do Microsoft 365 (24–48 h). | Nada a fazer. O alerta só dispara depois de 3 dias. |
| `% da cota` zerado | `{$SPO.TENANT.QUOTA.GB}` = 0. | Defina a cota do tenant em GB no host. |

## Pesquisa dos maiores arquivos

| Sintoma | Causa provável | Como resolver |
|---|---|---|
| `Graph search: HTTP 400 … region` | A pesquisa com permissão de aplicativo exige a região do tenant. | O item detecta e repete sozinho. Se persistir, defina `{$SPO.SEARCH.REGION}` (por exemplo `NAM`, `EUR`, `BRA`). |
| Poucos arquivos ou nenhum | Índice da pesquisa atrasado, ou `{$SPO.BIGFILES.MIN_MB}` alto. | Aguarde ou reduza o mínimo. |
| Aviso `Versões não lidas em N arquivo(s)` | Limite de requisições (HTTP 429) ou arquivo sem permissão. | Aumente `{$SPO.BIGFILES.INTERVAL}` ou reduza `{$SPO.VERSIONS.SCAN}`. |

## Lixeiras

| Sintoma | Causa provável | Como resolver |
|---|---|---|
| Aviso `Leitura das lixeiras desativada` | `{$SPO.RB.ENABLED}` = 0 (padrão). | Configure o certificado e a permissão e defina `{$SPO.RB.ENABLED}=1`. |
| `… recusou o token obtido com segredo do cliente (HTTP 401, "Unsupported app only token")` | A API do SharePoint só aceita token de aplicativo obtido com **certificado**. | Carregue o certificado no app e preencha `{$SPO.RB.CERT.THUMBPRINT}` e `{$SPO.RB.PRIVATE.KEY}`. |
| `Token SharePoint (certificado): HTTP 401 … AADSTS700027` | Impressão digital não confere, ou o certificado não foi carregado no app ou expirou. | Compare a impressão digital do portal com a da macro, em hexadecimal sem `:`. |
| `Chave privada (macro SPO.RB.PRIVATE.KEY) inválida` | Chave incompleta, criptografada (com senha) ou maior que 2048 bits. | Gere RSA 2048 **sem senha** (`-nodes`) e cole o PEM inteiro, com as linhas BEGIN e END. |
| Aviso `2º estágio não lido em N site(s)` e totais 0 | O app tem `SharePoint Sites.Read.All` em vez de `Sites.FullControl.All`. | Conceda `SharePoint → Sites.FullControl.All` (aplicativo) com consentimento e aguarde de 5 a 10 minutos. |
| Tabela "Lixeiras por site" vazia logo após ativar | A descoberta criou os itens na primeira execução. | Clique em **Executar agora** de novo no item `SPO: Leitura das lixeiras`. |
| Valores diferentes da tela da lixeira | A tela mostra só o que o usuário pode ver e pagina os itens. O item soma tudo, dos dois estágios. | Compare com o PnP (`tools/Test-SPORecycleBinApp.ps1`). |

## Zabbix

| Sintoma | Causa provável | Como resolver |
|---|---|---|
| Item Script com `Timeout while executing a shell script` ou timeout | Tenant grande. | Aumente `{$SPO.FOLDERS.TIMEOUT}`, `{$SPO.BIGFILES.TIMEOUT}` ou `{$SPO.RB.TIMEOUT}` até `600s`. |
| `Couldn't resolve host` / `Connection timed out` | Sem saída HTTPS ou DNS no server/proxy. No Docker, confira a rede do container. | Libere 443 para os domínios da [seção 1 do guia do Zabbix](02-zabbix.md#1-pré-requisitos), ou use `{$SPO.PROXY}`. |
| `maximum count of HttpRequest objects was reached` | Script alterado, criando objetos em excesso (limite de 10 simultâneos). | Reutilize objetos `HttpRequest` dentro do script. |
| Erro de sintaxe JavaScript depois de preencher uma macro | Uma macro foi escrita **dentro** do código do script e o Zabbix a substituiu. | Passe valores só pelos *Parâmetros* do item; nunca use `{$...}` no corpo do script. |

## Grafana

| Sintoma | Causa provável | Como resolver |
|---|---|---|
| Painel inteiro "Sem dados" | O usuário da API do Zabbix não enxerga o host, ou as variáveis Grupo e Host estão erradas. | Dê **Leitura** no grupo de hosts ao grupo do usuário do Grafana, confira as variáveis do topo e **salve o painel** com o grupo e o host certos. |
| Itens novos não aparecem | **Cache TTL** da fonte de dados (padrão 1 h). | Reduza para 5 min ou aguarde. |
| Tabelas vazias com período de 30 dias, mas o Zabbix tem dados | Itens novos ainda sem *trends*. | Os painéis usam 2 dias e sem *trends*. Se você alterou isso, volte para `2d` e *Use trends* desligado. |
| Título mostra `${cfg_max}` em vez do número | Itens `SPO: Config – …` ainda sem valor, ou cache. | Rode **Executar agora** em `SPO: Pesquisa dos maiores arquivos` e recarregue a página. |
| Links do arquivo e da pasta não aparecem | Itens `Arquivo …: url` sem valor ainda. | Rode **Executar agora** mais uma vez em `SPO: Pesquisa dos maiores arquivos`. |
| Link abre "Acesso negado" | O link usa o login de quem clica no SharePoint. | Comportamento esperado: o painel não dá acesso a ninguém. |

---

<sub>Autor: Pablo Pires de Godoi Silva · Licença MIT</sub>
