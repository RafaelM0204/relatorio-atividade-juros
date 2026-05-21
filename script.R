###############################################################################
# Acompanhamento de Atividade e Juros — Brasil e EUA
# EESP-QUANT, Tutorial 3
#
# Pacotes especializados em vez de chamadas HTTP cruas:
#   - quantmod::getSymbols("X", src = "FRED")  --> EUA
#   - rbcb::get_series(c(nome = codigo))       --> BCB
#   - sidrar::get_sidra(tabela, variable=..)   --> IBGE/SIDRA
#
# Fontes:
#   FRED INDPRO   — Produção industrial EUA, SA
#   FRED IPB50001N — Produção industrial EUA, NSA
#   FRED FEDFUNDS — Fed Funds Effective Rate
#   SGS 4189      — Selic acumulada anualizada base 252
#   SIDRA 8888    — PIM-PF Brasil (base 2022=100), v=12606 NSA, v=12607 SA
###############################################################################


## --- 0. Setup ---------------------------------------------------------------

rm(list = ls())
tryCatch(Sys.setlocale("LC_ALL", "C.UTF-8"), warning = function(w) NULL)
options(warn = 1, scipen = 999, timeout = 180)

pacotes <- c("dplyr", "tidyr", "purrr", "readr", "lubridate", "stringr",
             "ggplot2", "patchwork", "openxlsx",
             "quantmod", "rbcb", "sidrar")

for (p in pacotes) {
  if (!requireNamespace(p, quietly = TRUE)) {
    install.packages(p, repos = "https://cloud.r-project.org")
  }
}
invisible(lapply(pacotes, library, character.only = TRUE))


## --- 1. Parâmetros ----------------------------------------------------------

INICIO <- as.Date("2000-01-01")
FIM    <- Sys.Date()
SAIDA  <- "output_tutorial_3"
if (!dir.exists(SAIDA)) dir.create(SAIDA, recursive = TRUE)


## --- 2. Coleta --------------------------------------------------------------

# FRED via quantmod. Retorna objeto xts; converto para tibble (data, valor).
pegar_fred <- function(id) {
  cat("  FRED ", id, "...\n", sep = "")
  obj <- tryCatch(
    quantmod::getSymbols(id, src = "FRED", auto.assign = FALSE,
                         from = INICIO, to = FIM),
    error = function(e) { cat("    erro:", conditionMessage(e), "\n"); NULL }
  )
  if (is.null(obj)) return(NULL)
  tibble(
    data  = as.Date(zoo::index(obj)),
    valor = as.numeric(obj[, 1])
  ) |>
    filter(data >= INICIO, data <= FIM) |>
    drop_na(valor)
}

# BCB via rbcb. Devolve tibble com (date, <nome>). Padronizo para (data, valor).
pegar_sgs <- function(codigo, nome = "x") {
  cat("  SGS ", codigo, "...\n", sep = "")
  obj <- tryCatch(
    rbcb::get_series(setNames(codigo, nome), start_date = INICIO, end_date = FIM),
    error = function(e) { cat("    erro:", conditionMessage(e), "\n"); NULL }
  )
  if (is.null(obj) || nrow(obj) == 0) return(NULL)
  obj |>
    rename(data = date) |>
    mutate(data = as.Date(data)) |>
    select(data, valor = all_of(nome)) |>
    drop_na(valor)
}

# SIDRA via sidrar. Pega as duas variáveis da PIM-PF (NSA e SA).
pegar_pim_pf <- function() {
  cat("  SIDRA 8888 (PIM-PF)...\n")
  obj <- tryCatch(
    sidrar::get_sidra(x = 8888,
                      variable = c(12606, 12607),
                      period = "all",
                      geo = "Brazil"),
    error = function(e) { cat("    erro:", conditionMessage(e), "\n"); NULL }
  )
  if (is.null(obj) || nrow(obj) == 0) return(NULL)
  # Padroniza nomes
  obj <- obj |>
    rename(any_of(c(
      mes_cod   = "Mês (Código)",
      variavel  = "Variável (Código)",
      valor_raw = "Valor",
      secao     = "Seções e atividades industriais (CNAE 2.0)"
    )))

  tibble(
    data  = lubridate::ceiling_date(
      lubridate::ymd(paste0(substr(obj$mes_cod, 1, 4), "-",
                            substr(obj$mes_cod, 5, 6), "-01")),
      "month") - lubridate::days(1),
    tipo  = if_else(as.character(obj$variavel) == "12607", "SA", "NSA"),
    secao = as.character(obj$secao),
    valor = suppressWarnings(as.numeric(obj$valor_raw))
  ) |>
    drop_na(data, valor) |>
    filter(data >= INICIO, data <= FIM)
}


## --- 3. Agregação mensal fim-de-mês -----------------------------------------

