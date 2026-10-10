# 6. Segurança e manutenção das credenciais

O template **só lê**, mas as credenciais do app dão acesso de leitura a **todo o conteúdo** do SharePoint. Se o módulo de lixeiras estiver ativo, dão também **controle total**. Trate-as como credenciais privilegiadas.

## Princípios

| Prática | Como aplicar |
|---|---|
| **Menor privilégio** | Só Graph `Reports.Read.All` e `Sites.Read.All`. Acrescente SharePoint `Sites.FullControl.All` **somente** se for usar as lixeiras. |
| **Isolar a permissão alta** | Para as lixeiras, prefira um **app separado** só com o certificado e `Sites.FullControl.All`, sem segredo. Informe o ID dele em `{$SPO.RB.CLIENT.ID}`. |
| **Macros secretas** | `{$SPO.CLIENT.SECRET}` e `{$SPO.RB.PRIVATE.KEY}` sempre como **Texto secreto**. Elas não aparecem na tela nem na API do Zabbix, mas ficam no banco: proteja o banco e os backups dele. Se usar cofre (HashiCorp Vault ou CyberArk), use macros do tipo *Segredo do cofre*. |
| **Nunca compartilhe** | Não cole segredos, chaves privadas nem prints de macros em chamados, chats ou no Git. Se isso acontecer, **troque a credencial** na hora. |
| **Chave fora do disco** | Depois de colar a chave na macro, apague o arquivo `.key` (`shred -u`). Se precisar guardar, use um cofre de senhas. |
| **Usuário do Grafana** | Use um usuário do Zabbix só de leitura, com token de API ([03-grafana.md](03-grafana.md#2-usuário-do-zabbix-para-o-grafana-somente-leitura)), nunca *Super admin*. |

## Monitorar o uso do app

- **Entra ID → Monitoramento → Logs de entrada → Entradas de entidade de serviço**, filtrando pelo ID do app. O esperado são entradas só a partir do IP de saída do Zabbix.
- Com licença **Microsoft Entra Workload ID**, crie uma política de **Acesso Condicional para identidades de carga de trabalho** que restrinja o app aos IPs do Zabbix.
- Revise de tempos em tempos **Certificados e segredos**: só devem existir as credenciais em uso.

## Rotação

| Credencial | Validade sugerida | Como trocar sem interromper |
|---|---|---|
| Segredo do cliente | 12 meses | Crie um segredo novo, atualize `{$SPO.CLIENT.SECRET}`, rode **Executar agora** para confirmar e **exclua** o antigo no Entra. |
| Certificado das lixeiras | 12 meses | Gere um par novo, carregue o `.crt` no app, atualize `{$SPO.RB.CERT.THUMBPRINT}` e `{$SPO.RB.PRIVATE.KEY}`, confirme e **exclua** o certificado antigo no Entra. |
| Token de API do Grafana | 12 meses | Crie um token novo para o usuário `grafana`, atualize a fonte de dados e exclua o antigo. |

Coloque as datas de expiração na agenda da equipe, ou crie um alerta. Os itens de erro do template avisam quando o token falha, mas aí a coleta já parou.

## Em caso de vazamento

1. **Exclua** a credencial vazada no Entra ID (segredo ou certificado).
2. Crie uma nova e atualize as macros.
3. Revise os **logs de entrada** do app e os **logs de auditoria** do Microsoft 365 (Purview) no período de exposição.
4. Se o app tinha `Sites.FullControl.All`, verifique alterações e exclusões feitas pela identidade do app nos sites.

---

<sub>Autor: Pablo Pires de Godoi Silva · Licença MIT</sub>
