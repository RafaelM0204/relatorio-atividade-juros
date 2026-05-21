############################################################
# Tutorial 3 — Acompanhamento de Atividade e Juros (BR e EUA)
# EESP-QUANT
#
# Versão fundida:
#  - Base: código R do aluno (sem chave FRED, SIDRA, formato long,
#    gráficos profissionais, Selic acumulada anualizada SGS 4189).
#  - Incorpora: download resiliente com retry (.get), bloco de 10
#    anos no BCB, detecção dinâmica do período inicial comum às
#    bases (ponto em que todas as séries-base têm dado).
#
# Fontes:
#   FRED        — fredgraph.csv (sem API key)
#   BCB/SGS     — api.bcb.gov.br/dados/serie/bcdata.sgs
#   IBGE/SIDRA  — apisidra.ibge.gov.br/values
############################################################


############################################################
# 0. Ambiente
############################################################

rm(list = ls())

# Locale UTF-8 (necessário para escrever acentuação correta em
# ambientes minimalistas como GitHub Actions)
tryCatch(Sys.setlocale("LC_ALL", "C.UTF-8"), warning = function(w) NULL)

pacotes_necessarios <- c(
  "tidyverse", "lubridate", "httr", "jsonlite",
  "openxlsx", "scales"
)

for (pacote in setdiff(pacotes_necessarios, rownames(installed.packages()))) {
  install.packages(pacote, repos = "https://cloud.r-project.org")
}

invisible(lapply(pacotes_necessarios, library, character.only = TRUE))

options(scipen = 999)


############################################################
# 1. Parâmetros gerais
############################################################

# Janela máxima de busca; o período efetivo é depois recortado
# para o primeiro mês em que todas as séries-base têm dado.
DATA_INICIO_BUSCA <- as.Date("2000-01-01")
DATA_FIM          <- Sys.Date()
PASTA_SAIDA       <- "output_tutorial_3"

if (!dir.exists(PASTA_SAIDA)) dir.create(PASTA_SAIDA)


############################################################
# 2. Download resiliente — .get()
############################################################

# Toda chamada HTTP passa por aqui. Até 3 tentativas com espera
# crescente, retorna NULL em vez de quebrar o pipeline.
HEADERS <- c(
  "User-Agent" = "Mozilla/5.0 (relatorio-eesp-quant)",
  "Accept"     = "application/json, text/csv, */*"
)

.get <- function(url, retries = 3, timeout_s = 60, as = "text") {
  for (tentativa in seq_len(retries)) {
    resp <- tryCatch(
      httr::GET(url, httr::add_headers(.headers = HEADERS),
                httr::timeout(timeout_s)),
      error = function(e) NULL
    )

    if (is.null(resp)) { Sys.sleep(3 * tentativa); next }

    sc <- httr::status_code(resp)
    if (sc == 404)                return(NULL)
    if (sc %in% c(401, 403))      return(NULL)
    if (sc >= 400)              { Sys.sleep(3 * tentativa); next }

    body <- tryCatch(
      httr::content(resp, as = as, encoding = "UTF-8"),
      error = function(e) NULL
    )
    if (is.null(body) || !nzchar(trimws(body))) return(NULL)
    return(body)
  }
  NULL
}


############################################################
# 3. Download — FRED (via fredgraph.csv, sem chave)
############################################################

baixar_fred <- function(codigo_serie, nome_serie) {
  url <- paste0("https://fred.stlouisfed.org/graph/fredgraph.csv?id=",
                codigo_serie)
  txt <- .get(url)
  if (is.null(txt)) {
    warning(sprintf("Falha ao baixar FRED (%s)", codigo_serie))
    return(tibble(data = as.Date(character()), valor = numeric(),
                  serie = character(), fonte = character(),
                  codigo = character()))
  }

  dados <- readr::read_csv(I(txt), na = c(".", "NA", ""),
                           show_col_types = FALSE)

  dados |>
    rename(data = observation_date, valor = all_of(codigo_serie)) |>
    mutate(
      data   = as.Date(data),
      valor  = as.numeric(valor),
      serie  = nome_serie,
      fonte  = "FRED",
      codigo = codigo_serie
    ) |>
    filter(data >= DATA_INICIO_BUSCA, data <= DATA_FIM) |>
    select(data, valor, serie, fonte, codigo)
}


############################################################
# 4. Download — BCB/SGS (com paginação de 10 anos)
############################################################

