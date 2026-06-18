# Pipeline Overview

Extracts named-entity governance networks from California Integrated Regional
Water Management (IRWM) plan PDFs using spaCy (via textNet). The pipeline runs
stage by stage; intermediate outputs are stored in `tijuanabox/` (Box Drive,
symlinked from the repo root).

The unit of analysis is **Region_Year** (e.g., `Region_7_2020`). Individual PDFs
are processed independently through PDF extraction and cleaning, then grouped by
Region_Year for parsing, network extraction, disambiguation, and graph building.

All scripts live directly in `code/` (flat layout) and are run from the repo
root, e.g. `Rscript code/textnet_parse_and_extract.R` or
`python3 code/pdftotext.py`. Curated dictionaries and their build scripts live
in `code/dicts/`. Shared R helpers live in `code/utils.R`.

---

## Stages

| Script | Language | Description |
|--------|----------|-------------|
| `scraping.R` | R | Downloads IRWM plan PDFs from URLs in `planlinks.csv` into `tijuanabox/raw_data/plan_pdfs/` with Region_Year filename prefixes. Filenames are sanitized (spaces → underscores) at download time. |
| `find_duplicate_pdfs.py` | Python | Detects duplicate PDFs within the same Region_Year by MD5 hash; writes a report to `tijuanabox/raw_data/duplicate_pdfs.csv`. Run with `--delete` to remove duplicates after review. |
| `pdftotext.py` | Python | Converts PDFs in `plan_pdfs/` to two artifacts: a TSV (`page\ttext`) in `plan_txts_raw/`, and a **newline-preserved per-page parquet** (`page`, `raw_text`) in `plan_txts_raw_pages/`. The latter mirrors kings step1's raw-pages artifact and feeds the disambiguation step's front-matter acronym parser, which needs the original "ACR    Long Form" column layout. Poppler `pdftotext` CLI with tesseract OCR fallback. A normal rerun backfills `plan_txts_raw_pages/` for PDFs converted before this artifact existed. |
| `cleaningtxt.py` | Python | Filters non-prose pages (maps, figures, tables, TOCs) from the raw TSVs via density heuristics (punctuation, numeric, whitespace, length). Outputs cleaned parquet files to `plan_txts_clean/`; row count is preserved so pages still align with the source PDF. |
| `extract_region_dictionaries.py` | Python | Scans raw text for acronym/glossary sections, sends detected pages to the Claude API for term extraction, and writes a flat JSON term list per Region_Year to `tijuanabox/int_data/dictionaries/`. These supplement the curated dictionaries **as entity-ruler terms only** (they are flat term lists, not alias↔canonical links, so they do not feed disambiguation). Requires `ANTHROPIC_API_KEY`. |
| `textnet_parse_and_extract.R` | R | Loads cleaned parquet text, builds a spaCy entity ruler from all six dictionaries in `code/dicts/` (via the schema-aware loader in `utils.R`) plus the per-Region_Year JSON dicts, runs spaCy `en_core_web_trf` via textNet, groups parsed output by Region_Year, and extracts entity co-occurrence networks. Outputs one RDS per Region_Year to `raw_extracted_networks/` plus a combined `raw_extracts.RDS`. Requires the `spacy-env` conda env. |
| `disambiguate_nodelists.R` | R | **Disambiguation pass** (mirrors kings step4). For each Region_Year, builds an alias→canonical map by stacking (1) doc-mined acronyms — `find_intext_acronyms()` on the clean text + `extract_front_matter_acronyms()` on the raw pages, pooled across the Region_Year's PDFs — and (2) the alias links from all six dictionaries. Resolves duplicate keys (longest canonical wins), normalizes surfaces via `clean_entities()`, snapshots the pre-disambig name as `raw_entity_name`, then runs `textNet::disambiguate()`. Outputs to `disambiguated_extracted_networks/` plus a combined `disambiguated_extracts.RDS`. |
| `build_igraphs.R` | R | Builds igraph objects from the disambiguated extracts (port of kings step5). Per Region_Year writes a **multiplex** directed graph (one edge per SVO triple, verb attributes preserved) and a **uniplex** weighted graph (parallel edges collapsed, `weight` = count). Drops NA-endpoint edges and <2-letter names; keeps all nodes (no-edge nodes become isolates). Outputs to `igraph_objects/multiplex/` and `igraph_objects/uniplex/`. |
| `audit_pipeline.R` | R | Per-Region_Year retention audit (port of kings audit). Per-PDF stages (PDF pages, clean rows/non-blank) are aggregated up to Region_Year; extract/disambig/graph stages are per Region_Year. Writes `output/pipeline_audit.csv`. |

