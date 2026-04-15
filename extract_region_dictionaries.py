"""
extract_region_dictionaries.py
-------------------------------
Scans raw text files (plan_txts_raw/) for acronym and glossary sections,
extracts terms via Claude API, and writes a flat JSON term list per
Region_Year.

Output:
    tijuanabox/int_data/dictionaries/Region_X_YYYY_dict.json
    Each file is a flat JSON array of strings (full expanded names).
    These feed into Stage 2 (textnet_parse_and_extract.R) as part of the
    spaCy entity ruler, combined with the centralized water dictionaries.

Section detection:
    Pages are scanned for headers matching acronym/abbreviation/glossary
    patterns. Matching pages plus up to MAX_FOLLOW_PAGES subsequent pages
    are sent to Claude for term extraction.

Usage:
    python3 extract_region_dictionaries.py
    (run from project root, i.e. the folder containing tijuanabox/)

Requirements:
    pip install anthropic
    ANTHROPIC_API_KEY environment variable must be set
"""

import csv
import json
import os
import re
import traceback
from collections import defaultdict

import anthropic

# === FLAGS ===
TESTING = True   # Set False to process all Region_Years
CLOBBER = False  # Set True to overwrite existing dict files

# === PATHS ===
TXT_DIR  = "tijuanabox/int_data/plan_txts_raw"
DICT_DIR = "tijuanabox/int_data/dictionaries"

os.makedirs(DICT_DIR, exist_ok=True)

# === CONFIG ===
CLAUDE_MODEL     = "claude-haiku-4-5-20251001"
MAX_FOLLOW_PAGES = 4   # Pages to collect after a detected section header

# === TESTING SUBSET ===
TEST_N_REGIONS = 2   # Number of Region_Years to process in testing mode
TEST_MAX_FILES = 5   # Max total files to process in testing mode

# === SECTION DETECTION ===
# Matches common acronym/glossary section headers, allowing for leading
# whitespace (common in layout-preserved pdftotext output)
SECTION_RE = re.compile(
    r'(?m)^\s{0,10}'
    r'(?:list\s+of\s+)?'
    r'(?:acronyms?(?:\s+and\s+abbreviations?)?'
    r'|abbreviations?(?:\s+and\s+acronyms?)?'
    r'|glossary(?:\s+of\s+terms?)?'
    r'|terms?\s+and\s+(?:their\s+)?definitions?)',
    re.IGNORECASE
)

# === REGION_YEAR GROUPING ===
REGION_YEAR_RE = re.compile(r'^(Region_[^_]+_[0-9]{4})')


def group_files_by_region_year(txt_dir):
    """Return dict mapping Region_Year key -> sorted list of file paths."""
    groups = defaultdict(list)
    for fname in sorted(os.listdir(txt_dir)):
        if not fname.endswith(".txt"):
            continue
        m = REGION_YEAR_RE.match(fname)
        if m:
            groups[m.group(1)].append(os.path.join(txt_dir, fname))
        else:
            print(f"  Warning: could not extract Region_Year from {fname!r}")
    return dict(groups)


def read_pages(txt_path):
    """Read a plan_txts_raw .txt file into a list of (page_num, text) tuples."""
    pages = []
    with open(txt_path, encoding="utf-8", errors="replace") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            try:
                pages.append((int(row["page"]), row.get("text") or ""))
            except (KeyError, ValueError):
                pass
    return pages


def find_section_pages(pages):
    """
    Scan pages for acronym/glossary section headers.
    Returns a list of (page_num, text) for the header page and up to
    MAX_FOLLOW_PAGES subsequent pages, sorted and deduplicated.
    """
    hit_indices = set()
    for i, (_, text) in enumerate(pages):
        if SECTION_RE.search(text):
            for j in range(i, min(i + 1 + MAX_FOLLOW_PAGES, len(pages))):
                hit_indices.add(j)
    return [(pages[i][0], pages[i][1]) for i in sorted(hit_indices)]