baixar_bcb_sgs <- function(codigo_serie, nome_serie, bloco_anos = 10) {
  bordas <- seq(DATA_INICIO_BUSCA, DATA_FIM,
                by = sprintf("%d years", bloco_anos))
  if (tail(bordas, 1) < DATA_FIM) bordas <- c(bordas, DATA_FIM)

  pedacos <- list()
  for (i in seq_len(length(bordas) - 1)) {
    url <- sprintf(
      "https://api.bcb.gov.br/dados/serie/bcdata.sgs.%d/dados?formato=json&dataInicial=%s&dataFinal=%s",
      codigo_serie,
      format(bordas[i],     "%d/%m/%Y"),
      format(bordas[i + 1], "%d/%m/%Y")
    )
    txt <- .get(url)
    if (is.null(txt)) next

    js <- tryCatch(jsonlite::fromJSON(txt), error = function(e) NULL)
    if (is.null(js) || nrow(js) == 0) next

    pedacos[[length(pedacos) + 1]] <- as_tibble(js)
  }

  if (length(pedacos) == 0) {
    warning(sprintf("Falha ao baixar BCB/SGS (%d)", codigo_serie))
    return(tibble(data = as.Date(character()), valor = numeric(),
                  serie = character(), fonte = character(),
                  codigo = character()))
  }

  bind_rows(pedacos) |>
    distinct(data, .keep_all = TRUE) |>
    mutate(
      data   = dmy(data),
      valor  = as.numeric(str_replace(valor, ",", ".")),
      serie  = nome_serie,
      fonte  = "BCB/SGS",
      codigo = as.character(codigo_serie)
    ) |>
    arrange(data) |>
    select(data, valor, serie, fonte, codigo)
}


############################################################
# 5. Download — IBGE/SIDRA
############################################################

# Substitui sidrar::get_sidra. A API SIDRA aceita o mesmo caminho
# que o sidrar monta: /values/t/<tabela>/n1/all/v/all/p/all/c<cls>/all
baixar_sidra <- function(api_path, nome_base, codigo_tabela) {
  url <- paste0("https://apisidra.ibge.gov.br/values", api_path)
  txt <- .get(url, timeout_s = 120)
  if (is.null(txt)) {
    warning(sprintf("Falha ao baixar SIDRA (%s)", codigo_tabela))
    return(tibble(data = as.Date(character()), valor = numeric(),
                  variavel = character(), base = character(),
                  fonte = character(), codigo = character()))
  }

  js <- tryCatch(jsonlite::fromJSON(txt), error = function(e) NULL)
  if (is.null(js) || nrow(js) <= 1) {
    warning(sprintf("SIDRA (%s) retornou vazio", codigo_tabela))
    return(tibble(data = as.Date(character()), valor = numeric(),
                  variavel = character(), base = character(),
                  fonte = character(), codigo = character()))
  }

  # SIDRA retorna a 1ª linha como dicionário (rótulos) e as demais
  # como dados. Promove a 1ª como nomes amigáveis e descarta.
  rotulos <- as.character(js[1, ])
  dados   <- as_tibble(js[-1, , drop = FALSE])
  names(dados) <- rotulos

  padronizar_sidra(dados, nome_base, codigo_tabela)
}


############################################################
# 6. Tratamento — SIDRA
############################################################

# clean_names mínima (substitui janitor::clean_names)
clean_names <- function(df) {
  novos <- tolower(names(df))
  novos <- iconv(novos, to = "ASCII//TRANSLIT")
  novos <- gsub("[^a-z0-9]+", "_", novos)
  novos <- gsub("^_|_$", "", novos)
  names(df) <- novos
  df
}

