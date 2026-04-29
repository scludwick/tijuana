"""
extract_acronyms_and_mentions.py
--------------------------------
Builds per-document acronym dictionaries and entity-mention tables from the
raw plan texts, for later use in disambiguating textNet network nodes.

Inputs
------
    tijuanabox/int_data/plan_txts_raw/*.txt   (TSV: page\ttext)
    output/global_acronyms.json               (fallback acronym list)

Outputs
-------
    tijuanabox/int_data/plan_acronyms/<stem>.json
        Per-document acronym -> expansion map (JSON object).
        Sources are tracked alongside under <stem>.sources.json.

    tijuanabox/int_data/plan_mentions/<stem>.csv
        Per-document mention table with columns:
            span_start, span_end, surface, kind, head, is_plural,
            entity_id, canonical, section,
            resolved_from_idx, resolved_from_all_idxs

    tijuanabox/int_data/plan_acronyms/<Region_Year>_rollup.json
        Per-Region_Year merged acronym dict plus a `conflicts` list flagging
        cases where two documents in the region defined the same acronym
        with different expansions (e.g. GSA = Groundwater Sustainability
        Agency vs. General Services Administration).

    tijuanabox/int_data/plan_mentions/<Region_Year>_canonical.csv
        Per-Region_Year union of canonical entity forms and every raw
        surface that mapped to them, aggregated across all documents in
        that Region_Year. This is the lookup table the stage 3
        disambiguation script consumes.

Why raw text and not cleaned parquet?
-------------------------------------
cleaningtxt.py blanks pages that exceed WHITESPACE_DENSITY_MAX (0.75) or
PUNCT_DENSITY_MAX (0.10). Front-matter acronym tables — sparse two-column
`ACRONYM    Expansion` layouts and TOC-style dot-leader entries — fail
both. Running the extractor on the raw text preserves that high-precision
source. Disambiguation operates on entity *labels*, so character-offset
alignment with what textNet parses is not needed.

Global fallback
---------------
If a document's own acronym pass yields fewer than MIN_DOC_ACRONYMS entries,
the extractor is supplemented with the curated list in
output/global_acronyms.json. The per-document entries always win on
conflicts. This only kicks in for plans whose front matter lacks an
acronyms section and whose inline Schwartz-Hearst pass also comes up
empty.

Usage
-----
    python3 extract_acronyms_and_mentions.py
    (run from project root, i.e. the folder containing tijuanabox/)

Requirements
------------
    pip install "spacy>=3.7,<3.8" scispacy pandas
    pip install https://s3-us-west-2.amazonaws.com/ai2-s2-scispacy/\
releases/v0.5.4/en_core_sci_sm-0.5.4.tar.gz

The scispacy AbbreviationDetector is the only non-stdlib dependency of
acronym_extractor beyond pandas/csv; anaphor_resolver is pure Python.
"""

from __future__ import annotations

import csv
import json
import os
import re
import sys
import traceback
from collections import defaultdict

# Enable importing the helper modules from _XX_helpers/.
_HERE       = os.path.dirname(os.path.abspath(__file__))
_HELPER_DIR = os.path.abspath(os.path.join(_HERE, "..", "_XX_helpers"))
if _HELPER_DIR not in sys.path:
    sys.path.insert(0, _HELPER_DIR)

from acronym_extractor import build_acronym_dict            # noqa: E402
from anaphor_resolver import resolve as resolve_mentions    # noqa: E402

csv.field_size_limit(sys.maxsize)

# === FLAGS ===
CLOBBER = False   # Re-process documents that already have outputs
TESTING = False   # Process only a small TEST_MAX_FILES subset

# === PATHS ===
TXT_DIR            = "tijuanabox/int_data/plan_txts_raw"
ACRONYM_OUT_DIR    = "tijuanabox/int_data/plan_acronyms"
MENTION_OUT_DIR    = "tijuanabox/int_data/plan_mentions"
GLOBAL_ACRONYMS_FP = "output/global_acronyms.json"

os.makedirs(ACRONYM_OUT_DIR, exist_ok=True)
os.makedirs(MENTION_OUT_DIR, exist_ok=True)

