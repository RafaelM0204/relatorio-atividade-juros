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
#     Uso curl com HTTP/1.1 forçado pois o servidor do FRED tem bug
#     intermitente quando o cliente negocia HTTP/2.
#   - SIDRA tabela 8888 para Brasil PIM-PF: versão corrente da PIM-PF
#     (base 2022=100), cobre jan/2002 até hoje. Variáveis:
#       12606 = Número-índice (NSA)
#       12607 = Número-índice com ajuste sazonal (SA)
#   - Selic SGS 4189 (acumulada anualizada base 252): é taxa efetiva
#     realizada, comparável ao Fed Funds Effective Rate.
###############################################################################


## --- 0. Setup ---------------------------------------------------------------

rm(list = ls())

tryCatch(Sys.setlocale("LC_ALL", "C.UTF-8"), warning = function(w) NULL)
options(warn = 1)

pacotes <- c("dplyr", "tidyr", "purrr", "readr", "stringr",
             "lubridate", "ggplot2", "patchwork",
             "httr", "jsonlite", "openxlsx", "curl")

for (p in pacotes) {
  if (!requireNamespace(p, quietly = TRUE)) {
    install.packages(p, repos = "https://cloud.r-project.org")
  }
}
invisible(lapply(pacotes, library, character.only = TRUE))

options(scipen = 999, timeout = 120)


## --- 1. Parâmetros ----------------------------------------------------------

INICIO_BUSCA <- as.Date("2000-01-01")
FIM_BUSCA    <- Sys.Date()
SAIDA        <- "output_tutorial_3"

if (!dir.exists(SAIDA)) dir.create(SAIDA, recursive = TRUE)


## --- 2. HTTP resiliente -----------------------------------------------------

UA <- "Mozilla/5.0 (relatorio-eesp-quant)"

http_pegar <- function(url, timeout_s = 60) {
  for (k in 1:3) {
    r <- tryCatch(
      httr::GET(url,
                httr::add_headers(`User-Agent` = UA,
                                  Accept       = "application/json, */*"),
                httr::timeout(timeout_s)),
      error = function(e) {
        cat("    httr erro:", conditionMessage(e), "\n"); NULL
      }
    )
    if (is.null(r)) { Sys.sleep(3 * k); next }
    codigo <- httr::status_code(r)
    if (codigo %in% c(401, 403, 404)) {
      cat("    status", codigo, "- desistindo\n"); return(NULL)
    }
    if (codigo >= 400) {
      cat("    status", codigo, "- tentativa", k, "\n"); Sys.sleep(3 * k); next
    }
    corpo <- httr::content(r, as = "text", encoding = "UTF-8")
    if (is.null(corpo) || !nzchar(trimws(corpo))) return(NULL)
    return(corpo)
  }
  NULL
}


## --- 3. FRED ----------------------------------------------------------------

# Uso curl::curl_fetch_memory com handle customizado forçando HTTP/1.1.
# O servidor do FRED tem bug com HTTP/2; tanto httr quanto download.file
# falham por padrão. CURLOPT_HTTP_VERSION = 2 (CURL_HTTP_VERSION_1_1) força
# o cliente a não negociar HTTP/2.

CURL_HTTP_VERSION_1_1 <- 2L

fred_serie <- function(id_serie) {
  url <- paste0("https://fred.stlouisfed.org/graph/fredgraph.csv?id=", id_serie)

  resp <- NULL
  for (k in 1:3) {
    h <- curl::new_handle()
    curl::handle_setopt(h,
                        useragent    = UA,
                        timeout      = 120,
                        http_version = CURL_HTTP_VERSION_1_1)
    resp <- tryCatch(curl::curl_fetch_memory(url, handle = h),
                     error = function(e) {
                       cat("    curl erro:", conditionMessage(e), "\n"); NULL
                     })
    if (!is.null(resp) && resp$status_code == 200 && length(resp$content) > 0) break
    Sys.sleep(3 * k); resp <- NULL
  }

  if (is.null(resp)) {
    warning("FRED: falha em ", id_serie, immediate. = TRUE)
    return(NULL)
  }

  txt <- rawToChar(resp$content)
  df <- tryCatch(
    readr::read_csv(I(txt), na = c(".", "NA", ""), show_col_types = FALSE),
    error = function(e) { cat("    read_csv erro:", conditionMessage(e), "\n"); NULL }
  )
  if (is.null(df) || nrow(df) == 0) {
    warning("FRED: ", id_serie, " sem dados", immediate. = TRUE)
    return(NULL)
  }

  names(df) <- c("data", "valor")
  out <- df |>
    mutate(data  = as.Date(data),
           valor = as.numeric(valor)) |>
    filter(data >= INICIO_BUSCA, data <= FIM_BUSCA) |>
    drop_na(valor)
  cat("    ", id_serie, ":", nrow(out), "obs\n")
  out
}