padronizar_sidra <- function(dados_sidra, nome_base, codigo_tabela) {
  df <- clean_names(dados_sidra)
  df <- mutate(df, across(everything(), as.character))

  detectar_coluna <- function(nomes, padroes) {
    idx <- which(stringr::str_detect(nomes,
                                     stringr::regex(padroes, ignore_case = TRUE)))
    if (length(idx) == 0) return(NA_character_)
    nomes[idx[1]]
  }

  nomes <- names(df)
  col_periodo <- detectar_coluna(nomes,
                                 "mes_codigo|periodo_codigo|ano_mes_codigo")
  if (is.na(col_periodo)) col_periodo <- detectar_coluna(nomes, "^mes$|^periodo$")
  col_valor    <- detectar_coluna(nomes, "^valor$")
  col_variavel <- detectar_coluna(nomes, "^variavel$")

  if (is.na(col_valor) || is.na(col_variavel) || is.na(col_periodo)) {
    stop("Não consegui identificar Período/Valor/Variável no retorno do SIDRA.")
  }

  df |>
    rename(periodo  = all_of(col_periodo),
           valor    = all_of(col_valor),
           variavel = all_of(col_variavel)) |>
    mutate(
      periodo_numerico = stringr::str_extract(periodo, "\\d{6}|\\d{4}/\\d{2}|\\d{4}-\\d{2}"),
      data = case_when(
        stringr::str_detect(periodo_numerico, "^\\d{6}$") ~
          ymd(paste0(stringr::str_sub(periodo_numerico, 1, 4), "-",
                     stringr::str_sub(periodo_numerico, 5, 6), "-01")),
        stringr::str_detect(periodo_numerico, "^\\d{4}/\\d{2}$") ~
          ymd(paste0(stringr::str_replace(periodo_numerico, "/", "-"), "-01")),
        stringr::str_detect(periodo_numerico, "^\\d{4}-\\d{2}$") ~
          ymd(paste0(periodo_numerico, "-01")),
        TRUE ~ NA_Date_
      ),
      valor = readr::parse_number(
        valor,
        locale = readr::locale(decimal_mark = ",", grouping_mark = ".")
      ),
      base   = nome_base,
      fonte  = "IBGE/SIDRA",
      codigo = as.character(codigo_tabela)
    ) |>
    filter(!is.na(data), data >= DATA_INICIO_BUSCA, data <= DATA_FIM)
}


classificar_ajuste_sazonal <- function(variavel) {
  case_when(
    stringr::str_detect(variavel,
      stringr::regex("sem ajuste|n[aã]o ajustad", ignore_case = TRUE)) ~
      "Não ajustada sazonalmente",
    stringr::str_detect(variavel,
      stringr::regex("com ajuste|ajustad|dessazonal", ignore_case = TRUE)) ~
      "Ajustada sazonalmente",
    TRUE ~ "Não ajustada sazonalmente"
  )
}


############################################################
# 7. Estatísticas e comparações
############################################################

gerar_estatisticas <- function(dados, grupo_colunas) {
  dados |>
    group_by(across(all_of(grupo_colunas))) |>
    summarise(
      observacoes   = sum(!is.na(valor)),
      data_inicial  = min(data, na.rm = TRUE),
      data_final    = max(data, na.rm = TRUE),
      media         = mean(valor,   na.rm = TRUE),
      mediana       = median(valor, na.rm = TRUE),
      desvio_padrao = sd(valor,     na.rm = TRUE),
      minimo        = min(valor,    na.rm = TRUE),
      maximo        = max(valor,    na.rm = TRUE),
      .groups = "drop"
    )
}


calcular_comparacao_ajuste <- function(dados, col_serie,
                                       label_ajustada, label_nao_ajustada) {
  base <- dados |>
    select(data, serie_tipo = all_of(col_serie), valor) |>
    filter(serie_tipo %in% c(label_ajustada, label_nao_ajustada)) |>
    group_by(data, serie_tipo) |>
    summarise(valor = mean(valor, na.rm = TRUE), .groups = "drop") |>
    pivot_wider(names_from = serie_tipo, values_from = valor)

  if (!all(c(label_ajustada, label_nao_ajustada) %in% names(base))) {
    warning("Comparação SA vs NSA: uma das séries ausente.")
    return(list(
      comparacao = tibble(),
      estatisticas = tibble()
    ))
  }

  comparacao <- base |>
    rename(producao_ajustada     = all_of(label_ajustada),
           producao_nao_ajustada = all_of(label_nao_ajustada)) |>
    mutate(
      diferenca_nivel      = producao_ajustada - producao_nao_ajustada,
      diferenca_percentual = 100 * (producao_ajustada / producao_nao_ajustada - 1)
    )

  estatisticas <- comparacao |>
    summarise(
      correlacao                 = cor(producao_ajustada, producao_nao_ajustada,
                                       use = "complete.obs"),
      media_diferenca_nivel      = mean(diferenca_nivel,      na.rm = TRUE),
      media_diferenca_percentual = mean(diferenca_percentual, na.rm = TRUE),
      desvio_padrao_diferenca    = sd(diferenca_nivel,        na.rm = TRUE),
      minimo_diferenca           = min(diferenca_nivel,       na.rm = TRUE),
      maximo_diferenca           = max(diferenca_nivel,       na.rm = TRUE)
    )

  list(comparacao = comparacao, estatisticas = estatisticas)
}


