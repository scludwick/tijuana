# Pipeline Overview

Extracts named-entity co-occurrence networks from California Integrated Regional
Water Management (IRWM) plan PDFs using spaCy (via textNet). The pipeline runs
stage by stage; intermediate outputs are stored in `tijuanabox/` (Box Drive,
symlinked from the repo root).

The unit of analysis is **Region_Year** (e.g., `Region_7_2020`). Individual PDF
files are processed independently through stages 0–1, but dictionary extraction
and network generation operate on all documents belonging to a Region_Year together.

---

## Stages

### `_00_collection/`
| Script | Language | Description |
|--------|----------|-------------|
| `scraping.R` | R | Downloads IRWM plan PDFs from URLs in `planlinks.csv`. Organizes output into `tijuanabox/raw_data/plan_pdfs/` with Region_Year filename prefixes. Filenames are sanitized (spaces → underscores) at download time. |
| `find_duplicate_pdfs.py` | Python | Detects duplicate PDFs within the same Region_Year by MD5 hash and writes a report to `tijuanabox/raw_data/duplicate_pdfs.csv`. Run with `--delete` to remove duplicates after review. |

### `_01_preprocessing/`
| Script | Language | Description |
|--------|----------|-------------|
| `pdftotext.py` | Python | Converts PDFs in `plan_pdfs/` to tab-separated text files (`page\ttext`) in `plan_txts_raw/` using the poppler `pdftotext` CLI. Falls back to tesseract OCR for scanned/image-only PDFs. |
| `cleaningtxt.py` | Python | Filters out non-prose pages (maps, figures, tables, TOCs) from the raw text files using density heuristics (punctuation, numeric characters, whitespace, total length). Outputs cleaned parquet files to `plan_txts_clean/`. |
| `extract_region_dictionaries.py` | Python | Scans raw text files for acronym and glossary sections, sends detected pages to Claude API for term extraction, and writes a flat JSON term list per Region_Year to `tijuanabox/int_data/dictionaries/`. These regional dictionaries supplement the centralized water entity CSVs in stage 2. Requires `ANTHROPIC_API_KEY` environment variable. |
| `extract_acronyms_and_mentions.py` | Python | Runs a regex-based front-matter acronym parser plus scispacy's Schwartz-Hearst abbreviation detector on each raw plan text, and resolves in-document definite-reference anaphora (e.g. "the GSA" → "Kern County GSA") via the helper modules in `_XX_helpers/`. Falls back to `output/global_acronyms.json` when a plan's own dictionary has < `MIN_DOC_ACRONYMS` entries. Writes per-plan acronyms (`plan_acronyms/<stem>.json`) and mentions (`plan_mentions/<stem>.csv`), plus per-Region_Year rollups with conflict flagging. These feed stage 3. Requires `spacy`, `scispacy`, and the `en_core_sci_sm` model. |

### `_02_networkgeneration/`
| Script | Language | Description |
|--------|----------|-------------|
| `textnet_parse_and_extract.R` | R | Loads cleaned parquet text files, builds a spaCy entity ruler from the centralized water dictionaries (`output/`) and per-Region_Year JSON dicts, runs spaCy `en_core_web_trf` via textNet, groups parsed output by Region_Year, and extracts entity co-occurrence networks. Outputs one RDS network object per Region_Year to `raw_extracted_networks/`, plus a combined `raw_extracts.RDS`. Requires the `spacy-env` conda environment. |

### `_03_disambiguation/`
| Script | Language | Description |
|--------|----------|-------------|
| `disambiguate_network_nodes.py` | Python | Merges the per-plan acronym dicts and canonical mention forms from stage 1b into a single `raw_surface → canonical` lookup per Region_Year, then reads the textNet extract RDSes from `raw_extracted_networks/` via `pyreadr`, adds a canonical column to `nodelist` and `edgelist`, and writes disambiguated parquet outputs plus a human-readable `_node_map.csv` audit trail to `tijuanabox/int_data/disambiguated_networks/`. |

### `_XX_helpers/`
| Script | Language | Description |
|--------|----------|-------------|
| `build_water_entity_dictionary.ipynb` | Python | Builds `output/water_entity_dictionary.csv`: ~445 CA water governance entities (state/federal agencies, water districts, tribes, utilities, NGOs) with names, abbreviations, aliases, and region tags. |
| `build_water_infrastructure_dictionary.ipynb` | Python | Builds `output/water_infrastructure_dictionary.csv`: ~185 major water infrastructure features (dams, canals, aqueducts, treatment plants) with names, aliases, and operator/owner. |
| `build_water_bodies_dictionary.ipynb` | Python | Builds `output/water_bodies_dictionary.csv`: ~185 water bodies (rivers, streams, lakes, basins, aquifers) sourced from USGS NHD. |
| `acronym_extractor.py` | Python | Library module. Builds a per-document acronym dictionary by combining a front-matter table parser and scispacy's AbbreviationDetector (Schwartz-Hearst). Imported by `_01_preprocessing/extract_acronyms_and_mentions.py`. |
| `anaphor_resolver.py` | Python | Library module. Extracts full and anaphoric entity mentions and resolves in-document definite-reference anaphora (e.g. "the GSA" → most recent compatible full mention in the same section). Imported by `_01_preprocessing/extract_acronyms_and_mentions.py`. |

---

## Run Order

```
_00_collection/scraping.R
_00_collection/find_duplicate_pdfs.py                  # review duplicates before proceeding
_01_preprocessing/pdftotext.py
_01_preprocessing/cleaningtxt.py
_01_preprocessing/extract_region_dictionaries.py       # requires ANTHROPIC_API_KEY
_01_preprocessing/extract_acronyms_and_mentions.py     # requires scispacy + en_core_sci_sm
_02_networkgeneration/textnet_parse_and_extract.R      # requires spacy-env conda env
_03_disambiguation/disambiguate_network_nodes.py       # requires pyreadr
```

Stage 1b (`extract_acronyms_and_mentions.py`) runs on the raw texts (not the
cleaned parquets) because the density-based cleaning blanks sparse
two-column front-matter tables, which is exactly where the
highest-precision acronym definitions live. It is independent of stage 2,
so the two can run in either order, but stage 3 requires both to be done.

Stages 0–1 can be run incrementally as new PDFs arrive. Dictionary extraction
(1a and 1b) and stages 2–3 should be re-run when new Region_Years are
added to the corpus.

---

## Flags

Each script exposes flags at the top of the file for common run modes:

| Flag | Scripts | Effect |
|------|---------|--------|
| `CLOBBER` / `overwrite` | all pipeline scripts | Re-process files that already have output |
| `TESTING` / `testing` | `extract_region_dictionaries.py`, `textnet_parse_and_extract.R` | Restrict to a 5-file subset spanning 2 Region_Years |

---

## Filename Convention

All filenames use underscores, no spaces. The Region_Year prefix format is
`Region_X_YYYY` (e.g., `Region_7_2020`). This is enforced at download time
in `scraping.R` and can be applied retroactively with `rename_sanitize.py`.
