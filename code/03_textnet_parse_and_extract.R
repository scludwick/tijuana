# Purpose: Takes cleaned text files from preprocessing, runs spaCy (en_core_web_trf)
# via textNet to identify named entities and token dependencies, then runs
# textnet_extract to generate network files grouped by Region_Year.
# Setup: requires textNet, spaCy, python (conda env: spacy-env)
# Flags (CLOBBER, TESTING, TESTING_N, MIN_PAGE_CHARS, PARSE_WORKERS, SPACY_ENV)
# come from code/_config.R (sourced via utils.R). Override from the shell, e.g.
#   CLOBBER=1 Rscript code/03_textnet_parse_and_extract.R

library(textNet)
library(stringr)
library(jsonlite)
library(arrow)

source("code/utils.R")   # DICT_KEYS, dict_path(), load_dict_terms(); sources _config.R

# === PYTHON / spaCy ENV ===
# SPACY_ENV (from _config.R) is a conda env name or a full path to a python binary.
if (file.exists(SPACY_ENV)) {
  ret_path <- SPACY_ENV
} else {
  envs     <- reticulate::conda_list()
  matches  <- envs$python[envs$name == SPACY_ENV]
  ret_path <- if (length(matches) >= 1L) matches[1] else NA_character_
}
if (is.na(ret_path) || !nzchar(ret_path)) {
  stop("Could not resolve SPACY_ENV = '", SPACY_ENV,
       "'. Set it (in code/_config.R or via the SPACY_ENV env var) to a conda ",
       "env name or a python binary path with spacy + en_core_web_trf installed.")
}

# === LOAD CLEANED TEXT ===
# Read each clean parquet ONCE; keep the full newline-collapsed text per file so
# both the parser and the in-text acronym miner reuse the same in-memory copy
# (no second pass over the parquets).
files <- list.files(path = "tijuanabox/core_data/plan_txts_clean",
                    pattern = "\\.parquet$", full.names = TRUE)

# TESTING: restrict to the first TESTING_N Region_Years (no-op otherwise). Done
# up front so everything below — clean text, ruler mining, parse, extract — is
# bounded to the same subset.
files <- testing_filter(files)

clean_texts <- lapply(files, function(i) str_replace_all(arrow::read_parquet(i)$text, "\\n", " "))
names(clean_texts) <- basename(files)

# Parse input: pages with more than MIN_PAGE_CHARS usable characters.
texts <- lapply(clean_texts, function(tmp) tmp[!is.na(tmp) & nchar(tmp) > MIN_PAGE_CHARS])
names(texts) <- basename(files)

# Remove files with no usable text to keep texts/files/parse_fileloc aligned.
empty_texts <- sapply(texts, length) == 0
if (any(empty_texts)) {
  message("Removing ", sum(empty_texts), " file(s) with no text >", MIN_PAGE_CHARS,
          " chars: ", paste(basename(files[empty_texts]), collapse = ", "))
  files <- files[!empty_texts]
  texts <- texts[!empty_texts]
}

# === PARTIES ===
parties <- c("Project", "Projects",
             "Applicant", "Applicants",
             "Permittee", "Permittees",
             "Proponent", "Proponents",
             "Band", "Bands",
             "tribe", "tribes",
             "Tribe", "Tribes",
             "we", "We")

# === OUTPUT PATHS ===
dir.create("tijuanabox/core_data/parsed_files", recursive = TRUE, showWarnings = FALSE)
dir.create("tijuanabox/core_data/raw_extracted_networks", recursive = TRUE, showWarnings = FALSE)

parse_fileloc <- paste0("tijuanabox/core_data/parsed_files/", basename(files))

# === ENTITY RULER BUILD ===

# --- 1. Centralized dictionaries (all six in code/dicts/) ---
# DICT_KEYS and the schema-aware loader live in code/utils.R so this step and
# the disambiguation step stay in sync. load_dict_terms() handles both the
# `all_names` pipe-delimited schema (the five water/utility dicts) and the
# (State, Agency, Abbr) schema (gov_entities_dict). Every canonical + alias
# becomes a candidate entity-ruler term; the multi-word filter below trims
# single-token entries.
global_terms <- unlist(lapply(DICT_KEYS, function(k) load_dict_terms(dict_path(k))))

# --- 2. Doc-mined acronym full-names (deterministic; primary enrichment) ---
# extract_front_matter_acronyms() (glossary tables) + find_intext_acronyms()
# (parenthetical "Long Form (ACR)" defs) mine each document's own acronym
# expansions. Their `name` column enriches the entity ruler so spaCy
# recognizes document-specific entities. The SAME miner (mine_acronyms() in
# utils.R) feeds the disambiguation step's alias map, so the two stages stay
# in sync from one implementation — this replaces the Claude-API region-dict
# process for the common case (tabular glossaries + in-text parentheticals).
# Mined names come back concatenated (underscores); clean_entities() preserves
# case, so converting underscores back to spaces yields a correctly-cased,
# space-separated ruler term that matches the raw PDF text.
# In-text acronyms are mined from clean_texts already in memory (no re-read);
# front-matter acronyms need the raw-pages parquets (read once here).
acro_rawpg  <- list.files("tijuanabox/core_data/plan_txts_raw_pages",
                          pattern = "\\.parquet$", full.names = TRUE)
