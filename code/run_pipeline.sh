#!/usr/bin/env bash
# run_pipeline.sh — run the tijuana pipeline steps in order, each step's
# stdout/stderr captured to a single timestamped log file and tee'd to the
# terminal so you can watch the run. Ported from the kings core_code wrapper
# and adapted for tijuana's mixed R/Python, prefixed steps.
#
# Run from the REPO ROOT (the folder containing code/ and tijuanabox/):
#
#   ./code/run_pipeline.sh                     # default: 01,02,03,04,05 + audit (06)
#   ./code/run_pipeline.sh 03 04               # subset (run in the given order)
#   ./code/run_pipeline.sh --with-scrape       # prepend 00_scraping.R
#   ./code/run_pipeline.sh --no-audit          # skip the audit at the end
#   ./code/run_pipeline.sh --clobber           # CLOBBER=1 in every step
#   ./code/run_pipeline.sh --testing           # TESTING=1 (first TESTING_N units)
#
# Steps run sequentially: each must finish before the next starts, so you can
# "queue" later steps by listing them. A step token can be the full filename
# (03_textnet_parse_and_extract.R) or just its numeric prefix (03).
#
# Default sequence is the document -> graph pipeline. A couple of steps are NOT
# in the default and are run explicitly when you want them:
#   00_scraping.R               network download of source PDFs (--with-scrape)
#   XX_find_duplicate_pdfs.py   manual dedupe review (has a --delete mode)
# e.g.  ./code/run_pipeline.sh XX_find_duplicate_pdfs.py
#
# Dictionary creation is separate (not a pipeline step): the curated dict
# builders and code/dicts/extract_region_dictionaries.py live in code/dicts/
# and are run occasionally when the corpus / sources change.
#
# Flags become env vars consumed by code/_config.R (and the Python steps):
#   --clobber -> CLOBBER=1     --testing -> TESTING=1
# Export TESTING_N / MIN_PAGE_CHARS / PARSE_WORKERS / SPACY_ENV directly if
# you want to override those.
#
# Detach so the queue survives logout:
#   nohup ./code/run_pipeline.sh --with-scrape &
#   tail -f $(ls -t tijuanabox/core_data/pipeline_run_logs/run_*.log | head -1)

set -euo pipefail

# Default step sequence — keep in pipeline order. Full filenames.
DEFAULT_STEPS=(
  01_pdftotext.py
  02_cleaningtxt.py
  03_textnet_parse_and_extract.R
  04_disambiguate_nodelists.R
  05_build_igraphs.R
)
AUDIT_STEP="06_audit_pipeline.R"
SCRAPE_STEP="00_scraping.R"
CODE_DIR="code"
LOG_DIR="tijuanabox/core_data/pipeline_run_logs"
RUN_AUDIT=1
WITH_SCRAPE=0

# === Arg parsing ===
STEPS=()
for arg in "$@"; do
  case "$arg" in
    --no-audit)    RUN_AUDIT=0 ;;
    --clobber)     export CLOBBER=1 ;;
    --testing)     export TESTING=1 ;;
    --with-scrape) WITH_SCRAPE=1 ;;
    -h|--help)
      sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) STEPS+=("$arg") ;;
  esac
done
if [ ${#STEPS[@]} -eq 0 ]; then
  STEPS=("${DEFAULT_STEPS[@]}")
fi
# Prepend the scrape step if requested (idempotent).
if [ "$WITH_SCRAPE" -eq 1 ] && [[ ! " ${STEPS[*]} " =~ " ${SCRAPE_STEP} " ]]; then
  STEPS=("$SCRAPE_STEP" "${STEPS[@]}")
fi

# === Resolve a step token (full name or numeric/XX prefix) to a file path ===
resolve_step() {
  local tok="$1"
  if [ -f "${CODE_DIR}/${tok}" ]; then
    echo "${CODE_DIR}/${tok}"; return 0
  fi
  local matches=()
  for f in "${CODE_DIR}/${tok}"*.R "${CODE_DIR}/${tok}"*.py; do
    [ -f "$f" ] && matches+=("$f")
  done
  if [ ${#matches[@]} -eq 1 ]; then
    echo "${matches[0]}"; return 0
  elif [ ${#matches[@]} -eq 0 ]; then
    echo "ERROR: no step matches '${tok}' in ${CODE_DIR}/" >&2; return 1
  else
    echo "ERROR: '${tok}' is ambiguous: ${matches[*]}" >&2; return 1
  fi
}

# === Run one step with the right interpreter ===
run_one() {
  local path="$1"
  case "$path" in
    *.R)  Rscript "$path" ;;
    *.py) python3 "$path" ;;
    *)    echo "ERROR: don't know how to run $path" >&2; return 1 ;;
  esac
}

# === Log file ===
mkdir -p "$LOG_DIR"
TS=$(date +%Y%m%d_%H%M%S)
LOG="${LOG_DIR}/run_${TS}.log"

{
  echo "=== Pipeline run started $(date) ==="
  echo "Steps:   ${STEPS[*]}"
  [ "$RUN_AUDIT" -eq 1 ] && echo "Audit:   yes (${AUDIT_STEP})" || echo "Audit:   no"
  echo "Clobber: ${CLOBBER:-0}"
  echo "Testing: ${TESTING:-0}"
  echo "Log:     $LOG"
  echo
} | tee "$LOG"

# === Run ===
for tok in "${STEPS[@]}"; do
  script=$(resolve_step "$tok") || { echo "Halting." | tee -a "$LOG"; exit 1; }
  step=$(basename "$script")
  {
    echo "=== $step ==="
    echo "  started  $(date +%H:%M:%S)"
  } | tee -a "$LOG"
  if ! run_one "$script" 2>&1 | tee -a "$LOG"; then
    echo "  FAILED   $(date +%H:%M:%S)" | tee -a "$LOG"
    echo "Pipeline halted on $step. See $LOG" >&2
    exit 1
  fi
  echo "  finished $(date +%H:%M:%S)" | tee -a "$LOG"
  echo | tee -a "$LOG"
done

if [ "$RUN_AUDIT" -eq 1 ]; then
  script="${CODE_DIR}/${AUDIT_STEP}"
  if [ -f "$script" ]; then
    {
      echo "=== $AUDIT_STEP ==="
      echo "  started  $(date +%H:%M:%S)"
    } | tee -a "$LOG"
    Rscript "$script" 2>&1 | tee -a "$LOG" || true   # audit failure non-fatal
    echo "  finished $(date +%H:%M:%S)" | tee -a "$LOG"
  fi
fi

{
  echo
  echo "=== Pipeline run done $(date) ==="
  echo "Log: $LOG"
} | tee -a "$LOG"
