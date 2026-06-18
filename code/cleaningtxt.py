"""
cleaningtxt.py
--------------
Filters non-prose pages from raw text files before NER processing.
Python port of cleaningtxt.R, adapted from the salinas project.

Reads:  tijuanabox/int_data/plan_txts_raw/*.txt   (TSV: page\ttext)
Writes: tijuanabox/int_data/plan_txts_clean/*.parquet

Pages failing any density threshold have their text set to an empty string
rather than being removed. Page numbers are preserved so downstream code
can match network output back to the original PDF pages.

Thresholds (tuned on corpus samples — set to 1.0 to disable a filter):
    PUNCT_DENSITY_MAX      = 0.10   catches reference lists, TOCs
    NUMERIC_DENSITY_MAX    = 0.25   catches tables, data appendices
    WHITESPACE_DENSITY_MAX = 0.75   catches figures, maps
    MAX_CHARACTERS         = 20000  catches oversized map/image pages

Usage:
    python3 cleaningtxt.py
    (run from project root, i.e. the folder containing tijuanabox/)

Requirements:
    pip install pandas pyarrow
"""

import os
import re
import traceback

import pandas as pd

# === FLAGS ===
CLOBBER = False   # Set True to re-clean already-processed files
TESTING = False   # Set True to process first 5 files only

# === PATHS ===
RAW_DIR   = "tijuanabox/int_data/plan_txts_raw"
CLEAN_DIR = "tijuanabox/int_data/plan_txts_clean"

os.makedirs(CLEAN_DIR, exist_ok=True)

# === THRESHOLDS ===
PUNCT_DENSITY_MAX      = 0.10
NUMERIC_DENSITY_MAX    = 0.25
WHITESPACE_DENSITY_MAX = 0.75
MAX_CHARACTERS         = 20_000

# Pre-compiled patterns for density calculation
_PUNCT_RE   = re.compile(r'[^\w\s]')
_NUMERIC_RE = re.compile(r'[0-9]')
_WS_RE      = re.compile(r'\s')


def clean_pages(df):
    """
    Set text to '' for pages failing any density threshold.
    Returns (cleaned DataFrame, count of blanked pages).
    """
    df   = df.copy()
    text = df["text"].fillna("").astype(str)
    n    = text.str.len().clip(lower=1)   # avoid divide-by-zero

    punct_density = text.str.count(_PUNCT_RE.pattern)   / n
    numeric_density = text.str.count(_NUMERIC_RE.pattern) / n
    ws_density    = text.str.count(_WS_RE.pattern)      / n
    n_chars       = text.str.len()

    mask = (
        (n_chars == 0)                              |
        (punct_density   > PUNCT_DENSITY_MAX)       |
        (numeric_density > NUMERIC_DENSITY_MAX)     |
        (ws_density      > WHITESPACE_DENSITY_MAX)  |
        (n_chars         > MAX_CHARACTERS)
    )

    df.loc[mask, "text"] = ""
    return df, int(mask.sum())


# ── Main loop ─────────────────────────────────────────────────────────────────

files = sorted(f for f in os.listdir(RAW_DIR) if f.endswith(".txt"))
print(f"Files in plan_txts_raw/: {len(files)}")

if TESTING:
    files = files[:5]
    print(f"TESTING mode: processing {len(files)} file(s)")

cleaned = skipped = failed = 0

for fname in files:
    raw_path   = os.path.join(RAW_DIR, fname)
    out_name   = re.sub(r"\.txt$", ".parquet", fname)
    clean_path = os.path.join(CLEAN_DIR, out_name)

    if os.path.exists(clean_path) and not CLOBBER:
        skipped += 1
        continue

    try:
        df = pd.read_csv(raw_path, sep="\t", dtype={"page": int, "text": str})

        df_clean, n_blanked = clean_pages(df)

        df_clean.to_parquet(clean_path, index=False)
        total = len(df_clean)
        print(f"  {fname}: {total} pages, {n_blanked} blanked ({n_blanked/max(total,1):.0%})"
              f" → {out_name}")
        cleaned += 1

    except Exception as e:
        print(f"  ERROR: {fname}: {e}")
        traceback.print_exc()
        failed += 1

print(f"\nDone.  Cleaned: {cleaned}  Skipped: {skipped}  Failed: {failed}")
