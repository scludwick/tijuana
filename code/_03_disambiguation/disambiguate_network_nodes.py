"""
disambiguate_network_nodes.py
-----------------------------
Stage 3 of the pipeline. Uses the per-plan acronym dicts and canonical
mention forms from
    _01_preprocessing/extract_acronyms_and_mentions.py
to disambiguate node labels in the textNet extract objects from
    _02_networkgeneration/textnet_parse_and_extract.R

Inputs
------
    tijuanabox/int_data/raw_extracted_networks/<Region_Year>_nodelist.parquet
    tijuanabox/int_data/raw_extracted_networks/<Region_Year>_edgelist.parquet
        Output of textnet_extract() rendered as parquet by the R stage.
        Preferred input: read directly with pyarrow (no pyreadr).

    tijuanabox/int_data/raw_extracted_networks/extract_<Region_Year>.RDS
        Legacy fallback for Region_Years whose parquet pair hasn't been
        backfilled. Loaded via pyreadr if needed.

    tijuanabox/int_data/plan_acronyms/<Region_Year>_rollup.json
        Per-Region_Year merged acronym dict with conflict tracking.

    tijuanabox/int_data/plan_mentions/<stem>.csv
        One per source plan in the Region_Year. Contains the resolved
        anaphor mentions plus their canonical entity form.

Outputs
-------
    tijuanabox/int_data/disambiguated_networks/<Region_Year>_nodelist.parquet
        Every row from the original nodelist preserved as-is, with an
        added `canonical_name` column that holds the canonical entity
        each row resolved to. Rows that resolve to the same canonical
        will share a `canonical_name` but remain separate rows.

    tijuanabox/int_data/disambiguated_networks/<Region_Year>_edgelist.parquet
        Every row from the original edgelist preserved as-is, with two
        added columns: `canonical_source` and `canonical_target` holding
        the resolved endpoints. Original `source` / `target` columns
        kept for comparison. Edges are NOT aggregated — multiple edges
        between the same pair of canonical entities remain distinct
        rows, because edge multiplicity is itself a signal.

    tijuanabox/int_data/disambiguated_networks/<Region_Year>_node_map.csv
        Human-readable mapping: raw_label -> canonical -> list of source
        plans where the evidence for that mapping was found.

This script never modifies the original parquets in
raw_extracted_networks/ — those remain available for direct
comparison against the disambiguated outputs.

Strategy
--------
For each Region_Year:

  1. Pull in the per-plan mention tables → build a master map
         raw_surface (lowercased, whitespace-collapsed) -> canonical
     The anaphor_resolver canonical form expands acronyms, so
     `GSA` / `the GSA` / `Kern County GSA` all collapse to
     `kern county groundwater sustainability agency` once the anaphors
     are resolved and the entity_id chain is followed.

  2. Also fold in the Region_Year acronym rollup so that a node labelled
     simply `EPA` (with no prior full-mention context in the plan) still
     canonicalizes to `environmental protection agency`.

  3. Load the network (parquet preferred; RDS fallback) and write a
     non-destructive copy with `canonical_name` (nodelist) and
     `canonical_source` / `canonical_target` (edgelist) added.

Usage
-----
    python3 disambiguate_network_nodes.py
    (run from project root, i.e. the folder containing tijuanabox/)

Requirements
------------
    pip install pandas pyarrow
    # pyreadr only needed for the legacy RDS fallback path.
"""

from __future__ import annotations

import csv
import glob
import json
import os
import re
import sys
import traceback
from collections import defaultdict

csv.field_size_limit(sys.maxsize)

import pandas as pd  # noqa: E402

# pyreadr is imported lazily inside the RDS loader so the script can at
# least emit the node_map.csv even when pyreadr isn't installed.

# === FLAGS ===
CLOBBER = False   # Re-disambiguate Region_Years that already have output

# === PATHS ===
NETWORKS_DIR       = "tijuanabox/int_data/raw_extracted_networks"
ACRONYM_DIR        = "tijuanabox/int_data/plan_acronyms"
MENTION_DIR        = "tijuanabox/int_data/plan_mentions"
OUT_DIR            = "tijuanabox/int_data/disambiguated_networks"

os.makedirs(OUT_DIR, exist_ok=True)