############################################################
# 8. Gráficos profissionais
############################################################

tema_profissional <- theme_minimal(base_size = 13) +
  theme(
    plot.title    = element_text(face = "bold", size = 16, colour = "#1F1F1F"),
    plot.subtitle = element_text(size = 11, colour = "#4F4F4F"),
    axis.title    = element_text(face = "bold", colour = "#1F1F1F"),
    axis.text     = element_text(colour = "#333333"),
    legend.position = "bottom",
    legend.title    = element_blank(),
    legend.text     = element_text(size = 10),
    panel.grid.minor   = element_blank(),
    panel.grid.major.x = element_blank(),
    panel.grid.major.y = element_line(colour = "#D9D9D9", linewidth = 0.4),
    plot.caption       = element_text(size = 9, colour = "#666666")
  )


salvar_grafico <- function(dados, nome_arquivo, titulo, subtitulo,
                           eixo_y, fonte, cores = NULL,
                           base_100 = FALSE, sufixo_y = "") {
  dados_g <- dados |> filter(!is.na(valor))
  if (nrow(dados_g) == 0) {
    warning("Gráfico não gerado (sem dados): ", nome_arquivo)
    return(NULL)
  }

  if (base_100) {
    dados_g <- dados_g |>
      group_by(serie) |>
      arrange(data) |>
      mutate(valor_g = 100 * valor / first(valor[!is.na(valor)])) |>
      ungroup()
  } else {
    dados_g <- dados_g |> mutate(valor_g = valor)
  }

  g <- ggplot(dados_g, aes(x = data, y = valor_g, color = serie)) +
    geom_line(linewidth = 1.1, na.rm = TRUE) +
    scale_x_date(date_breaks = "2 years", date_labels = "%Y") +
    scale_y_continuous(labels = scales::label_number(
      accuracy = 0.1, suffix = sufixo_y,
      decimal.mark = ",", big.mark = ".")) +
    labs(title = titulo, subtitle = subtitulo,
         x = NULL, y = eixo_y, caption = fonte) +
    tema_profissional

  if (!is.null(cores)) g <- g + scale_color_manual(values = cores)

  ggsave(file.path(PASTA_SAIDA, nome_arquivo), plot = g,
         width = 10, height = 6, dpi = 300)
  invisible(g)
}


############################################################
# 9. Pipeline principal
############################################################

