# audit_pipeline_correspondence.R
#
# Checks correspondence across three pipeline stages:
#   (1) plan_txts_raw/   — raw text TSVs, one per PDF
#   (2) plan_txts_clean/ — cleaned parquet, one per raw txt
#   (3) raw_extracted_networks/ — RDS network objects, one per Region_Year group
#
# Run from the project root (the folder containing tijuanabox/).
# Output is printed to console; a summary CSV is written to tijuanabox/int_data/.

suppressPackageStartupMessages({
  library(arrow)
  library(dplyr)
  library(stringr)
  library(purrr)
})

# ── 0. Locate folders (handle alternate naming conventions) ──────────────────

find_dir <- function(candidates) {
  hit <- Filter(dir.exists, candidates)
  if (length(hit) == 0) return(NA_character_)
  hit[[1]]
}

raw_dir <- find_dir(c(
  "tijuanabox/int_data/plan_txts_raw",
  "tijuanabox/plan_text_raw",
  "tijuanabox/int_data/plan_text_raw"
))

clean_dir <- find_dir(c(
  "tijuanabox/int_data/plan_txts_clean",
  "tijuanabox/plan_text_clean",
  "tijuanabox/int_data/plan_text_clean"
))

net_dir <- find_dir(c(
  "tijuanabox/int_data/raw_extracted_networks",
  "tijuanabox/raw_extract_networks",
  "tijuanabox/int_data/raw_extract_networks"
))

cat("=== PIPELINE AUDIT ===\n\n")
cat("Raw text dir:   ", ifelse(is.na(raw_dir),   "[NOT FOUND]", raw_dir),   "\n")
cat("Clean text dir: ", ifelse(is.na(clean_dir), "[NOT FOUND]", clean_dir), "\n")
cat("Networks dir:   ", ifelse(is.na(net_dir),   "[NOT FOUND]", net_dir),   "\n\n")

stopifnot(
  "raw_dir not found — check path"   = !is.na(raw_dir),
  "clean_dir not found — check path" = !is.na(clean_dir),
  "net_dir not found — check path"   = !is.na(net_dir)
)

# ── 1. Inventory raw txt files ───────────────────────────────────────────────

raw_files  <- list.files(raw_dir, pattern = "\\.txt$", full.names = TRUE)
raw_stems  <- str_remove(basename(raw_files), "\\.txt$")

cat("── Stage 1: Raw text files ──────────────────────────────────────────────\n")
cat("  Files found:", length(raw_files), "\n\n")

raw_summary <- map_dfr(raw_files, function(f) {
  tryCatch({
    df <- read.delim(f, sep = "\t", colClasses = c(page = "integer", text = "character"),
                     quote = "", stringsAsFactors = FALSE)
    tibble(
      stem          = str_remove(basename(f), "\\.txt$"),
      raw_n_pages   = nrow(df),
      raw_nonempty  = sum(nchar(trimws(df$text)) > 0, na.rm = TRUE)
    )
  }, error = function(e) {
    tibble(stem = str_remove(basename(f), "\\.txt$"),
           raw_n_pages = NA_integer_, raw_nonempty = NA_integer_)
  })
})

cat("  Total raw pages:    ", sum(raw_summary$raw_n_pages, na.rm = TRUE), "\n")
cat("  Total non-empty:    ", sum(raw_summary$raw_nonempty, na.rm = TRUE), "\n\n")

# ── 2. Inventory clean parquet files ─────────────────────────────────────────

clean_files <- list.files(clean_dir, pattern = "\\.parquet$", full.names = TRUE)
clean_stems <- str_remove(basename(clean_files), "\\.parquet$")

cat("── Stage 2: Clean parquet files ─────────────────────────────────────────\n")
cat("  Files found:", length(clean_files), "\n\n")

clean_summary <- map_dfr(clean_files, function(f) {
  tryCatch({
    df <- arrow::read_parquet(f)
    tibble(
      stem             = str_remove(basename(f), "\\.parquet$"),
      clean_n_pages    = nrow(df),
      clean_nonempty   = sum(nchar(trimws(df$text)) > 0, na.rm = TRUE),
      clean_blanked    = sum(nchar(trimws(df$text)) == 0 | is.na(df$text), na.rm = TRUE),
      clean_usable     = sum(nchar(trimws(df$text)) > 200, na.rm = TRUE)
    )
  }, error = function(e) {
    tibble(stem = str_remove(basename(f), "\\.parquet$"),
           clean_n_pages = NA_integer_, clean_nonempty = NA_integer_,
           clean_blanked = NA_integer_, clean_usable = NA_integer_)
  })
})

