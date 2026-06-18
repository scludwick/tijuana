# utils.R — shared helpers for the tijuana network pipeline.
# Sourced by textnet_parse_and_extract.R, disambiguate_nodelists.R,
# build_igraphs.R, and audit_pipeline.R. Keeps the dictionary list and the
# schema-aware loaders in one place so the parse step (entity ruler) and the
# disambiguation step stay in sync, and provides crash-safe atomic writes.
#
# Usage in a script (run from the repo root):
#   source("code/utils.R")
#
# Ported/adapted from the kings core_code pipeline (_config.R, step3, step4).
# Deliberately lightweight: no filekey.csv / env-var config layer — tijuana's
# paths are few and stable, so the KISS choice is plain relative paths in
# each script plus this shared helper file.

suppressPackageStartupMessages({
  library(stringr)
  library(data.table)
})

# Pipeline flags + tunables (CLOBBER, TESTING, TESTING_N, MIN_PAGE_CHARS,
# PARSE_WORKERS, SPACY_ENV) and atomic_write()/atomic_saveRDS() live in
# _config.R, kings-style. Sourcing utils.R brings them in too.
source("code/_config.R")

# === Dictionaries ===========================================================
# Canonical list of curated dictionaries the pipeline knows about. Used by
# the parse step (entity-ruler patterns) AND the disambiguation step
# (alias -> canonical map). Edit here; both steps pick it up.
#
# Schema note: the five water + utility dicts share the `all_names`
# pipe-delimited schema (first piece = canonical, rest = aliases).
# gov_entities_dict has (State, Agency, Abbr) columns instead. Both loaders
# below detect the schema at load time and handle either form.
DICT_DIR  <- "code/dicts"
DICT_KEYS <- c("water_entity_dictionary",
               "water_infrastructure_dictionary",
               "water_bodies_dictionary",
               "water_gsa_dictionary",
               "ca_utilities_dictionary",
               "gov_entities_dict")

# Resolve a dictionary key to its CSV path. Errors loudly if missing so a
# typo in DICT_KEYS surfaces immediately rather than silently dropping a dict.
dict_path <- function(key) {
  p <- file.path(DICT_DIR, paste0(key, ".csv"))
  if (!file.exists(p)) stop("Dictionary not found: ", p,
                            " (check DICT_DIR / DICT_KEYS in code/utils.R)")
  p
}

# Extract the Region_Year grouping key (e.g. "Region_7_2020") from a path or
# filename. The unit of analysis in tijuana is Region_Year: individual PDFs
# (clean parquet, raw-pages parquet) carry it as a filename prefix
# (Region_X_YYYY_<rest>), and per-Region_Year extracts are named
# extract_<Region_Year>.RDS. Legacy double-underscore (Region_X__YYYY) is
# normalized to a single underscore. Returns NA if no key is present.
region_year_key <- function(x) {
  b <- basename(x)
  b <- stringr::str_replace(b, "(Region_[^_]+)__([0-9]{4})", "\\1_\\2")
  stringr::str_extract(b, "Region_[^_]+_[0-9]{4}")
}

# Normalize a dict surface form to the spaCy concatenated entity surface
# (hyphens and whitespace -> underscore) so dict aliases align with the
# nodelist's concatenated entity names. Idempotent.
to_concat <- function(x) stringr::str_replace_all(x, "-|\\s", "_")

# --- Entity-ruler loader (parse step) -------------------------------------
# Returns a flat character vector of every candidate entity surface in a
# dictionary (canonical + all aliases). Space-separated on disk so the
# entity ruler matches raw PDF text; the parse step filters to multi-word
# terms afterwards.
load_dict_terms <- function(f) {
  if (!file.exists(f)) { warning("Missing dictionary: ", f); return(character(0)) }
  d <- read.csv(f, stringsAsFactors = FALSE)
  if ("all_names" %in% names(d)) {
    unlist(strsplit(d$all_names, split = "|", fixed = TRUE))
  } else if (all(c("Agency", "Abbr") %in% names(d))) {
    unique(c(d$Agency, d$Abbr))
  } else {
    warning("Unknown dictionary schema (", f,
            "): expected 'all_names' or Agency+Abbr")
    character(0)
  }
}