main <- function() {
  ## 9.1 Download ----------------------------------------------------------
  cat("[1/6] FRED…\n")
  producao_eua_sa  <- baixar_fred("INDPRO",
                                  "EUA - Produção industrial - ajustada sazonalmente")
  producao_eua_nsa <- baixar_fred("IPB50001N",
                                  "EUA - Produção industrial - não ajustada sazonalmente")
  juros_eua        <- baixar_fred("FEDFUNDS",
                                  "EUA - Federal Funds Effective Rate")

  cat("[2/6] BCB/SGS…\n")
  juros_brasil <- baixar_bcb_sgs(
    4189, "Brasil - Selic acumulada no mês anualizada base 252")

  cat("[3/6] IBGE/SIDRA…\n")
  producao_brasil_categorias <- baixar_sidra(
    "/t/8158/n1/all/v/all/p/all/c543/all",
    "Brasil - Produção industrial por categoria de uso", 8158)
  producao_brasil_setores <- baixar_sidra(
    "/t/8159/n1/all/v/all/p/all/c544/all",
    "Brasil - Produção industrial por setores", 8159)

  ## 9.2 Processamento ----------------------------------------------------
  cat("[4/6] Processando…\n")

  producao_eua <- bind_rows(producao_eua_sa, producao_eua_nsa)

  producao_brasil <- bind_rows(
    producao_brasil_setores,
    producao_brasil_categorias
  ) |>
    filter(stringr::str_detect(variavel,
      stringr::regex("número|numero|índice|indice", ignore_case = TRUE))) |>
    mutate(ajuste_sazonal = classificar_ajuste_sazonal(variavel))

  diagnostico_variaveis_brasil <- producao_brasil |>
    distinct(variavel, ajuste_sazonal)

  producao_brasil_industria_geral <- producao_brasil |>
    filter(if_any(everything(), ~ stringr::str_detect(
      as.character(.x),
      stringr::regex("indústria geral|industria geral", ignore_case = TRUE)))) |>
    mutate(serie = paste0("Brasil - Produção industrial - ", ajuste_sazonal))

  # --- recorte: primeiro mês comum a todas as séries-base ---
  primeiros_meses <- c(
    EUA_SA   = if (nrow(producao_eua_sa)  > 0) min(producao_eua_sa$data)  else NA,
    EUA_NSA  = if (nrow(producao_eua_nsa) > 0) min(producao_eua_nsa$data) else NA,
    EUA_FFR  = if (nrow(juros_eua)        > 0) min(juros_eua$data)        else NA,
    BR_SELIC = if (nrow(juros_brasil)     > 0) min(juros_brasil$data)     else NA,
    BR_PI    = if (nrow(producao_brasil_industria_geral) > 0)
                 min(producao_brasil_industria_geral$data) else NA
  )
  primeiros_meses <- primeiros_meses[!is.na(primeiros_meses)]
  data_corte <- if (length(primeiros_meses) > 0) max(primeiros_meses)
                else DATA_INICIO_BUSCA
  cat(sprintf("       período inicial comum: %s\n", format(data_corte)))
  cat("       (limitante: ",
      names(primeiros_meses)[which.max(primeiros_meses)], ")\n", sep = "")

  filtrar_corte <- function(df) df |> filter(data >= data_corte)
  producao_eua                    <- filtrar_corte(producao_eua)
  producao_eua_sa                 <- filtrar_corte(producao_eua_sa)
  producao_eua_nsa                <- filtrar_corte(producao_eua_nsa)
  juros_eua                       <- filtrar_corte(juros_eua)
  juros_brasil                    <- filtrar_corte(juros_brasil)
  producao_brasil                 <- filtrar_corte(producao_brasil)
  producao_brasil_industria_geral <- filtrar_corte(producao_brasil_industria_geral)

  juros_comparativos <- bind_rows(juros_brasil, juros_eua)

  producao_comparativa <- bind_rows(
    producao_eua |>
      mutate(
        ajuste_sazonal = if_else(codigo == "INDPRO",
                                 "Ajustada sazonalmente",
                                 "Não ajustada sazonalmente"),
        variavel = serie,
        base     = "EUA - Produção industrial"
      ),
    producao_brasil_industria_geral |>
      select(data, valor, serie, fonte, codigo, variavel, ajuste_sazonal, base)
  )

  ## 9.3 Estatísticas -----------------------------------------------------
  estatisticas_producao_eua <- gerar_estatisticas(
    producao_eua, c("serie", "fonte", "codigo"))
  estatisticas_juros <- gerar_estatisticas(
    juros_comparativos, c("serie", "fonte", "codigo"))

  estatisticas_producao_brasil <- producao_brasil |>
    group_by(base, variavel, ajuste_sazonal, fonte, codigo) |>
    summarise(
      observacoes   = sum(!is.na(valor)),
      data_inicial  = min(data, na.rm = TRUE),
      data_final    = max(data, na.rm = TRUE),
      media         = mean(valor,   na.rm = TRUE),
      mediana       = median(valor, na.rm = TRUE),
      desvio_padrao = sd(valor,     na.rm = TRUE),
      minimo        = min(valor,    na.rm = TRUE),
      maximo        = max(valor,    na.rm = TRUE),
      .groups = "drop"
    )

  ## 9.4 Comparações SA vs NSA -------------------------------------------
  resultado_eua <- calcular_comparacao_ajuste(
    producao_eua, "serie",
    "EUA - Produção industrial - ajustada sazonalmente",
    "EUA - Produção industrial - não ajustada sazonalmente"
  )
  resultado_brasil <- calcular_comparacao_ajuste(
    producao_brasil_industria_geral, "ajuste_sazonal",
    "Ajustada sazonalmente",
    "Não ajustada sazonalmente"
  )

  ## 9.5 CSVs e Excel ----------------------------------------------------
  cat("[5/6] Exportando…\n")

  salvar_csv <- function(d, n) readr::write_csv(d, file.path(PASTA_SAIDA, n))

  csvs <- list(
    "producao_industrial_eua.csv"                     = producao_eua,
    "producao_industrial_brasil.csv"                   = producao_brasil,
    "producao_industrial_brasil_industria_geral.csv"   = producao_brasil_industria_geral,
    "juros_brasil_eua.csv"                             = juros_comparativos,
    "producao_comparativa_brasil_eua.csv"              = producao_comparativa,
    "estatisticas_producao_eua.csv"                    = estatisticas_producao_eua,
    "estatisticas_producao_brasil.csv"                 = estatisticas_producao_brasil,
    "estatisticas_juros.csv"                           = estatisticas_juros,
    "comparacao_eua_ajuste_sazonal.csv"                = resultado_eua$comparacao,
    "estatisticas_diferenca_eua.csv"                   = resultado_eua$estatisticas,
    "comparacao_brasil_ajuste_sazonal.csv"             = resultado_brasil$comparacao,
    "estatisticas_diferenca_brasil.csv"                = resultado_brasil$estatisticas,
    "diagnostico_variaveis_brasil.csv"                 = diagnostico_variaveis_brasil
  )
  invisible(purrr::iwalk(csvs, ~ salvar_csv(.x, .y)))

  openxlsx::write.xlsx(
    x = list(
      "producao_eua"          = producao_eua,
      "producao_brasil"       = producao_brasil,
      "prod_brasil_ind_geral" = producao_brasil_industria_geral,
      "juros_brasil_eua"      = juros_comparativos,
      "producao_comparativa"  = producao_comparativa,
      "estat_prod_eua"        = estatisticas_producao_eua,
      "estat_prod_brasil"     = estatisticas_producao_brasil,
      "estat_juros"           = estatisticas_juros,
      "dif_eua_ajuste"        = resultado_eua$comparacao,
      "estat_dif_eua"         = resultado_eua$estatisticas,
      "dif_brasil_ajuste"     = resultado_brasil$comparacao,
      "estat_dif_brasil"      = resultado_brasil$estatisticas,
      "diagnostico_brasil"    = diagnostico_variaveis_brasil
    ),
    file = file.path(PASTA_SAIDA, "relatorio_tutorial_3.xlsx"),
    overwrite = TRUE
  )

  ## 9.6 Gráficos --------------------------------------------------------
  cat("[6/6] Gráficos…\n")

  salvar_grafico(
    dados = producao_eua,
    nome_arquivo = "grafico_producao_eua.png",
    titulo    = "Estados Unidos: Produção Industrial",
    subtitulo = "Comparação entre as séries ajustada e não ajustada sazonalmente",
    eixo_y = "Índice", fonte = "Fonte: FRED",
    cores = c(
      "EUA - Produção industrial - ajustada sazonalmente"     = "#1F77B4",
      "EUA - Produção industrial - não ajustada sazonalmente" = "#FF7F0E"
    )
  )

  salvar_grafico(
    dados = juros_comparativos,
    nome_arquivo = "grafico_juros_brasil_eua.png",
    titulo    = "Brasil e EUA: Juros de Curto Prazo",
    subtitulo = "Selic acumulada anualizada (base 252) e Federal Funds Effective Rate",
    eixo_y = "Taxa (% a.a.)",
    fonte  = "Fontes: BCB/SGS (4189) e FRED (FEDFUNDS)",
    cores = c(
      "Brasil - Selic acumulada no mês anualizada base 252" = "#0B6E4F",
      "EUA - Federal Funds Effective Rate"                  = "#8E44AD"
    ),
    sufixo_y = "%"
  )

  salvar_grafico(
    dados = producao_brasil_industria_geral,
    nome_arquivo = "grafico_producao_brasil_industria_geral.png",
    titulo    = "Brasil: Produção Industrial",
    subtitulo = "Evolução do índice geral",
    eixo_y = "Índice", fonte = "Fonte: IBGE/SIDRA",
    cores = c(
      "Brasil - Produção industrial - Ajustada sazonalmente"     = "#006D77",
      "Brasil - Produção industrial - Não ajustada sazonalmente" = "#E29578"
    )
  )

  salvar_grafico(
    dados = producao_comparativa,
    nome_arquivo = "grafico_producao_brasil_eua.png",
    titulo    = "Produção Industrial: Brasil x EUA",
    subtitulo = "Séries normalizadas em base 100 no início da amostra",
    eixo_y = "Índice, base 100",
    fonte  = "Fontes: FRED e IBGE/SIDRA",
    cores = c(
      "EUA - Produção industrial - ajustada sazonalmente"        = "#1F77B4",
      "EUA - Produção industrial - não ajustada sazonalmente"    = "#6BAED6",
      "Brasil - Produção industrial - Ajustada sazonalmente"     = "#D62728",
      "Brasil - Produção industrial - Não ajustada sazonalmente" = "#FF9896"
    ),
    base_100 = TRUE
  )

  cat("\nConcluído. Arquivos em:", PASTA_SAIDA, "\n")
  invisible(list(
    eua = producao_eua, brasil = producao_brasil,
    juros = juros_comparativos, data_corte = data_corte
  ))
}

if (sys.nframe() == 0) main()
