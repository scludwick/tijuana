# disambiguate_nodelists.R
# Disambiguates entity names in the per-Region_Year extracts produced by
# textnet_parse_and_extract.R. Input and output are both textnet_extract
# objects (lists with $edgelist + $nodelist as data.tables); the output is
# the same object with surface variants of entity names rewritten to
# canonical forms.
#
# This mirrors the kings core_code step4 disambiguation pass, simplified for
# the IRWM corpus: the per-GSP "agency_nicknames" source (which depends on
# the SGMA portal manifest + GSA metadata) is dropped, because tijuana has no
# such metadata. The two remaining sources are doc-mined acronyms and the
# curated dictionaries.
#
# Graph construction, filtering of incomplete edges, weighting, etc. live in
# build_igraphs.R — this script is intentionally just the disambig pass so
# downstream consumers can choose their own filtering and graph-build options.
#
# Inputs:
#   raw_extracted_networks/extract_<Region_Year>.RDS   (from parse step)
#       textnet_extract list: $edgelist + $nodelist as data.tables
#   plan_txts_clean/<Region_Year>_<rest>.parquet       (cleaned text)
#       per-PDF; mined for parenthetical acronyms via find_intext_acronyms()
#   plan_txts_raw_pages/<Region_Year>_<rest>.parquet   (newline-preserved)
#       per-PDF; mined for front-matter acronym tables via
#       extract_front_matter_acronyms()
#   code/dicts/*.csv (all six)                          (alias -> canonical)
#
# Outputs:
#   disambiguated_extracted_networks/extract_<Region_Year>.RDS
#       textnet_extract object with entity names canonicalized; nodelist
#       gains raw_entity_name preserving the pre-disambig surface form.
#   disambiguated_extracts.RDS  (combined list, parity with raw_extracts.RDS)
#
# Run from the repo root:  Rscript code/04_disambiguate_nodelists.R
# Flags (CLOBBER, TESTING, TESTING_N) come from code/_config.R (sourced via
# utils.R). Override from the shell, e.g. CLOBBER=1 Rscript code/04_*.R

library(stringr)
library(data.table)
library(textNet)
library(arrow)

source("code/utils.R")   # DICT_KEYS, build_global_dict(), region_year_key(),
                         # clean_entities() helpers, atomic_saveRDS()

# === Paths ===
raw_dir        <- "tijuanabox/core_data/raw_extracted_networks"
clean_dir      <- "tijuanabox/core_data/plan_txts_clean"
raw_pages_dir  <- "tijuanabox/core_data/plan_txts_raw_pages"
out_dir        <- "tijuanabox/core_data/disambiguated_extracted_networks"
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

try_drop <- "^US_|^U_S_|^United_States_|^UnitedStates_"

# === Enumerate inputs / to-do subset ===
extract_files <- sort(list.files(raw_dir, pattern = "\\.RDS$", full.names = TRUE))
if (length(extract_files) == 0L) {
  stop("No extracts found in ", raw_dir,
       ". Run code/textnet_parse_and_extract.R first.")
}
# Region_Year key for each extract file. The parse step names these
# extract_<Region_Year>.RDS where <Region_Year> is exactly the Region_X_YYYY
# group key, so stripping the prefix/suffix yields the same key form that
# region_year_key() extracts from the member clean/raw-pages parquets below
# (used to gather a Region_Year's PDFs for acronym mining). If extract naming
# ever gains a suffix, switch this to region_year_key() to keep them aligned.
ry_keys   <- sub("^extract_", "", str_remove(basename(extract_files), "\\.RDS$"))
out_paths <- file.path(out_dir, basename(extract_files))

todo_idx <- if (CLOBBER) seq_along(extract_files) else which(!file.exists(out_paths))
n_skipped <- length(extract_files) - length(todo_idx)
if (n_skipped > 0L) {
  message("Skipping ", n_skipped, " Region_Year(s) with existing disambiguated ",
          "extracts (set CLOBBER=1 to rebuild).")
}
if (TESTING && length(todo_idx) > 0L) {
  n <- min(TESTING_N, length(todo_idx))
  message("TESTING mode: using ", n, " of ", length(todo_idx), " to-do Region_Year(s)")
  todo_idx <- todo_idx[seq_len(n)]
}
if (length(todo_idx) == 0L) {
  message("Nothing to do; all disambiguated extracts already present.")
}

# === Global alias -> canonical dictionary (built once) ===
# Only dictionary rows that link an alias to a *different* canonical
# contribute; single-name rows and self-mappings are filtered inside
# build_global_dict(). See code/utils.R.
message("Building global dictionary from ", length(DICT_KEYS), " dict(s)...")
global_dict <- build_global_dict()
message("  global_dict: ", nrow(global_dict), " alias->canonical pair(s)")

