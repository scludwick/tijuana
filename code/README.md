# Pipeline Overview

Extracts named-entity governance networks from California Integrated Regional
Water Management (IRWM) plan PDFs using spaCy (via textNet). The pipeline runs
stage by stage. All pipeline data — source PDFs, intermediate artifacts, and
outputs — lives under `tijuanabox/core_data/` (Box Drive, symlinked from the repo
root), mirroring the kings `data/core_data` layout (the older `raw_data/` +
`int_data/` split has been consolidated into this single `core_data/`).

The unit of analysis is **Region_Year** (e.g., `Region_7_2020`). Individual PDFs
are processed independently through PDF extraction and cleaning, then grouped by
Region_Year for parsing, network extraction, disambiguation, and graph building.

All pipeline scripts live directly in `code/` (flat layout) and carry a two-digit
prefix giving their run order. Run them from the repo root, e.g.
`Rscript code/03_textnet_parse_and_extract.R` or `python3 code/01_pdftotext.py`.
Side utilities that aren't part of the sequential workflow use an `XX_` prefix.
Dictionaries and their build scripts live in `code/dicts/`. Shared R config and
helpers live in `code/_config.R` (flags/tunables) and `code/utils.R` (dictionary
loaders, etc.) — both sourced, not run, so they carry no number.

---

## Stages

| Script | Language | Description |
|--------|----------|-------------|
| `00_scraping.R` | R | Downloads IRWM plan PDFs from URLs in `planlinks.csv` into `tijuanabox/core_data/plan_pdfs/` with Region_Year filename prefixes. Filenames are sanitized (spaces → underscores) at download time. |
| `01_pdftotext.py` | Python | Converts PDFs in `plan_pdfs/` to two artifacts: a TSV (`page\ttext`) in `plan_txts_raw/`, and a **newline-preserved per-page parquet** (`page`, `raw_text`) in `plan_txts_raw_pages/`. The latter mirrors kings step1's raw-pages artifact and feeds the disambiguation step's front-matter acronym parser, which needs the original "ACR    Long Form" column layout. Poppler `pdftotext` CLI with tesseract OCR fallback. A normal rerun backfills `plan_txts_raw_pages/` for PDFs converted before this artifact existed. |
| `02_cleaningtxt.py` | Python | Filters non-prose pages (maps, figures, tables, TOCs) from the raw TSVs via density heuristics (punctuation, numeric, whitespace, length). Outputs cleaned parquet files to `plan_txts_clean/`; row count is preserved so pages still align with the source PDF. |
| `03_textnet_parse_and_extract.R` | R | Loads cleaned parquet text, builds a spaCy entity ruler from all six dictionaries in `code/dicts/` (via the schema-aware loader in `utils.R`) **plus deterministically doc-mined acronym full-names** (front-matter glossaries + in-text parentheticals, via `mine_acronyms()`), plus any optional per-Region_Year JSON dicts, runs spaCy `en_core_web_trf` via textNet, groups parsed output by Region_Year, and extracts entity co-occurrence networks. Outputs one RDS per Region_Year to `raw_extracted_networks/` plus a combined `raw_extracts.RDS`. Requires the `spacy-env` conda env. |
| `04_disambiguate_nodelists.R` | R | **Disambiguation pass** (mirrors kings step4). For each Region_Year, builds an alias→canonical map by stacking (1) doc-mined acronyms — the shared `mine_acronyms()` helper (`find_intext_acronyms()` on the clean text + `extract_front_matter_acronyms()` on the raw pages), the same code that enriches the parse step's ruler — pooled across the Region_Year's PDFs, and (2) the alias links from all six dictionaries. Resolves duplicate keys (longest canonical wins), normalizes surfaces via `clean_entities()`, snapshots the pre-disambig name as `raw_entity_name`, then runs `textNet::disambiguate()`. Outputs to `disambiguated_extracted_networks/` plus a combined `disambiguated_extracts.RDS`. |
| `05_build_igraphs.R` | R | Builds igraph objects from the disambiguated extracts (port of kings step5). Per Region_Year writes a **multiplex** directed graph (one edge per SVO triple, verb attributes preserved) and a **uniplex** weighted graph (parallel edges collapsed, `weight` = count). Drops NA-endpoint edges and <2-letter names; keeps all nodes (no-edge nodes become isolates). Outputs to `igraph_objects/multiplex/` and `igraph_objects/uniplex/`. |
| `06_audit_pipeline.R` | R | Per-Region_Year retention audit (port of kings audit). Per-PDF stages (PDF pages, clean rows/non-blank) are aggregated up to Region_Year; extract/disambig/graph stages are per Region_Year. Writes `output/pipeline_audit.csv`. Optional QA — run any time after the extract step. |
| `XX_find_duplicate_pdfs.py` | Python | **Side utility, not a pipeline stage.** Detects duplicate PDFs within the same Region_Year by MD5 hash; writes a report to `tijuanabox/core_data/duplicate_pdfs.csv`. Run with `--delete` to remove duplicates after manual review (typically right after `00_scraping.R`). |