cat("  Total clean pages:  ", sum(clean_summary$clean_n_pages, na.rm = TRUE), "\n")
cat("  Blanked by filters: ", sum(clean_summary$clean_blanked, na.rm = TRUE), "\n")
cat("  Usable (>200 chars):", sum(clean_summary$clean_usable, na.rm = TRUE), "\n\n")

# ── 3. Inventory RDS network files ───────────────────────────────────────────

rds_files <- list.files(net_dir, pattern = "\\.RDS$", full.names = TRUE)

cat("── Stage 3: RDS network files ───────────────────────────────────────────\n")
cat("  Files found:", length(rds_files), "\n\n")

net_summary <- map_dfr(rds_files, function(f) {
  tryCatch({
    obj <- readRDS(f)
    rk  <- str_extract(basename(f), "Region_[^_]+_[0-9]{4}")
    tibble(
      rds_file    = basename(f),
      region_year = ifelse(is.na(rk), basename(f), rk),
      n_nodes     = nrow(obj$nodelist),
      n_edges     = nrow(obj$edgelist)
    )
  }, error = function(e) {
    tibble(rds_file    = basename(f),
           region_year = str_extract(basename(f), "Region_[^_]+_[0-9]{4}"),
           n_nodes     = NA_integer_,
           n_edges     = NA_integer_)
  })
})

cat("  Total nodes (sum):  ", sum(net_summary$n_nodes, na.rm = TRUE), "\n")
cat("  Total edges (sum):  ", sum(net_summary$n_edges, na.rm = TRUE), "\n")
cat("  Empty networks:     ",
    sum(is.na(net_summary$n_edges) | net_summary$n_edges == 0), "\n\n")

# ── 4. Correspondence: raw ↔ clean ───────────────────────────────────────────

cat("── Correspondence: raw ↔ clean ──────────────────────────────────────────\n")

in_raw_not_clean <- setdiff(raw_stems, clean_stems)
in_clean_not_raw <- setdiff(clean_stems, raw_stems)

cat("  Raw files with no matching clean file:", length(in_raw_not_clean), "\n")
if (length(in_raw_not_clean) > 0) {
  cat("    ", paste(in_raw_not_clean, collapse = "\n    "), "\n")
}
cat("  Clean files with no matching raw file:", length(in_clean_not_raw), "\n")
if (length(in_clean_not_raw) > 0) {
  cat("    ", paste(in_clean_not_raw, collapse = "\n    "), "\n")
}

# Join and compute page-level retention stats.
# Note: cleaningtxt.py blanks filtered pages in-place (same row count as raw),
# so raw_n_pages == clean_n_pages is expected. The meaningful mismatch is
# raw_n_pages → clean_usable (pages surviving to network extraction).
raw_clean <- full_join(raw_summary, clean_summary, by = "stem") %>%
  mutate(
    row_count_ok = raw_n_pages == clean_n_pages,  # should always be TRUE
    pct_blanked  = round(100 * clean_blanked / pmax(clean_n_pages, 1), 1),
    pct_usable   = round(100 * clean_usable  / pmax(raw_n_pages,   1), 1),
    status       = case_when(
      is.na(raw_n_pages)   ~ "missing_raw",
      is.na(clean_n_pages) ~ "missing_clean",
      !row_count_ok        ~ "row_count_mismatch",  # unexpected — worth investigating
      clean_usable == 0    ~ "no_usable_text",
      TRUE                 ~ "ok"
    )
  )

# File-level status tally
status_tally <- count(raw_clean, status, name = "n_files")
cat("\n  File status summary:\n")
print(as.data.frame(status_tally), row.names = FALSE)

# Page retention summary (the expected mismatch)
matched <- filter(raw_clean, !is.na(raw_n_pages), !is.na(clean_n_pages))
total_raw    <- sum(matched$raw_n_pages,  na.rm = TRUE)
total_usable <- sum(matched$clean_usable, na.rm = TRUE)
total_blanked <- sum(matched$clean_blanked, na.rm = TRUE)
overall_pct  <- round(100 * total_usable / max(total_raw, 1), 1)

