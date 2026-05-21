#!/usr/bin/env Rscript
# Script de diagnóstico — descobre o que cada API está realmente retornando
# para a gente poder ajustar os parsers.

suppressPackageStartupMessages({
  for (p in c("httr","jsonlite","readr","dplyr")) library(p, character.only = TRUE)
})

UA <- "Mozilla/5.0 (relatorio-eesp-quant)"

pegar <- function(url) {
  cat("\n>>> GET", url, "\n")
  r <- tryCatch(
    httr::GET(url, httr::add_headers(`User-Agent` = UA),
              httr::timeout(60)),
    error = function(e) { cat("   ERRO:", conditionMessage(e), "\n"); NULL }
  )
  if (is.null(r)) return(NULL)
  cat("   status:", httr::status_code(r), "\n")
  cat("   content-type:", httr::headers(r)$`content-type`, "\n")
  txt <- httr::content(r, as = "text", encoding = "UTF-8")
  cat("   bytes:", nchar(txt), "\n")
  cat("   primeiros 500 chars:\n")
  cat("---\n")
  cat(substr(txt, 1, 500))
  cat("\n---\n")
  txt
}

cat("==================== FRED ====================\n")
pegar("https://fred.stlouisfed.org/graph/fredgraph.csv?id=INDPRO")

cat("\n==================== SGS 4189 ====================\n")
pegar("https://api.bcb.gov.br/dados/serie/bcdata.sgs.4189/dados?formato=json&dataInicial=01/01/2024&dataFinal=01/06/2024")

cat("\n==================== SIDRA 8159 (cabeçalhos) ====================\n")
txt <- pegar("https://apisidra.ibge.gov.br/values/t/8159/n1/all/v/all/p/202401-202402/c544/all")
if (!is.null(txt)) {
  j <- tryCatch(jsonlite::fromJSON(txt), error = function(e) NULL)
  if (!is.null(j) && nrow(j) >= 1) {
    cat("\nCabeçalhos SIDRA 8159 (linha 1 do JSON):\n")
    print(as.character(j[1, ]))
    cat("\nValores da linha 2 (1ª observação):\n")
    print(as.character(j[2, ]))
  }
}

cat("\n==================== SIDRA 8158 (cabeçalhos) ====================\n")
txt <- pegar("https://apisidra.ibge.gov.br/values/t/8158/n1/all/v/all/p/202401-202402/c543/all")
if (!is.null(txt)) {
  j <- tryCatch(jsonlite::fromJSON(txt), error = function(e) NULL)
  if (!is.null(j) && nrow(j) >= 1) {
    cat("\nCabeçalhos SIDRA 8158 (linha 1 do JSON):\n")
    print(as.character(j[1, ]))
    cat("\nValores da linha 2 (1ª observação):\n")
    print(as.character(j[2, ]))
  }
}

cat("\n==================== FIM ====================\n")