# === REGEX ===
REGION_YEAR_RE = re.compile(r"^extract_(Region_[^_]+_[0-9]{4})\.RDS$")

# textNet column names that hold entity labels. We look for any of these in
# order in the nodelist and edgelist; whichever exists is what we remap.
NODE_LABEL_CANDIDATES = ["entity_name", "entity", "name", "label", "node"]
EDGE_SOURCE_CANDIDATES = ["source", "from", "source_entity", "head_entity"]
EDGE_TARGET_CANDIDATES = ["target", "to",   "target_entity", "tail_entity"]


# ---------------------------------------------------------------------------
# Map construction
# ---------------------------------------------------------------------------

def _norm(s: str) -> str:
    return re.sub(r"\s+", " ", (s or "").strip().lower())


def build_region_map(region_year: str) -> tuple[dict[str, str], dict[str, set[str]], dict[str, object]]:
    """Build a raw_surface -> canonical map for one Region_Year.

    Returns
    -------
    (lookup, provenance, inputs_report)
        lookup        : normalized surface string -> canonical form
        provenance    : canonical form -> set of source plan stems
                        (used for the audit CSV)
        inputs_report : per-Region_Year accounting of which inputs were
                        found, missing, or empty. Keys:
                          rollup_path, rollup_present, rollup_n_acronyms,
                          mention_pattern, mention_n_files, mention_n_rows
    """
    lookup: dict[str, str] = {}
    provenance: dict[str, set[str]] = defaultdict(set)
    report: dict[str, object] = {}

    # --- 1. Fold in the acronym rollup ---
    rollup_path = os.path.join(ACRONYM_DIR, f"{region_year}_rollup.json")
    report["rollup_path"]        = rollup_path
    report["rollup_present"]     = os.path.exists(rollup_path)
    report["rollup_n_acronyms"]  = 0
    if report["rollup_present"]:
        with open(rollup_path, encoding="utf-8") as f:
            rollup = json.load(f)
        acronyms = rollup.get("acronyms", {})
        report["rollup_n_acronyms"] = len(acronyms)
        for ac, expansion in acronyms.items():
            canon = _norm(expansion)
            for surface in (ac, f"the {ac}", f"The {ac}", expansion):
                lookup.setdefault(_norm(surface), canon)
            provenance[canon].add(f"{region_year}:acronym_rollup")

    # --- 2. Fold in per-plan mentions ---
    # Each mention has a canonical; the raw surface is `surface`. For full
    # mentions, canonical is the full expanded form; for anaphors, canonical
    # has been copied from the resolved antecedent.
    pattern = os.path.join(MENTION_DIR, f"{region_year}_*.csv")
    # Exclude the aggregate <region>_canonical.csv (that's a rollup, not a
    # per-plan mention table).
    mention_files = [
        p for p in sorted(glob.glob(pattern))
        if not p.endswith("_canonical.csv")
    ]
    report["mention_pattern"] = pattern
    report["mention_n_files"] = len(mention_files)
    report["mention_n_rows"]  = 0
    for mf in mention_files:
        stem = os.path.splitext(os.path.basename(mf))[0]
        try:
            df = pd.read_csv(mf, dtype=str, keep_default_na=False)
        except Exception as e:
            print(f"    could not read {mf}: {e}")
            continue
        if df.empty or "canonical" not in df.columns or "surface" not in df.columns:
            continue
        report["mention_n_rows"] += len(df)
        for _, row in df.iterrows():
            canon = _norm(row["canonical"])
            if not canon:
                continue
            surface_norm = _norm(row["surface"])
            if not surface_norm:
                continue
            lookup.setdefault(surface_norm, canon)
            # Strip "the " prefix so "the GSA" and "GSA" both resolve.
            stripped = re.sub(r"^the\s+", "", surface_norm)
            if stripped and stripped != surface_norm:
                lookup.setdefault(stripped, canon)
            provenance[canon].add(stem)

    return lookup, provenance, report


def write_node_map(
    region_year: str,
    lookup: dict[str, str],
    provenance: dict[str, set[str]],
) -> str:
    """Write the per-Region_Year audit CSV and return its path."""
    out_path = os.path.join(OUT_DIR, f"{region_year}_node_map.csv")
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["raw_surface", "canonical", "source_plans"])
        # Group rows by canonical so duplicate raw surfaces are readable.
        for surface in sorted(lookup):
            canon = lookup[surface]
            writer.writerow([
                surface,
                canon,
                "|".join(sorted(provenance.get(canon, set()))),
            ])
    return out_path


