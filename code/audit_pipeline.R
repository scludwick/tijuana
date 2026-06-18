# audit_pipeline.R
# Per-Region_Year retention audit across the pipeline. tijuana fans many
# source PDFs into one Region_Year at the extract stage, so the early stages
# (PDFs, clean text) are measured per PDF and aggregated up to Region_Year,
# while the extract / disambig / graph stages are already per Region_Year.
#
# Columns:
#   n_pdfs          source PDFs belonging to the Region_Year
#   pdf_pages       sum of source-PDF page counts (pdftools::pdf_info)
#   clean_rows      sum of clean-parquet rows (pages carried into cleaning)
#   clean_nonblank  sum of clean-parquet rows whose text is not blank
#   extract_nodes   nrow(raw extract $nodelist)
#   extract_edges   nrow(raw extract $edgelist)
#   disambig_nodes  nrow(disambiguated $nodelist)
#   graph_nodes     igraph::vcount(multiplex)
#   graph_edges     igraph::ecount(multiplex)
#   status          ok / missing_<stage>
#
# Deviation from the kings audit: kings counts raw-TSV newlines for raw_rows
# because its TSV strips in-cell newlines (1 line per page). tijuana's TSV
# preserves in-cell newlines, so a newline count would overcount; clean_rows
# (one row per page, read via arrow) is the reliable analogue and is used here.
#
# Adapted from kings core_code step_audit_pipeline.R.
# Run from the repo root:  Rscript code/audit_pipeline.R

suppressPackageStartupMessages({
  library(data.table)
  library(stringr)
  library(arrow)
  library(igraph)
  library(pdftools)
})

source("code/utils.R")   # region_year_key(), atomic_write()

pdf_dir       <- "tijuanabox/raw_data/plan_pdfs"
clean_dir     <- "tijuanabox/int_data/plan_txts_clean"
extract_dir   <- "tijuanabox/int_data/raw_extracted_networks"
disambig_dir  <- "tijuanabox/int_data/disambiguated_extracted_networks"
multiplex_dir <- "tijuanabox/int_data/igraph_objects/multiplex"
out_csv       <- "output/pipeline_audit.csv"

list_or_empty <- function(d, pat) {
  if (dir.exists(d)) list.files(d, pattern = pat, full.names = TRUE) else character(0)
}
# extract_<Region_Year>.RDS -> Region_Year
extract_ry <- function(f) sub("^extract_", "", str_remove(basename(f), "\\.RDS$"))

cat("=== TIJUANA PIPELINE AUDIT ===\n\n")

# 1. Source PDFs: page counts, aggregated to Region_Year ---------------------
pdf_files <- list_or_empty(pdf_dir, "\\.[Pp][Dd][Ff]$")
cat(sprintf("Source PDFs:   %d\n", length(pdf_files)))
pdf_dt <- if (length(pdf_files)) rbindlist(lapply(pdf_files, function(f) {
  info <- tryCatch(pdftools::pdf_info(f), error = function(e) NULL)
  data.table(Region_Year = region_year_key(f),
             pdf_pages = if (is.null(info)) NA_integer_ else as.integer(info$pages))
})) else data.table(Region_Year = character(0), pdf_pages = integer(0))
pdf_agg <- pdf_dt[!is.na(Region_Year),
                  .(n_pdfs = .N, pdf_pages = sum(pdf_pages, na.rm = TRUE)),
                  by = Region_Year]

# 2. Clean parquet: rows + non-blank rows, aggregated to Region_Year ---------
clean_files <- list_or_empty(clean_dir, "\\.parquet$")
cat(sprintf("Clean parquet: %d\n", length(clean_files)))
clean_dt <- if (length(clean_files)) rbindlist(lapply(clean_files, function(f) {
  df <- tryCatch(arrow::read_parquet(f, col_select = "text"), error = function(e) NULL)
  data.table(
    Region_Year    = region_year_key(f),
    clean_rows     = if (is.null(df)) NA_integer_ else nrow(df),
    clean_nonblank = if (is.null(df)) NA_integer_
                     else sum(!is.na(df$text) & nchar(trimws(df$text)) > 0L))
})) else data.table(Region_Year = character(0))
clean_agg <- clean_dt[!is.na(Region_Year),
                      .(clean_rows = sum(clean_rows, na.rm = TRUE),
                        clean_nonblank = sum(clean_nonblank, na.rm = TRUE)),
                      by = Region_Year]

# 3. Raw extracts (per Region_Year) -----------------------------------------
extract_files <- list_or_empty(extract_dir, "\\.RDS$")
cat(sprintf("Raw extracts:  %d\n", length(extract_files)))
extract_dt <- if (length(extract_files)) rbindlist(lapply(extract_files, function(f) {
  obj <- tryCatch(readRDS(f), error = function(e) NULL)
  data.table(Region_Year   = extract_ry(f),
             extract_nodes = if (is.null(obj)) NA_integer_ else nrow(obj$nodelist),
             extract_edges = if (is.null(obj)) NA_integer_ else nrow(obj$edgelist))
})) else data.table(Region_Year = character(0))

# 4. Disambiguated extracts (per Region_Year) -------------------------------
disambig_files <- list_or_empty(disambig_dir, "\\.RDS$")
cat(sprintf("Disambig:      %d\n", length(disambig_files)))
disambig_dt <- if (length(disambig_files)) rbindlist(lapply(disambig_files, function(f) {
  obj <- tryCatch(readRDS(f), error = function(e) NULL)
  data.table(Region_Year    = extract_ry(f),
             disambig_nodes = if (is.null(obj)) NA_integer_ else nrow(obj$nodelist))
})) else data.table(Region_Year = character(0))

# 5. Multiplex graphs (per Region_Year) -------------------------------------
graph_files <- list_or_empty(multiplex_dir, "\\.RDS$")
cat(sprintf("Multiplex:     %d\n\n", length(graph_files)))
graph_dt <- if (length(graph_files)) rbindlist(lapply(graph_files, function(f) {
  g <- tryCatch(readRDS(f), error = function(e) NULL)
  data.table(Region_Year = extract_ry(f),
             graph_nodes = if (is.null(g)) NA_integer_ else igraph::vcount(g),
             graph_edges = if (is.null(g)) NA_integer_ else igraph::ecount(g))
})) else data.table(Region_Year = character(0))

# Join (full outer across all stages) ---------------------------------------
merge_all <- function(x, y) merge(x, y, by = "Region_Year", all = TRUE)
audit <- Reduce(merge_all, list(pdf_agg, clean_agg, extract_dt, disambig_dt, graph_dt))
setorder(audit, Region_Year)

audit[, status := fifelse(is.na(pdf_pages),      "missing_pdf",
                  fifelse(is.na(clean_nonblank), "missing_clean",
                  fifelse(is.na(extract_nodes),  "missing_extract",
                  fifelse(is.na(disambig_nodes), "missing_disambig",
                  fifelse(is.na(graph_nodes),    "missing_graph", "ok")))))]

cat("File status summary:\n")
print(audit[, .(n = .N), by = status])

dir.create(dirname(out_csv), recursive = TRUE, showWarnings = FALSE)
atomic_write(out_csv, function(p) write.csv(audit, p, row.names = FALSE))
cat(sprintf("\nWrote audit summary to %s\n", out_csv))
