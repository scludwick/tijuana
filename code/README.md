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
| `scraping.R` | R | Downloads IRWM plan PDFs from URLs in `planlinks.csv`. Organizes output into `tijuanabox/raw_data/plan_pdfs/` with Region_Year filename prefixes. Set `CLOBBER <- TRUE` to re-download existing files. |

### `_01_preprocessing/`
| Script | Language | Description |
|--------|----------|-------------|
| `pdftotext_py.py` | Python | Converts PDFs in `plan_pdfs/` to tab-separated text files (`page\ttext`) in `plan_txts_raw/` using the poppler `pdftotext` CLI. Falls back to tesseract OCR for scanned/image-only PDFs. Canonical PDF-to-text converter for this project. |
| `cleaningtxt.py` | Python | Filters out non-prose pages (maps, figures, tables, TOCs) from the raw text files using density heuristics (punctuation, numeric characters, whitespace, total length). Outputs cleaned parquet files to `plan_txts_clean/`. |
| `extract_region_dictionaries.py` | Python | Scans raw text files for acronym and glossary sections, sends detected pages to Claude API for term extraction, and writes a flat JSON term list per Region_Year to `tijuanabox/int_data/dictionaries/`. These regional dictionaries supplement the centralized water entity CSVs in stage 2. Set `TESTING = True` to run on a 5-file subset. |

### `_02_networkgeneration/`
| Script | Language | Description |
|--------|----------|-------------|
| `textnet_parse_and_extract.R` | R | Loads cleaned text (RDS), builds a spaCy entity ruler from the centralized water dictionaries (`output/`) and any available per-Region_Year JSON dicts, runs spaCy `en_core_web_trf` via textNet, groups parsed output by Region_Year, and extracts entity co-occurrence networks. Outputs one RDS network object per Region_Year to `raw_extracted_networks/`, plus a combined `raw_extracts.RDS`. Set `testing <- TRUE` to run on a 5-file subset. |

### `_XX_helpers/`
| Script | Language | Description |
|--------|----------|-------------|
| `build_water_entity_dictionary.ipynb` | Python | Builds `output/water_entity_dictionary.csv`: ~445 CA water governance entities (state/federal agencies, water districts, tribes, utilities, NGOs) with names, abbreviations, aliases, and region tags. |
| `build_water_infrastructure_dictionary.ipynb` | Python | Builds `output/water_infrastructure_dictionary.csv`: ~185 major water infrastructure features (dams, canals, aqueducts, treatment plants) with names, aliases, and operator/owner. |
| `build_water_bodies_dictionary.ipynb` | Python | Builds `output/water_bodies_dictionary.csv`: ~185 water bodies (rivers, streams, lakes, basins, aquifers) sourced from USGS NHD. |

---

## Run Order

```
_00_collection/scraping.R
_01_preprocessing/pdftotext_py.py
_01_preprocessing/cleaningtxt.R
_01_preprocessing/extract_region_dictionaries.py   # requires ANTHROPIC_API_KEY
_02_networkgeneration/textnet_parse_and_extract.R  # requires spacy-env conda env
```

Stages 0–1 can be run incrementally as new PDFs arrive. Stage 1.5
(dictionary extraction) and stage 2 should be re-run when new Region_Years
are added to the corpus.

---

## Flags

Each script exposes flags at the top of the file for common run modes:

| Flag | Scripts | Effect |
|------|---------|--------|
| `CLOBBER` / `overwrite` | all | Re-process files that already have output |
| `TESTING` / `testing` | `extract_region_dictionaries.py`, `textnet_parse_and_extract.R` | Restrict to a 5-file subset spanning 2 Region_Years |