# ---------------------------------------------------------------------------
# Network remapping
# ---------------------------------------------------------------------------

def _first_existing(df: pd.DataFrame, candidates: list[str]) -> str | None:
    for c in candidates:
        if c in df.columns:
            return c
    return None


def remap_frame(
    df: pd.DataFrame,
    col: str,
    lookup: dict[str, str],
    canonical_col: str,
) -> pd.DataFrame:
    """Add a column named `canonical_col` containing the remapped form
    of values from `col` (or the original value when no mapping exists).

    The original `col` is left untouched so the disambiguation is
    non-destructive and the original textNet labels remain available
    side-by-side with the canonical resolution.
    """
    def apply(val):
        if not isinstance(val, str):
            return val
        hit = lookup.get(_norm(val))
        if hit:
            return hit
        # Try stripping a leading "the "
        stripped = re.sub(r"^the\s+", "", _norm(val))
        hit = lookup.get(stripped)
        return hit if hit else val
    df = df.copy()
    df[canonical_col] = df[col].map(apply)
    return df


def load_network(
    region_year: str,
) -> tuple[pd.DataFrame | None, pd.DataFrame | None, str]:
    """Load the nodelist and edgelist for one Region_Year.

    Prefers parquet (written by the updated R stage 2). Falls back to
    pyreadr on the legacy RDS for Region_Years that haven't been
    backfilled. Returns (node_df, edge_df, source_label) where
    source_label is "parquet" or "rds" for logging.
    """
    node_pq = os.path.join(NETWORKS_DIR, f"{region_year}_nodelist.parquet")
    edge_pq = os.path.join(NETWORKS_DIR, f"{region_year}_edgelist.parquet")

    if os.path.exists(node_pq) and os.path.exists(edge_pq):
        node_df = pd.read_parquet(node_pq)
        edge_df = pd.read_parquet(edge_pq)
        return node_df, edge_df, "parquet"

    # --- RDS fallback ---
    rds_path = os.path.join(NETWORKS_DIR, f"extract_{region_year}.RDS")
    if not os.path.exists(rds_path):
        return None, None, "missing"
    try:
        import pyreadr  # local import; only needed for fallback
    except ImportError:
        print("    parquet not found and pyreadr not installed; cannot "
              "load network. Either re-run textnet_parse_and_extract.R "
              "(it now writes parquets) or `pip install pyreadr`.")
        return None, None, "missing"
    try:
        rds = pyreadr.read_r(rds_path)
    except Exception as e:
        print(f"    couldn't load {rds_path}: {e}")
        return None, None, "missing"
    frames = {k: v for k, v in rds.items() if isinstance(v, pd.DataFrame)}
    node_df = frames.get("nodelist") or frames.get("nodes")
    edge_df = frames.get("edgelist") or frames.get("edges")
    return node_df, edge_df, "rds"


