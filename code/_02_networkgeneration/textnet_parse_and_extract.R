# Purpose: Takes cleaned text files from preprocessing, runs spaCy (en_core_web_trf)
# via textNet to identify named entities and token dependencies, then runs
# textnet_extract to generate network files grouped by Region_Year.
# Setup: requires textNet, spaCy, python (conda env: spacy-env)
# Set overwrite <- TRUE to re-parse already-processed files.

overwrite <- FALSE
testing   <- FALSE  # Set TRUE to process a fixed 5-file subset

library(textNet)
library(stringr)
library(jsonlite)
library(arrow)

# === PYTHON / spaCy ENV ===
ret_path <- grep("spacy-env", reticulate::conda_list()$python, value = TRUE)

# === LOAD CLEANED TEXT ===
files <- list.files(path = "tijuanabox/int_data/plan_txts_clean",
                    pattern = "\\.parquet$", full.names = TRUE)

texts <- lapply(files, function(i) {
  tmp <- arrow::read_parquet(i)$text
  tmp <- str_replace_all(tmp, "\\n", " ")
  tmp <- tmp[!is.na(tmp) & nchar(tmp) > 200]
  tmp
})
names(texts) <- basename(files)

# Remove files with no usable text to keep texts and parse_fileloc aligned
empty_texts <- sapply(texts, length) == 0
if (any(empty_texts)) {
  message("Removing ", sum(empty_texts), " file(s) with no text >200 chars: ",
          paste(basename(files[empty_texts]), collapse = ", "))
  files <- files[!empty_texts]
  texts <- texts[!empty_texts]
}

# Testing mode: restrict to first 5 files
if (testing) {
  n <- min(5L, length(files))
  message("TESTING mode: using ", n, " of ", length(files), " file(s)")
  files <- files[seq_len(n)]
  texts <- texts[seq_len(n)]
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
dir.create("tijuanabox/int_data/parsed_files", recursive = TRUE, showWarnings = FALSE)
dir.create("tijuanabox/int_data/raw_extracted_networks", recursive = TRUE, showWarnings = FALSE)

parse_fileloc <- paste0("tijuanabox/int_data/parsed_files/", basename(files))

# === ENTITY RULER BUILD ===

# --- 1. Centralized dictionaries (water entities, infrastructure, water bodies) ---
dict_csvs <- c(
  "output/water_entity_dictionary.csv",
  "output/water_infrastructure_dictionary.csv",
  "output/water_bodies_dictionary.csv"
)
global_terms <- unlist(lapply(dict_csvs, function(f) {
  d <- read.csv(f, stringsAsFactors = FALSE)
  unlist(strsplit(d$all_names, split = "|", fixed = TRUE))
}))

# --- 2. Per-Region_Year dictionaries extracted from document glossary/acronym sections ---
regional_json_files <- list.files("tijuanabox/int_data/dictionaries",
                                  pattern = "^Region_.*_dict\\.json$",
                                  full.names = TRUE)
regional_terms <- if (length(regional_json_files) > 0) {
  unlist(lapply(regional_json_files, jsonlite::fromJSON))
} else {
  character(0)
}

if (length(regional_json_files) > 0) {
  message("Loaded ", length(regional_json_files), " regional dict(s), ",
          length(regional_terms), " term(s)")
} else {
  message("No regional dicts found in tijuanabox/int_data/dictionaries/ — ",
          "run extract_region_dictionaries.py to generate them")
}

# --- 3. Compose entity ruler: multi-word terms only ---
all_terms <- unique(c(global_terms, regional_terms))
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
  overwrite             = overwrite,
  entity_ruler_patterns = dict_ents,
  overwrite_ents        = TRUE,
  ruler_position        = "after",
  custom_entities       = list(PARTIES = parties)
)

# === GROUP BY REGION_YEAR ===
# Filenames follow the pattern Region_X_YYYY_<rest>.RDS
# Extract grouping key: e.g. "Region_7_2020"
parsed_files <- list.files("tijuanabox/int_data/parsed_files",
                           pattern = "\\.parquet$", full.names = TRUE)
parsed <- lapply(parsed_files, textNet::read_parsed_trf)
names(parsed) <- basename(parsed_files)

# Extract Region_X_YYYY key; handle legacy double-underscore filenames (Region_X__YYYY)
# by normalising to single underscore before extracting.
group_keys <- str_extract(
  str_replace(basename(parsed_files), "^(Region_[^_]+)__([0-9]{4})", "\\1_\\2"),
  "^Region_[^_]+_[0-9]{4}"
)

if (any(is.na(group_keys))) {
  warning(sum(is.na(group_keys)), " file(s) could not be assigned a Region_Year key and will be skipped:\n",
          paste(basename(parsed_files)[is.na(group_keys)], collapse = "\n"))
  parsed_files <- parsed_files[!is.na(group_keys)]
  parsed      <- parsed[!is.na(group_keys)]
  group_keys  <- group_keys[!is.na(group_keys)]
}

projects <- vector(mode = "list", length = length(unique(group_keys)))
names(projects) <- unique(group_keys)

filenum <- 1
for (i in seq_along(projects)) {
  projects[[i]] <- parsed[[filenum]]
  filenum <- filenum + 1
  while (filenum <= length(parsed) &&
         !is.na(group_keys[filenum]) &&
         group_keys[filenum] == names(projects)[i]) {
    projects[[i]] <- rbind(projects[[i]], parsed[[filenum]])
    filenum <- filenum + 1
  }
}

# === EXTRACT NETWORKS ===
extracts <- vector(mode = "list", length = length(projects))

keptentities <- c("PERSON",
                  "NORP",
                  "FAC",
                  "ORG", "GPE",
                  "LOC", "PRODUCT",
                  "EVENT", "WORK_OF_ART",
                  "LAW", "LANGUAGE",
                  "PARTIES", "CUSTOM", "DICT", "PATTERN")

for (m in seq_along(projects)) {
  extract_file <- paste0("tijuanabox/int_data/raw_extracted_networks/extract_",
                         names(projects)[m], ".RDS")
  if (overwrite || !file.exists(extract_file)) {
    extracts[[m]] <- textnet_extract(projects[[m]],
                                     cl                    = 1,
                                     keep_entities         = keptentities,
                                     return_to_memory      = TRUE,
                                     keep_incomplete_edges = TRUE,
                                     file                  = extract_file)
  } else {
    message("File already exists, skipping: ", extract_file)
  }
}

saveRDS(object = extracts, file = "tijuanabox/int_data/raw_extracts.RDS")