def extract_terms_with_claude(section_pages, source_label, client):
    """
    Send section text to Claude and return a flat list of extracted terms.
    Returns an empty list on any failure.
    """
    combined_text = "\n\n---\n\n".join(text for _, text in section_pages)
    if not combined_text.strip():
        return []

    prompt = (
        "You are extracting terms from acronym or glossary sections of a "
        "California Integrated Regional Water Management (IRWM) policy document.\n\n"
        "The text below is from pages identified as acronym lists, abbreviation "
        "lists, or glossary sections.\n\n"
        "Return a JSON array of strings containing the FULL EXPANDED names only — "
        "not the abbreviations themselves. Include multi-word organization names, "
        "program names, place names, and technical terms. Omit single-word common "
        "terms and bare acronyms with no expansion present in the text.\n\n"
        "Return ONLY the JSON array, no explanation or markdown.\n\n"
        f"Text:\n{combined_text[:12000]}"
    )

    try:
        response = client.messages.create(
            model=CLAUDE_MODEL,
            max_tokens=1024,
            messages=[{"role": "user", "content": prompt}]
        )
        raw = response.content[0].text.strip()
        # Strip markdown code fences if present
        raw = re.sub(r"^```(?:json)?\s*|\s*```$", "", raw, flags=re.DOTALL).strip()
        terms = json.loads(raw)
        if isinstance(terms, list):
            return [t for t in terms if isinstance(t, str) and t.strip()]
    except Exception as e:
        print(f"    → Claude extraction failed for {source_label}: {e}")
    return []


def deduplicate(terms):
    """Deduplicate a list of strings, preserving first-seen order."""
    seen = set()
    out  = []
    for t in terms:
        if t not in seen:
            seen.add(t)
            out.append(t)
    return out


def get_testing_subset(groups):
    """
    Select up to TEST_MAX_FILES files from the first TEST_N_REGIONS
    Region_Years (alphabetical order).
    """
    subset = {}
    total  = 0
    for key in sorted(groups)[:TEST_N_REGIONS]:
        subset[key] = []
        for f in groups[key]:
            if total >= TEST_MAX_FILES:
                break
            subset[key].append(f)
            total += 1
    return subset


# ── Main loop ─────────────────────────────────────────────────────────────────

client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY from environment

groups = group_files_by_region_year(TXT_DIR)
print(f"Region_Years found: {len(groups)}")

if TESTING:
    groups = get_testing_subset(groups)
    n_files = sum(len(v) for v in groups.values())
    print(f"TESTING mode: {n_files} file(s) across {len(groups)} Region_Year(s): "
          f"{', '.join(sorted(groups))}")

processed = skipped = failed = 0

for region_year, files in sorted(groups.items()):
    dict_path = os.path.join(DICT_DIR, f"{region_year}_dict.json")

    if os.path.exists(dict_path) and not CLOBBER:
        print(f"\n  Skipping {region_year} (already exists)")
        skipped += 1
        continue

    print(f"\n  {region_year} ({len(files)} file(s))")
    all_terms = []

    try:
        for fpath in files:
            fname = os.path.basename(fpath)
            pages = read_pages(fpath)
            if not pages:
                print(f"    {fname}: no pages read, skipping")
                continue

            section_pages = find_section_pages(pages)
            if not section_pages:
                print(f"    {fname}: no acronym/glossary sections detected")
                continue

            print(f"    {fname}: {len(section_pages)} section page(s) → calling Claude")
            terms = extract_terms_with_claude(section_pages, fname, client)
            print(f"    → {len(terms)} term(s) extracted")
            all_terms.extend(terms)

        unique_terms = deduplicate(all_terms)

        with open(dict_path, "w", encoding="utf-8") as f:
            json.dump(unique_terms, f, indent=2, ensure_ascii=False)

        print(f"  → {len(unique_terms)} unique term(s) → {os.path.basename(dict_path)}")
        processed += 1

    except Exception as e:
        print(f"  → ERROR processing {region_year}: {e}")
        traceback.print_exc()
        failed += 1

print(f"\nDone.  Processed: {processed}  Skipped: {skipped}  Failed: {failed}")