def disambiguate_network(
    region_year: str,
    lookup: dict[str, str],
) -> None:
    """Load the network, write annotated parquets to disambiguated_networks/.

    The original parquets in raw_extracted_networks/ are NEVER modified.
    Disambiguation is non-destructive: the output preserves every row of
    the original nodelist and edgelist, with new columns added:

      Nodelist : `canonical_name`
                   The canonical entity for each row's textNet label.
                   Rows that resolve to the same canonical share a value.
      Edgelist : `canonical_source`, `canonical_target`
                   Each row's source/target endpoint resolved to its
                   canonical entity. The original `source` / `target`
                   columns are kept for comparison.

    No row aggregation, no edge collapsing, no node merging — that lets
    multiple edges between the same pair of canonical entities remain
    distinct rows, which matters for downstream analysis where the
    *number* of co-occurrences is itself a signal.
    """
    node_df, edge_df, source_label = load_network(region_year)
    if node_df is None and edge_df is None:
        print(f"    network not found (no parquet pair, no RDS) for "
              f"{region_year}")
        return
    print(f"    loaded network from {source_label}")

    if node_df is not None:
        col = _first_existing(node_df, NODE_LABEL_CANDIDATES)
        if col is None:
            print(f"    nodelist: no recognised label column in "
                  f"{list(node_df.columns)}")
        else:
            node_df = remap_frame(node_df, col, lookup,
                                  canonical_col="canonical_name")
            out_path = os.path.join(
                OUT_DIR, f"{region_year}_nodelist.parquet"
            )
            node_df.to_parquet(out_path, index=False)
            n_mapped = (node_df["canonical_name"] != node_df[col]).sum()
            print(f"    nodelist: {n_mapped}/{len(node_df)} rows resolved to "
                  f"a canonical (label column {col!r})  ->  "
                  f"{os.path.basename(out_path)}")

    if edge_df is not None:
        src_col = _first_existing(edge_df, EDGE_SOURCE_CANDIDATES)
        tgt_col = _first_existing(edge_df, EDGE_TARGET_CANDIDATES)
        if src_col is None or tgt_col is None:
            print(f"    edgelist: missing source/target columns. "
                  f"Columns: {list(edge_df.columns)}")
        else:
            edge_df = remap_frame(edge_df, src_col, lookup,
                                  canonical_col="canonical_source")
            edge_df = remap_frame(edge_df, tgt_col, lookup,
                                  canonical_col="canonical_target")
            out_path = os.path.join(
                OUT_DIR, f"{region_year}_edgelist.parquet"
            )
            edge_df.to_parquet(out_path, index=False)
            n_src = (edge_df["canonical_source"] != edge_df[src_col]).sum()
            n_tgt = (edge_df["canonical_target"] != edge_df[tgt_col]).sum()
            print(f"    edgelist: {n_src} source / {n_tgt} target endpoints "
                  f"resolved (columns {src_col!r}, {tgt_col!r})  ->  "
                  f"{os.path.basename(out_path)}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def _region_year_from_filename(fname: str, regex: re.Pattern) -> str | None:
    m = regex.match(fname)
    return m.group(1) if m else None


def preflight_inventory() -> dict[str, dict[str, bool]]:
    """Inventory which Region_Years have which inputs.

    Returns a dict keyed by Region_Year with bool flags for each expected
    input source. Used to print a single up-front report so silent skips
    don't go unnoticed.
    """
    rds_paths     = sorted(glob.glob(os.path.join(NETWORKS_DIR, "extract_*.RDS")))
    node_pq_paths = sorted(glob.glob(os.path.join(NETWORKS_DIR,
                                                  "Region_*_nodelist.parquet")))
    rollup_paths  = sorted(glob.glob(os.path.join(ACRONYM_DIR, "*_rollup.json")))
    mention_paths = sorted(glob.glob(os.path.join(MENTION_DIR, "*.csv")))

    node_pq_re = re.compile(r"^(Region_[^_]+_[0-9]{4})_nodelist\.parquet$")
    rollup_re  = re.compile(r"^(Region_[^_]+_[0-9]{4})_rollup\.json$")
    mention_re = re.compile(r"^(Region_[^_]+_[0-9]{4})_.+\.csv$")

    have_rds      = {_region_year_from_filename(os.path.basename(p), REGION_YEAR_RE)
                     for p in rds_paths}
    have_pq       = {_region_year_from_filename(os.path.basename(p), node_pq_re)
                     for p in node_pq_paths}
    have_rollup   = {_region_year_from_filename(os.path.basename(p), rollup_re)
                     for p in rollup_paths}
    have_mentions = {_region_year_from_filename(os.path.basename(p), mention_re)
                     for p in mention_paths}
    for s in (have_rds, have_pq, have_rollup, have_mentions):
        s.discard(None)

    all_regions = sorted(have_rds | have_pq | have_rollup | have_mentions)
    inventory = {
        ry: {
            "rds":      ry in have_rds,
            "parquet":  ry in have_pq,
            "rollup":   ry in have_rollup,
            "mentions": ry in have_mentions,
        }
        for ry in all_regions
    }
    return inventory


def print_inventory(inventory: dict[str, dict[str, bool]]) -> None:
    """Print a one-line-per-Region_Year report showing which inputs are
    present (OK) vs missing (--)."""
    if not inventory:
        print("Pre-flight inventory: no inputs found in any of "
              f"{NETWORKS_DIR}, {ACRONYM_DIR}, {MENTION_DIR}")
        return
    print("Pre-flight inventory  (rds | parquet | rollup | mentions)")
    print("-" * 70)
    n_complete = n_missing_net = n_missing_dis_inputs = 0
    for ry, flags in inventory.items():
        has_net = flags["rds"] or flags["parquet"]
        rds_m  = "OK" if flags["rds"]      else "--"
        pq_m   = "OK" if flags["parquet"]  else "--"
        roll_m = "OK" if flags["rollup"]   else "--"
        ment_m = "OK" if flags["mentions"] else "--"
        complete = has_net and flags["rollup"] and flags["mentions"]
        if complete:
            n_complete += 1
        if not has_net:
            n_missing_net += 1
        if has_net and (not flags["rollup"] or not flags["mentions"]):
            n_missing_dis_inputs += 1
        annotations = []
        if complete:
            annotations.append("will run")
        elif flags["rollup"] and flags["mentions"] and not has_net:
            annotations.append("has inputs but no network (run stage 2)")
        elif has_net and not (flags["rollup"] and flags["mentions"]):
            annotations.append("has network but missing disambig inputs (run stage 1b)")
        ann = ("    <- " + "; ".join(annotations)) if annotations else ""
        print(f"  {ry:<22} | {rds_m} | {pq_m} | {roll_m} | {ment_m}{ann}")
    print("-" * 70)
    print(f"  {n_complete} Region_Year(s) ready to disambiguate")
    if n_missing_net:
        print(f"  {n_missing_net} Region_Year(s) have intermediate inputs "
              f"but no network (run stage 2: textnet_parse_and_extract.R)")
    if n_missing_dis_inputs:
        print(f"  {n_missing_dis_inputs} Region_Year(s) have a network but missing "
              f"acronym/mention inputs (run stage 1b: extract_acronyms_and_mentions.py)")
    print()


def main() -> None:
    inventory = preflight_inventory()
    print_inventory(inventory)

    # Drive on Region_Years that have a network (parquet or RDS).
    region_years = sorted(
        ry for ry, flags in inventory.items()
        if flags["rds"] or flags["parquet"]
    )
    print(f"Networks found: {len(region_years)}")

    processed = skipped = failed = 0
    skipped_no_inputs: list[str] = []

    for region_year in region_years:
        # "Already done" = both annotated parquets exist for this
        # Region_Year. The script is non-destructive and idempotent;
        # set CLOBBER=True to re-run.
        node_out = os.path.join(OUT_DIR, f"{region_year}_nodelist.parquet")
        edge_out = os.path.join(OUT_DIR, f"{region_year}_edgelist.parquet")
        if os.path.exists(node_out) and os.path.exists(edge_out) and not CLOBBER:
            print(f"  {region_year}: outputs exist, skipping (CLOBBER=False)")
            skipped += 1
            continue

        print(f"\n  {region_year}")
        try:
            lookup, provenance, report = build_region_map(region_year)
            print(f"    rollup:   {'present' if report['rollup_present'] else 'MISSING'}"
                  f" ({report['rollup_n_acronyms']} acronyms)"
                  f"  [{report['rollup_path']}]")
            print(f"    mentions: {report['mention_n_files']} file(s), "
                  f"{report['mention_n_rows']} row(s)"
                  f"  [{report['mention_pattern']}]")
            print(f"    {len(lookup)} surface -> canonical entries in map")

            if not lookup:
                print(f"    !! NO acronym/mention inputs found for "
                      f"{region_year}; skipping. Run "
                      f"extract_acronyms_and_mentions.py first.")
                skipped_no_inputs.append(region_year)
                skipped += 1
                continue

            map_path = write_node_map(region_year, lookup, provenance)
            print(f"    wrote {os.path.basename(map_path)}")

            disambiguate_network(region_year, lookup)
            processed += 1
        except Exception as e:
            print(f"  → ERROR: {e}")
            traceback.print_exc()
            failed += 1

    print(f"\nDone.  Processed: {processed}  Skipped: {skipped}  Failed: {failed}")
    if skipped_no_inputs:
        print(f"\nSkipped for missing acronym/mention inputs ({len(skipped_no_inputs)}):")
        for ry in skipped_no_inputs:
            print(f"  - {ry}")
        print("Run _01_preprocessing/extract_acronyms_and_mentions.py for these "
              "regions, then re-run this script.")


if __name__ == "__main__":
    main()