# === CONFIG ===
# If a document's own extraction produces fewer than this many acronyms, we
# supplement with the global fallback list. 5 is a conservative floor — most
# real IRWM plans define 30+ acronyms in their front matter.
MIN_DOC_ACRONYMS = 5

# spaCy model for the Schwartz-Hearst inline pass. Set to None to skip the
# inline pass (front-matter table only).
SPACY_MODEL: str | None = "en_core_sci_sm"

# === TESTING SUBSET ===
TEST_MAX_FILES = 5

# === REGION_YEAR GROUPING ===
REGION_YEAR_RE = re.compile(r"^(Region_[^_]+_[0-9]{4})")


# ---------------------------------------------------------------------------
# IO helpers
# ---------------------------------------------------------------------------

def read_pages_as_text(txt_path: str) -> str:
    """Read a plan_txts_raw TSV and return the full concatenated document text.

    Pages are joined with a double-newline so anaphor_resolver's section
    segmenter and the front-matter heading regex in acronym_extractor still
    see the blank-line boundaries they rely on.
    """
    pages: list[str] = []
    with open(txt_path, encoding="utf-8", errors="replace") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for row in reader:
            text = row.get("text") or ""
            if text:
                pages.append(text)
    return "\n\n".join(pages)


def load_global_acronyms() -> dict[str, str]:
    """Load the curated fallback acronym list from output/global_acronyms.json."""
    if not os.path.exists(GLOBAL_ACRONYMS_FP):
        print(f"  Warning: global acronym file not found at {GLOBAL_ACRONYMS_FP}")
        return {}
    with open(GLOBAL_ACRONYMS_FP, encoding="utf-8") as f:
        payload = json.load(f)
    # Support both flat {"EPA": "Environmental Protection Agency", ...} and
    # {"acronyms": {...}, "_comment": "..."} structures.
    if "acronyms" in payload and isinstance(payload["acronyms"], dict):
        return payload["acronyms"]
    return {k: v for k, v in payload.items() if isinstance(v, str)}


def group_files_by_region_year(txt_dir: str) -> dict[str, list[str]]:
    """Return dict mapping Region_Year key -> sorted list of file paths."""
    groups: dict[str, list[str]] = defaultdict(list)
    for fname in sorted(os.listdir(txt_dir)):
        if not fname.endswith(".txt"):
            continue
        m = REGION_YEAR_RE.match(fname)
        if m:
            groups[m.group(1)].append(os.path.join(txt_dir, fname))
        else:
            print(f"  Warning: could not extract Region_Year from {fname!r}")
    return dict(groups)


# ---------------------------------------------------------------------------
# Per-document extraction
# ---------------------------------------------------------------------------

def process_document(
    txt_path: str,
    global_acronyms: dict[str, str],
) -> tuple[dict[str, str], dict[str, list[str]], list]:
    """Run the full extractor pipeline on one document.

    Returns
    -------
    (acronym_map, sources_map, mentions)
        acronym_map : acronym -> expansion (post-fallback merge)
        sources_map : acronym -> list of sources (front_matter / inline /
                      global_fallback)
        mentions    : list of anaphor_resolver.Mention objects, canonicalized.
    """
    text = read_pages_as_text(txt_path)
    if not text.strip():
        return {}, {}, []

    # --- Acronym pass ---
    # Always try the per-document pass first.
    use_inline = SPACY_MODEL is not None
    ac = build_acronym_dict(
        text,
        spacy_model=SPACY_MODEL or "en_core_web_sm",
        use_front_matter=True,
        use_inline=use_inline,
    )

    acronym_map   = dict(ac.mapping)
    sources_map: dict[str, list[str]] = {
        a: sorted(ac.sources.get(a, set())) for a in acronym_map
    }

    # Supplement with global fallback only when the per-doc pass is thin.
    if len(acronym_map) < MIN_DOC_ACRONYMS:
        added = 0
        for k, v in global_acronyms.items():
            if k not in acronym_map:
                acronym_map[k] = v
                sources_map.setdefault(k, []).append("global_fallback")
                added += 1
        print(f"    → per-doc dict had {len(ac.mapping)} entries; "
              f"merged {added} from global fallback")

    # --- Mention resolution pass ---
    mentions = resolve_mentions(text, acronym_map)

    return acronym_map, sources_map, mentions