cat("\n  Page retention (raw → usable after cleaning):\n")
cat("    Raw pages total:        ", total_raw, "\n")
cat("    Blanked by filters:     ", total_blanked,
    sprintf("(%s%%)", round(100 * total_blanked / max(total_raw, 1), 1)), "\n")
cat("    Usable pages (>200 ch): ", total_usable,
    sprintf("(%s%% of raw)", overall_pct), "\n")

# Flag any files with unexpectedly high or low retention
cat("\n  Files with <10% usable pages (may need review):\n")
low_yield <- filter(raw_clean, status == "ok", pct_usable < 10) %>%
  select(stem, raw_n_pages, clean_usable, pct_usable) %>%
  arrange(pct_usable)
if (nrow(low_yield) == 0) cat("    None\n") else print(as.data.frame(low_yield), row.names = FALSE)

cat("\n  Row count mismatches (unexpected — raw rows ≠ clean rows):\n")
mismatch <- filter(raw_clean, status == "row_count_mismatch") %>%
  select(stem, raw_n_pages, clean_n_pages)
if (nrow(mismatch) == 0) cat("    None\n") else print(as.data.frame(mismatch), row.names = FALSE)

# ── 5. Correspondence: clean ↔ networks ──────────────────────────────────────

cat("\n── Correspondence: clean parquet → Region_Year network ──────────────────\n")

# Derive Region_Year key from clean file stems
clean_keys <- tibble(
  stem        = clean_stems,
  region_year = str_extract(
    str_replace(clean_stems, "^(Region_[^_]+)__([0-9]{4})", "\\1_\\2"),
    "^Region_[^_]+_[0-9]{4}"
  )
)

rdy_from_clean <- clean_keys %>%
  filter(!is.na(region_year)) %>%
  distinct(region_year) %>%
  pull(region_year)

rdy_from_rds <- net_summary$region_year

in_clean_not_rds <- setdiff(rdy_from_clean, rdy_from_rds)
in_rds_not_clean <- setdiff(rdy_from_rds, rdy_from_clean)

cat("  Region_Year groups in clean files:     ", length(rdy_from_clean), "\n")
cat("  Region_Year groups with RDS:           ", length(rdy_from_rds), "\n")
cat("  Groups in clean but NO network RDS:   ", length(in_clean_not_rds), "\n")
if (length(in_clean_not_rds) > 0) {
  cat("    ", paste(sort(in_clean_not_rds), collapse = "\n    "), "\n")
}
cat("  RDS files with no matching clean files:", length(in_rds_not_clean), "\n")
if (length(in_rds_not_clean) > 0) {
  cat("    ", paste(sort(in_rds_not_clean), collapse = "\n    "), "\n")
}

# Files whose stem can't be parsed to Region_Year
unparseable <- clean_keys %>% filter(is.na(region_year))
if (nrow(unparseable) > 0) {
  cat("\n  WARNING:", nrow(unparseable),
      "clean file(s) couldn't be parsed to a Region_Year key:\n")
  cat("    ", paste(unparseable$stem, collapse = "\n    "), "\n")
}

# ── 6. Network detail table ───────────────────────────────────────────────────

cat("\n── Network detail (by Region_Year) ──────────────────────────────────────\n")

# Sum usable clean pages (>200 chars) per Region_Year
pages_per_group <- clean_keys %>%
  filter(!is.na(region_year)) %>%
  left_join(clean_summary, by = "stem") %>%
  group_by(region_year) %>%
  summarise(clean_usable_pages = sum(clean_usable, na.rm = TRUE), .groups = "drop")

net_detail <- net_summary %>%
  left_join(pages_per_group, by = "region_year") %>%
  arrange(region_year)

print(as.data.frame(net_detail), row.names = FALSE)

cat("\nDone.\n")

library(ggplot2)
net_detail |> arrange(-clean_usable_pages) |> ggplot() +
  geom_point(aes(x = log(n_edges), y = clean_usable_pages))
l
net_detail |> filter(n_edges < 10) |> arrange(-clean_usable_pages)