# --- Disambiguation loader (disambiguate step) ----------------------------
# Returns a (to, from) data.table of alias -> canonical pairs. A dictionary
# row only contributes if it links an alias to a *different* canonical;
# single-name rows (no alias) and self-mappings tell disambiguate() nothing
# and are filtered out by the caller. Names are concatenated and run through
# textNet::clean_entities() so they meet the nodelist in the same surface form.
load_alias_pairs <- function(f) {
  if (!file.exists(f)) { warning("Missing dictionary: ", f); return(NULL) }
  d <- read.csv(f, stringsAsFactors = FALSE)
  if ("all_names" %in% names(d)) {
    data.table::rbindlist(lapply(d$all_names, function(s) {
      parts <- strsplit(s, "|", fixed = TRUE)[[1]]
      if (length(parts) < 2L) return(NULL)   # canonical only, no alias
      canonical <- textNet::clean_entities(to_concat(parts[1]),  remove_nums = TRUE)
      aliases   <- textNet::clean_entities(to_concat(parts[-1]), remove_nums = TRUE)
      data.table::data.table(to = canonical, from = aliases)
    }))
  } else if (all(c("Agency", "Abbr") %in% names(d))) {
    canonical <- textNet::clean_entities(to_concat(d$Agency), remove_nums = TRUE)
    aliases   <- textNet::clean_entities(to_concat(d$Abbr),   remove_nums = TRUE)
    data.table::data.table(to = canonical, from = aliases)
  } else {
    warning("Unknown dictionary schema (", f,
            "): expected 'all_names' or Agency+Abbr")
    NULL
  }
}

# Build the full alias->canonical map from every dictionary in DICT_KEYS,
# dropping NA / empty / self-mapping rows. This is the `global_dict` the
# disambiguation step stacks under each Region_Year's mined acronyms.
build_global_dict <- function(keys = DICT_KEYS) {
  csvs <- vapply(keys, dict_path, character(1))
  gd   <- data.table::rbindlist(lapply(csvs, load_alias_pairs))
  unique(gd[!is.na(to) & !is.na(from) &
            nchar(to) > 0 & nchar(from) > 0 &
            to != from])
}

# === Acronym mining =========================================================
# One deterministic acronym miner used by BOTH the parse step (its `name`
# column enriches the entity ruler) and the disambiguation step (its
# (name, acronym) pairs become alias->canonical rows). This replaces the
# Claude-API region-dictionary process for the common case of tabular
# glossaries + in-text parenthetical definitions.
#
#   rawpg_files : raw-pages parquets (newline-preserved) -> front-matter
#                 acronym tables via extract_front_matter_acronyms()
#   clean_files : cleaned-text parquets -> parenthetical "Long Form (ACR)"
#                 definitions via find_intext_acronyms()
#
# Returns a unique (name, acronym) data.table. `name` is the full expansion
# in spaCy concatenated form (underscores), run through clean_entities() so
# it meets the nodelist surface in the disambiguation step. Front-matter rows
# win over in-text on an acronym collision (a document's own glossary is most
# authoritative). Requires textNet + arrow available (loaded by the callers).
mine_acronyms <- function(clean_files = character(0), rawpg_files = character(0)) {
  empty <- data.table::data.table(name = character(0), acronym = character(0))

  fm <- data.table::rbindlist(lapply(rawpg_files, function(f) {
    tp <- arrow::read_parquet(f)$raw_text
    tp <- tp[!is.na(tp) & nchar(tp) > 0]
    if (length(tp) == 0L) return(empty)
    out <- tryCatch(textNet::extract_front_matter_acronyms(tp),
                    error = function(e) {
                      warning("extract_front_matter_acronyms failed for ", f,
                              ": ", conditionMessage(e)); empty })
    if (is.null(out) || nrow(out) == 0L) empty else out
  }), fill = TRUE)

  il <- data.table::rbindlist(lapply(clean_files, function(f) {
    txt <- arrow::read_parquet(f)$text
    txt <- stringr::str_replace_all(txt, "\\n", " ")
    txt <- txt[!is.na(txt) & nchar(txt) > 0]
    if (length(txt) == 0L) return(empty)
    out <- tryCatch(textNet::find_intext_acronyms(txt),
                    error = function(e) {
                      warning("find_intext_acronyms failed for ", f,
                              ": ", conditionMessage(e)); empty })
    if (is.null(out) || nrow(out) == 0L) empty else out
  }), fill = TRUE)

  if (nrow(fm) == 0L && nrow(il) == 0L) return(empty)
  mined <- unique(rbind(fm, il, fill = TRUE), by = "acronym")  # front-matter wins
  mined$name    <- textNet::clean_entities(mined$name)
  mined$acronym <- textNet::clean_entities(mined$acronym)
  mined <- unique(mined, by = "acronym")
  mined[nchar(name) > 0 & nchar(acronym) > 0]
}

# === Atomic writes ==========================================================
# atomic_write() / atomic_saveRDS() are defined in code/_config.R (sourced
# at the top of this file).
