#!/usr/bin/env Rscript
# Diagnóstico tabela 8888 — substituta moderna da 8159
suppressPackageStartupMessages({
  library(httr); library(jsonlite)
})

UA <- "Mozilla/5.0 (relatorio-eesp-quant)"

testar <- function(rotulo, url) {
  cat("\n===", rotulo, "===\n")
  cat("URL:", url, "\n")
  r <- tryCatch(GET(url, add_headers(`User-Agent` = UA), timeout(120)),
                error = function(e) { cat("ERRO:", conditionMessage(e), "\n"); NULL })
  if (is.null(r)) return()
  cat("status:", status_code(r), "\n")
  txt <- content(r, "text", encoding = "UTF-8")
  j <- tryCatch(fromJSON(txt), error = function(e) NULL)
  if (is.null(j)) { cat("não parseou\n"); return() }
  cat("nrow:", nrow(j), "\n")
  if (nrow(j) >= 2) {
    cat("\nrotulos:\n"); print(as.character(j[1, ]))
    cat("\nobs 1:\n"); print(as.character(j[2, ]))
    if (nrow(j) >= 3) { cat("\nobs 2:\n"); print(as.character(j[3, ])) }
    cat("\núltima obs:\n"); print(as.character(j[nrow(j), ]))
  }
}

# Teste 1: última observação, todas as variáveis
testar("8888 - última obs, todas variáveis",
  "https://apisidra.ibge.gov.br/values/t/8888/n1/all/v/all/p/last%201")

# Teste 2: pegar 1 mês recente
testar("8888 - 2026-01 a 2026-02",
  "https://apisidra.ibge.gov.br/values/t/8888/n1/all/v/all/p/202601-202602")

# Teste 3: confirmar período total disponível
cat("\n\n=== Período mais antigo (200201) e mais recente (último) ===\n")
testar("8888 - jan/2002",
  "https://apisidra.ibge.gov.br/values/t/8888/n1/all/v/all/p/200201")
