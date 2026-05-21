# Relatório mensal de atividade e juros (Brasil e EUA)

Projeto do Tutorial 3 da disciplina Programação e Resolução de Problemas (EESP-FGV, 1º sem/2026).

Robô que produz, todo dia 5 de cada mês, um conjunto de tabelas e gráficos com indicadores de produção industrial e juros de curto prazo para Brasil e Estados Unidos. Não exige nenhum computador ligado: tudo roda na infraestrutura gratuita do GitHub Actions.

## Indicadores

```
Brasil
  Produção industrial — Indústria geral (SA e NSA)   IBGE/SIDRA, tabela 8159
  Produção industrial — categorias de uso            IBGE/SIDRA, tabela 8158
  Selic acumulada anualizada base 252                BCB/SGS, série 4189

EUA
  Industrial Production Index (SA)                   FRED, INDPRO
  Industrial Production Index (NSA)                  FRED, IPB50001N
  Federal Funds Effective Rate                       FRED, FEDFUNDS
```

## Por que essas fontes específicas

**FRED via endpoint público `fredgraph.csv`** em vez da API JSON.
O endpoint de CSV não exige chave de API. Isso remove a necessidade de configurar um *Secret* no GitHub e simplifica o workflow.

**IBGE/SIDRA para a produção industrial brasileira** em vez do BCB/SGS.
O SIDRA expõe metadados que o SGS não tem: nome da variável (que distingue SA de NSA), categoria de uso, setor de atividade. Isso permite a desagregação por categoria de uso que o enunciado do tutorial pede.

**Selic SGS 4189 (acumulada anualizada base 252)** em vez da Selic-meta (SGS 432).
A SGS 4189 é a taxa **efetivamente realizada** no mercado; o `FEDFUNDS` do FRED também é uma taxa efetiva. Comparar realizada com realizada faz mais sentido do que comparar meta com efetiva.

## O que sai

Pasta `output_tutorial_3/`:

```
eua.csv                          Painel mensal EUA: 3 colunas (SA, NSA, FedFunds)
brasil.csv                       Painel mensal Brasil: 3 colunas (SA, NSA, Selic)
brasil_categorias_uso.csv        PIM-PF brasileira em formato longo
estatisticas.csv                 Estatísticas descritivas (1 linha por série)
comparacao_sa_nsa_resumo.csv     Resumo da comparação ajustada x não-ajustada
comparacao_sa_nsa_serie.csv      Diferença SA - NSA mês a mês
painel_atividade_juros.png       Painel 2×2 com as 4 séries principais
diferenca_sa_nsa.png             Magnitude da sazonalidade ao longo do tempo
relatorio_atividade_juros.xlsx   Todos os CSVs num único arquivo, em abas
```

## Como o código está organizado

`script.R` é dividido em seções numeradas. Cada uma tem uma única responsabilidade:

0. Setup de pacotes e locale.
1. Parâmetros: janela de busca, pasta de saída.
2. `http_pegar()` — wrapper sobre `httr::GET` com 3 tentativas e backoff (3s, 6s, 9s). Em 401/403/404 desiste imediato; em 5xx ou timeout, tenta de novo. Retorna `NULL` em vez de quebrar.
3. `fred_serie()` — leitor de `fredgraph.csv`.
4. `sgs_serie()` — leitor do SGS com paginação de 10 anos (a API engasga com janelas longas).
5. `sidra_serie()` + `sidra_arrumar()` — leitor do SIDRA, normaliza a tabela retornada (data como fim-de-mês, valores numéricos).
6. `mensal_fim()` — agrega séries diárias em mensais pegando o último dia útil de cada mês.
7. Coleta efetiva das 6 séries.
8. Montagem dos painéis wide (`eua` e `brasil`) e do formato longo (`br_categorias`).
9. Recorte do histórico para começar no primeiro mês em que todas as séries-base têm observação. A função imprime no log qual série foi a limitante.
10. `descritivas()` — N, média, desvio, mín, quartis, mediana, máx.
11. `compara_sa_nsa()` — correlação, diferença média/min/max, desvio da diferença, variação interanual média de cada uma.
12. Gráficos (ggplot2 + patchwork).
13. Exportação para CSV e XLSX.

## Como rodar localmente

```bash
Rscript -e 'install.packages(c("dplyr","tidyr","purrr","readr","stringr","lubridate","ggplot2","patchwork","httr","jsonlite","openxlsx"))'
Rscript script.R
```

Os arquivos aparecem em `./output_tutorial_3/`.

## Como o agendamento funciona

`.github/workflows/relatorio.yml` define:

- **Quando**: cron `0 12 5 * *` — dia 5 de cada mês, 12h UTC (= 9h de Brasília). Também aceita disparo manual pelo botão "Run workflow" na aba Actions.
- **Onde**: VM Ubuntu 24, R 4.4, instalação de pacotes com cache entre runs.
- **O que faz depois**: faz commit dos arquivos gerados de volta no repositório (pasta `output_tutorial_3/`) e disponibiliza o mesmo conteúdo como *artifact* do run, com retenção de 90 dias.

Permissão `contents: write` é necessária no `permissions:` do workflow (e em Settings → Actions → General → Workflow permissions).

## Operação

Status de cada execução: aba **Actions**. Verde = sucesso; vermelho = falhou em algum passo (basta clicar no run para ver o log e identificar onde quebrou). O GitHub envia e-mail automaticamente em caso de falha.

Workflows agendados são desativados se o repositório fica 60 dias sem qualquer atividade. Para reativar: aba Actions → botão "Enable workflow". Qualquer commit zera esse contador.

## Notas econômicas (para incluir no relatório de entrega)

A correlação entre série SA e NSA é da ordem de **0,97 para a indústria americana** e **0,78 para a brasileira**. Isso quantifica algo que aparece à vista no painel: a produção industrial brasileira tem um componente sazonal muito mais pronunciado, com oscilação mensal típica de ±7 pontos do índice contra ±1 ponto nos EUA.

Hipóteses para explorar:
- composição setorial (peso de setores sazonais como alimentos/bebidas)
- estrutura do calendário de feriados (Carnaval, festas de fim de ano)
- ciclos agropecuários que se transmitem para a indústria de beneficiamento

A queda de COVID-19 (março–abril/2020) aparece em ambas as séries como uma descontinuidade brusca, com magnitude semelhante (~15 pontos), mas a recuperação seguiu trajetórias diferentes — útil para discutir resposta de política industrial.