# ---------------------------------------------------------------------------
# Output writers
# ---------------------------------------------------------------------------

def write_doc_outputs(
    stem: str,
    acronym_map: dict[str, str],
    sources_map: dict[str, list[str]],
    mentions: list,
) -> None:
    """Write per-document acronym JSON + mentions CSV."""
    acronym_path = os.path.join(ACRONYM_OUT_DIR, f"{stem}.json")
    sources_path = os.path.join(ACRONYM_OUT_DIR, f"{stem}.sources.json")
    mention_path = os.path.join(MENTION_OUT_DIR, f"{stem}.csv")

    with open(acronym_path, "w", encoding="utf-8") as f:
        json.dump(acronym_map, f, indent=2, ensure_ascii=False, sort_keys=True)
    with open(sources_path, "w", encoding="utf-8") as f:
        json.dump(sources_map, f, indent=2, ensure_ascii=False, sort_keys=True)

    with open(mention_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow([
            "span_start", "span_end", "surface", "kind", "head", "is_plural",
            "entity_id", "canonical", "section",
            "resolved_from_idx", "resolved_from_all_idxs",
        ])
        for m in mentions:
            writer.writerow([
                m.span[0], m.span[1], m.surface, m.kind, m.head,
                "true" if m.is_plural else "false",
                m.entity_id or "", m.canonical or "", m.section or "",
                m.resolved_from if m.resolved_from is not None else "",
                ";".join(str(j) for j in m.resolved_from_all),
            ])


def write_region_rollups(
    region_year: str,
    per_doc_results: dict[str, tuple[dict[str, str], dict[str, list[str]], list]],
) -> None:
    """Roll per-document results up to a single Region_Year summary.

    Produces:
      - <Region_Year>_rollup.json : merged acronym dict with a `conflicts`
        list where two documents defined the same acronym differently.
      - <Region_Year>_canonical.csv : canonical entity form -> pipe-joined
        list of raw surface forms (from any document in the region), plus
        how many documents and mentions that canonical appeared in.
    """
    # --- Acronym rollup with conflict flagging ---
    merged: dict[str, str] = {}
    origin: dict[str, str] = {}                      # acronym -> doc stem where accepted value came from
    conflicts: list[dict] = []

    for stem, (acronyms, _sources, _mentions) in per_doc_results.items():
        for ac, expansion in acronyms.items():
            if ac not in merged:
                merged[ac] = expansion
                origin[ac] = stem
                continue
            # Conflict: same acronym, different expansion text.
            if _normalize(merged[ac]) != _normalize(expansion):
                conflicts.append({
                    "acronym":  ac,
                    "kept":     {"document": origin[ac], "expansion": merged[ac]},
                    "conflict": {"document": stem,       "expansion": expansion},
                })

    rollup_path = os.path.join(ACRONYM_OUT_DIR, f"{region_year}_rollup.json")
    with open(rollup_path, "w", encoding="utf-8") as f:
        json.dump(
            {
                "region_year": region_year,
                "acronyms": merged,
                "conflicts": conflicts,
            },
            f, indent=2, ensure_ascii=False, sort_keys=True,
        )

    # --- Canonical-form rollup ---
    # canonical -> {'surfaces': set[str], 'doc_stems': set[str], 'n_mentions': int}
    canon_rows: dict[str, dict] = {}
    for stem, (_ac, _src, mentions) in per_doc_results.items():
        for m in mentions:
            if not m.canonical:
                continue
            row = canon_rows.setdefault(
                m.canonical,
                {"surfaces": set(), "doc_stems": set(), "n_mentions": 0},
            )
            row["surfaces"].add(m.surface)
            row["doc_stems"].add(stem)
            row["n_mentions"] += 1

    canon_path = os.path.join(MENTION_OUT_DIR, f"{region_year}_canonical.csv")
    with open(canon_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow([
            "canonical", "n_documents", "n_mentions", "raw_surfaces",
            "documents",
        ])
        for canon in sorted(canon_rows):
            r = canon_rows[canon]
            writer.writerow([
                canon,
                len(r["doc_stems"]),
                r["n_mentions"],
                "|".join(sorted(r["surfaces"])),
                "|".join(sorted(r["doc_stems"])),
            ])

    if conflicts:
        print(f"  {region_year}: rollup has {len(merged)} acronyms, "
              f"{len(conflicts)} conflict(s) flagged")
    else:
        print(f"  {region_year}: rollup has {len(merged)} acronyms, "
              f"no conflicts")


def _normalize(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "").strip().lower())


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

def main() -> None:
    global_acronyms = load_global_acronyms()
    print(f"Loaded {len(global_acronyms)} global fallback acronyms")

    groups = group_files_by_region_year(TXT_DIR)
    print(f"Region_Years found: {len(groups)}")

    if TESTING:
        trimmed: dict[str, list[str]] = {}
        total = 0
        for key in sorted(groups):
            trimmed[key] = []
            for f in groups[key]:
                if total >= TEST_MAX_FILES:
                    break
                trimmed[key].append(f)
                total += 1
            if total >= TEST_MAX_FILES:
                break
        groups = {k: v for k, v in trimmed.items() if v}
        print(f"TESTING mode: {sum(len(v) for v in groups.values())} file(s) "
              f"across {len(groups)} Region_Year(s)")

    processed = skipped = failed = 0

    for region_year, files in sorted(groups.items()):
        print(f"\n  {region_year} ({len(files)} file(s))")
        per_doc: dict[str, tuple] = {}

        for fpath in files:
            fname = os.path.basename(fpath)
            stem  = fname[:-4] if fname.endswith(".txt") else fname

            acronym_path = os.path.join(ACRONYM_OUT_DIR, f"{stem}.json")
            mention_path = os.path.join(MENTION_OUT_DIR, f"{stem}.csv")
            already_done = (
                os.path.exists(acronym_path) and os.path.exists(mention_path)
            )

            if already_done and not CLOBBER:
                # Still need to load the results for the Region_Year rollup.
                try:
                    with open(acronym_path, encoding="utf-8") as f:
                        acronym_map = json.load(f)
                    sources_map: dict[str, list[str]] = {}
                    sources_path = os.path.join(ACRONYM_OUT_DIR, f"{stem}.sources.json")
                    if os.path.exists(sources_path):
                        with open(sources_path, encoding="utf-8") as f:
                            sources_map = json.load(f)
                    mentions = _load_mentions_csv(mention_path)
                    per_doc[stem] = (acronym_map, sources_map, mentions)
                    skipped += 1
                    continue
                except Exception as e:
                    print(f"    {fname}: couldn't reload cached outputs ({e}), "
                          f"reprocessing")

            try:
                print(f"    {fname}")
                acronym_map, sources_map, mentions = process_document(
                    fpath, global_acronyms
                )
                write_doc_outputs(stem, acronym_map, sources_map, mentions)
                per_doc[stem] = (acronym_map, sources_map, mentions)
                print(f"    → {len(acronym_map)} acronyms, {len(mentions)} mentions")
                processed += 1
            except Exception as e:
                print(f"    → ERROR: {e}")
                traceback.print_exc()
                failed += 1

        if per_doc:
            write_region_rollups(region_year, per_doc)

    print(f"\nDone.  Processed: {processed}  Skipped: {skipped}  Failed: {failed}")


def _load_mentions_csv(path: str) -> list:
    """Rehydrate the per-doc mentions CSV into lightweight objects for rollup.

    We don't need the full Mention dataclass here — just the attributes the
    rollup reads (canonical, surface).
    """
    class _M:
        __slots__ = ("canonical", "surface")
    out = []
    with open(path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for row in reader:
            m = _M()
            m.canonical = row.get("canonical") or None
            m.surface   = row.get("surface") or ""
            out.append(m)
    return out


if __name__ == "__main__":
    main()
