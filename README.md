# Acompanhamento de Atividade e Juros — Brasil e EUA

Robô que produz mensalmente um relatório com indicadores macroeconômicos de produção industrial e juros de curto prazo para Brasil e EUA. Roda na nuvem do GitHub e não exige nenhum computador ligado: no dia 5 de cada mês, às 9h (horário de Brasília), os dados são baixados, processados e os arquivos atualizados são publicados de volta no repositório.

## Indicadores e fontes

| País | Indicador | Fonte | Código |
|------|-----------|-------|--------|
| EUA | Produção industrial (SA) | FRED | `INDPRO` |
| EUA | Produção industrial (NSA) | FRED | `IPB50001N` |
| EUA | Federal Funds Effective Rate | FRED | `FEDFUNDS` |
| Brasil | Produção industrial — Indústria geral (SA e NSA) | IBGE/SIDRA | tabela `8159` |
| Brasil | Produção industrial — por categoria de uso | IBGE/SIDRA | tabela `8158` |
| Brasil | Selic acumulada no mês — anualizada base 252 | BCB/SGS | `4189` |

**Por que essas fontes específicas:**

- **FRED via `fredgraph.csv`** (e não a API JSON): o endpoint público de CSV não exige chave de API. Tira o `FRED_API_KEY` da lista de segredos a gerenciar, simplificando o workflow.
- **IBGE/SIDRA via API** (e não BCB/SGS para PIM-PF): o SIDRA traz metadados ricos (nome da variável, categoria de uso, setor), permitindo a desagregação que o tutorial pede. O BCB/SGS expõe apenas pontos da série sem rótulos.
- **Selic SGS 4189 (acumulada anualizada, base 252)** — e não SGS 432 (meta): para comparar com o `FEDFUNDS` effective rate é mais correto usar uma taxa **efetivamente realizada** do que a taxa-meta do Copom.

## Arquitetura

Três componentes no repositório:

```
.
├── script.R                       # baixa, processa, exporta
├── .github/workflows/relatorio.yml # quando e como rodar
└── output_tutorial_3/             # outputs gerados (commitados a cada run)
```

**Fluxo:**

1. GitHub Actions é acionado (agendamento mensal ou botão `workflow_dispatch`).
2. Uma VM Ubuntu é criada com R 4.4.
3. Pacotes R são instalados (cache reutilizado entre runs).
4. `script.R` roda: baixa FRED + BCB/SGS + IBGE/SIDRA, processa, gera CSVs/XLSX/PNG.
5. Arquivos são commitados em `output_tutorial_3/`.
6. Os mesmos arquivos ficam disponíveis como _artifact_ do run por 90 dias.

## Estrutura do `script.R`

Dividido em blocos:

- **`.get(url)`** — wrapper resiliente: até 3 tentativas com backoff crescente, retorna `NULL` em vez de quebrar. Falha rápido em 401/403/404.
- **`baixar_fred(codigo, nome)`** — endpoint `fredgraph.csv` (sem chave).
- **`baixar_bcb_sgs(codigo, nome)`** — `api.bcb.gov.br/dados/serie/bcdata.sgs`; **quebra a janela em pedaços de 10 anos** para evitar timeout da API com históricos longos.
- **`baixar_sidra(api_path, ...)`** — `apisidra.ibge.gov.br/values`; promove a 1ª linha do JSON como rótulos amigáveis das colunas.
- **`padronizar_sidra(...)`** — extrai data do código de período (suporta `YYYYMM`, `YYYY/MM`, `YYYY-MM`), parseia valores com vírgula decimal.
- **`classificar_ajuste_sazonal(var)`** — detecta SA vs NSA pelo texto da variável.
- **`gerar_estatisticas(...)`** — média, mediana, desvio, min, max, observações, período.
- **`calcular_comparacao_ajuste(...)`** — correlação SA×NSA, diferença média/std/min/max em nível e em percentual.
- **`salvar_grafico(...)`** — `ggplot2` + tema profissional + paleta consistente.
- **`main()`** — orquestra tudo e detecta o **primeiro mês em que todas as séries-base têm dado**, recortando o histórico nesse ponto.

## Outputs gerados (`output_tutorial_3/`)

| Arquivo | Conteúdo |
|---------|----------|
| `relatorio_tutorial_3.xlsx` | Excel com 13 abas (tudo num único arquivo) |
| `producao_industrial_eua.csv` | Série EUA (SA + NSA), formato long |
| `producao_industrial_brasil.csv` | Brasil — todas as variáveis (índice geral + categorias + setores) |
| `producao_industrial_brasil_industria_geral.csv` | Brasil — apenas índice geral |
| `juros_brasil_eua.csv` | Selic + FedFunds |
| `producao_comparativa_brasil_eua.csv` | EUA + Brasil em base 100 |
| `estatisticas_*.csv` | Estatísticas descritivas |
| `comparacao_*_ajuste_sazonal.csv` | Mês a mês: SA, NSA, diferença em nível e % |
| `estatisticas_diferenca_*.csv` | Resumo da comparação SA×NSA |
| `diagnostico_variaveis_brasil.csv` | Lista de todas as variáveis detectadas |
| `grafico_producao_eua.png` | EUA: SA vs NSA |
| `grafico_juros_brasil_eua.png` | Selic vs FedFunds |
| `grafico_producao_brasil_industria_geral.png` | Brasil: SA vs NSA |
| `grafico_producao_brasil_eua.png` | Brasil × EUA em base 100 |

## Como configurar o repositório

1. Criar repo público (ou privado) no GitHub.
2. Subir `script.R` na raiz e `relatorio.yml` em `.github/workflows/`.
3. **Não é necessário** configurar nenhum _Secret_ (o `fredgraph.csv` é público).
4. Habilitar Actions em Settings → Actions → General → Allow all actions.
5. Settings → Actions → General → Workflow permissions → marcar "Read and write permissions" (necessário para o passo de commit).
6. Para testar imediatamente: aba Actions → "Relatório Mensal de Atividade e Juros" → botão **Run workflow**.

## Como rodar localmente

```bash
# Pré-requisito: R 4.x e pacotes
Rscript -e 'install.packages(c("tidyverse","lubridate","httr","jsonlite","openxlsx","scales"))'

# Rodar
Rscript script.R

# Outputs ficam em ./output_tutorial_3/
```

## Operação

- **Status do run mensal**: aba Actions; ícone verde = sucesso, vermelho = falha. GitHub envia e-mail em caso de falha.
- **Erros comuns**: API fora do ar (rerodar o workflow), série descontinuada (verificar código no FRED/SGS/SIDRA).
- **Workflow agendado pode hibernar**: GitHub desativa workflows agendados após 60 dias sem atividade no repo. Reativar em Actions → Enable workflow. Qualquer commit zera esse contador.

## Sobre as séries

**Por que SA e NSA?** Séries sem ajuste (NSA) preservam a sazonalidade — útil para entender o "calendário" da produção (férias, festas, safra). Séries com ajuste (SA) removem esse padrão para mostrar a tendência subjacente — útil para comparar mês a mês a evolução genuína.

**Por que isso importa no Brasil?** A correlação SA×NSA é ~0.78, indicando sazonalidade forte: a produção brasileira oscila visivelmente entre ~14% acima e ~13% abaixo da tendência ao longo do ano. Nos EUA a correlação é ~0.97 — sazonalidade muito mais sutil. Visualmente isso aparece como uma linha em "zigue-zague" no Brasil vs uma quase-reta nos EUA quando ambas são plotadas.
