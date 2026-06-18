"""
pdftotext_py.py
---------------
Python equivalent of pdftotext.R — converts all PDFs in plan_pdfs/ to
tab-separated text files in plan_txts_raw/, one row per page.

Output format (matches pdftotext.R):
    page\ttext

Extraction engine:
    Uses the system `pdftotext` CLI (poppler), the same underlying library
    as pdftools::pdf_text() in R. This ensures new .txt files are consistent
    with existing ones produced by pdftotext.R.

    pdfplumber (pdfminer-based) was intentionally NOT used here because
    pdfminer and poppler have different whitespace normalization, layout
    handling, and Unicode ligature resolution. Mixing engines across the
    corpus would create inconsistencies for downstream NLP.

Differences from pdftotext.R:
  - Processes ALL files in plan_pdfs/, not just those ending in .pdf
    (many downloaded files have no extension due to non-pdf URLs)
  - OCR fallback via tesseract CLI for scanned/image-only PDFs

Requirements:
    poppler (provides pdftotext CLI):
        macOS:   brew install poppler
        Ubuntu:  apt install poppler-utils
    tesseract (optional, for OCR fallback):
        macOS:   brew install tesseract
        Ubuntu:  apt install tesseract-ocr
    pdf2image (optional, for OCR fallback):
        pip install pdf2image

Usage:
    python3 pdftotext_py.py
    (run from the project root, i.e. the folder containing tijuanabox/)
"""

import os
import csv
import subprocess
import shutil
import traceback

CLOBBER = False  # Set True to overwrite existing txt files

# Paths — adjust if running from a different working directory
PDF_DIR = "tijuanabox/raw_data/plan_pdfs"
TXT_DIR = "tijuanabox/int_data/plan_txts_raw"

os.makedirs(TXT_DIR, exist_ok=True)

# Verify pdftotext is available
if not shutil.which("pdftotext"):
    raise EnvironmentError(
        "pdftotext not found. Install poppler:\n"
        "  macOS:  brew install poppler\n"
        "  Ubuntu: sudo apt install poppler-utils"
    )


def extract_text_poppler(pdf_path):
    """
    Extract text page-by-page using pdftotext (poppler CLI).
    Pages are separated by form-feed characters (\\f) in the output.
    Returns a list of strings, one per page.
    """
    result = subprocess.run(
        ["pdftotext", "-layout", pdf_path, "-"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        raise RuntimeError(f"pdftotext error: {result.stderr.strip()}")
    # pdftotext separates pages with form-feed; split and drop trailing empty
    pages = result.stdout.split("\f")
    # The last element after the final \f is always empty — remove it
    if pages and pages[-1].strip() == "":
        pages = pages[:-1]
    return pages


def extract_text_ocr(pdf_path):
    """
    OCR fallback for scanned/image-only PDFs.
    Requires: pip install pdf2image  AND  brew/apt install tesseract poppler
    """
    try:
        from pdf2image import convert_from_path
        import pytesseract

        images = convert_from_path(pdf_path, dpi=200)
        return [pytesseract.image_to_string(img) for img in images]
    except ImportError:
        return []


def write_tsv(pages, txt_path):
    """Write page list to TSV matching pdftotext.R output format."""
    with open(txt_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f, delimiter="\t")
        writer.writerow(["page", "text"])
        for i, text in enumerate(pages, 1):
            writer.writerow([i, text])


# ── Main loop ────────────────────────────────────────────────────────────────

files = sorted(os.listdir(PDF_DIR))
print(f"Files in plan_pdfs/: {len(files)}")

converted = skipped = failed = 0

for fname in files:
    pdf_path = os.path.join(PDF_DIR, fname)

    # Skip directories
    if os.path.isdir(pdf_path):
        continue

    # Strip .pdf extension if present; otherwise use full filename as stem
    stem = fname[:-4] if fname.lower().endswith(".pdf") else fname
    txt_path = os.path.join(TXT_DIR, stem + ".txt")

    if os.path.exists(txt_path) and not CLOBBER:
        skipped += 1
        continue

    print(f"  Converting: {fname[:70]}")
    try:
        pages = extract_text_poppler(pdf_path)

        # If poppler returned all-empty pages, try OCR
        if not any(p.strip() for p in pages):
            print("    → empty text, trying OCR...")
            pages = extract_text_ocr(pdf_path)

        if pages:
            write_tsv(pages, txt_path)
            print(f"    → {len(pages)} pages → {os.path.basename(txt_path)}")
            converted += 1
        else:
            print("    → SKIP: no text extracted (may need manual OCR)")
            failed += 1

    except Exception as e:
        print(f"    → ERROR: {e}")
        traceback.print_exc()
        failed += 1

print(f"\nDone. Converted: {converted}  Skipped (already done): {skipped}  Failed: {failed}")
