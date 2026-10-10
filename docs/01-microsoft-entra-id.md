# 1. Microsoft Entra ID: app, permissões e credenciais

O Zabbix acessa o Microsoft 365 como **aplicativo** (sem usuário logado), por meio de um *App Registration* no Entra ID. Este guia cria o app, concede as permissões mínimas, gera o segredo e, se você quiser monitorar as lixeiras, configura o certificado.

> Papéis necessários: **Administrador de Aplicativos** (ou Administrador de Aplicativos de Nuvem) para criar o app, e **Administrador Global** ou **Administrador de Funções Privilegiadas** para conceder o consentimento do administrador.

---

## 1. Criar o App Registration

1. Acesse **https://entra.microsoft.com** → **Identidade → Aplicativos → Registros de aplicativo → Novo registro**.
2. **Nome:** por exemplo `Zabbix - SharePoint Online (monitoramento)`.
3. **Tipos de conta com suporte:** *Contas somente neste diretório organizacional (locatário único)*.
4. **URI de redirecionamento:** deixe em branco.
5. Clique em **Registrar**.
6. Na **Visão geral**, anote:
   - **ID do aplicativo (cliente)**, que vai em `{$SPO.CLIENT.ID}`;
   - **ID do diretório (locatário)**, que vai em `{$SPO.TENANT.ID}`.

## 2. Permissões de API

Em **Permissões de APIs → Adicionar uma permissão**:

| API | Tipo | Permissão | Para quê |
|---|---|---|---|
| **Microsoft Graph** | Permissões de aplicativo | `Reports.Read.All` | Relatórios de uso do SharePoint: uso e cota do tenant, uso e atividade por site, sites excluídos. |
| **Microsoft Graph** | Permissões de aplicativo | `Sites.Read.All` | Lista de todos os sites (`/sites/getAllSites`), bibliotecas e pastas (`/drives`), Pesquisa do Microsoft 365 (maiores arquivos) e versões dos arquivos. |
| **SharePoint** *(opcional)* | Permissões de aplicativo | `Sites.FullControl.All` | **Só** para o módulo de lixeiras. Veja a [seção 5](#5-certificado-para-a-leitura-das-lixeiras-opcional). |

Depois de adicionar, clique em **Conceder consentimento do administrador para \<sua organização\>**. A coluna *Status* deve mostrar "Concedido" em todas.

**Não adicione** outras permissões do Graph, como `Sites.ReadWrite.All`, `Sites.Manage.All` ou `Sites.FullControl.All` no Graph. O template só lê, e essas permissões só aumentariam o estrago possível se a credencial vazar.

Pode remover a permissão delegada `User.Read`, que o portal adiciona por padrão. Ela não é usada.

## 3. Segredo do cliente

1. Vá em **Certificados e segredos → Segredos do cliente → Novo segredo do cliente**.
2. Descrição `zabbix`, validade de **12 meses**. Prefira prazos curtos e anote a data de renovação.
3. Copie o **Valor** na hora: ele só aparece uma vez. O **ID do segredo não serve** como senha.
4. O valor vai na macro `{$SPO.CLIENT.SECRET}`, sempre do tipo **Texto secreto**.

## 4. Nomes de sites nos relatórios

Por padrão o Microsoft 365 **oculta** nomes de usuários, grupos e sites nos relatórios de uso. O template contorna isso associando cada site pelo ID (via `/sites/getAllSites`), mas para ter os dados mais completos:

1. Acesse **https://admin.microsoft.com** → **Configurações → Configurações da organização → Serviços → Relatórios**.
2. **Desmarque** a opção de exibir nomes ocultos de usuário, grupo e site em todos os relatórios (em inglês: *Display concealed user, group, and site names in all reports*).
3. Salve. A mudança pode levar algumas horas para aparecer nos relatórios.

> Problema conhecido da Microsoft: em alguns tenants a coluna *Site URL* do relatório vem vazia mesmo com a opção desmarcada. O template já trata isso e busca a URL pelo ID do site.

## 5. Certificado para a leitura das lixeiras (opcional)

### Por que certificado

A quantidade e o tamanho das lixeiras, separados por **1º e 2º estágio**, só existem na **API REST do SharePoint** (`/_api/site/RecycleBin`).

- **O Graph não serve:** a lixeira de sites no Graph só existe em beta, não informa o estágio e, com permissão de aplicativo, devolve a lista vazia.
- **O segredo não serve:** a API REST do SharePoint **recusa** tokens de aplicativo obtidos com segredo do cliente (`HTTP 401 – Unsupported app only token`). Ela só aceita tokens obtidos com **certificado**.
- **Como o item faz:** o item `spo.recyclebin.get` assina sozinho um JWT RS256 com a chave privada do certificado, usando a função `sign()` do Zabbix 7.x.

### Por que `Sites.FullControl.All`

- **2º estágio:** a lixeira de 2º estágio (do conjunto de sites) só é visível para **administradores do conjunto de sites**.
- **1º estágio:** na lixeira de 1º estágio, um usuário comum vê só o que ele mesmo excluiu.

Com `SharePoint → Sites.Read.All` o app recebe "Access denied" no 2º estágio e **zero itens** no 1º. O único papel de aplicativo que vê as lixeiras de todos os sites é `Sites.FullControl.All`.

> ⚠️ **Risco:** com essa permissão, quem tiver a **chave privada** pode **alterar e excluir** conteúdo em todos os sites. O template só lê, mas a credencial permite mais. Avalie com a sua equipe de segurança e siga o [guia de segurança](06-seguranca.md). Se não puder conceder essa permissão, deixe o módulo desativado (`{$SPO.RB.ENABLED}=0`, o padrão). O resto do template funciona normalmente.

### Passos

**5.1 Gerar o certificado** (bash, no servidor do Zabbix ou em qualquer Linux com OpenSSL). Use RSA de **2048 bits**: a chave precisa caber na macro, que tem limite de 2048 caracteres.

```bash
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 365 -subj "/CN=Zabbix-SharePoint-Lixeiras" -keyout spo-lixeiras.key -out spo-lixeiras.crt
```
```bash
chmod 600 spo-lixeiras.key
```

Impressão digital SHA-1, que vai em `{$SPO.RB.CERT.THUMBPRINT}`:
```bash
openssl x509 -in spo-lixeiras.crt -noout -fingerprint -sha1 | sed 's/.*=//; s/://g'
```

**5.2 Carregar no app:** em **Certificados e segredos → Certificados → Carregar certificado**, envie o `spo-lixeiras.crt`. A impressão digital mostrada no portal deve ser igual à do comando acima.

**5.3 Permissão:** em **Permissões de APIs → Adicionar uma permissão → SharePoint** (não "Microsoft Graph") **→ Permissões de aplicativo → `Sites.FullControl.All`**. Depois clique em **Conceder consentimento do administrador**.

**5.4 Macros no host do Zabbix**

| Macro | Valor |
|---|---|
| `{$SPO.RB.ENABLED}` | `1` |
| `{$SPO.RB.CERT.THUMBPRINT}` | impressão digital do passo 5.1 |
| `{$SPO.RB.PRIVATE.KEY}` | conteúdo de `spo-lixeiras.key`, de `-----BEGIN PRIVATE KEY-----` até `-----END PRIVATE KEY-----`. Tipo **Texto secreto**. Pode ser colado em uma linha só. |
| `{$SPO.RB.CLIENT.ID}` | vazio = usa o mesmo app de `{$SPO.CLIENT.ID}`. Preencha só se usar um app separado para as lixeiras. |

**5.5 Remover a chave do disco** depois de salvar a macro. Se precisar guardar uma cópia, use um cofre de senhas.
```bash
shred -u spo-lixeiras.key
```

> Alternativa mais isolada: crie um **segundo app**, só com `SharePoint → Sites.FullControl.All` e o certificado, sem segredo, e informe o ID dele em `{$SPO.RB.CLIENT.ID}`. Assim a permissão alta fica separada do app que usa segredo.

## 6. Validar antes de ir para o Zabbix (opcional)

Os scripts de [tools/](../tools) testam as permissões em **PowerShell 7**, só lendo. O passo a passo está em [05-ferramentas-powershell.md](05-ferramentas-powershell.md).

## Checklist

- [ ] App de locatário único criado; IDs do aplicativo e do locatário anotados.
- [ ] Graph `Reports.Read.All` e `Sites.Read.All` (aplicativo) com consentimento concedido.
- [ ] Segredo criado; valor copiado; data de expiração anotada.
- [ ] Nomes de site não ocultos nos relatórios.
- [ ] *(Lixeiras)* Certificado de 2048 bits carregado; SharePoint `Sites.FullControl.All` com consentimento; chave em macro secreta; chave removida do disco.

---

<sub>Autor: Pablo Pires de Godoi Silva · Licença MIT</sub>
