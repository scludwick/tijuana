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
    tijuanabox/int_data/raw_extracted_networks/extract_<Region_Year>.RDS
        Output of textnet_extract(), one RDS per Region_Year. Contains a
        list of data frames (nodelist, edgelist, etc.).

    tijuanabox/int_data/plan_acronyms/<Region_Year>_rollup.json
        Per-Region_Year merged acronym dict with conflict tracking.

    tijuanabox/int_data/plan_mentions/<stem>.csv
        One per source plan in the Region_Year. Contains the resolved
        anaphor mentions plus their canonical entity form.

Outputs
-------
    tijuanabox/int_data/disambiguated_networks/<Region_Year>_nodelist.parquet
    tijuanabox/int_data/disambiguated_networks/<Region_Year>_edgelist.parquet
        Node and edge tables with an added `canonical` column alongside the
        original label. Parquet rather than RDS because pyreadr can't round-
        trip complex textNet list structures. Downstream R code can read
        these with arrow::read_parquet().

    tijuanabox/int_data/disambiguated_networks/<Region_Year>_node_map.csv
        Human-readable mapping: raw_label -> canonical -> list of source
        plans where the evidence for that mapping was found.

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

  3. Load the RDS network extract. Look for fields `nodelist` and
     `edgelist` (the standard textnet_extract shape) and remap the entity
     label column in each. If the RDS doesn't conform (e.g., an older or
     custom textNet version), log the structure and skip gracefully.

Usage
-----
    python3 disambiguate_network_nodes.py
    (run from project root, i.e. the folder containing tijuanabox/)

Requirements
------------
    pip install pyreadr pandas pyarrow
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


def build_region_map(region_year: str) -> tuple[dict[str, str], dict[str, set[str]]]:
    """Build a raw_surface -> canonical map for one Region_Year.

    Returns
    -------
    (lookup, provenance)
        lookup     : normalized surface string -> canonical form
        provenance : canonical form -> set of source plan stems
                     (used for the audit CSV)
    """
    lookup: dict[str, str] = {}
    provenance: dict[str, set[str]] = defaultdict(set)

    # --- 1. Fold in the acronym rollup ---
    rollup_path = os.path.join(ACRONYM_DIR, f"{region_year}_rollup.json")
    if os.path.exists(rollup_path):
        with open(rollup_path, encoding="utf-8") as f:
            rollup = json.load(f)
        for ac, expansion in rollup.get("acronyms", {}).items():
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
    for mf in mention_files:
        stem = os.path.splitext(os.path.basename(mf))[0]
        try:
            df = pd.read_csv(mf, dtype=str, keep_default_na=False)
        except Exception as e:
            print(f"    could not read {mf}: {e}")
            continue
        if df.empty or "canonical" not in df.columns or "surface" not in df.columns:
            continue
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

    return lookup, provenance


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
) -> pd.DataFrame:
    """Add a `<col>_canonical` column with the remapped form (or the
    original value when no mapping exists)."""
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
    df[f"{col}_canonical"] = df[col].map(apply)
    return df


def load_rds(path: str):
    """Load a textNet extract RDS into a dict of data frames.

    pyreadr returns an OrderedDict of {name -> DataFrame}. For a list of
    data frames (the usual textNet extract shape) names will be the R list
    element names if present, else numeric indices.
    """
    try:
        import pyreadr
    except ImportError:
        raise ImportError(
            "pyreadr is required to read textNet RDS files. Install with:\n"
            "    pip install pyreadr"
        )
    result = pyreadr.read_r(path)
    return result  # dict-like {name: DataFrame}


