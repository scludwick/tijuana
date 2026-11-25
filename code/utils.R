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

# TESTING subset helper. When TESTING is on (from _config.R), restrict a vector
# of file paths to those belonging to the first TESTING_N Region_Years (sorted),
# so a --testing run is a coherent end-to-end smoke test on a few complete
# Region_Year networks. No-op when TESTING is off. Every R step funnels its
# input file list through this so the subset is identical across steps.
testing_filter <- function(paths) {
  if (!isTRUE(TESTING)) return(paths)
  ry   <- region_year_key(paths)
  keep <- head(sort(unique(ry[!is.na(ry)])), TESTING_N)
  message("TESTING: restricting to ", length(keep), " Region_Year(s): ",
          paste(keep, collapse = ", "))
  paths[!is.na(ry) & ry %in% keep]
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

# --- Entity-ruler labels (parse step) -------------------------------------
# The ruler labels each term with a standard spaCy entity type, so ruler
# matches sit alongside spaCy's own entities instead of under a catch-all
# label. Each dictionary has a default label; a few row types override it.
DICT_SPACY_LABELS <- c(water_entity_dictionary         = "ORG",
                       water_infrastructure_dictionary = "FAC",
                       water_bodies_dictionary         = "LOC",
                       water_gsa_dictionary            = "ORG",
                       ca_utilities_dictionary         = "ORG",
                       gov_entities_dict               = "ORG")
DICT_TYPE_SPACY_LABELS <- c(statute = "LAW", publication = "WORK_OF_ART")
.DICT_TYPE_COLS <- c("entity_type", "body_type", "infra_type")

# Returns a (term, label, is_canonical) data.table for every name in one
# dictionary. Terms keep their on-disk surface form, the same strings
# load_dict_terms() returns, so the two can be joined.
load_dict_labels <- function(f, key) {
  if (!file.exists(f)) { warning("Missing dictionary: ", f); return(NULL) }
  d <- read.csv(f, stringsAsFactors = FALSE)
  if ("all_names" %in% names(d)) {
    tcol  <- intersect(.DICT_TYPE_COLS, names(d))[1]
    parts <- strsplit(d$all_names, "|", fixed = TRUE)
    type  <- if (is.na(tcol)) NA_character_ else rep(d[[tcol]], lengths(parts))
    dt <- data.table::data.table(
      term         = unlist(parts),
      type         = type,
      is_canonical = unlist(lapply(parts, function(p) seq_along(p) == 1L)))
  } else if (all(c("Agency", "Abbr") %in% names(d))) {
    dt <- data.table::data.table(
      term         = c(d$Agency, d$Abbr),
      type         = NA_character_,
      is_canonical = rep(c(TRUE, FALSE), each = nrow(d)))
  } else {
    warning("Unknown dictionary schema (", f,
            "): expected 'all_names' or Agency+Abbr")
    return(NULL)
  }
  dt[, label := data.table::fcoalesce(unname(DICT_TYPE_SPACY_LABELS[type]),
                                      unname(DICT_SPACY_LABELS[key]))]
  dt[!is.na(term) & nzchar(term), .(term, label, is_canonical)]
}

# Term -> label for every dictionary term. A term listed in several rows or
# dictionaries keeps one label: a row where it is the canonical name beats
# one where it is an alias, then DICT_KEYS order wins (specific water dicts
# before the broad gov dict).
build_dict_labels <- function(keys = DICT_KEYS) {
  dt <- data.table::rbindlist(lapply(keys, function(k)
    load_dict_labels(dict_path(k), key = k)[, key_rank := match(k, keys)]))
  data.table::setorder(dt, term, -is_canonical, key_rank)
  unique(dt, by = "term")[, .(term, label)]
}

# Labels for ruler terms with no dictionary entry (doc-mined acronym
# expansions, regional JSON dicts), guessed from the term's last word:
# "... Water District" -> ORG, "... Act" -> LAW, "... Creek" -> LOC.
# Returns NA when the last word is not listed; the parse step leaves those
# terms out of the ruler so spaCy labels them itself.
HEAD_WORD_SPACY_LABELS <- list(
  ORG = c("district", "districts", "agency", "agencies", "authority",
          "association", "council", "councils", "committee", "commission",
          "company", "corporation", "institute", "board", "department",
          "administration", "service", "services", "alliance", "coalition",
          "group", "laboratory", "center", "foundation", "partnership",
          "conservancy", "cooperative", "utility", "bureau", "office",
          "division", "governments", "society", "university", "college",
          "trust", "consortium", "collaborative", "corps", "inc", "llc",
          "associates", "subcommittee"),
  GPE = c("county", "city", "town"),
  LOC = c("river", "creek", "lake", "basin", "subbasin", "valley", "delta",
          "bay", "watershed", "slough", "estuary", "aquifer", "marsh",
          "park", "refuge", "forest", "canyon"),
  FAC = c("dam", "canal", "aqueduct", "pipeline", "plant", "reservoir",
          "facility", "tunnel", "levee", "weir", "bypass"),
  LAW = c("act", "code", "bill", "ordinance", "regulations", "proposition"),
  WORK_OF_ART = c("plan", "study", "report", "assessment", "handbook",
                  "bulletin", "manual", "guidelines", "strategy"))

head_word_labels <- function(terms) {
  lookup <- stats::setNames(rep(names(HEAD_WORD_SPACY_LABELS),
                                lengths(HEAD_WORD_SPACY_LABELS)),
                            unlist(HEAD_WORD_SPACY_LABELS))
  # In "X of Y" the head is the last word of X ("Corporation of Mariposa
  # County" is an ORG, not a GPE).
  head <- sub("\\s+(of|for)\\s.*$", "", terms, ignore.case = TRUE)
  unname(lookup[tolower(stringr::word(head, -1))])
}

# === Proper-noun filter (entity-ruler terms) ================================
# The ruler should only impose proper nouns. Acronym glossaries also expand
# common concepts ("SLR" -> "sea level rise", "BMP" -> "Best Management
# Practices"), and glossaries title-case those, so casing in the glossary
# alone can't separate them from names. The corpus can: a proper noun is
# (almost) never written in lowercase in running text, while a concept is.
#
# A term is kept only if
#   1. every content word starts with a capital or contains a digit
#      (function words like "of", "and", "de" are exempt), and
#   2. among its corpus occurrences (case-insensitive), the share written
#      entirely in lowercase is <= max_lower_share. Terms seen fewer than
#      min_count times pass on rule 1 alone (too rare to judge).
# Returns a data.table (term, n, n_lower, lower_share, keep) so callers can
# both filter and log what was dropped.
.FUNCTION_WORDS <- c("of", "and", "the", "for", "in", "on", "to", "at", "by",
                     "with", "&", "a", "an", "de", "del", "la", "las", "los",
                     "el", "y")

proper_noun_terms <- function(terms, text_list, max_lower_share = 0.1,
                              min_count = 3L) {
  norm <- function(x) {
    x <- stringi::stri_replace_all_regex(x, "['\u2019]", "")  # Governor's -> Governors
    stringi::stri_trim_both(stringi::stri_replace_all_regex(x, "[^\\p{L}\\p{N}&]+", " "))
  }
  # URLs/emails are lowercase by convention (noaa.gov) and would count as
  # common-noun usage, so they are removed from the corpus before counting.
  strip_urls <- function(x) stringi::stri_replace_all_regex(
    x, "\\S*(https?://|www\\.|@)\\S*|\\S+\\.(gov|org|com|edu|net|us)\\b\\S*", " ",
    opts_regex = stringi::stri_opts_regex(case_insensitive = TRUE))
  terms <- unique(terms)
  words <- strsplit(norm(terms), " ", fixed = TRUE)
  capitalized <- vapply(words, function(w) {
    w <- w[!tolower(w) %in% .FUNCTION_WORDS]
    length(w) > 0L && all(grepl("^[[:upper:]]|[[:digit:]]", w))
  }, logical(1))

  # Count occurrences by tokenizing the corpus once and matching k-grams that
  # start at a term's first word (a per-term substring scan over a ~200M-char
  # corpus is far too slow). Occurrences directly after a capitalized word are
  # skipped: they sit inside a longer name ("Vista Irrigation District") and
  # would make a generic term ("Irrigation District") look like a proper noun.
  tok    <- stringi::stri_split_regex(norm(strip_urls(unlist(text_list))), " +")
  tok    <- unlist(tok, use.names = FALSE)
  tok_lc <- tolower(tok)
  N      <- length(tok)
  key    <- tolower(norm(terms))
  klen   <- lengths(strsplit(key, " ", fixed = TRUE))
  n <- n_lower <- integer(length(terms))
  for (k in unique(klen)) {
    idx   <- which(klen == k)
    first <- vapply(strsplit(key[idx], " ", fixed = TRUE), `[`, "", 1L)
    pos   <- which(tok_lc %in% first)
    pos   <- pos[pos + k - 1L <= N]
    prev  <- tok[pmax(pos - 1L, 1L)]
    pos   <- pos[pos == 1L | !grepl("^[[:upper:]]", prev) |
                 tolower(prev) %in% .FUNCTION_WORDS]
    gram  <- do.call(paste, lapply(seq_len(k) - 1L, function(j) tok_lc[pos + j]))
    orig  <- do.call(paste, lapply(seq_len(k) - 1L, function(j) tok[pos + j]))
    m     <- match(gram, key[idx])
    hit   <- !is.na(m)
    n[idx]       <- tabulate(m[hit], nbins = length(idx))
    n_lower[idx] <- tabulate(m[hit & orig == gram], nbins = length(idx))
  }
  share <- ifelse(n > 0, n_lower / n, 0)

  data.table::data.table(
    term = terms, n = n, n_lower = n_lower, lower_share = round(share, 3),
    keep = capitalized & (n < min_count | share <= max_lower_share))
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
#
# The miner is split into three composable pieces so a caller that already has
# the cleaned text in memory (the parse step) can mine in-text acronyms without
# re-reading the parquets:
#   mine_frontmatter_acronyms(rawpg_files) : reads raw-pages parquets
#   mine_intext_acronyms(text_list)        : operates on already-loaded text
#   combine_acronyms(fm, il)               : dedupe + clean (front-matter wins)
# mine_acronyms(clean_files, rawpg_files) is the file-based convenience wrapper
# (used by the disambiguation step).
.empty_acronyms <- function() data.table::data.table(name = character(0),
                                                     acronym = character(0))

mine_frontmatter_acronyms <- function(rawpg_files = character(0)) {
  data.table::rbindlist(lapply(rawpg_files, function(f) {
    tp <- arrow::read_parquet(f)$raw_text
    tp <- tp[!is.na(tp) & nchar(tp) > 0]
    if (length(tp) == 0L) return(.empty_acronyms())
    out <- tryCatch(textNet::extract_front_matter_acronyms(tp),
                    error = function(e) {
                      warning("extract_front_matter_acronyms failed for ", f,
                              ": ", conditionMessage(e)); .empty_acronyms() })
    if (is.null(out) || nrow(out) == 0L) .empty_acronyms() else out
  }), fill = TRUE)
}

# text_list: a list (or vector) of character vectors of page text. Newlines are
# collapsed here, so callers may pass either raw or already-collapsed text.
mine_intext_acronyms <- function(text_list) {
  if (is.character(text_list)) text_list <- list(text_list)
  data.table::rbindlist(lapply(text_list, function(txt) {
    txt <- stringr::str_replace_all(txt, "\\n", " ")
    txt <- txt[!is.na(txt) & nchar(txt) > 0]
    if (length(txt) == 0L) return(.empty_acronyms())
    out <- tryCatch(textNet::find_intext_acronyms(txt),
                    error = function(e) {
                      warning("find_intext_acronyms failed: ",
                              conditionMessage(e)); .empty_acronyms() })
    if (is.null(out) || nrow(out) == 0L) .empty_acronyms() else out
  }), fill = TRUE)
}

combine_acronyms <- function(fm, il) {
  if (nrow(fm) == 0L && nrow(il) == 0L) return(.empty_acronyms())
  mined <- unique(rbind(fm, il, fill = TRUE), by = "acronym")  # front-matter wins
  mined$name    <- textNet::clean_entities(mined$name)
  mined$acronym <- textNet::clean_entities(mined$acronym)
  mined <- unique(mined, by = "acronym")
  mined[nchar(name) > 0 & nchar(acronym) > 0]
}

mine_acronyms <- function(clean_files = character(0), rawpg_files = character(0)) {
  fm <- mine_frontmatter_acronyms(rawpg_files)
  il <- mine_intext_acronyms(lapply(clean_files, function(f) arrow::read_parquet(f)$text))
  combine_acronyms(fm, il)
}

# === Atomic writes ==========================================================
# atomic_write() / atomic_saveRDS() are defined in code/_config.R (sourced
# at the top of this file).
