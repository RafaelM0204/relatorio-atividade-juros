###############################################################################
# Acompanhamento de Atividade e Juros — Brasil e EUA
# EESP-QUANT, Tutorial 3
#
# Pipeline mensal:
#   (1) baixar FRED, BCB/SGS e IBGE/SIDRA
#   (2) processar para formato wide (uma coluna por série)
#   (3) gerar estatísticas descritivas e comparação SA vs NSA
#   (4) plotar painel de gráficos
#   (5) exportar para CSV, XLSX e PNG
#
# Justificativas das escolhas de fonte:
#   - FRED via fredgraph.csv: endpoint público, sem chave de API.
#     Simplifica o workflow do GitHub Actions (sem Secret).
#   - SIDRA para Brasil PIM-PF: traz metadados (variável, categoria,
#     setor) que o BCB SGS não expõe, permitindo a desagregação por
#     categoria de uso pedida no tutorial.
#   - Selic SGS 4189 (acumulada anualizada base 252): é taxa efetiva
#     realizada, comparável ao Fed Funds Effective Rate (também
#     realizado). A Selic-meta (432) seria comparável apenas com a
#     meta do Fed Funds (target), que é uma série diferente.
###############################################################################


## --- 0. Setup ---------------------------------------------------------------

rm(list = ls())

# Locale UTF-8 (cabeçalhos com acento saem corretos no GitHub Actions)
tryCatch(Sys.setlocale("LC_ALL", "C.UTF-8"), warning = function(w) NULL)

pacotes <- c("dplyr", "tidyr", "purrr", "readr", "stringr",
             "lubridate", "ggplot2", "patchwork",
             "httr", "jsonlite", "openxlsx")

for (p in pacotes) {
  if (!requireNamespace(p, quietly = TRUE)) {
    install.packages(p, repos = "https://cloud.r-project.org")
  }
}
invisible(lapply(pacotes, library, character.only = TRUE))

options(scipen = 999)


## --- 1. Parâmetros ----------------------------------------------------------

INICIO_BUSCA <- as.Date("2000-01-01")
FIM_BUSCA    <- Sys.Date()
SAIDA        <- "output_tutorial_3"

if (!dir.exists(SAIDA)) dir.create(SAIDA, recursive = TRUE)


## --- 2. HTTP resiliente -----------------------------------------------------

# Wrapper único usado por todos os downloaders. Repete até 3 vezes com
# backoff (3s, 6s, 9s). Em 401/403/404 falha rápido (não adianta repetir).
# Retorna NULL em vez de quebrar — o caller decide o que fazer.

UA <- "Mozilla/5.0 (relatorio-eesp-quant)"

http_pegar <- function(url, timeout_s = 60) {
  for (k in 1:3) {
    r <- tryCatch(
      httr::GET(url,
                httr::add_headers(`User-Agent` = UA,
                                  Accept       = "application/json, text/csv, */*"),
                httr::timeout(timeout_s)),
      error = function(e) NULL
    )
    if (is.null(r)) { Sys.sleep(3 * k); next }

    codigo <- httr::status_code(r)
    if (codigo %in% c(401, 403, 404))         return(NULL)
    if (codigo >= 400)                       { Sys.sleep(3 * k); next }

    corpo <- httr::content(r, as = "text", encoding = "UTF-8")
    if (is.null(corpo) || !nzchar(trimws(corpo))) return(NULL)
    return(corpo)
  }
  NULL
}


## --- 3. FRED (CSV público) --------------------------------------------------

# Endpoint público fredgraph.csv. Não precisa de chave de API.
# Estrutura: 2 colunas (observation_date, <SERIES_ID>).

fred_serie <- function(id_serie) {
  url <- paste0("https://fred.stlouisfed.org/graph/fredgraph.csv?id=", id_serie)
  texto <- http_pegar(url)
  if (is.null(texto)) {
    warning("FRED: falha em ", id_serie); return(NULL)
  }

  df <- readr::read_csv(I(texto),
                        na = c(".", "NA", ""),
                        show_col_types = FALSE)

  # FRED nomeia a coluna de valor com o próprio ID; padronizo.
  names(df) <- c("data", "valor")
  df |>
    mutate(data  = as.Date(data),
           valor = as.numeric(valor)) |>
    filter(data >= INICIO_BUSCA, data <= FIM_BUSCA) |>
    drop_na(valor)
}