Unprefixed files in `code/`: `_config.R` and `utils.R` (sourced helpers),
`run_pipeline.sh` (the run wrapper), `README.md`, and the `dicts/` directory.
(`pdftotext_py.py` is a legacy variant of `01_pdftotext.py` and is not part of
the run order.)

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
only. The loaders enforce this automatically. Dictionary creation is **not** part
of the numbered run order — regenerate occasionally (when sources / corpus
change). The builders use `DICTS_DIR = "."` / `DICTS_DIR <- "."`, so run them
from inside `code/dicts/`:

```bash
cd code/dicts && Rscript build_gov_entities_dict.R
cd code/dicts && python3 -c "import json;nb=json.load(open('build_water_gsa_dictionary.ipynb'));exec('\n'.join(''.join(c['source']) for c in nb['cells'] if c['cell_type']=='code'))"
```

`build_gov_entities_dict.R` reads `govscienceuseR_agencies.RDS` and
`govsci_custom_abbreviations.csv` (both in `code/dicts/`).

### Per-Region_Year dictionaries (`extract_region_dictionaries.py`) — optional

`code/dicts/extract_region_dictionaries.py` scans the raw text for
acronym/glossary sections, sends detected pages to the Claude API, and writes a
flat JSON term list per Region_Year to `tijuanabox/core_data/dictionaries/`. The
parse step loads these as entity-ruler terms if present.

**This is now optional and largely superseded.** The deterministic
`mine_acronyms()` path (front-matter glossary tables + in-text parentheticals)
already feeds the entity ruler at parse time and the disambiguation map — for the
common case of tabular glossaries, the Claude step re-derives names the regex
extractors already produce for free. Its only unique value is **non-tabular /
narrative glossaries** the deterministic row parser can't read. The pipeline does
**not** depend on it. To decide whether to keep it, diff its term list against
the parse step's `mine_acronyms()` names on a few Region_Years; if there's little
the regex misses, you can drop it. Run only if you want that extra coverage:

```bash
ANTHROPIC_API_KEY=… python3 code/dicts/extract_region_dictionaries.py
```

> The earlier `output/water_*.csv` dictionaries are superseded by `code/dicts/`
> and can be deleted.

---

## Run Order

```
code/00_scraping.R
code/XX_find_duplicate_pdfs.py         # side utility: review duplicates before proceeding
code/01_pdftotext.py
code/02_cleaningtxt.py
code/03_textnet_parse_and_extract.R    # requires spacy-env conda env
code/04_disambiguate_nodelists.R
code/05_build_igraphs.R
code/06_audit_pipeline.R               # optional QA, run any time after extract
```

PDF extraction and cleaning (01–02) can be run incrementally as new PDFs arrive.
Parsing through graph building (03–05) should be re-run when new Region_Years are
added. Region dictionaries (`code/dicts/extract_region_dictionaries.py`) are
regenerated separately, before the parse step, only when the corpus changes.

