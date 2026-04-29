"""
acronym_extractor.py

Build a document-specific acronym dictionary by combining two sources:

    1. Any "Acronyms and Abbreviations" (or similarly named) table in the
       document's front matter. This is the highest-precision source because
       the authors have already told you what the abbreviations mean.

    2. scispacy's AbbreviationDetector, which applies the Schwartz-Hearst
       (2003) algorithm to find `Long Form (SHORT)` or `SHORT (Long Form)`
       patterns throughout the text. This catches anything introduced inline
       but not listed in the front matter.

The two sources are merged with the explicit table taking precedence on
conflicts. Building the dictionary per-document means colliding acronyms
across documents (e.g. GSA = Groundwater Sustainability Agency vs. General
Services Administration) are never a problem.

Dependencies
------------
    pip install "spacy>=3.7,<3.8" scispacy
    pip install https://s3-us-west-2.amazonaws.com/ai2-s2-scispacy/releases/v0.5.4/en_core_sci_sm-0.5.4.tar.gz

scispacy pins tightly to specific spaCy versions; check the project README
if the versions above fail to resolve.

Usage
-----
    from acronym_extractor import build_acronym_dict

    acronyms = build_acronym_dict(full_text)
    # {'EPA': 'Environmental Protection Agency',
    #  'GSA': 'Groundwater Sustainability Agency', ...}
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Iterable


# ---------------------------------------------------------------------------
# 1. Front-matter acronym table extraction
# ---------------------------------------------------------------------------

# Section headings commonly used in environmental / policy documents.
# Case-insensitive; matched on a line by itself (allowing leading numbering
# like "1.2" or "Appendix A"). Extend as needed for your corpus.
FRONT_MATTER_HEADINGS = [
    r"acronyms\s+and\s+abbreviations",
    r"abbreviations\s+and\s+acronyms",
    r"list\s+of\s+acronyms",
    r"list\s+of\s+abbreviations",
    r"acronyms",
    r"abbreviations",
    r"glossary\s+of\s+acronyms",
]

_HEADING_RE = re.compile(
    r"^[\s\d\.\-]*(?:" + "|".join(FRONT_MATTER_HEADINGS) + r")\s*$",
    re.IGNORECASE | re.MULTILINE,
)

# When we've found the heading, we stop collecting rows at the next heading-like
# line. This is intentionally conservative: a line in ALL CAPS or Title Case
# with no trailing punctuation that isn't itself an acronym entry.
_NEXT_SECTION_RE = re.compile(
    r"^(?:[\dIVX]+\.[\dIVX\.]*\s+)?[A-Z][A-Za-z\s,'\-]{3,}$"
)

# An acronym-row pattern: the acronym (2+ uppercase letters, possibly with
# digits or embedded ampersand/slash) followed by whitespace or a separator,
# then the expansion. We allow the expansion to run to end-of-line.
#
# Examples this matches:
#     EPA    Environmental Protection Agency
#     EPA - Environmental Protection Agency
#     EPA: Environmental Protection Agency
#     EPA\tEnvironmental Protection Agency
#     CEQA   California Environmental Quality Act
#     SB 1383  Senate Bill 1383
_ROW_RE = re.compile(
    r"""
    ^\s*
    (?P<acronym>[A-Z][A-Z0-9&/\-]{1,}(?:\s[A-Z0-9]+)?)  # 2+ char acronym; allow "SB 1383"
    \s*[-:\t ]{2,}\s*                                    # separator: dashes, colon, tab, or 2+ spaces
    (?P<expansion>[A-Za-z][^\n]{3,}?)                    # expansion text
    \s*$
    """,
    re.VERBOSE | re.MULTILINE,
)


def extract_front_matter_acronyms(text: str) -> dict[str, str]:
    """Parse an acronyms table from the document's front matter.

    Returns
    -------
    dict mapping uppercase acronym -> expansion. Empty dict if no table found.

    Notes
    -----
    This is heuristic. It works on text extracted from PDFs where the table
    has been flattened to one entry per line. If your document stores the
    acronym table as a true PDF table, extract it with pdfplumber or camelot
    first, then pass the flattened text here (or skip this function and build
    the dict directly from the extracted table rows).
    """
    heading_match = _HEADING_RE.search(text)
    if heading_match is None:
        return {}

    # Take a generous slice after the heading; we'll stop at the next section.
    start = heading_match.end()
    # Look for the next plausible section heading within ~10000 chars.
    search_window = text[start : start + 10_000]

    # Walk line by line; collect rows until we hit a blank-line gap followed
    # by what looks like a new section heading, or until the window ends.
    lines = search_window.splitlines()
    collected: list[str] = []
    blank_streak = 0
    for line in lines:
        if not line.strip():
            blank_streak += 1
            # A double blank line often separates sections in extracted PDF text.
            if blank_streak >= 2 and collected:
                break
            continue
        blank_streak = 0

        # Stop if the line looks like a new section heading (and isn't an
        # acronym row itself).
        if _NEXT_SECTION_RE.match(line) and _ROW_RE.match(line) is None:
            # But allow headings that are themselves short all-caps words —
            # could be a subcategory within the acronyms section. Heuristic:
            # if the line is < 40 chars and has no lowercase letters, treat
            # as a sub-heading and keep going.
            if len(line) < 40 and not re.search(r"[a-z]", line):
                continue
            break

        collected.append(line)

    block = "\n".join(collected)

    acronyms: dict[str, str] = {}
    for m in _ROW_RE.finditer(block):
        acronym = m.group("acronym").strip()
        expansion = m.group("expansion").strip()
        # Strip trailing footnote markers, page numbers, etc.
        expansion = re.sub(r"\s*\.{2,}\s*\d+\s*$", "", expansion)  # "...  42"
        expansion = re.sub(r"\s+\d+\s*$", "", expansion)           # trailing page num
        if expansion:
            acronyms[acronym] = expansion

    return acronyms


# ---------------------------------------------------------------------------
# 2. Schwartz-Hearst via scispacy
# ---------------------------------------------------------------------------

def extract_inline_acronyms(text: str, spacy_model: str = "en_core_sci_sm") -> dict[str, str]:
    """Apply Schwartz-Hearst to find `Long Form (SHORT)` patterns in the text.

    Parameters
    ----------
    text : the full document text.
    spacy_model : the spaCy model to use. `en_core_sci_sm` is the default
        scispacy small model. `en_core_web_sm` also works if you've installed
        the scispacy component separately.

    Returns
    -------
    dict mapping acronym -> expansion.

    Notes
    -----
    scispacy's AbbreviationDetector is language-agnostic in practice — it
    doesn't use any biomedical knowledge, just the Schwartz-Hearst algorithm.
    It works fine on policy text.

    For documents longer than spaCy's default max_length (~1M chars), we bump
    the limit. If your documents are even larger than that, chunk the text
    and merge the returned dicts.
    """
    try:
        import spacy
        from scispacy.abbreviation import AbbreviationDetector  # noqa: F401
    except ImportError as e:
        raise ImportError(
            "acronym_extractor requires spacy and scispacy. Install with:\n"
            "    pip install 'spacy>=3.7,<3.8' scispacy\n"
            "    pip install https://s3-us-west-2.amazonaws.com/ai2-s2-scispacy/"
            "releases/v0.5.4/en_core_sci_sm-0.5.4.tar.gz"
        ) from e

    nlp = spacy.load(spacy_model, disable=["ner", "lemmatizer", "textcat"])
    if "abbreviation_detector" not in nlp.pipe_names:
        nlp.add_pipe("abbreviation_detector")

    # Bump max_length for long documents.
    if len(text) > nlp.max_length:
        nlp.max_length = len(text) + 1000

    doc = nlp(text)

    acronyms: dict[str, str] = {}
    for abrv in doc._.abbreviations:
        short = abrv.text.strip()
        long_form = abrv._.long_form.text.strip()
        if short and long_form and short != long_form:
            # Keep the first expansion seen for each acronym. Schwartz-Hearst
            # sometimes finds multiple candidates; the first (earliest in text)
            # is almost always the definitional one.
            acronyms.setdefault(short, long_form)

    return acronyms


# ---------------------------------------------------------------------------
# 3. Merge
# ---------------------------------------------------------------------------

@dataclass
class AcronymDict:
    """A merged acronym dictionary with provenance tracking.

    Attributes
    ----------
    mapping : acronym -> expansion. This is what you'll use at lookup time.
    sources : acronym -> set of sources it was found in
        ({'front_matter', 'inline'}). Useful for debugging precision issues.
    conflicts : list of (acronym, front_matter_expansion, inline_expansion)
        tuples for cases where the two sources disagreed. The front-matter
        value wins in `mapping`, but you may want to inspect these.
    """
    mapping: dict[str, str] = field(default_factory=dict)
    sources: dict[str, set[str]] = field(default_factory=dict)
    conflicts: list[tuple[str, str, str]] = field(default_factory=list)

    def __contains__(self, key: str) -> bool:
        return key in self.mapping

    def __getitem__(self, key: str) -> str:
        return self.mapping[key]

    def get(self, key: str, default=None):
        return self.mapping.get(key, default)

    def __iter__(self):
        return iter(self.mapping)

    def items(self):
        return self.mapping.items()

    def __len__(self):
        return len(self.mapping)


def build_acronym_dict(
    text: str,
    spacy_model: str = "en_core_sci_sm",
    use_front_matter: bool = True,
    use_inline: bool = True,
) -> AcronymDict:
    """Build a document-specific acronym dictionary.

    Strategy:
      1. Extract any acronym table in the front matter (high precision).
      2. Run scispacy's AbbreviationDetector over the full text (high recall).
      3. Merge, with front-matter values winning on conflict.

    Parameters
    ----------
    text : full document text.
    spacy_model : spaCy model to load for the inline pass.
    use_front_matter : set False to skip the front-matter table parse.
    use_inline : set False to skip the scispacy pass.

    Returns
    -------
    AcronymDict with `.mapping`, `.sources`, and `.conflicts`.
    """
    result = AcronymDict()

    front: dict[str, str] = {}
    if use_front_matter:
        front = extract_front_matter_acronyms(text)
        for ac, exp in front.items():
            result.mapping[ac] = exp
            result.sources.setdefault(ac, set()).add("front_matter")

    if use_inline:
        inline = extract_inline_acronyms(text, spacy_model=spacy_model)
        for ac, exp in inline.items():
            if ac in front:
                # Front matter wins, but record the conflict if expansions differ.
                if _normalize(front[ac]) != _normalize(exp):
                    result.conflicts.append((ac, front[ac], exp))
                result.sources.setdefault(ac, set()).add("inline")
            else:
                result.mapping[ac] = exp
                result.sources.setdefault(ac, set()).add("inline")

    return result


def _normalize(s: str) -> str:
    """Lowercase and collapse whitespace for loose equality checks."""
    return re.sub(r"\s+", " ", s.strip().lower())


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import argparse
    import json
    import sys

    parser = argparse.ArgumentParser(
        description="Build a per-document acronym dictionary."
    )
    parser.add_argument("textfile", help="Path to a plain-text document.")
    parser.add_argument(
        "--no-front-matter",
        action="store_true",
        help="Skip parsing the front-matter acronym table.",
    )
    parser.add_argument(
        "--no-inline",
        action="store_true",
        help="Skip the scispacy Schwartz-Hearst pass.",
    )
    parser.add_argument(
        "--model", default="en_core_sci_sm", help="spaCy model name."
    )
    parser.add_argument(
        "--show-conflicts", action="store_true", help="Print conflicts to stderr."
    )
    args = parser.parse_args()

    with open(args.textfile, "r", encoding="utf-8") as f:
        text = f.read()

    result = build_acronym_dict(
        text,
        spacy_model=args.model,
        use_front_matter=not args.no_front_matter,
        use_inline=not args.no_inline,
    )

    if args.show_conflicts and result.conflicts:
        print(f"# {len(result.conflicts)} conflicts (front-matter value kept):",
              file=sys.stderr)
        for ac, fm, il in result.conflicts:
            print(f"  {ac}: front={fm!r} inline={il!r}", file=sys.stderr)

    print(json.dumps(result.mapping, indent=2, sort_keys=True))
