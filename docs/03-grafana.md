# 3. Grafana: plugin, fonte de dados e painel

Testado no **Grafana 13.2** com o plugin **Zabbix** (`alexanderzobnin-zabbix-app`). O painel lê os dados do Zabbix pela API. Ele não fala com a Microsoft.

---

## 1. Instalar o plugin Zabbix

**Grafana instalado no sistema:**
```bash
grafana-cli plugins install alexanderzobnin-zabbix-app
```
```bash
systemctl restart grafana-server
```

**Grafana em Docker:** acrescente ao serviço no `compose.yaml` e recrie o container:
```yaml
    environment:
      - GF_INSTALL_PLUGINS=alexanderzobnin-zabbix-app
```

Depois: **Administração → Plugins e dados → Plugins → Zabbix → Ativar**.

## 2. Usuário do Zabbix para o Grafana (somente leitura)

Não use um usuário *Super admin*. O Grafana só precisa **ler**.

1. **Usuários → Funções de usuário → Criar função de usuário:**
   - **Nome:** `Grafana - Leitura`;
   - **Tipo de usuário:** *Usuário*;
   - **Acesso à API:** ativado.
   - **Opcional:** em *Métodos da API*, escolha **Permitir lista** com `*.get`. O plugin só consulta. Se algum painel parar de carregar, remova essa restrição.
2. **Usuários → Grupos de usuários → Criar grupo:** `Grafana - Leitura`, aba **Permissões de host**, com **Leitura** no grupo de hosts do SharePoint (por exemplo `Microsoft 365`).
3. **Usuários → Usuários → Criar usuário:** `grafana`, no grupo `Grafana - Leitura`, com a função `Grafana - Leitura`.
4. **Usuários → Tokens de API → Criar token de API:** para o usuário `grafana`, com data de expiração. Copie o token.

> Sem grupo com permissão de leitura no grupo de hosts, o usuário não enxerga o host e o painel fica "Sem dados", mesmo com tudo certo no Zabbix.

## 3. Fonte de dados

**Conexões → Fontes de dados → Adicionar → Zabbix:**

| Campo | Valor |
|---|---|
| Nome | por exemplo `Zabbix` |
| URL | `http://<frontend-do-zabbix>/api_jsonrpc.php`. Se o frontend estiver em `/zabbix`, use `http://<host>/zabbix/api_jsonrpc.php`. |
| Autenticação | **Token de API**, com o token do passo anterior |
| Trends | ativado, *Trends from* `7d` |
| Cache TTL | `5m`. O padrão é 1 h, e itens recém-criados pelas descobertas levariam até 1 h para aparecer no painel. |

Clique em **Salvar e testar**. A mensagem deve mostrar a versão do Zabbix.

## 4. Importar o painel

1. **Painéis → Novo → Importar → Carregar arquivo JSON**.
2. Selecione `grafana/dashboard_sharepoint_online.json`.
3. Em **Zabbix**, escolha a fonte de dados do passo 3.
4. Clique em **Importar**.
5. No topo do painel, ajuste as variáveis:
   - **Grupo:** o grupo de hosts, por exemplo `Microsoft 365`.
   - **Host:** o host do SharePoint Online.
   - **Tenant:** o nome antes de `.sharepoint.com` (por exemplo `contoso`). É usado só nos atalhos do topo.
6. Clique em **Salvar painel**, para que as escolhas fiquem como padrão.

## 5. O que o painel mostra

| Seção | Painéis |
|---|---|
| **Capacidade do tenant** | Gauge de % da cota; armazenamento usado; cota; espaço livre (negativo = acima da cota); sites ativos; tendência de uso × cota. |
| **Lixeiras e espaço recuperável** | Lixeira de 1º e 2º estágio (tamanho e itens); barras de **espaço recuperável** (lixeiras, versões antigas e sites excluídos); tabela de lixeiras por site. |
| **Sites e bibliotecas** | Top 20 sites; tamanho por biblioteca de todos os sites; maiores pastas; última modificação das bibliotecas. |
| **Arquivos grandes e versões** | Maiores arquivos (top N) e maiores históricos de versões (top N), com **links** para abrir o arquivo e a pasta no SharePoint em uma nova aba. |
| **Saúde da coleta e alertas** | Status de cada coleta, data e idade do relatório, sites lidos nas lixeiras e eventos das triggers do host. |

Atalhos no topo, que abrem em nova aba: Centro de administração do SharePoint, lixeira do site raiz e métricas de armazenamento do site raiz.

## 6. Como o painel foi montado (para quem for alterar)

- **Últimos valores:** os painéis de valor e as tabelas usam *Relative time* `2d` e *Use trends* desligado. Itens novos ainda não têm *trends* e apareceriam vazios em períodos longos.
- **Tabelas de arquivos:** juntam várias consultas pelo nome dos itens (`Arquivo <nome> | <site> | <pasta>: <métrica>`) com as transformações `reduce` → `extractFields` → `groupingToMatrix` → `joinByField`. As URLs vêm de itens de texto em consultas separadas, com filtro por *refId*, e ficam em colunas ocultas usadas pelos links.
- **Valores das macros:** as variáveis ocultas `cfg_*` leem os itens `SPO: Config – …`. Assim títulos e descrições mostram os valores atuais das macros (por exemplo "top 50", "acima de 200 MB"). O Grafana não lê macros herdadas do template.
- **Cards com dois valores:** o plugin junta as consultas num conjunto só. Por isso os ajustes de cada campo usam o **nome do item** (regex), não a letra da consulta.

---

<sub>Autor: Pablo Pires de Godoi Silva · Licença MIT</sub>