### `run_pipeline.sh`

`code/run_pipeline.sh` queues the steps in order, captures a single timestamped
log to `tijuanabox/core_data/pipeline_run_logs/`, and tees output to the terminal.
Run it from the repo root:

```bash
./code/run_pipeline.sh                  # default: 01, 02, 03, 04, 05 + audit (06)
./code/run_pipeline.sh 03 04            # subset, in the given order (prefix or full name)
./code/run_pipeline.sh --with-scrape    # prepend 00_scraping.R
./code/run_pipeline.sh --clobber        # CLOBBER=1 everywhere
./code/run_pipeline.sh --testing        # TESTING=1 (first TESTING_N units)
./code/run_pipeline.sh --no-audit       # skip the audit at the end

nohup ./code/run_pipeline.sh --with-scrape &   # detach; survives logout
```

The default sequence is the document → graph pipeline. `00_scraping.R` (network
download, via `--with-scrape`) and `XX_find_duplicate_pdfs.py` (manual dedupe
review) are **not** in the default — run them explicitly by listing them. Steps
run sequentially and a failure halts the run (the audit failing is non-fatal);
flags become the `CLOBBER` / `TESTING` env vars from `_config.R`.

---

## Configuration & flags (`code/_config.R`)

Cross-step settings live in `code/_config.R` (ported from kings), sourced by
every R step via `utils.R`. Defaults are baked in; override any of them from the
shell with an environment variable. The Python preprocessing steps read the same
`CLOBBER` / `TESTING` / `TESTING_N` variables, so the toggles are uniform across
the whole pipeline.

| Env var | R variable | Default | Used by |
|---|---|---|---|
| `CLOBBER` | `CLOBBER` | `FALSE` | 01–05 (re-run even if output exists) |
| `TESTING` | `TESTING` | `FALSE` | 02, 03, 04 (restrict to a small subset) |
| `TESTING_N` | `TESTING_N` | `5` | 02, 03, 04 (subset size) |
| `MIN_PAGE_CHARS` | `MIN_PAGE_CHARS` | `200` | 03 (drop short pages before parsing) |
| `PARSE_WORKERS` | `PARSE_WORKERS` | `1` | 03 (`cl` passed to `textnet_extract`) |
| `SPACY_ENV` | `SPACY_ENV` | `"spacy-env"` | 03 (conda env name or python binary path) |

```bash
CLOBBER=1 Rscript code/04_disambiguate_nodelists.R           # rebuild everything
TESTING=1 TESTING_N=3 Rscript code/03_textnet_parse_and_extract.R
CLOBBER=1 python3 code/01_pdftotext.py
```

(`extract_region_dictionaries.py` defaults `CLOBBER` to TRUE and has its own
`TEST_N_REGIONS` / `TEST_MAX_FILES` subset knobs; set `CLOBBER=0` to skip
existing dict files.)

`_config.R` also defines crash-safe `atomic_write()` / `atomic_saveRDS()` (outputs
go to a `.tmp` file and are renamed on success, so an interrupted run never leaves
a half-written file that a later rerun would skip). `utils.R` adds the dictionary
loaders (`DICT_KEYS`, `load_dict_terms`, `load_alias_pairs`, `build_global_dict`),
the shared `mine_acronyms()` (used by both the parse and disambiguation steps),
and `region_year_key()`.

---

## Filename Convention

All filenames use underscores, no spaces. The Region_Year prefix format is
`Region_X_YYYY` (e.g., `Region_7_2020`), enforced at download time in
`00_scraping.R`. Per-Region_Year artifacts are named `extract_<Region_Year>.RDS`.

---

## textNet dependency

The disambiguation step requires a textNet build that exports
`find_intext_acronyms()`, `extract_front_matter_acronyms()`, and the current
`disambiguate()` signature (textNet ≥ 1.0.1). Verify with
`packageVersion("textNet")` and `exists("extract_front_matter_acronyms")` after
`library(textNet)`.