mined <- combine_acronyms(mine_frontmatter_acronyms(acro_rawpg),
                          mine_intext_acronyms(clean_texts))
mined_names <- gsub("_", " ", mined$name)
message("Doc-mined acronym names: ", length(unique(mined_names)), " term(s)")

# --- 3. Optional: per-Region_Year JSON dicts from extract_region_dictionaries.py ---
# Superseded for tabular glossaries by the deterministic miner above; kept as an
# optional enrichment for non-tabular/narrative glossaries. Loaded if present.
regional_json_files <- list.files("tijuanabox/core_data/dictionaries",
                                  pattern = "^Region_.*_dict\\.json$",
                                  full.names = TRUE)
regional_terms <- if (length(regional_json_files) > 0) {
  unlist(lapply(regional_json_files, jsonlite::fromJSON))
} else {
  character(0)
}
if (length(regional_json_files) > 0) {
  message("Loaded ", length(regional_json_files), " optional regional JSON dict(s), ",
          length(regional_terms), " term(s)")
}

# --- 4. Compose entity ruler: multi-word terms only ---
all_terms <- unique(c(global_terms, mined_names, regional_terms))
all_terms <- all_terms[!is.na(all_terms) & nzchar(all_terms)]
all_terms <- all_terms[stringr::str_count(all_terms, "\\s+") >= 1]
message("Entity ruler: ", length(all_terms), " unique multi-word term(s)")

dict_ents <- entity_specify(all_terms,
                            case_sensitive = TRUE,
                            whole_word_only = TRUE,
                            entity_label = "DICT")
dict_ents <- c(dict_ents, textNet::build_structural_org_patterns())

# === RUN PARSING ===
parsed <- textNet::parse_text_trf(
  ret_path,
  text_list             = texts,
  parsed_filenames      = parse_fileloc,
  overwrite             = CLOBBER,
  entity_ruler_patterns = dict_ents,
  overwrite_ents        = TRUE,
  ruler_position        = "after",
  custom_entities       = list(PARTIES = parties)
)

# === GROUP BY REGION_YEAR ===
# Group by Region_Year key (via region_year_key(); also normalizes legacy
# Region_X__YYYY). Grouping is by key, not by file order — split() collects each
# Region_Year's files regardless of how they sort. We group only the files
# parsed in THIS run (parse_fileloc), not everything in parsed_files/, so a
# TESTING run stays bounded and stale leftovers never leak into the extract.
parsed_files <- parse_fileloc[file.exists(parse_fileloc)]
parsed     <- lapply(parsed_files, textNet::read_parsed_trf)
group_keys <- region_year_key(parsed_files)

if (any(is.na(group_keys))) {
  warning(sum(is.na(group_keys)), " file(s) could not be assigned a Region_Year key and will be skipped:\n",
          paste(basename(parsed_files)[is.na(group_keys)], collapse = "\n"))
  parsed     <- parsed[!is.na(group_keys)]
  group_keys <- group_keys[!is.na(group_keys)]
}

# Row-bind each Region_Year's parsed tables. names(projects) are the unique keys.
projects <- lapply(split(seq_along(parsed), group_keys),
                   function(idx) do.call(rbind, parsed[idx]))

# === EXTRACT NETWORKS ===
keptentities <- c("PERSON",
                  "NORP",
                  "FAC",
                  "ORG", "GPE",
                  "LOC", "PRODUCT",
                  "EVENT", "WORK_OF_ART",
                  "LAW", "LANGUAGE",
                  "PARTIES", "CUSTOM", "DICT", "PATTERN")

extract_dir <- "tijuanabox/core_data/raw_extracted_networks"
for (m in seq_along(projects)) {
  extract_file <- file.path(extract_dir, paste0("extract_", names(projects)[m], ".RDS"))
  if (CLOBBER || !file.exists(extract_file)) {
    textnet_extract(projects[[m]],
                    cl                    = PARSE_WORKERS,
                    keep_entities         = keptentities,
                    return_to_memory      = FALSE,
                    keep_incomplete_edges = TRUE,
                    file                  = extract_file)
  } else {
    message("File already exists, skipping: ", extract_file)
  }
}

# Combined list, read from disk so it reflects the full corpus on every run
# (no NULLs for Region_Years skipped on a partial rerun) — mirrors step 04.
existing_extracts <- sort(list.files(extract_dir, pattern = "\\.RDS$", full.names = TRUE))
raw_extracts <- lapply(existing_extracts, readRDS)
names(raw_extracts) <- sub("^extract_", "", str_remove(basename(existing_extracts), "\\.RDS$"))
saveRDS(raw_extracts, "tijuanabox/core_data/raw_extracts.RDS")
message("Done. ", length(raw_extracts), " raw extract(s) on disk.")