## --- 4. BCB / SGS -----------------------------------------------------------

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
  if (length(pedacos) == 0) {
    warning("SGS: falha em ", codigo, immediate. = TRUE); return(NULL)
  }

  out <- bind_rows(pedacos) |>
    mutate(data  = lubridate::dmy(data),
           valor = as.numeric(stringr::str_replace(valor, ",", "."))) |>
    distinct(data, .keep_all = TRUE) |>
    arrange(data) |>
    select(data, valor)
  cat("    SGS ", codigo, ":", nrow(out), "obs\n")
  out
}


## --- 5. IBGE / SIDRA --------------------------------------------------------

# Função para converter "YYYYMM" em Date (último dia do mês).
# Mantida separada para clareza e para evitar bug do pipe |> dentro de transmute.
yyyymm_para_fim_mes <- function(s) {
  ano <- substr(s, 1, 4)
  mes <- substr(s, 5, 6)
  d <- suppressWarnings(lubridate::ymd(paste0(ano, "-", mes, "-01")))
  # ceiling_date("month") - days(1) = último dia do mês
  lubridate::ceiling_date(d, "month") - lubridate::days(1)
}

sidra_8888 <- function() {
  url <- "https://apisidra.ibge.gov.br/values/t/8888/n1/all/v/all/p/all"
  txt <- http_pegar(url, timeout_s = 180)
  if (is.null(txt)) { warning("SIDRA: falha em 8888", immediate. = TRUE); return(NULL) }

  raw <- tryCatch(jsonlite::fromJSON(txt), error = function(e) NULL)
  if (is.null(raw) || nrow(raw) < 2) {
    warning("SIDRA: 8888 sem dados", immediate. = TRUE); return(NULL)
  }

  rotulos <- as.character(raw[1, ])
  dados   <- as_tibble(raw[-1, , drop = FALSE])
  names(dados) <- rotulos

  cat("    SIDRA 8888: linhas brutas =", nrow(dados), "\n")

  col_mes  <- "Mês (Código)"
  col_var  <- "Variável (Código)"
  col_vnom <- "Variável"
  col_val  <- "Valor"
  col_sec  <- "Seções e atividades industriais (CNAE 2.0)"

  faltam <- setdiff(c(col_mes, col_var, col_vnom, col_val, col_sec), names(dados))
  if (length(faltam) > 0) {
    warning("SIDRA: faltam colunas: ", paste(faltam, collapse = ", "),
            immediate. = TRUE)
    return(NULL)
  }

  # Conversões em passos separados para facilitar diagnóstico
  cat("    primeiras amostras antes do parse:\n")
  cat("      Mês (Código):", paste(head(unique(dados[[col_mes]]), 5), collapse=", "), "\n")
  cat("      Valor:", paste(head(dados[[col_val]], 5), collapse=", "), "\n")
  cat("      Variável (Código):", paste(head(unique(dados[[col_var]]), 5), collapse=", "), "\n")

  dados$.data_fim <- yyyymm_para_fim_mes(dados[[col_mes]])
  dados$.valor    <- suppressWarnings(as.numeric(dados[[col_val]]))

  cat("    após parse:\n")
  cat("      data não-NA:", sum(!is.na(dados$.data_fim)), "/", nrow(dados), "\n")
  cat("      valor não-NA:", sum(!is.na(dados$.valor)),    "/", nrow(dados), "\n")

  out <- tibble(
    data   = dados$.data_fim,
    v_cod  = dados[[col_var]],
    v_nome = dados[[col_vnom]],
    secao  = dados[[col_sec]],
    valor  = dados$.valor
  ) |>
    drop_na(data, valor) |>
    filter(data >= INICIO_BUSCA, data <= FIM_BUSCA)

  cat("    SIDRA 8888 limpo:", nrow(out), "obs\n")
  if (nrow(out) > 0) {
    cat("    cobertura:",
        format(min(out$data)), "a", format(max(out$data)), "\n")
    cat("    códigos de variável:", paste(sort(unique(out$v_cod)), collapse = ", "), "\n")
  }
  out
}


