# Changelog

Autor: Pablo Pires de Godoi Silva.

## 1.1.0

- Simulação (somente leitura) de manter só as N versões mais recentes por arquivo: colunas **Excedentes** e **Liberável** e total liberável (macro `{$SPO.VERSIONS.KEEP}`, padrão 5).
- Script PowerShell **`tools/Remove-SPOFileVersions.ps1`** para manter só as N versões mais recentes de um ou vários arquivos (URL ou CSV): simulação por padrão, lixeira com `-Execute` ou exclusão permanente com `-Permanent`, confirmação digitada, arquivos com retenção ou em check-out ignorados e log CSV. O template e o painel continuam somente leitura.
- Leitura de versões agora segue a paginação do Graph: arquivos com mais de 200 versões passam a ser contados por inteiro.

## 1.0.0

Primeira versão pública.

- Template Zabbix 7.4 **SharePoint Online by Microsoft Graph**:
  - relatórios de uso do tenant e dos sites (Graph `reports`), com associação de URL pelo ID do site;
  - tamanho de bibliotecas de todos os sites e pastas de 1º nível (Graph `drives` + `$batch`);
  - maiores arquivos e maiores históricos de versões (Pesquisa do Microsoft 365 + versões), com URLs do arquivo e da pasta;
  - lixeiras de 1º e 2º estágio de todos os sites (API REST do SharePoint com certificado, JWT RS256 via `sign()`), opcional com `{$SPO.RB.ENABLED}`;
  - itens `SPO: Config – …` com os valores efetivos das macros, para o Grafana;
  - triggers de cota do tenant e dos sites, falhas de coleta e falta de dados.
- Painel Grafana com seções de capacidade, lixeiras e espaço recuperável, sites e bibliotecas, arquivos grandes e versões, e saúde da coleta.
- Scripts PowerShell 7 de validação e análise (somente leitura).