def disambiguate_network(
    region_year: str,
    rds_path: str,
    lookup: dict[str, str],
) -> tuple[str | None, str | None]:
    """Load the RDS, remap node and edge labels, write parquet outputs.

    Returns (nodelist_out_path, edgelist_out_path) — either may be None if
    the RDS doesn't have the corresponding frame in a shape we understand.
    """
    try:
        rds = load_rds(rds_path)
    except Exception as e:
        print(f"    couldn't load {rds_path}: {e}")
        return None, None

    # Inventory: most textNet extracts expose at least `nodelist` and
    # `edgelist` at the top level. Some older versions nest them. We pick
    # up both; if neither is present we report the keys so the user can
    # adapt.
    frames = {k: v for k, v in rds.items() if isinstance(v, pd.DataFrame)}
    if not frames:
        print(f"    RDS has no top-level data frames. Keys present: "
              f"{list(rds.keys())}")
        return None, None

    node_df = frames.get("nodelist") or frames.get("nodes")
    edge_df = frames.get("edgelist") or frames.get("edges")

    nodelist_out = edgelist_out = None

    if node_df is not None:
        col = _first_existing(node_df, NODE_LABEL_CANDIDATES)
        if col is None:
            print(f"    nodelist: no recognised label column in "
                  f"{list(node_df.columns)}")
        else:
            remapped = remap_frame(node_df, col, lookup)
            nodelist_out = os.path.join(
                OUT_DIR, f"{region_year}_nodelist.parquet"
            )
            remapped.to_parquet(nodelist_out, index=False)
            n_mapped = (remapped[f"{col}_canonical"] != remapped[col]).sum()
            print(f"    nodelist: {n_mapped}/{len(remapped)} rows remapped "
                  f"on column {col!r}")
    else:
        print(f"    no `nodelist` frame. Frames present: {list(frames.keys())}")

    if edge_df is not None:
        src_col = _first_existing(edge_df, EDGE_SOURCE_CANDIDATES)
        tgt_col = _first_existing(edge_df, EDGE_TARGET_CANDIDATES)
        if src_col is None or tgt_col is None:
            print(f"    edgelist: missing source/target columns. "
                  f"Columns: {list(edge_df.columns)}")
        else:
            remapped = remap_frame(edge_df, src_col, lookup)
            remapped = remap_frame(remapped, tgt_col, lookup)
            edgelist_out = os.path.join(
                OUT_DIR, f"{region_year}_edgelist.parquet"
            )
            remapped.to_parquet(edgelist_out, index=False)
            n_src = (remapped[f"{src_col}_canonical"] != remapped[src_col]).sum()
            n_tgt = (remapped[f"{tgt_col}_canonical"] != remapped[tgt_col]).sum()
            print(f"    edgelist: {n_src} source / {n_tgt} target rows "
                  f"remapped (columns {src_col!r}, {tgt_col!r})")
    else:
        print(f"    no `edgelist` frame. Frames present: {list(frames.keys())}")

    return nodelist_out, edgelist_out


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    rds_paths = sorted(glob.glob(os.path.join(NETWORKS_DIR, "extract_*.RDS")))
    print(f"Networks found: {len(rds_paths)}")

    processed = skipped = failed = 0

    for rds_path in rds_paths:
        fname = os.path.basename(rds_path)
        m = REGION_YEAR_RE.match(fname)
        if m is None:
            print(f"  Skipping {fname!r}: filename does not match "
                  f"extract_Region_X_YYYY.RDS")
            continue
        region_year = m.group(1)

        node_out = os.path.join(OUT_DIR, f"{region_year}_nodelist.parquet")
        edge_out = os.path.join(OUT_DIR, f"{region_year}_edgelist.parquet")
        if os.path.exists(node_out) and os.path.exists(edge_out) and not CLOBBER:
            print(f"  {region_year}: outputs exist, skipping (CLOBBER=False)")
            skipped += 1
            continue

        print(f"\n  {region_year}")
        try:
            lookup, provenance = build_region_map(region_year)
            print(f"    {len(lookup)} surface -> canonical entries in map")
            map_path = write_node_map(region_year, lookup, provenance)
            print(f"    wrote {os.path.basename(map_path)}")
            disambiguate_network(region_year, rds_path, lookup)
            processed += 1
        except Exception as e:
            print(f"  → ERROR: {e}")
            traceback.print_exc()
            failed += 1

    print(f"\nDone.  Processed: {processed}  Skipped: {skipped}  Failed: {failed}")


if __name__ == "__main__":
    main()
