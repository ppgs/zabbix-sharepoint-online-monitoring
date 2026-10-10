# Código dos itens Script

Estes arquivos são o JavaScript embutido nos itens **Script** do template (campo *Script*). Estão aqui para revisão e controle de versão. **O que vale é o que está no template**: ao alterar um arquivo, copie o conteúdo para o item correspondente, ou para o YAML, e reimporte.

| Arquivo | Item | O que faz |
|---|---|---|
| `reports.js` | `spo.reports.get` | Token (segredo), relatórios `getSharePointSiteUsageDetail` e `getSharePointSiteUsageStorage` (CSV via redirecionamento), associação de URL por `getAllSites`. |
| `libraries_folders.js` | `spo.folders.get` | Bibliotecas de todos os sites e pastas de 1º nível, com `$batch` (20 por chamada). |
| `bigfiles_versions.js` | `spo.bigfiles.get` | Pesquisa do Microsoft 365 (`driveItem`, região automática), maiores arquivos, versões via `$batch`, união do top por tamanho e do top por versões. |
| `recyclebin.js` | `spo.recyclebin.get` | Token do SharePoint com certificado (JWT RS256 assinado com `sign()`), leitura de `/_api/site/RecycleBin` em todos os sites, totais por estágio. |

Regras para quem for alterar:

1. **Nunca escreva `{$MACRO}` no corpo do script**, nem em comentários ou mensagens: o Zabbix substitui as macros no código antes de executar. Passe valores pelos **Parâmetros** do item (`value` é o JSON com os parâmetros).
2. **Limite de 10 objetos `HttpRequest` simultâneos** por script: reutilize objetos em laços.
3. **Ambiente Duktape (ES5):** use `var`, sem arrow functions nem declarações de função dentro de blocos.
4. **Erros:** devolva sempre JSON com `error` e `warning` (vazio = OK), para os itens de saúde e as triggers.

---

<sub>Autor: Pablo Pires de Godoi Silva · Licença MIT</sub>