# === Acronym mining (per Region_Year) ===
# Uses the shared mine_acronyms() in utils.R (extract_front_matter_acronyms()
# on the raw pages + find_intext_acronyms() on the clean text, front-matter
# winning on collision). The same function feeds the parse step's entity
# ruler, so the two stages stay in sync from one implementation. Here we gather
# the Region_Year's member PDFs and pass their parquets to the miner.
mine_acronyms_for_ry <- function(ry) {
  clean_files <- list.files(clean_dir, pattern = "\\.parquet$", full.names = TRUE)
  clean_files <- clean_files[!is.na(region_year_key(clean_files)) &
                             region_year_key(clean_files) == ry]
  rawpg_files <- list.files(raw_pages_dir, pattern = "\\.parquet$", full.names = TRUE)
  rawpg_files <- rawpg_files[!is.na(region_year_key(rawpg_files)) &
                             region_year_key(rawpg_files) == ry]

  if (length(clean_files) == 0L) {
    warning("No cleaned parquet(s) for ", ry, " in ", clean_dir,
            " — acronym mining limited to front-matter (if any).")
  }
  if (length(rawpg_files) == 0L) {
    warning("No raw-pages parquet(s) for ", ry, " in ", raw_pages_dir,
            " — front-matter acronyms skipped. Re-run code/01_pdftotext.py to ",
            "populate raw pages.")
  }

  mine_acronyms(clean_files, rawpg_files)
}

# === Build per-Region_Year customdt + resolve duplicate `from` keys ===
# Stack mined acronyms (to = long form, from = acronym) under global_dict
# (to = canonical, from = alias), drop duplicates, and resolve any `from`
# that maps to more than one `to` (longest `to` wins as canonical; the
# losing `to` values become aliases of the winner). All rows use
# match_partial_entity = TRUE (the per-GSP nicknames source that needed
# FALSE is not used here).
build_customdt_for_ry <- function(ry) {
  acron <- mine_acronyms_for_ry(ry)
  if (nrow(acron) > 0L) setnames(acron, c("name", "acronym"), c("to", "from"))
  else acron <- data.table(to = character(0), from = character(0))

  customdt <- unique(rbind(acron, global_dict, fill = TRUE))
  customdt <- customdt[!is.na(to) & !is.na(from) &
                       nchar(to) > 0 & nchar(from) > 0 & to != from]
  customdt$match_partial_entity <- TRUE

  fromgroups <- table(customdt$from)
  fromgroups <- fromgroups[fromgroups > 1]
  if (length(fromgroups) > 0L) {
    for (k in seq_along(fromgroups)) {
      dup_from <- names(fromgroups)[k]
      tos      <- customdt[from == dup_from]$to
      keepto   <- tos[order(-nchar(tos))][1]   # longest (most specific) wins
      makefrom <- setdiff(tos, keepto)
      customdt <- customdt[!(from %in% dup_from)]
      customdt <- rbind(customdt, list(keepto, dup_from, TRUE))
      for (mf in makefrom) {
        if (!is.na(mf) && nzchar(mf) && !(mf %in% customdt$from)) {
          customdt <- rbind(customdt, list(keepto, mf, TRUE))
        }
      }
    }
  }
  customdt
}

# === Apply disambiguation ===
# For each Region_Year: read the extract, snapshot the original entity_name
# as raw_entity_name (crosswalk/debugging), normalize the entity-name columns
# through clean_entities() so they match the customdt surface form, run
# disambiguate(), and save. clean_entities() on both sides closes the
# concatenator-vs-clean_entities punctuation drift before lookups.
results <- vector(mode = "list", length = length(extract_files))
names(results) <- ry_keys

for (m in todo_idx) {
  ry <- ry_keys[m]
  message(sprintf("[%d/%d] %s", match(m, todo_idx), length(todo_idx), ry))
  res <- tryCatch({
    customdt <- build_customdt_for_ry(ry)
    edgenodelist <- readRDS(extract_files[m])

    edgenodelist$nodelist$raw_entity_name <- edgenodelist$nodelist$entity_name
    edgenodelist$edgelist$source      <- clean_entities(edgenodelist$edgelist$source)
    edgenodelist$edgelist$target      <- clean_entities(edgenodelist$edgelist$target)
    edgenodelist$nodelist$entity_name <- clean_entities(edgenodelist$nodelist$entity_name)

    edgenodelist <- disambiguate(
      from                 = as.list(customdt$from),
      to                   = as.list(customdt$to),
      match_partial_entity = customdt$match_partial_entity,
      textnet_extract      = edgenodelist,
      try_drop             = try_drop)

    atomic_saveRDS(edgenodelist, out_paths[m])
    edgenodelist
  }, error = function(e) {
    message(sprintf("  ERROR (%s): %s -- continuing", ry, conditionMessage(e)))
    NULL
  })
  results[[m]] <- res
}

# === Combined list (parity with raw_extracts.RDS) ===
# Read whatever disambiguated extracts now exist on disk so the combined file
# reflects the full corpus, not just this run's to-do subset.
all_out <- file.path(out_dir, paste0("extract_", ry_keys, ".RDS"))
have    <- file.exists(all_out)
combined <- lapply(all_out[have], readRDS)
names(combined) <- ry_keys[have]
saveRDS(combined, "tijuanabox/core_data/disambiguated_extracts.RDS")
message("Done. ", sum(have), " disambiguated extract(s) on disk.")
