"""
rename_sanitize.py
------------------
Replaces spaces with underscores in all filenames across the pipeline
directories. Run once after the initial download to clean up legacy names,
and again whenever new files are added with spaces.

Directories cleaned:
    tijuanabox/raw_data/plan_pdfs/
    tijuanabox/int_data/plan_txts_raw/
    tijuanabox/int_data/plan_txts_clean/
    tijuanabox/int_data/parsed_files/
    tijuanabox/int_data/dictionaries/
    tijuanabox/int_data/raw_extracted_networks/

Also updates url_prefix_map.json to strip all spaces from prefix values.

Usage:
    python3 rename_sanitize.py           # dry run — shows what would change
    python3 rename_sanitize.py --apply   # apply renames
"""

import argparse
import json
import os
import re

DIRS = [
    "tijuanabox/raw_data/plan_pdfs",
    "tijuanabox/int_data/plan_txts_raw",
    "tijuanabox/int_data/plan_txts_clean",
    "tijuanabox/int_data/parsed_files",
    "tijuanabox/int_data/dictionaries",
    "tijuanabox/int_data/raw_extracted_networks",
]

# Metadata files whose text content contains spaced Region_ references
METADATA_FILES = [
    "url_prefix_map.json",
    "download_plans.sh",
    "fix_empty_files.sh",
    "pdf_links_from_html.md",
]

# Pattern: "Region_43 _2019" → "Region_43_2019"
SPACE_RE = re.compile(r"(Region_\d+)\s+_")


def sanitize(name):
    """Replace spaces with underscores in a filename."""
    return name.replace(" ", "_")


def collect_renames(directories):
    """Return list of (old_path, new_path) for files with spaces in their name."""
    renames = []
    for d in directories:
        if not os.path.isdir(d):
            continue
        for fname in sorted(os.listdir(d)):
            if " " in fname:
                old = os.path.join(d, fname)
                new = os.path.join(d, sanitize(fname))
                renames.append((old, new))
    return renames


def fix_metadata_file(path, apply):
    """
    Replace spaced Region_ patterns in a text file.
    url_prefix_map.json is handled as JSON to preserve formatting;
    other files are fixed with a regex substitution on raw text.
    Returns number of substitutions made.
    """
    if not os.path.exists(path):
        return 0

    if path.endswith(".json"):
        with open(path) as f:
            m = json.load(f)
        fixed = {url: sanitize(SPACE_RE.sub(r"\1_", prefix))
                 for url, prefix in m.items()}
        changed = sum(1 for u in m if m[u] != fixed[u])
        if changed and apply:
            with open(path, "w") as f:
                json.dump(fixed, f, indent=2)
        return changed
    else:
        with open(path, encoding="utf-8") as f:
            content = f.read()
        fixed, n = SPACE_RE.subn(r"\1_", content)
        if n and apply:
            with open(path, "w", encoding="utf-8") as f:
                f.write(fixed)
        return n


# ── Main ──────────────────────────────────────────────────────────────────────

parser = argparse.ArgumentParser()
parser.add_argument("--apply", action="store_true",
                    help="Apply renames (default is dry run)")
args = parser.parse_args()

mode = "APPLYING" if args.apply else "DRY RUN"
print(f"=== rename_sanitize.py  [{mode}] ===\n")

renames = collect_renames(DIRS)

if not renames:
    print("No files with spaces found.")
else:
    for old, new in renames:
        print(f"  {os.path.basename(old)}")
        print(f"→ {os.path.basename(new)}\n")
    if args.apply:
        conflicts = [new for _, new in renames if os.path.exists(new)]
        if conflicts:
            print("ERROR: rename would overwrite existing files:")
            for c in conflicts:
                print(f"  {c}")
            print("Resolve conflicts manually before re-running.")
        else:
            for old, new in renames:
                os.rename(old, new)
            print(f"Renamed {len(renames)} file(s).")
    else:
        print(f"{len(renames)} file(s) would be renamed. Re-run with --apply to rename.")

print("\n--- Metadata files ---")
for mf in METADATA_FILES:
    n = fix_metadata_file(mf, args.apply)
    if n:
        action = "Fixed" if args.apply else "Would fix"
        print(f"  {action} {n} occurrence(s) in {mf}")
    elif os.path.exists(mf):
        print(f"  {mf}: clean")