## --- 4. BCB / SGS -----------------------------------------------------------

# A API do SGS engasga com janelas longas (>10 anos) e às vezes devolve
# vazio. Estratégia: pedir em pedaços, concatenar e deduplicar nas
# fronteiras. Para 25+ anos de histórico, 3 pedaços bastam.

sgs_serie <- function(codigo) {
  bordas <- seq(INICIO_BUSCA, FIM_BUSCA, by = "10 years")
  if (tail(bordas, 1) < FIM_BUSCA) bordas <- c(bordas, FIM_BUSCA)

  pedacos <- vector("list", length(bordas) - 1)

  for (i in seq_along(pedacos)) {
    url <- sprintf(
      "https://api.bcb.gov.br/dados/serie/bcdata.sgs.%d/dados?formato=json&dataInicial=%s&dataFinal=%s",
      codigo,
      format(bordas[i],     "%d/%m/%Y"),
      format(bordas[i + 1], "%d/%m/%Y")
    )
    txt <- http_pegar(url)
    if (is.null(txt)) next

    parsed <- tryCatch(jsonlite::fromJSON(txt), error = function(e) NULL)
    if (is.null(parsed) || !is.data.frame(parsed) || nrow(parsed) == 0) next

    pedacos[[i]] <- parsed
  }

  pedacos <- compact(pedacos)
  if (length(pedacos) == 0) { warning("SGS: falha em ", codigo); return(NULL) }

  bind_rows(pedacos) |>
    mutate(data  = lubridate::dmy(data),
           valor = as.numeric(stringr::str_replace(valor, ",", "."))) |>
    distinct(data, .keep_all = TRUE) |>
    arrange(data) |>
    select(data, valor)
}


## --- 5. IBGE / SIDRA --------------------------------------------------------

# A API SIDRA aceita o mesmo path que o pacote sidrar usa internamente.
# O JSON retorna a primeira linha como dicionário de rótulos amigáveis;
# uso esses rótulos como nomes de coluna e descarto essa linha.

sidra_serie <- function(tabela, classificacao) {
  url <- sprintf(
    "https://apisidra.ibge.gov.br/values/t/%s/n1/all/v/all/p/all/c%s/all",
    tabela, classificacao
  )
  txt <- http_pegar(url, timeout_s = 120)
  if (is.null(txt)) { warning("SIDRA: falha em ", tabela); return(NULL) }

  raw <- tryCatch(jsonlite::fromJSON(txt), error = function(e) NULL)
  if (is.null(raw) || nrow(raw) < 2) {
    warning("SIDRA: tabela ", tabela, " sem dados"); return(NULL)
  }

  rotulos <- as.character(raw[1, ])
  dados   <- raw[-1, , drop = FALSE]
  names(dados) <- rotulos
  as_tibble(dados)
}


# Da estrutura crua do SIDRA extraio apenas o que importa:
# data, valor, nome_da_variavel, nome_da_categoria.
# A coluna "Mês (Código)" vem como YYYYMM; converto para data fim-de-mês.

sidra_arrumar <- function(df, col_categoria) {
  if (is.null(df) || nrow(df) == 0) return(NULL)

  # Tolerância a variações de cabeçalho do SIDRA
  col_mes  <- grep("M[eê]s.*C[oó]digo", names(df), value = TRUE)[1]
  col_var  <- grep("^Vari[aá]vel$",      names(df), value = TRUE)[1]
  col_val  <- grep("^Valor$",            names(df), value = TRUE)[1]
  col_cat  <- grep(col_categoria,        names(df), value = TRUE)[1]

  if (any(is.na(c(col_mes, col_var, col_val, col_cat)))) {
    stop("SIDRA: cabeçalhos esperados não encontrados")
  }

  df |>
    transmute(
      data       = lubridate::ymd(paste0(substr(.data[[col_mes]], 1, 4), "-",
                                         substr(.data[[col_mes]], 5, 6), "-01")),
      data       = lubridate::ceiling_date(data, "month") - 1,
      variavel   = .data[[col_var]],
      categoria  = .data[[col_cat]],
      valor      = suppressWarnings(as.numeric(.data[[col_val]]))
    ) |>
    drop_na(data, valor) |>
    filter(data >= INICIO_BUSCA, data <= FIM_BUSCA)
}