# Códigos da tabela 8888: 12607 = SA, 12606 = NSA
sa_ou_nsa <- function(v_cod) {
  if_else(v_cod == "12607", "SA",
  if_else(v_cod == "12606", "NSA",
                            "OUTRO"))
}


## --- 6. Agregação mensal ---------------------------------------------------

mensal_fim <- function(df) {
  if (is.null(df) || nrow(df) == 0) return(df)
  df |>
    mutate(fim_mes = lubridate::ceiling_date(data, "month") - lubridate::days(1)) |>
    group_by(fim_mes) |>
    summarise(valor = last(valor), .groups = "drop") |>
    rename(data = fim_mes) |>
    arrange(data)
}


## --- 7. Pipeline ------------------------------------------------------------

preparar_serie <- function(d, nome_coluna) {
  if (is.null(d) || nrow(d) == 0) {
    return(tibble(data = as.Date(character()), !!nome_coluna := numeric()))
  }
  d |> rename(!!nome_coluna := valor)
}

executar <- function() {

cat("Baixando séries...\n")

cat("  FRED INDPRO\n");    eua_pi_sa  <- mensal_fim(fred_serie("INDPRO"))
cat("  FRED IPB50001N\n"); eua_pi_nsa <- mensal_fim(fred_serie("IPB50001N"))
cat("  FRED FEDFUNDS\n");  eua_juros  <- mensal_fim(fred_serie("FEDFUNDS"))

cat("  SGS 4189 (Selic anualizada)\n")
br_juros <- mensal_fim(sgs_serie(4189))

cat("  SIDRA 8888 (PIM-PF atual, base 2022=100)\n")
sidra <- sidra_8888()


## --- 8. Painéis wide --------------------------------------------------------

cat("Montando painéis...\n")

eua <- list(
  preparar_serie(eua_pi_sa,  "ind_prod_sa"),
  preparar_serie(eua_pi_nsa, "ind_prod_nsa"),
  preparar_serie(eua_juros,  "fed_funds")
) |>
  reduce(full_join, by = "data") |>
  arrange(data)

cat("  EUA:", nrow(eua), "linhas\n")


if (is.null(sidra) || nrow(sidra) == 0) {
  br_ind_geral <- tibble(data = as.Date(character()),
                         ind_prod_sa = numeric(),
                         ind_prod_nsa = numeric())
  br_secoes <- tibble(data = as.Date(character()),
                      secao = character(), tipo = character(),
                      valor = numeric())
} else {
  br_ind_geral <- sidra |>
    filter(stringr::str_detect(
      secao,
      stringr::regex("ind[uú]stria geral", ignore_case = TRUE))) |>
    mutate(tipo = sa_ou_nsa(v_cod)) |>
    filter(tipo %in% c("SA", "NSA")) |>
    select(data, tipo, valor) |>
    pivot_wider(names_from = tipo, values_from = valor,
                names_prefix = "ind_prod_") |>
    rename_with(tolower)

  cat("  BR indústria geral:", nrow(br_ind_geral), "linhas\n")

  br_secoes <- sidra |>
    filter(!stringr::str_detect(
      secao,
      stringr::regex("ind[uú]stria geral", ignore_case = TRUE))) |>
    mutate(tipo = sa_ou_nsa(v_cod)) |>
    filter(tipo %in% c("SA", "NSA")) |>
    select(data, secao, tipo, valor) |>
    arrange(data, secao, tipo)

  cat("  BR seções:", nrow(br_secoes), "linhas\n")
}

if (!"ind_prod_sa"  %in% names(br_ind_geral)) br_ind_geral$ind_prod_sa  <- NA_real_
if (!"ind_prod_nsa" %in% names(br_ind_geral)) br_ind_geral$ind_prod_nsa <- NA_real_

brasil <- br_ind_geral |>
  full_join(preparar_serie(br_juros, "selic"), by = "data") |>
  arrange(data)

cat("  Brasil:", nrow(brasil), "linhas\n")


## --- 9. Corte para período comum --------------------------------------------

primeiro_se_existe <- function(df, col) {
  if (is.null(df) || nrow(df) == 0) return(NA)
  v <- df[[col]]
  d <- df$data[!is.na(v)]
  if (length(d) == 0) NA else min(d)
}

primeiros <- c(
  eua_pi_sa  = primeiro_se_existe(eua,    "ind_prod_sa"),
  eua_pi_nsa = primeiro_se_existe(eua,    "ind_prod_nsa"),
  eua_juros  = primeiro_se_existe(eua,    "fed_funds"),
  br_juros   = primeiro_se_existe(brasil, "selic"),
  br_pi      = primeiro_se_existe(brasil, "ind_prod_sa")
)
primeiros <- primeiros[!is.na(primeiros)]
corte     <- if (length(primeiros) > 0) max(as.Date(primeiros, origin = "1970-01-01"))
             else INICIO_BUSCA

cat("Período comum começa em:", format(corte))
if (length(primeiros) > 0) {
  cat(" (limitante:", names(primeiros)[which.max(primeiros)], ")")
}
cat("\n")

eua       <- eua       |> filter(data >= corte)
brasil    <- brasil    |> filter(data >= corte)
br_secoes <- br_secoes |> filter(data >= corte)


## --- 10. Estatísticas descritivas -------------------------------------------

descritivas <- function(x) {
  x <- x[!is.na(x)]
  if (length(x) == 0) {
    return(tibble(n = 0L, media = NA_real_, dp = NA_real_,
                  min = NA_real_, p25 = NA_real_, p50 = NA_real_,
                  p75 = NA_real_, max = NA_real_))
  }
  tibble(
    n     = length(x),
    media = mean(x),
    dp    = sd(x),
    min   = min(x),
    p25   = quantile(x, 0.25, names = FALSE),
    p50   = median(x),
    p75   = quantile(x, 0.75, names = FALSE),
    max   = max(x)
  )
}

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

compara_sa_nsa <- function(df, rotulo_pais) {
  if (!all(c("ind_prod_sa", "ind_prod_nsa") %in% names(df))) return(NULL)
  d <- df |> select(data, sa = ind_prod_sa, nsa = ind_prod_nsa) |>
    drop_na(sa, nsa)
  if (nrow(d) == 0) return(NULL)

  diff_nivel <- d$sa - d$nsa
  diff_pct   <- 100 * (d$sa / d$nsa - 1)

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
    mutate(diff_nivel = diff_nivel, diff_pct = diff_pct, pais = rotulo_pais)

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

estilo <- function() {
  theme_minimal(base_size = 11) +
    theme(
      plot.title    = element_text(face = "bold", size = 13),
      plot.subtitle = element_text(size = 10, color = "grey35"),
      plot.caption  = element_text(size = 8,  color = "grey50", hjust = 1),
      panel.grid.minor   = element_blank(),
      panel.grid.major.x = element_blank(),
      legend.position    = "none"
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

janela_subtitulo <- function() {
  d <- c(eua$data, brasil$data); d <- d[!is.na(d)]
  if (length(d) == 0) return("")
  sprintf("Janela: %s a %s", format(min(d), "%Y-%m"), format(max(d), "%Y-%m"))
}

painel <-
  (linha(eua,    "ind_prod_sa", "EUA: Produção industrial (SA)", "Índice") |
   linha(eua,    "fed_funds",   "EUA: Fed Funds Rate",            "% a.a.")) /
  (linha(brasil, "ind_prod_sa", "Brasil: Produção industrial (SA)", "Índice") |
   linha(brasil, "selic",       "Brasil: Selic anualizada base 252", "% a.a.")) +
  plot_annotation(
    title    = "Atividade e Juros — Brasil e EUA",
    subtitle = janela_subtitulo(),
    caption  = "Fontes: FRED, IBGE/SIDRA, BCB/SGS",
    theme    = theme(plot.title = element_text(face = "bold", size = 16))
  )

ggsave(file.path(SAIDA, "painel_atividade_juros.png"),
       painel, width = 11, height = 7, dpi = 110)


if (!is.null(comparacao_serie) && nrow(comparacao_serie) > 0) {
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

salvar_csv(eua,               "eua.csv")
salvar_csv(brasil,            "brasil.csv")
salvar_csv(br_secoes,         "brasil_secoes_cnae.csv")
salvar_csv(estat,             "estatisticas.csv")
salvar_csv(comparacao_resumo, "comparacao_sa_nsa_resumo.csv")
salvar_csv(comparacao_serie,  "comparacao_sa_nsa_serie.csv")

openxlsx::write.xlsx(
  list(EUA               = eua,
       Brasil            = brasil,
       Secoes_CNAE_BR    = br_secoes,
       Estatisticas      = estat,
       Comparacao_Resumo = comparacao_resumo,
       Comparacao_Mensal = comparacao_serie),
  file = file.path(SAIDA, "relatorio_atividade_juros.xlsx"),
  overwrite = TRUE
)

cat("Pronto. Arquivos em ./", SAIDA, "/\n", sep = "")

} # fim executar()

if (sys.nframe() == 0) executar()