mensal_fim <- function(df) {
  if (is.null(df) || nrow(df) == 0) return(df)
  df |>
    mutate(fim = lubridate::ceiling_date(data, "month") - lubridate::days(1)) |>
    group_by(fim) |>
    summarise(valor = last(valor), .groups = "drop") |>
    rename(data = fim) |>
    arrange(data)
}


## --- 4. Pipeline ------------------------------------------------------------

cat("Baixando séries...\n")

eua_sa  <- mensal_fim(pegar_fred("INDPRO"))
eua_nsa <- mensal_fim(pegar_fred("IPB50001N"))
eua_ffr <- mensal_fim(pegar_fred("FEDFUNDS"))
br_selic <- mensal_fim(pegar_sgs(4189, "valor"))
pim       <- pegar_pim_pf()

nr <- function(x) if (is.null(x)) 0 else nrow(x)
cat("  obs: EUA SA=", nr(eua_sa),
    " NSA=", nr(eua_nsa),
    " FFR=", nr(eua_ffr),
    " Selic=", nr(br_selic),
    " PIM-PF=", nr(pim), "\n", sep = "")


## --- 5. Painéis wide --------------------------------------------------------

renomear <- function(d, nome) {
  if (is.null(d) || nrow(d) == 0)
    return(tibble(data = as.Date(character()), !!nome := numeric()))
  d |> rename(!!nome := valor)
}

eua <- list(
  renomear(eua_sa,  "ind_prod_sa"),
  renomear(eua_nsa, "ind_prod_nsa"),
  renomear(eua_ffr, "fed_funds")
) |> reduce(full_join, by = "data") |> arrange(data)

# Indústria geral do Brasil
br_ind_geral <- if (is.null(pim)) {
  tibble(data = as.Date(character()),
         ind_prod_sa = numeric(), ind_prod_nsa = numeric())
} else {
  pim |>
    filter(stringr::str_detect(secao,
           stringr::regex("ind[uú]stria geral", ignore_case = TRUE))) |>
    select(data, tipo, valor) |>
    pivot_wider(names_from = tipo, values_from = valor,
                names_prefix = "ind_prod_") |>
    rename_with(tolower)
}

if (!"ind_prod_sa"  %in% names(br_ind_geral)) br_ind_geral$ind_prod_sa  <- NA_real_
if (!"ind_prod_nsa" %in% names(br_ind_geral)) br_ind_geral$ind_prod_nsa <- NA_real_

brasil <- br_ind_geral |>
  full_join(renomear(br_selic, "selic"), by = "data") |>
  arrange(data)

# Desagregação por seção CNAE (sem indústria geral)
br_secoes <- if (is.null(pim)) {
  tibble(data = as.Date(character()),
         secao = character(), tipo = character(), valor = numeric())
} else {
  pim |>
    filter(!stringr::str_detect(secao,
           stringr::regex("ind[uú]stria geral", ignore_case = TRUE))) |>
    arrange(data, secao, tipo)
}

cat("  Painéis: EUA=", nrow(eua), " BR=", nrow(brasil),
    " seções=", nrow(br_secoes), "\n", sep = "")


## --- 6. Recorte para período comum ------------------------------------------

primeiro <- function(df, col) {
  if (is.null(df) || nrow(df) == 0) return(NA)
  d <- df$data[!is.na(df[[col]])]
  if (length(d) == 0) NA else min(d)
}

primeiros <- c(
  eua_sa   = primeiro(eua,    "ind_prod_sa"),
  eua_nsa  = primeiro(eua,    "ind_prod_nsa"),
  eua_ffr  = primeiro(eua,    "fed_funds"),
  br_selic = primeiro(brasil, "selic"),
  br_pi    = primeiro(brasil, "ind_prod_sa")
)
primeiros <- primeiros[!is.na(primeiros)]
corte     <- if (length(primeiros) > 0)
               max(as.Date(primeiros, origin = "1970-01-01")) else INICIO

cat("Corte: ", format(corte))
if (length(primeiros) > 0)
  cat(" (limitante: ", names(primeiros)[which.max(primeiros)], ")", sep = "")
cat("\n")

eua       <- eua       |> filter(data >= corte)
brasil    <- brasil    |> filter(data >= corte)
br_secoes <- br_secoes |> filter(data >= corte)


## --- 7. Estatísticas --------------------------------------------------------

descritivas <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0)
    return(tibble(n=0L, media=NA_real_, dp=NA_real_, min=NA_real_,
                  p25=NA_real_, p50=NA_real_, p75=NA_real_, max=NA_real_))
  tibble(n = length(x), media = mean(x), dp = sd(x), min = min(x),
         p25 = quantile(x, 0.25, names = FALSE), p50 = median(x),
         p75 = quantile(x, 0.75, names = FALSE), max = max(x))
}

descritivas_painel <- function(df, pais) {
  cols <- setdiff(names(df), "data")
  map_dfr(cols, \(c) descritivas(df[[c]]) |>
                    mutate(serie = c, pais = pais)) |>
    select(pais, serie, everything())
}