# Marca como SA ou NSA a partir do texto da variável retornada pelo SIDRA.
# As tabelas 8158/8159 trazem variáveis tipo:
#   "Indústria geral - Índice com ajuste sazonal..."
#   "Indústria geral - Índice base fixa sem ajuste..."

sa_ou_nsa <- function(texto_variavel) {
  com_ajuste <- stringr::str_detect(
    texto_variavel,
    stringr::regex("com ajuste|dessazonal", ignore_case = TRUE)
  )
  if_else(com_ajuste, "SA", "NSA")
}


## --- 6. Agregação para mensal "fim-de-mês" ---------------------------------

# Para séries diárias (FedFunds, Selic), pego o último valor de cada mês
# e atribuo ao último dia do mês. Idempotente para séries já mensais.

mensal_fim <- function(df) {
  if (is.null(df) || nrow(df) == 0) return(df)
  df |>
    mutate(fim_mes = lubridate::ceiling_date(data, "month") - 1) |>
    group_by(fim_mes) |>
    summarise(valor = last(valor), .groups = "drop") |>
    rename(data = fim_mes) |>
    arrange(data)
}


## --- 7. Pipeline de coleta --------------------------------------------------

executar <- function() {

cat("Baixando séries...\n")

cat("  FRED INDPRO\n");    eua_pi_sa  <- mensal_fim(fred_serie("INDPRO"))
cat("  FRED IPB50001N\n"); eua_pi_nsa <- mensal_fim(fred_serie("IPB50001N"))
cat("  FRED FEDFUNDS\n");  eua_juros  <- mensal_fim(fred_serie("FEDFUNDS"))

cat("  SGS 4189 (Selic anualizada)\n")
br_juros <- mensal_fim(sgs_serie(4189))

cat("  SIDRA 8159 (PIM-PF por setor)\n")
sidra_setores <- sidra_arrumar(sidra_serie("8159", "544"),
                               col_categoria = "Se[cç][aã]o|Atividade")

cat("  SIDRA 8158 (PIM-PF por categoria de uso)\n")
sidra_categorias <- sidra_arrumar(sidra_serie("8158", "543"),
                                  col_categoria = "Categoria.*uso")


## --- 8. Montagem dos painéis wide -------------------------------------------

# Painel EUA (1 linha por mês, 3 séries)
eua <- list(ind_prod_sa  = eua_pi_sa,
            ind_prod_nsa = eua_pi_nsa,
            fed_funds    = eua_juros) |>
  imap(\(d, nome) if (is.null(d)) tibble() else
       d |> rename(!!nome := valor)) |>
  reduce(full_join, by = "data") |>
  arrange(data)


# Para o Brasil, extraio a "Indústria geral" da tabela 8159 (todas as
# categorias = "Indústria geral") nas duas variantes SA/NSA.
br_ind_geral <- sidra_setores |>
  filter(stringr::str_detect(
    categoria,
    stringr::regex("ind[uú]stria geral", ignore_case = TRUE))) |>
  mutate(tipo = sa_ou_nsa(variavel)) |>
  group_by(data, tipo) |>
  summarise(valor = mean(valor, na.rm = TRUE), .groups = "drop") |>
  pivot_wider(names_from = tipo, values_from = valor,
              names_prefix = "ind_prod_") |>
  rename_with(tolower)

brasil <- br_ind_geral |>
  full_join(br_juros |> rename(selic = valor), by = "data") |>
  arrange(data)


# Categorias de uso: deixo em formato long porque são várias categorias
# x 2 versões (SA/NSA). Mais útil para análise downstream.
br_categorias <- sidra_categorias |>
  mutate(tipo = sa_ou_nsa(variavel)) |>
  select(data, categoria, tipo, valor) |>
  arrange(data, categoria, tipo)


## --- 9. Recorte para o período comum a todas as séries-base -----------------

primeiros <- c(
  eua_pi_sa  = if (nrow(eua_pi_sa)  > 0) min(eua_pi_sa$data)        else NA,
  eua_pi_nsa = if (nrow(eua_pi_nsa) > 0) min(eua_pi_nsa$data)       else NA,
  eua_juros  = if (nrow(eua_juros)  > 0) min(eua_juros$data)        else NA,
  br_juros   = if (nrow(br_juros)   > 0) min(br_juros$data)         else NA,
  br_pi      = if (nrow(br_ind_geral) > 0) min(br_ind_geral$data)   else NA
)
primeiros <- primeiros[!is.na(primeiros)]
corte     <- if (length(primeiros) > 0) max(primeiros) else INICIO_BUSCA

cat("Período comum começa em:", format(corte),
    " (limitante:", names(primeiros)[which.max(primeiros)], ")\n")

eua           <- eua           |> filter(data >= corte)
brasil        <- brasil        |> filter(data >= corte)
br_categorias <- br_categorias |> filter(data >= corte)


## --- 10. Estatísticas descritivas -------------------------------------------

# Função simples: aplica describe a um vetor numérico, retorna 1 linha.
descritivas <- function(x) {
  x <- x[!is.na(x)]
  tibble(
    n      = length(x),
    media  = mean(x),
    dp     = sd(x),
    min    = min(x),
    p25    = quantile(x, 0.25, names = FALSE),
    p50    = median(x),
    p75    = quantile(x, 0.75, names = FALSE),
    max    = max(x)
  )
}

# Aplico a cada coluna de série, marcando o país.
descritivas_painel <- function(df, rotulo_pais) {
  cols <- setdiff(names(df), "data")
  map_dfr(cols, \(c) descritivas(df[[c]]) |>
                    mutate(serie = c, pais = rotulo_pais)) |>
    select(pais, serie, everything())
}

estat <- bind_rows(
  descritivas_painel(eua,    "EUA"),
  descritivas_painel(brasil, "Brasil")
)


## --- 11. Comparação SA vs NSA -----------------------------------------------

# Para cada país, restrinjo aos meses em que SA e NSA têm dado, computo
# a diferença em nível e em % e devolvo um resumo + a série mensal da
# diferença (para inspeção/auditoria).

compara_sa_nsa <- function(df, rotulo_pais) {
  d <- df |> select(data, sa = ind_prod_sa, nsa = ind_prod_nsa) |>
    drop_na(sa, nsa)

  if (nrow(d) == 0) return(NULL)

  diff_nivel  <- d$sa - d$nsa
  diff_pct    <- 100 * (d$sa / d$nsa - 1)

  # Variação interanual média (12 meses) para cada uma
  yoy_media <- function(v) {
    if (length(v) <= 12) return(NA_real_)
    mean((v[13:length(v)] / v[1:(length(v) - 12)] - 1) * 100, na.rm = TRUE)
  }

  resumo <- tibble(
    pais = rotulo_pais,
    n_obs = nrow(d),
    periodo_inicial = format(min(d$data), "%Y-%m"),
    periodo_final   = format(max(d$data), "%Y-%m"),
    correlacao      = cor(d$sa, d$nsa),
    media_diff      = mean(diff_nivel),
    dp_diff         = sd(diff_nivel),
    min_diff        = min(diff_nivel),
    max_diff        = max(diff_nivel),
    yoy_media_sa    = yoy_media(d$sa),
    yoy_media_nsa   = yoy_media(d$nsa)
  )

  serie_diff <- d |>
    mutate(diff_nivel = diff_nivel,
           diff_pct   = diff_pct,
           pais       = rotulo_pais)

  list(resumo = resumo, serie = serie_diff)
}

comp_eua    <- compara_sa_nsa(eua,    "EUA")
comp_brasil <- compara_sa_nsa(brasil, "Brasil")

comparacao_resumo <- bind_rows(
  if (!is.null(comp_eua))    comp_eua$resumo    else NULL,
  if (!is.null(comp_brasil)) comp_brasil$resumo else NULL
)

comparacao_serie <- bind_rows(
  if (!is.null(comp_eua))    comp_eua$serie    else NULL,
  if (!is.null(comp_brasil)) comp_brasil$serie else NULL
)


## --- 12. Gráficos -----------------------------------------------------------

# Estilo próprio: limpo, fontes serif para títulos (diferenciação visual),
# minimal grid, anotação de fonte no canto direito.

estilo <- function() {
  theme_minimal(base_size = 11) +
    theme(
      plot.title    = element_text(face = "bold", size = 13),
      plot.subtitle = element_text(size = 10, color = "grey35"),
      plot.caption  = element_text(size = 8,  color = "grey50", hjust = 1),
      panel.grid.minor = element_blank(),
      panel.grid.major.x = element_blank(),
      legend.position = "none"
    )
}

linha <- function(df, col, titulo, ylab) {
  if (is.null(df) || !(col %in% names(df))) return(plot_spacer())
  d <- df |> select(data, v = all_of(col)) |> drop_na()
  if (nrow(d) == 0) return(plot_spacer())
  ggplot(d, aes(data, v)) +
    geom_line(linewidth = 0.6, color = "#2c3e50") +
    labs(title = titulo, x = NULL, y = ylab) +
    estilo()
}

painel <-
  (linha(eua,    "ind_prod_sa", "EUA: Produção industrial (SA)", "Índice") |
   linha(eua,    "fed_funds",   "EUA: Fed Funds Rate",            "% a.a.")) /
  (linha(brasil, "ind_prod_sa", "Brasil: Produção industrial (SA)", "Índice") |
   linha(brasil, "selic",       "Brasil: Selic anualizada base 252", "% a.a.")) +
  plot_annotation(
    title    = "Atividade e Juros — Brasil e EUA",
    subtitle = sprintf("Janela: %s a %s",
                       format(min(eua$data), "%Y-%m"),
                       format(max(eua$data), "%Y-%m")),
    caption  = "Fontes: FRED, IBGE/SIDRA, BCB/SGS",
    theme    = theme(plot.title = element_text(face = "bold", size = 16))
  )

ggsave(file.path(SAIDA, "painel_atividade_juros.png"),
       painel, width = 11, height = 7, dpi = 110)


# Gráfico extra: diferença SA - NSA ao longo do tempo (dois países)
if (nrow(comparacao_serie) > 0) {
  g_diff <- ggplot(comparacao_serie, aes(data, diff_nivel)) +
    geom_hline(yintercept = 0, linewidth = 0.3, color = "grey60") +
    geom_line(linewidth = 0.5, color = "#c0392b") +
    facet_wrap(~ pais, ncol = 1, scales = "free_y") +
    labs(title = "Diferença entre série ajustada e não-ajustada (SA − NSA)",
         subtitle = "Magnitude da sazonalidade mês a mês",
         x = NULL, y = "Diferença (pontos do índice)",
         caption = "Fontes: FRED, IBGE/SIDRA") +
    theme_minimal(base_size = 11) +
    theme(strip.text = element_text(face = "bold"),
          panel.grid.minor = element_blank())
  ggsave(file.path(SAIDA, "diferenca_sa_nsa.png"),
         g_diff, width = 10, height = 6, dpi = 110)
}


## --- 13. Exportação ---------------------------------------------------------

cat("Exportando...\n")

salvar_csv <- function(df, nome) {
  readr::write_csv(df, file.path(SAIDA, nome), na = "")
}

salvar_csv(eua,                "eua.csv")
salvar_csv(brasil,             "brasil.csv")
salvar_csv(br_categorias,      "brasil_categorias_uso.csv")
salvar_csv(estat,              "estatisticas.csv")
salvar_csv(comparacao_resumo,  "comparacao_sa_nsa_resumo.csv")
salvar_csv(comparacao_serie,   "comparacao_sa_nsa_serie.csv")

openxlsx::write.xlsx(
  list(EUA               = eua,
       Brasil            = brasil,
       Categorias_Uso_BR = br_categorias,
       Estatisticas      = estat,
       Comparacao_Resumo = comparacao_resumo,
       Comparacao_Mensal = comparacao_serie),
  file = file.path(SAIDA, "relatorio_atividade_juros.xlsx"),
  overwrite = TRUE
)

cat("Pronto. Arquivos em ./", SAIDA, "/\n", sep = "")

} # fim executar()

if (sys.nframe() == 0) executar()
