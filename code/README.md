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
| `_01_1_pdftotext.py` | Python | Converts PDFs in `plan_pdfs/` to tab-separated text files (`page\ttext`) in `plan_txts_raw/` using the poppler `pdftotext` CLI. Falls back to tesseract OCR for scanned/image-only PDFs. |
| `_01_2_cleaningtxt.py` | Python | Filters out non-prose pages (maps, figures, tables, TOCs) from the raw text files using density heuristics (punctuation, numeric characters, whitespace, total length). Outputs cleaned parquet files to `plan_txts_clean/`. |
| `extract_region_dictionaries.py` | Python | Scans raw text files for acronym and glossary sections, sends detected pages to Claude API for term extraction, and writes a flat JSON term list per Region_Year to `tijuanabox/int_data/dictionaries/`. These regional dictionaries supplement the centralized water entity CSVs in stage 2. Requires `ANTHROPIC_API_KEY` environment variable. |
| `extract_acronyms_and_mentions.py` | Python | Runs a regex-based front-matter acronym parser plus scispacy's Schwartz-Hearst abbreviation detector on each raw plan text, and resolves in-document definite-reference anaphora (e.g. "the GSA" → "Kern County GSA") via the helper modules in `_XX_helpers/`. Falls back to `output/global_acronyms.json` when a plan's own dictionary has < `MIN_DOC_ACRONYMS` entries. Writes per-plan acronyms (`plan_acronyms/<stem>.json`) and mentions (`plan_mentions/<stem>.csv`), plus per-Region_Year rollups with conflict flagging. These feed stage 3. Requires `spacy`, `scispacy`, and the `en_core_sci_sm` model. |

### `_02_networkgeneration/`
| Script | Language | Description |
|--------|----------|-------------|
| `textnet_parse_and_extract.R` | R | Loads cleaned parquet text files, builds a spaCy entity ruler from the centralized water dictionaries (`output/`) and per-Region_Year JSON dicts, runs spaCy `en_core_web_trf` via textNet, groups parsed output by Region_Year, and extracts entity co-occurrence networks. Outputs one RDS network object per Region_Year to `raw_extracted_networks/`, plus a combined `raw_extracts.RDS`. Requires the `spacy-env` conda environment. |

### `_03_disambiguation/`
| Script | Language | Description |
|--------|----------|-------------|
| `disambiguate_network_nodes.py` | Python | Merges the per-plan acronym dicts and canonical mention forms from stage 1b into a single `raw_surface → canonical` lookup per Region_Year, reads the parquet (or RDS fallback) network extracts from `raw_extracted_networks/`, and writes a non-destructive disambiguated copy to `tijuanabox/int_data/disambiguated_networks/`. The original parquets are never modified: every row of the original nodelist is preserved with an added `canonical_name` column, and every row of the original edgelist is preserved with added `canonical_source` and `canonical_target` columns. No node merging, no edge aggregation — multiple edges between the same pair of canonical entities remain distinct rows because edge multiplicity is itself a signal. A `_node_map.csv` audit file documents the surface→canonical mapping. |

### `_XX_helpers/`
Runtime helper modules imported by the main pipeline. Not run directly.

| Script | Language | Description |
|--------|----------|-------------|
| `acronym_extractor.py` | Python | Library module. Builds a per-document acronym dictionary by combining a front-matter table parser and scispacy's AbbreviationDetector (Schwartz-Hearst). Imported by `_01_preprocessing/extract_acronyms_and_mentions.py`. |
| `anaphor_resolver.py` | Python | Library module. Extracts full and anaphoric entity mentions and resolves in-document definite-reference anaphora (e.g. "the GSA" → most recent compatible full mention in the same section). Imported by `_01_preprocessing/extract_acronyms_and_mentions.py`. |

### `_XX_build_dictionaries/scrape_external_lists/`
External dictionary builders. Notebooks that produce CSVs in `output/` consumed by the textNet entity ruler in stage 2. Re-run only when the underlying source data changes.

| Notebook | Language | Description |
|----------|----------|-------------|
| `build_water_entity_dictionary.ipynb` | Python | Builds `output/water_entity_dictionary.csv`: ~445 CA water governance entities (state/federal agencies, water districts, tribes, utilities, NGOs) with names, abbreviations, aliases, and region tags. |
| `build_water_infrastructure_dictionary.ipynb` | Python | Builds `output/water_infrastructure_dictionary.csv`: ~185 major water infrastructure features (dams, canals, aqueducts, treatment plants) with names, aliases, and operator/owner. |
| `build_water_bodies_dictionary.ipynb` | Python | Builds `output/water_bodies_dictionary.csv`: ~185 water bodies (rivers, streams, lakes, basins, aquifers) sourced from USGS NHD. |

---

## Run Order

```
_00_collection/scraping.R
_00_collection/find_duplicate_pdfs.py                  # review duplicates before proceeding
_01_preprocessing/_01_1_pdftotext.py
_01_preprocessing/_01_2_cleaningtxt.py
_01_preprocessing/extract_region_dictionaries.py       # requires ANTHROPIC_API_KEY
_01_preprocessing/extract_acronyms_and_mentions.py     # requires scispacy + en_core_sci_sm
_02_networkgeneration/textnet_parse_and_extract.R      # requires spacy-env conda env
_03_disambiguation/disambiguate_network_nodes.py       # requires pyreadr
```

External dictionary builders in `_XX_build_dictionaries/scrape_external_lists/`
are out-of-band: re-run them only when the underlying source data
changes. Their outputs (`output/water_*.csv`) are committed to the repo so
the main pipeline does not depend on running them.

Stage 1b (`extract_acronyms_and_mentions.py`) runs on the raw texts (not the
cleaned parquets) because the density-based cleaning blanks sparse
two-column front-matter tables, which is exactly where the
highest-precision acronym definitions live. It is independent of stage 2,
so the two can run in either order, but stage 3 requires both to be done.

The acronym/anaphor work in stage 1b is **not** an edit on the input text. The
text fed to stage 2 is unchanged. Stage 1b produces a separate map of
`(surface form → canonical entity)` that stage 3 applies *after* the
network has been parsed: nodes that resolve to the same canonical entity
should be collapsed into one node with the surface forms preserved as an
`aliases` list. This keeps parsing decisions (stage 2) decoupled from
identity decisions (stage 3).

---

## Two views per Region_Year

Stages 2 and 3 produce two parquet pairs per Region_Year. Originals
are never overwritten; they sit in a different directory from the
disambiguation outputs so you can compare side by side.

| View | Path | Added columns | When to use |
|------|------|---------------|-------------|
| **Original** (raw textNet output) | `tijuanabox/int_data/raw_extracted_networks/<RY>_nodelist.parquet` and `_edgelist.parquet` | none | Audit, comparison, or any analysis where you specifically don't want acronym/anaphor resolution to influence the network shape. |
| **Disambiguated** (originals preserved, canonical columns added) | `tijuanabox/int_data/disambiguated_networks/<RY>_nodelist.parquet` and `_edgelist.parquet` | nodelist: `canonical_name`. edgelist: `canonical_source`, `canonical_target`. | Downstream analysis using canonical entity identities while still being able to inspect the original textNet labels in the same row. |

Both views have the same row count for a given Region_Year — the
disambiguation stage is non-destructive and does no aggregation. To
collapse rows sharing the same canonical entity for a particular
analysis, do that downstream (e.g., `groupby("canonical_name")` in
pandas, or `tidygraph::convert(to_simple)` in R).

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