---

## Dictionaries (`code/dicts/`)

Six curated dictionaries, copied from the kings `core_code` pipeline and used by
both the parse step (entity ruler) and the disambiguation step (alias map). The
canonical list and the schema-aware loaders live in `code/utils.R` (`DICT_KEYS`).

| dictionary | build script | schema | covers |
|---|---|---|---|
| `water_entity_dictionary.csv` | `build_water_entity_dictionary.ipynb` | `all_names` | CA water governance entities (agencies, districts, tribes, NGOs) |
| `water_infrastructure_dictionary.csv` | `build_water_infrastructure_dictionary.ipynb` | `all_names` | dams, canals, aqueducts, treatment plants (with operator) |
| `water_bodies_dictionary.csv` | `build_water_bodies_dictionary.ipynb` | `all_names` | rivers, lakes, basins, aquifers, watersheds |
| `water_gsa_dictionary.csv` | `build_water_gsa_dictionary.ipynb` | `all_names` | DWR i03 GSAs (live fetch) |
| `ca_utilities_dictionary.csv` | `build_ca_utilities_dictionary.ipynb` | `all_names` | CA water + electric utilities (live fetch + supplement) |
| `gov_entities_dict.csv` | `build_gov_entities_dict.R` | `State, Agency, Abbr` | federal + CA state + local government agencies |

A dictionary entry only contributes to **disambiguation** if it links two
surface forms (alias ↔ canonical); single-name rows feed the **entity ruler**
only. The loaders enforce this automatically. The `.ipynb` builders use
`DICTS_DIR = "."` and `build_gov_entities_dict.R` uses `DICTS_DIR <- "."`, so run
them from inside `code/dicts/`:

```bash
cd code/dicts && Rscript build_gov_entities_dict.R
cd code/dicts && python3 -c "import json;nb=json.load(open('build_water_gsa_dictionary.ipynb'));exec('\n'.join(''.join(c['source']) for c in nb['cells'] if c['cell_type']=='code'))"
```

`build_gov_entities_dict.R` reads `govscienceuseR_agencies.RDS` and
`govsci_custom_abbreviations.csv` (both in `code/dicts/`).

> The earlier `output/water_*.csv` dictionaries are superseded by `code/dicts/`
> and can be deleted.

---

## Run Order

```
code/scraping.R
code/find_duplicate_pdfs.py            # review duplicates before proceeding
code/pdftotext.py
code/cleaningtxt.py
code/extract_region_dictionaries.py    # requires ANTHROPIC_API_KEY
code/textnet_parse_and_extract.R       # requires spacy-env conda env
code/disambiguate_nodelists.R
code/build_igraphs.R
code/audit_pipeline.R                   # optional QA, run any time after extract
```

PDF extraction and cleaning can be run incrementally as new PDFs arrive. Parsing
through graph building should be re-run when new Region_Years are added.

---

## Flags

Each script exposes flags at the top of the file:

| Flag | Scripts | Effect |
|------|---------|--------|
| `CLOBBER` / `overwrite` | all pipeline scripts | Re-process files that already have output |
| `testing` / `TESTING` | `extract_region_dictionaries.py`, `textnet_parse_and_extract.R`, `disambiguate_nodelists.R` | Restrict to a small subset for a fast smoke test |

R steps source `code/utils.R`, which provides `DICT_KEYS`/dictionary loaders,
`region_year_key()`, and crash-safe `atomic_write()` / `atomic_saveRDS()` (outputs
are written to a `.tmp` file and renamed on success, so an interrupted run never
leaves a half-written file that a later rerun would skip).

---

## Filename Convention

All filenames use underscores, no spaces. The Region_Year prefix format is
`Region_X_YYYY` (e.g., `Region_7_2020`), enforced at download time in
`scraping.R`. Per-Region_Year artifacts are named `extract_<Region_Year>.RDS`.

---

## textNet dependency

The disambiguation step requires a textNet build that exports
`find_intext_acronyms()`, `extract_front_matter_acronyms()`, and the current
`disambiguate()` signature (textNet ≥ 1.0.1). Verify with
`packageVersion("textNet")` and `exists("extract_front_matter_acronyms")` after
`library(textNet)`.
