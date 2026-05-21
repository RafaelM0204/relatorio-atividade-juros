#!/usr/bin/env Rscript
# Diagnóstico 2: descobrir o filtro correto do SIDRA.
# Testo várias variações para ver qual retorna dados reais.

suppressPackageStartupMessages({
  library(httr); library(jsonlite)
})

UA <- "Mozilla/5.0 (relatorio-eesp-quant)"

testar <- function(rotulo, url) {
  cat("\n===", rotulo, "===\n")
  cat("URL:", url, "\n")
  r <- tryCatch(
    GET(url, add_headers(`User-Agent` = UA), timeout(60)),
    error = function(e) { cat("ERRO:", conditionMessage(e), "\n"); NULL }
  )
  if (is.null(r)) return()
  cat("status:", status_code(r), "\n")
  txt <- content(r, "text", encoding = "UTF-8")
  j <- tryCatch(fromJSON(txt), error = function(e) NULL)
  if (is.null(j)) { cat("não parseou como JSON\n"); return() }
  cat("nrow:", nrow(j), "\n")
  if (nrow(j) >= 2) {
    cat("cabeçalhos:\n"); print(as.character(j[1, ]))
    cat("primeira observação:\n"); print(as.character(j[2, ]))
    if (nrow(j) >= 3) {
      cat("segunda observação:\n"); print(as.character(j[3, ]))
    }
  }
}

# Tabela 8159 — "Indústria geral por setor (CNAE 2.0)"
# Variáveis disponíveis: 11602 (com ajuste), 11603 (sem ajuste), 11604 (geral)...
# Vou testar pegando uma variável específica primeiro, sem filtro de classificação
testar(
  "8159 — sem filtro de classificação, 1 variável (12606=indice base fixa)",
  "https://apisidra.ibge.gov.br/values/t/8159/n1/all/v/12606/p/202401-202402"
)

testar(
  "8159 — variável 12607 (índice com ajuste sazonal?), última observação",
  "https://apisidra.ibge.gov.br/values/t/8159/n1/all/v/12607/p/last%201"
)

testar(
  "8159 — todas variáveis, última observação, sem classificação",
  "https://apisidra.ibge.gov.br/values/t/8159/n1/all/v/all/p/last%201"
)

testar(
  "8158 — todas variáveis, última observação, sem classificação",
  "https://apisidra.ibge.gov.br/values/t/8158/n1/all/v/all/p/last%201"
)

# Listar metadados das tabelas via endpoint /metadados (se existir)
cat("\n=== Metadados tabela 8159 ===\n")
r <- tryCatch(GET("https://apisidra.ibge.gov.br/desctabapi.aspx?c=8159",
                  add_headers(`User-Agent` = UA), timeout(30)),
              error = function(e) NULL)
if (!is.null(r)) {
  cat("status:", status_code(r), "\n")
  cat("primeiros 2000 chars:\n")
  cat(substr(content(r, "text", encoding = "UTF-8"), 1, 2000), "\n")
}
