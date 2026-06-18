"""
find_duplicate_pdfs.py
----------------------
Detects duplicate PDF files in plan_pdfs/ by MD5 content hash.
Prints a report of duplicate groups and writes a CSV for review.

Does NOT delete anything — review the output and remove duplicates manually
or with the --delete flag (see below).

Output:
    tijuanabox/raw_data/duplicate_pdfs.csv
    Columns: hash, keep, duplicate, region_year

Usage:
    python3 find_duplicate_pdfs.py            # report only
    python3 find_duplicate_pdfs.py --delete   # delete the 'duplicate' file
                                              # in each pair after confirmation
"""

import argparse
import csv
import hashlib
import os
import re
import sys
from collections import defaultdict

PDF_DIR    = "tijuanabox/raw_data/plan_pdfs"
REPORT_CSV = "tijuanabox/raw_data/duplicate_pdfs.csv"

REGION_YEAR_RE = re.compile(r"^Region_(\d+)\s*_\s*(\d{4})")


def md5(path, chunk=1 << 20):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(chunk), b""):
            h.update(block)
    return h.hexdigest()


def region_year(fname):
    m = REGION_YEAR_RE.match(fname)
    return f"Region_{m.group(1)}_{m.group(2)}" if m else "unknown"


def pick_keeper(paths):
    """
    From a group of identical files, prefer the one with the longer/more
    descriptive filename (more information in the name = more likely canonical).
    """
    return max(paths, key=lambda p: len(os.path.basename(p)))


# ── Main ──────────────────────────────────────────────────────────────────────

parser = argparse.ArgumentParser()
parser.add_argument("--delete", action="store_true",
                    help="Delete duplicate files after confirmation")
args = parser.parse_args()

files = [
    os.path.join(PDF_DIR, f)
    for f in sorted(os.listdir(PDF_DIR))
    if os.path.isfile(os.path.join(PDF_DIR, f))
]
print(f"Hashing {len(files)} files in {PDF_DIR} ...")

by_hash = defaultdict(list)
for i, path in enumerate(files, 1):
    if i % 50 == 0:
        print(f"  {i}/{len(files)}")
    by_hash[md5(path)].append(path)

# Split into same-Region_Year duplicates (accidental) vs cross-Region_Year
# identical files (different issue, not cleaned up here)
same_ry_dupes  = {}
cross_ry_dupes = {}

for h, paths in by_hash.items():
    if len(paths) < 2:
        continue
    rys = [region_year(os.path.basename(p)) for p in paths]
    if len(set(rys)) == 1:
        same_ry_dupes[h] = paths       # same content, same Region_Year
    else:
        cross_ry_dupes[h] = paths      # same content, different Region_Years

if cross_ry_dupes:
    print(f"Note: {len(cross_ry_dupes)} file(s) appear in multiple Region_Years "
          f"— skipping (not accidental duplicates).")

if not same_ry_dupes:
    print("No same-Region_Year duplicates found.")
    sys.exit(0)

print(f"\nFound {len(same_ry_dupes)} duplicate group(s) within the same Region_Year:\n")

rows = []
for h, paths in sorted(same_ry_dupes.items()):
    keeper = pick_keeper(paths)
    dupe_paths = [p for p in paths if p != keeper]
    ry = region_year(os.path.basename(keeper))
    for dp in dupe_paths:
        rows.append({
            "hash":        h,
            "keep":        os.path.basename(keeper),
            "duplicate":   os.path.basename(dp),
            "region_year": ry,
        })
        print(f"  Region_Year: {ry}")
        print(f"  KEEP:        {os.path.basename(keeper)}")
        print(f"  DUPLICATE:   {os.path.basename(dp)}")
        print()

os.makedirs(os.path.dirname(REPORT_CSV), exist_ok=True)
with open(REPORT_CSV, "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=["hash", "keep", "duplicate", "region_year"])
    writer.writeheader()
    writer.writerows(rows)

print(f"Report written to {REPORT_CSV}")
print(f"Total duplicates to remove: {len(rows)}")

if args.delete:
    print(f"\nAbout to delete {len(rows)} file(s). This cannot be undone.")
    confirm = input("Type 'yes' to proceed: ").strip().lower()
    if confirm == "yes":
        for row in rows:
            path = os.path.join(PDF_DIR, row["duplicate"])
            os.remove(path)
            print(f"  Deleted: {row['duplicate']}")
        print("Done.")
    else:
        print("Cancelled.")