estat <- bind_rows(descritivas_painel(eua, "EUA"),
                   descritivas_painel(brasil, "Brasil"))


## --- 8. Comparação SA vs NSA ------------------------------------------------

compara <- function(df, pais) {
  if (!all(c("ind_prod_sa", "ind_prod_nsa") %in% names(df))) return(NULL)
  d <- df |> select(data, sa = ind_prod_sa, nsa = ind_prod_nsa) |>
    drop_na(sa, nsa)
  if (nrow(d) == 0) return(NULL)
  diff_n <- d$sa - d$nsa
  diff_p <- 100 * (d$sa / d$nsa - 1)
  yoy <- function(v) {
    if (length(v) <= 12) return(NA_real_)
    mean((v[13:length(v)] / v[1:(length(v) - 12)] - 1) * 100, na.rm = TRUE)
  }
  list(
    resumo = tibble(
      pais = pais, n_obs = nrow(d),
      periodo_inicial = format(min(d$data), "%Y-%m"),
      periodo_final   = format(max(d$data), "%Y-%m"),
      correlacao = cor(d$sa, d$nsa),
      media_diff = mean(diff_n), dp_diff = sd(diff_n),
      min_diff = min(diff_n), max_diff = max(diff_n),
      yoy_media_sa = yoy(d$sa), yoy_media_nsa = yoy(d$nsa)
    ),
    serie = d |> mutate(diff_nivel = diff_n, diff_pct = diff_p, pais = pais)
  )
}

c_eua <- compara(eua, "EUA")
c_br  <- compara(brasil, "Brasil")

comp_resumo <- bind_rows(c_eua$resumo, c_br$resumo)
comp_serie  <- bind_rows(c_eua$serie,  c_br$serie)


## --- 9. Gráficos ------------------------------------------------------------

estilo <- function() {
  theme_minimal(base_size = 11) +
    theme(plot.title = element_text(face = "bold", size = 13),
          plot.subtitle = element_text(size = 10, color = "grey35"),
          plot.caption  = element_text(size = 8, color = "grey50", hjust = 1),
          panel.grid.minor = element_blank(),
          panel.grid.major.x = element_blank(),
          legend.position = "none")
}

linha <- function(df, col, titulo, ylab) {
  if (is.null(df) || !(col %in% names(df))) return(plot_spacer())
  d <- df |> select(data, v = all_of(col)) |> drop_na()
  if (nrow(d) == 0) return(plot_spacer())
  ggplot(d, aes(data, v)) +
    geom_line(linewidth = 0.6, color = "#2c3e50") +
    labs(title = titulo, x = NULL, y = ylab) + estilo()
}

janela <- function() {
  d <- c(eua$data, brasil$data); d <- d[!is.na(d)]
  if (length(d) == 0) "" else sprintf("Janela: %s a %s",
    format(min(d), "%Y-%m"), format(max(d), "%Y-%m"))
}

painel <-
  (linha(eua,    "ind_prod_sa", "EUA: Produção industrial (SA)", "Índice") |
   linha(eua,    "fed_funds",   "EUA: Fed Funds Rate",            "% a.a.")) /
  (linha(brasil, "ind_prod_sa", "Brasil: Produção industrial (SA)", "Índice") |
   linha(brasil, "selic",       "Brasil: Selic anualizada base 252", "% a.a.")) +
  plot_annotation(
    title = "Atividade e Juros — Brasil e EUA",
    subtitle = janela(),
    caption = "Fontes: FRED, IBGE/SIDRA, BCB/SGS",
    theme = theme(plot.title = element_text(face = "bold", size = 16))
  )
ggsave(file.path(SAIDA, "painel_atividade_juros.png"),
       painel, width = 11, height = 7, dpi = 110)

if (!is.null(comp_serie) && nrow(comp_serie) > 0) {
  g_diff <- ggplot(comp_serie, aes(data, diff_nivel)) +
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


## --- 10. Exportação ---------------------------------------------------------

cat("Exportando...\n")
salvar <- function(df, nome) readr::write_csv(df, file.path(SAIDA, nome), na = "")

salvar(eua,         "eua.csv")
salvar(brasil,      "brasil.csv")
salvar(br_secoes,   "brasil_secoes_cnae.csv")
salvar(estat,       "estatisticas.csv")
salvar(comp_resumo, "comparacao_sa_nsa_resumo.csv")
salvar(comp_serie,  "comparacao_sa_nsa_serie.csv")

openxlsx::write.xlsx(
  list(EUA = eua, Brasil = brasil, Secoes_CNAE_BR = br_secoes,
       Estatisticas = estat,
       Comparacao_Resumo = comp_resumo, Comparacao_Mensal = comp_serie),
  file = file.path(SAIDA, "relatorio_atividade_juros.xlsx"),
  overwrite = TRUE
)

cat("Pronto. Arquivos em ./", SAIDA, "/\n", sep = "")
