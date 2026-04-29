"""
anaphor_resolver.py

Resolve in-document definite-reference anaphora for named entities in
environmental / policy documents. The driving example:

    "...the Kern County GSA filed a report... The GSA noted that..."

Here "The GSA" should resolve to "Kern County GSA". More generally:

    - A "full mention" is an entity named in full, usually qualified by a
      proper-noun modifier (e.g. "Kern County GSA", "Environmental Protection
      Agency Region 9").
    - An "anaphoric mention" is a definite noun phrase whose head matches a
      previously-mentioned full form, typically introduced by "the" (e.g.
      "the GSA", "the Agency", "the Department").

Resolution rule (approximation of salience-based anaphora resolution):
    Each anaphoric mention resolves to the most recent full mention, within
    the same section, whose canonical form ends with the same head noun (or
    its acronym expansion). If no match exists in the current section, fall
    back to the most recent match in the preceding sections; if still no
    match, the anaphor is flagged as unresolved.

This deliberately does not try to handle pronouns ("it", "they"),
inter-clausal reference, or split antecedents. For those, bolt on a
coreference model like Maverick or fastcoref. This module handles the
specific, high-signal case of anaphoric definite NPs, which is the majority
of within-document entity references in formal policy documents.

Inputs
------
- The full document text.
- An acronym dictionary (e.g. from `acronym_extractor.build_acronym_dict`).
- Optionally a section segmentation (list of (start_char, end_char, name)).
  If not provided, we fall back to a sliding-window heuristic.

Output
------
- A list of Mention records, each with:
    - surface: the raw text of the mention
    - span: (start, end) character offsets
    - kind: 'full' or 'anaphoric'
    - entity_id: a canonical identifier shared by coreferring mentions
    - canonical: the canonical long-form name of the entity
    - resolved_from: for anaphoric mentions, the index of the full mention
      it resolved to; None for unresolved

Dependencies
------------
    pip install spacy
    python -m spacy download en_core_web_sm
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Optional


# ---------------------------------------------------------------------------
# Data classes
# ---------------------------------------------------------------------------

@dataclass
class Mention:
    surface: str
    span: tuple[int, int]
    kind: str  # 'full' or 'anaphoric'
    head: str  # the head-noun / acronym used for matching (e.g. "GSA", "Agency")
    entity_id: Optional[str] = None
    canonical: Optional[str] = None
    # For singular anaphors, this is the one antecedent index. For plural
    # anaphors, it is None (use `resolved_from_all` instead). Full mentions
    # and unresolved anaphors leave this None.
    resolved_from: Optional[int] = None
    # Unified field: for any resolved anaphor (singular OR plural), this
    # contains the list of antecedent indices into the mentions list. For a
    # singular anaphor it will have length 1; for a plural, length >= 1.
    # Full mentions and unresolved anaphors leave this empty.
    resolved_from_all: list[int] = field(default_factory=list)
    # True for plural anaphors like "the GSAs" and for full mentions that
    # were split out from a coordinated plural ("Kern County and Semitropic
    # GSAs" → two full mentions, both with is_plural=False since they
    # represent single entities; the plural anaphor itself carries the flag).
    is_plural: bool = False
    section: Optional[str] = None


@dataclass
class Section:
    start: int
    end: int
    name: str


# ---------------------------------------------------------------------------
# Section segmentation
# ---------------------------------------------------------------------------

# Section heading patterns for acronym tables — mirrors the list in
# acronym_extractor.py. We use these to detect and EXCLUDE the acronym
# table region from mention extraction, since entries there aren't real
# document mentions.
_ACRONYM_SECTION_HEADINGS = [
    r"acronyms\s+and\s+abbreviations",
    r"abbreviations\s+and\s+acronyms",
    r"list\s+of\s+acronyms",
    r"list\s+of\s+abbreviations",
    r"acronyms",
    r"abbreviations",
    r"glossary\s+of\s+acronyms",
]

_ACRONYM_SECTION_RE = re.compile(
    r"^[\s\d\.\-]*(?:" + "|".join(_ACRONYM_SECTION_HEADINGS) + r")\s*$",
    re.IGNORECASE | re.MULTILINE,
)


def find_acronym_table_region(text: str) -> Optional[tuple[int, int]]:
    """Return (start, end) char offsets of the acronym table region, or None.

    The region extends from the heading to the next section heading or a
    double blank line. This is intentionally generous — we'd rather skip a
    few extra lines than include table rows as real mentions.
    """
    heading = _ACRONYM_SECTION_RE.search(text)
    if heading is None:
        return None

    start = heading.start()
    # Search forward for the end of the table: the next section heading
    # or a double-blank-line gap followed by a line that isn't a table row.
    search_window = text[heading.end() : heading.end() + 20_000]

    # Simple rule: end at the first double newline followed by a
    # non-indented line that looks like a regular paragraph (mixed case,
    # not starting with an acronym-style token).
    end_in_window = None
    for m in re.finditer(r"\n\n+([^\n]+)", search_window):
        next_line = m.group(1).strip()
        if not next_line:
            continue
        # If the line looks like a regular paragraph (has a lowercase word
        # in the first ~40 chars AND does not start with a likely acronym),
        # treat it as end of table.
        first_token = next_line.split()[0] if next_line.split() else ""
        is_acronym_like = bool(re.match(r"^[A-Z0-9&/\-]{2,}$", first_token))
        has_lower = bool(re.search(r"[a-z]", next_line[:40]))
        if has_lower and not is_acronym_like:
            end_in_window = m.start()
            break

    if end_in_window is None:
        end = heading.end() + len(search_window)
    else:
        end = heading.end() + end_in_window

    return (start, end)


# Match numbered section headings like "3.2 Groundwater", "CHAPTER 4",
# "Section 5.1.2", or all-caps titles on their own line. Tune to your corpus.
#
# We require a blank line before the heading to avoid matching mid-paragraph
# lines that happen to look like titles. This is the single most important
# discriminator for finding real section breaks in flattened PDF text.
_SECTION_HEADING_RE = re.compile(
    r"""
    (?:^|\n)\n                              # preceded by blank line
    (?P<heading>
        (?:(?:CHAPTER|Chapter|SECTION|Section|Appendix|APPENDIX)\s+[\dIVX]+[A-Z]?[^\n]*)
        |
        (?:\d+(?:\.\d+){0,3}\s+[A-Z][^\n]{2,80})
        |
        (?:[A-Z][A-Z\s,'\-]{5,60})          # ALL-CAPS title line
    )
    \s*(?=\n)
    """,
    re.VERBOSE,
)


def segment_sections(text: str, fallback_window: int = 8000) -> list[Section]:
    """Split text into sections by heading regex.

    Falls back to fixed-size windows if no headings are found. Tune
    `fallback_window` to roughly match a typical section length in your
    corpus; 8000 chars is ~1500 words, about a normal EIR subsection.
    """
    matches = list(_SECTION_HEADING_RE.finditer(text))
    if not matches:
        # Fallback: fixed-size windows.
        sections = []
        for i in range(0, len(text), fallback_window):
            sections.append(
                Section(i, min(i + fallback_window, len(text)), f"window_{i}")
            )
        return sections

    sections = []
    # If the first heading isn't at position 0, the prelude is its own section.
    if matches[0].start("heading") > 0:
        sections.append(Section(0, matches[0].start("heading"), "preamble"))

    for i, m in enumerate(matches):
        # The heading text starts at the heading group, not the whole match
        # (which includes the preceding blank line).
        start = m.start("heading")
        end = matches[i + 1].start("heading") if i + 1 < len(matches) else len(text)
        name = m.group("heading").strip()
        sections.append(Section(start, end, name))

    return sections


def section_of(span: tuple[int, int], sections: list[Section]) -> Optional[Section]:
    """Return the section containing the given character span."""
    start = span[0]
    for sec in sections:
        if sec.start <= start < sec.end:
            return sec
    return None


# ---------------------------------------------------------------------------
# Mention extraction
# ---------------------------------------------------------------------------

# Anaphoric noun phrases: "the <Noun>" or "the <Adjective> <Noun>" where the
# noun is capitalized (we only resolve proper-noun anaphors, not common
# nouns). This deliberately excludes "the agency" (lowercase) which is
# harder to disambiguate without deeper parsing.
#
# We also allow the head to be an acronym (2+ uppercase letters).
_ANAPHOR_RE = re.compile(
    r"""
    \bThe\s+                              # "The" at sentence start, or
    |                                      #   (alternation)
    \bthe\s+                              # "the" mid-sentence
    """,
    re.VERBOSE,
)

# A head noun or acronym: either ALL-CAPS 2-6 letters (optionally + 's' for
# plural acronyms like "GSAs", "EIRs"), or a capitalized word 3+ letters (to
# exclude "The A" noise). Optionally preceded by a single capitalized
# adjective like "State" or "Regional".
_HEAD_RE = re.compile(
    r"""
    (?:(?P<modifier>[A-Z][a-z]+)\s+)?       # optional leading cap word
    (?P<head>
        [A-Z]{2,6}s                           # acronym plural: GSAs
        |
        [A-Z]{2,6}                            # acronym singular: GSA
        |
        [A-Z][a-z]{2,}                        # capitalized word
    )
    \b
    """,
    re.VERBOSE,
)

# A full mention: a run of capitalized tokens ending in either an acronym
# or a capitalized noun that's known to be an "organizational head word"
# (Agency, Department, Board, District, Authority, County, etc.). We
# deliberately match greedily backward so "Kern County Groundwater
# Sustainability Agency" is captured as one mention.
#
# This is stored as a dict mapping plural → singular so that singular and
# plural forms collapse to the same "head" during matching. "Agencies" and
# "Agency" both normalize to "Agency".
_ORG_HEAD_PLURAL_TO_SINGULAR = {
    "Agencies": "Agency",
    "Departments": "Department",
    "Boards": "Board",
    "Bureaus": "Bureau",
    "Commissions": "Commission",
    "Committees": "Committee",
    "Councils": "Council",
    "Districts": "District",
    "Authorities": "Authority",
    "Offices": "Office",
    "Administrations": "Administration",
    "Services": "Service",
    "Divisions": "Division",
    "Programs": "Program",
    "Projects": "Project",
    "Plans": "Plan",
    "Acts": "Act",
    "Corporations": "Corporation",
    "Associations": "Association",
    "Societies": "Society",
    "Coalitions": "Coalition",
    "Consortia": "Consortium",
    "Groups": "Group",
    "Panels": "Panel",
    "Regions": "Region",
    "Teams": "Team",
}

_ORG_HEAD_SINGULARS = set(_ORG_HEAD_PLURAL_TO_SINGULAR.values())
_ORG_HEAD_PLURALS = set(_ORG_HEAD_PLURAL_TO_SINGULAR.keys())

# Union of both forms — used anywhere we need "is this a known org head word
# regardless of number?"
ORG_HEAD_WORDS = _ORG_HEAD_SINGULARS | _ORG_HEAD_PLURALS


def _singularize_head(head: str) -> str:
    """Collapse a plural head to its singular form.

    Handles ORG head words via the explicit mapping, and acronym plurals
    via the "ACRONYM + s" convention (e.g. "GSAs" -> "GSA", "EIRs" -> "EIR").
    Leaves other heads unchanged.
    """
    if head in _ORG_HEAD_PLURAL_TO_SINGULAR:
        return _ORG_HEAD_PLURAL_TO_SINGULAR[head]
    # Acronym plural: 2-6 uppercase letters followed by lowercase 's'.
    m = re.fullmatch(r"([A-Z]{2,6})s", head)
    if m:
        return m.group(1)
    return head


def _is_plural_head(head: str) -> bool:
    """True if the head form is plural."""
    if head in _ORG_HEAD_PLURAL_TO_SINGULAR:
        return True
    if re.fullmatch(r"[A-Z]{2,6}s", head):
        return True
    return False


# Regex to detect coordinated plural mentions like:
#     "Kern County and Semitropic GSAs"
#     "Kern County, Semitropic, and Rosedale GSAs"
#     "Kern County, Semitropic and Rosedale GSAs"  (no Oxford comma)
#
# The pattern captures the list of modifier phrases (group 'mods') and the
# trailing plural head token (group 'head'). Each modifier phrase is one or
# more capitalized tokens; separators are ", ", " and ", or ", and ".
_COORDINATED_PLURAL_RE = re.compile(
    r"""
    ^                                               # anchor to start of surface
    (?P<mods>
        (?:[A-Z][A-Za-z0-9\-'&]*(?:\s+[A-Z][A-Za-z0-9\-'&]*)*)  # first modifier phrase
        (?:
            (?:\s*,\s+|\s+and\s+|\s*,\s+and\s+)     # separator
            [A-Z][A-Za-z0-9\-'&]*(?:\s+[A-Z][A-Za-z0-9\-'&]*)*  # next modifier phrase
        )+                                          # one or more additional phrases
    )
    \s+
    (?P<head>[A-Z]{2,6}s|[A-Z][a-z]+)              # plural head
    \s*$
    """,
    re.VERBOSE,
)


def _split_coordinated_plural(
    mention: "Mention",
    text: str,
) -> list["Mention"]:
    """Split a coordinated plural mention into its component full mentions.

    "Kern County and Semitropic GSAs" -> [Kern County GSA, Semitropic GSA]

    Returns an empty list if the surface doesn't match a coordinated pattern
    (in which case the caller should leave the original mention alone).

    The singularized head is appended to each modifier to form the new
    singular surface. Character spans for the split mentions point to the
    modifier's location in the original text (best-effort, using the
    mention's own span as the search window).
    """
    surface = mention.surface
    m = _COORDINATED_PLURAL_RE.match(surface)
    if m is None:
        return []

    plural_head = m.group("head")
    singular_head = _singularize_head(plural_head)
    mods_text = m.group("mods")

    # Split modifiers on "," and "and", handling "A, B, and C" / "A, B and C"
    # / "A and B". We normalize the list to a sequence of cleanly-stripped
    # modifier phrases.
    # Strategy: replace " and " (surrounded by optional comma/spaces) with a
    # comma, then split on commas.
    normalized = re.sub(r"\s*,?\s+and\s+", ",", mods_text)
    modifier_phrases = [p.strip() for p in normalized.split(",") if p.strip()]

    if len(modifier_phrases) < 2:
        return []

    # Compute approximate spans for each component by searching within the
    # mention's original character range. We locate each modifier phrase in
    # the original text slice starting at mention.span[0].
    base_start, base_end = mention.span
    window = text[base_start:base_end]

    pieces: list[Mention] = []
    search_offset = 0
    for mod in modifier_phrases:
        idx = window.find(mod, search_offset)
        if idx < 0:
            # Couldn't locate the modifier cleanly (unusual punctuation);
            # fall back to the whole mention's span for this piece.
            mod_start = base_start
            mod_end = base_end
        else:
            mod_start = base_start + idx
            # The span for the component mention covers the modifier plus
            # the shared trailing head. We represent it as
            # "<modifier> <singular_head>" with a span ending at the end of
            # the original plural mention (so that tools that care about
            # where this came from can see it).
            mod_end = base_end
            search_offset = idx + len(mod)

        new_surface = f"{mod} {singular_head}"
        pieces.append(Mention(
            surface=new_surface,
            span=(mod_start, mod_end),
            kind="full",
            head=singular_head,
            is_plural=False,
        ))

    return pieces

# Regex for full mentions: 1-8 capitalized tokens, ending in an ORG head word
# or an acronym. We use `[^\S\n]` instead of `\s` so mentions don't span
# across line breaks — environmental docs wrap organization names onto one
# line almost always, and allowing \n breakage causes the scanner to eat
# acronym-table rows as giant spurious mentions.
#
# We deliberately ALLOW a leading "The "/"the " in the match; it gets
# stripped in post-processing. And a mention that was only "The <head>"
# with no real proper-noun modifier gets re-classified as an anaphor
# there — so this regex is permissive and the logic below decides.
_FULL_MENTION_RE = re.compile(
    r"""
    (?<![A-Za-z])                           # left boundary (no alpha just before)
    (?:[A-Z][A-Za-z0-9\-'&]*[^\S\n]+){0,8}  # 0-8 leading capitalized tokens, space (no newline)
    (?:
        [A-Z][a-z]+                          # final capitalized word
        |
        [A-Z]{2,6}s                          # or final acronym plural
        |
        [A-Z]{2,6}                           # or final acronym singular
    )
    (?![A-Za-z])
    """,
    re.VERBOSE,
)

# Words that can appear capitalized at sentence start but aren't proper-noun
# modifiers. If these are the only leading token(s) before the head of a
# candidate "full" mention, the mention is really an anaphor.
_LEADING_ARTICLES = {"The", "A", "An"}


def extract_full_mentions(
    text: str,
    acronym_dict: dict[str, str],
    exclude_regions: Optional[list[tuple[int, int]]] = None,
) -> tuple[list[Mention], list[Mention]]:
    """Find full-form entity mentions in the text.

    A mention qualifies as "full" if either:
      (a) its final token is in ORG_HEAD_WORDS and it has at least one
          proper-noun modifier (e.g., "Kern County Department"), OR
      (b) its final token is an acronym present in `acronym_dict`, and
          it is either preceded by a proper-noun modifier (so we get
          "Kern County GSA" not just "GSA"), OR
      (c) it matches an acronym's full expansion literally (e.g.
          "Environmental Protection Agency" when EPA is in the dict).

    Case (c) is handled by a second pass over the expansions.

    Returns
    -------
    (full_mentions, reclassified_anaphors)
        The second list is candidate anaphors that the scanner encountered
        while scanning for full mentions — specifically, matches like "The
        GSA" where the only token before the head is an article. These
        should be merged into the anaphor pool by the caller.

    Parameters
    ----------
    exclude_regions : list of (start, end) char offset tuples to skip.
        Use this to exclude the acronym table, tables of contents, and
        similar boilerplate where entity mentions aren't really references.
    """
    exclude_regions = exclude_regions or []

    def in_excluded(pos: int) -> bool:
        for s, e in exclude_regions:
            if s <= pos < e:
                return True
        return False

    mentions: list[Mention] = []
    reclassified_as_anaphor: list[Mention] = []

    for m in _FULL_MENTION_RE.finditer(text):
        if in_excluded(m.start()):
            continue
        surface = m.group().strip()
        tokens = surface.split()
        start = m.start()

        # Strip leading article (The/A/An). If that leaves fewer than 2 tokens,
        # the "full mention" is really an anaphor candidate — we'll emit it
        # from the anaphor pipeline, so skip here.
        leading_article_stripped = False
        if tokens and tokens[0] in _LEADING_ARTICLES:
            # Advance the start offset past the article + whitespace.
            article_len = len(tokens[0])
            # Find the whitespace run after the article.
            post = m.group()[article_len:]
            ws_match = re.match(r"\s+", post)
            ws_len = ws_match.end() if ws_match else 0
            start = m.start() + article_len + ws_len
            tokens = tokens[1:]
            surface = " ".join(tokens)
            leading_article_stripped = True

        if len(tokens) < 2:
            # After stripping, we have at most one token — not a full mention.
            # If the one remaining token is a known acronym or an org head
            # word (accepting both singular and plural forms), this is an
            # anaphor.
            if tokens:
                tok = tokens[0]
                tok_singular = _singularize_head(tok)
                is_known = (
                    tok_singular in acronym_dict
                    or tok_singular in _ORG_HEAD_SINGULARS
                )
                if is_known and leading_article_stripped:
                    abs_start = m.start()
                    abs_end = m.end()
                    reclassified_as_anaphor.append(Mention(
                        surface=text[abs_start:abs_end],
                        span=(abs_start, abs_end),
                        kind="anaphoric",
                        head=tok,
                        is_plural=_is_plural_head(tok),
                    ))
            continue

        final = tokens[-1]
        # Singularize for dict lookup: "GSAs" -> "GSA", "Agencies" -> "Agency".
        # We keep `final` as-is for the head attribute (so downstream can
        # see that this mention's surface was plural), but check membership
        # in acronym_dict / ORG_HEAD_WORDS against the singular form.
        final_singular = _singularize_head(final)

        # Case (a): ends in an org head word (singular or plural), has a
        # modifier.
        if final_singular in _ORG_HEAD_SINGULARS:
            mentions.append(Mention(
                surface=surface,
                span=(start, m.end()),
                kind="full",
                head=final,
                is_plural=_is_plural_head(final),
            ))
            continue

        # Case (b): ends in a known acronym (singular or plural form of
        # something in acronym_dict), has a modifier.
        if final_singular in acronym_dict and len(tokens) >= 2:
            mentions.append(Mention(
                surface=surface,
                span=(start, m.end()),
                kind="full",
                head=final,
                is_plural=_is_plural_head(final),
            ))
            continue

    # Case (c): literal matches of known expansions.
    # For each acronym -> expansion, find all occurrences of the expansion
    # in text. These are "full" mentions whose head is the acronym.
    for acronym, expansion in acronym_dict.items():
        # Case-insensitive search, but require the match to start with a
        # capital to avoid matching inside other words.
        pattern = re.compile(
            r"\b" + re.escape(expansion) + r"\b", re.IGNORECASE
        )
        for m in pattern.finditer(text):
            if in_excluded(m.start()):
                continue
            matched = m.group()
            if not matched[0].isupper():
                continue
            mentions.append(Mention(
                surface=matched,
                span=(m.start(), m.end()),
                kind="full",
                head=acronym,  # canonical head is the acronym
            ))

    # Dedicated pass: coordinated plurals like
    #     "Kern County and Semitropic GSAs"
    #     "the Kern County, Semitropic, and Rosedale GSAs"
    # These don't match _FULL_MENTION_RE because "and" is a non-capitalized
    # token that breaks the regex's capitalized-token run. We scan for them
    # directly and emit one full mention per component.
    # Pattern: one or more "<ModifierPhrase> , " or "<ModifierPhrase> and "
    # sequences followed by a final modifier + plural head.
    _coord_text_re = re.compile(
        r"""
        (?<![A-Za-z])
        (?P<all>
            (?:[A-Z][A-Za-z0-9\-'&]*(?:[^\S\n]+[A-Z][A-Za-z0-9\-'&]*)*)  # first modifier phrase
            (?:
                [^\S\n]*,[^\S\n]+                                          # ", "
                |
                [^\S\n]+and[^\S\n]+                                        # " and "
                |
                [^\S\n]*,[^\S\n]+and[^\S\n]+                               # ", and "
            )
            (?:[A-Z][A-Za-z0-9\-'&]*(?:[^\S\n]+[A-Z][A-Za-z0-9\-'&]*)*)  # another phrase
            (?:
                (?:
                    [^\S\n]*,[^\S\n]+
                    |
                    [^\S\n]+and[^\S\n]+
                    |
                    [^\S\n]*,[^\S\n]+and[^\S\n]+
                )
                (?:[A-Z][A-Za-z0-9\-'&]*(?:[^\S\n]+[A-Z][A-Za-z0-9\-'&]*)*)
            )*
            [^\S\n]+
            (?P<plural_head>[A-Z]{2,6}s|[A-Z][a-z]+)
        )
        (?![A-Za-z])
        """,
        re.VERBOSE,
    )

    for m in _coord_text_re.finditer(text):
        if in_excluded(m.start()):
            continue
        plural_head = m.group("plural_head")
        head_singular = _singularize_head(plural_head)
        # Only accept if the plural head is a known org head word (plural
        # form) or a known acronym plural.
        if plural_head not in _ORG_HEAD_PLURALS:
            if head_singular not in acronym_dict or plural_head == head_singular:
                continue
        # Build a synthetic parent mention and run the splitter.
        synthetic = Mention(
            surface=m.group("all"),
            span=(m.start(), m.end()),
            kind="full",
            head=plural_head,
            is_plural=True,
        )
        pieces = _split_coordinated_plural(synthetic, text)
        if len(pieces) >= 2:
            mentions.extend(pieces)


    # different rules). Keep the first.
    mentions.sort(key=lambda x: (x.span[0], x.span[1]))
    deduped: list[Mention] = []
    seen_spans: set[tuple[int, int]] = set()
    for mention in mentions:
        if mention.span in seen_spans:
            continue
        # Also drop if fully contained in a previously-kept mention
        # (prefer the longer outer span).
        contained = False
        for kept in deduped:
            if kept.span[0] <= mention.span[0] and mention.span[1] <= kept.span[1]:
                contained = True
                break
        if contained:
            continue
        deduped.append(mention)
        seen_spans.add(mention.span)

    return deduped, reclassified_as_anaphor


def extract_anaphoric_mentions(
    text: str,
    acronym_dict: dict[str, str],
    full_mention_spans: list[tuple[int, int]],
    exclude_regions: Optional[list[tuple[int, int]]] = None,
) -> list[Mention]:
    """Find definite-reference anaphors: "the GSA", "the Agency", etc.

    We skip any anaphor whose span is inside a full mention's span (those
    are part of the full mention, not a separate reference) and any that
    fall inside `exclude_regions` (e.g., the acronym table).
    """
    exclude_regions = exclude_regions or []

    def in_excluded(pos: int) -> bool:
        for s, e in exclude_regions:
            if s <= pos < e:
                return True
        return False

    # Build a fast "is this inside a full mention" check.
    # Sort spans; for each candidate we bisect.
    spans_sorted = sorted(full_mention_spans)

    def inside_full_mention(pos: int) -> bool:
        # Linear scan is fine for typical document sizes; swap in bisect if needed.
        for s, e in spans_sorted:
            if s <= pos < e:
                return True
            if s > pos:
                break
        return False

    anaphors: list[Mention] = []
    # Scan for "the <word>" / "The <word>" patterns. We use [^\S\n]+ (any
    # whitespace except newline) so "the\nDepartment" on separate lines
    # doesn't match — that's almost always an accidental layout artifact,
    # not a real anaphor.
    the_re = re.compile(r"\b[Tt]he[^\S\n]+")
    for the_match in the_re.finditer(text):
        if in_excluded(the_match.start()):
            continue
        if inside_full_mention(the_match.start()):
            continue

        # Look at what follows "the".
        tail_start = the_match.end()
        # Grab up to 40 chars to parse the head (stop at newline).
        tail = text[tail_start : tail_start + 40].split("\n", 1)[0]
        head_match = _HEAD_RE.match(tail)
        if not head_match:
            continue

        head = head_match.group("head")
        modifier = head_match.group("modifier")

        # Singularize for the "is this a known head?" check. "GSAs" is
        # accepted if "GSA" is in the acronym dict; "Agencies" is accepted
        # because the singular "Agency" is an ORG head word.
        head_singular = _singularize_head(head)

        # Only accept as anaphor if the singularized head is:
        #  - a known acronym in the doc, or
        #  - in ORG_HEAD_WORDS singular set.
        if head_singular not in acronym_dict and head_singular not in _ORG_HEAD_SINGULARS:
            continue

        # Critical: if the noun phrase has a proper-noun modifier (e.g.
        # "the Kern County GSA", "the Semitropic GSA"), this is NOT an
        # anaphoric reference — it's a full mention with "the" in front.
        # The _HEAD_RE captures only one modifier; we check for further
        # capitalized tokens before the head in the original text to be safe.
        has_modifier = modifier is not None
        if not has_modifier:
            # Check for extra capitalized tokens between "the" and the head
            # that we might have missed.
            between = tail[: head_match.start("head")]
            if re.search(r"[A-Z][a-z]+", between):
                has_modifier = True

        if has_modifier:
            continue  # it's a full mention with a definite article, skip.

        abs_start = the_match.start()
        abs_end = tail_start + head_match.end()
        surface = text[abs_start:abs_end]

        anaphors.append(Mention(
            surface=surface,
            span=(abs_start, abs_end),
            kind="anaphoric",
            head=head,
            is_plural=_is_plural_head(head),
        ))

    return anaphors


# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------

def resolve(
    text: str,
    acronym_dict: dict[str, str],
    sections: Optional[list[Section]] = None,
    exclude_regions: Optional[list[tuple[int, int]]] = None,
) -> list[Mention]:
    """End-to-end: extract full and anaphoric mentions, assign entity_ids,
    and resolve anaphors to their antecedents.

    Resolution rule:
        For each anaphoric mention, find the most recent full mention in the
        same section (preferring same-section) whose head matches the
        anaphor's head. If no same-section match, fall back to the most
        recent earlier full mention in any preceding section.

    Parameters
    ----------
    exclude_regions : list of (start, end) char offset tuples to skip during
        mention extraction. If None, we auto-detect the acronym table
        region and exclude it (the table's entries aren't real references).
        Pass an empty list to disable auto-detection.
    """
    if sections is None:
        sections = segment_sections(text)

    if exclude_regions is None:
        exclude_regions = []
        acronym_region = find_acronym_table_region(text)
        if acronym_region is not None:
            exclude_regions.append(acronym_region)

    full, reclassified = extract_full_mentions(
        text, acronym_dict, exclude_regions=exclude_regions
    )
    anaphoric = extract_anaphoric_mentions(
        text, acronym_dict, [m.span for m in full],
        exclude_regions=exclude_regions,
    )
    # Merge in any anaphors the full-mention scanner reclassified, dedup'd
    # against anaphors already found (same start position).
    known_starts = {a.span[0] for a in anaphoric}
    for a in reclassified:
        if a.span[0] not in known_starts:
            anaphoric.append(a)

    # Attach section info.
    for m in full + anaphoric:
        sec = section_of(m.span, sections)
        m.section = sec.name if sec else None

    # Assign entity ids to full mentions by canonical form.
    # Two full mentions belong to the same entity iff they share the same
    # normalized surface form. This is intentional: "Kern County GSA" and
    # "Semitropic GSA" are different entities even though they share a head.
    id_by_canonical: dict[str, str] = {}
    next_id = 0
    for m in full:
        canon = _canonicalize_full(m.surface, acronym_dict)
        m.canonical = canon
        if canon not in id_by_canonical:
            id_by_canonical[canon] = f"E{next_id:04d}"
            next_id += 1
        m.entity_id = id_by_canonical[canon]

    # Merge mentions list, sorted by position.
    all_mentions = sorted(full + anaphoric, key=lambda x: x.span[0])

    # Resolve each anaphor.
    for i, m in enumerate(all_mentions):
        if m.kind != "anaphoric":
            continue

        if m.is_plural:
            # Plural anaphor: collect ALL compatible earlier full mentions
            # in the same section; fall back to any earlier section if none
            # exist in-section.
            antecedent_idxs = _find_all_antecedents(
                all_mentions, i,
                prefer_section=m.section,
                acronym_dict=acronym_dict,
            )
            if not antecedent_idxs:
                m.canonical = None
                continue
            m.resolved_from_all = antecedent_idxs
            m.resolved_from = None  # not meaningful for plural
            # For plural anaphors, the entity_id / canonical represent the
            # SET — we synthesize a readable canonical as "{canon1} + {canon2} + ...".
            ant_canonicals = sorted({
                all_mentions[j].canonical for j in antecedent_idxs
                if all_mentions[j].canonical
            })
            m.canonical = " + ".join(ant_canonicals) if ant_canonicals else None
            # entity_id for a plural is None — callers should iterate
            # resolved_from_all and look up each antecedent's entity_id.
            m.entity_id = None
        else:
            # Singular anaphor: classic one-antecedent resolution.
            antecedent_idx = _find_antecedent(
                all_mentions, i,
                prefer_section=m.section,
                acronym_dict=acronym_dict,
            )
            if antecedent_idx is None:
                m.canonical = None
                continue

            antecedent = all_mentions[antecedent_idx]
            m.entity_id = antecedent.entity_id
            m.canonical = antecedent.canonical
            m.resolved_from = antecedent_idx
            m.resolved_from_all = [antecedent_idx]

    return all_mentions


def _canonicalize_full(surface: str, acronym_dict: dict[str, str]) -> str:
    """Normalize a full mention's surface form into a canonical entity key.

    Rule: if the surface ends in an acronym (singular or plural) known to
    the dict, replace it with the expansion so that "Kern County GSA" and
    "Kern County Groundwater Sustainability Agency" canonicalize to the
    same key. Plural trailing tokens ("GSAs") are singularized first.
    Then collapse whitespace and case.
    """
    tokens = surface.split()
    if tokens:
        last_singular = _singularize_head(tokens[-1])
        if last_singular in acronym_dict:
            expansion = acronym_dict[last_singular]
            tokens = tokens[:-1] + expansion.split()
        elif last_singular in _ORG_HEAD_SINGULARS and tokens[-1] != last_singular:
            # Plural ORG head word — singularize for canonical form.
            tokens = tokens[:-1] + [last_singular]
    canon = " ".join(tokens)
    return re.sub(r"\s+", " ", canon).strip().lower()


def _heads_compatible(
    anaphor_head: str,
    candidate: Mention,
    acronym_dict: dict[str, str],
) -> bool:
    """Check whether a candidate full mention could be the antecedent of an
    anaphor with head `anaphor_head`.

    All comparisons singularize first — "GSAs" and "GSA" are treated as the
    same head, "Agencies" and "Agency" the same. This lets plural anaphors
    match singular full mentions and vice versa.

    Compatibility is defined as any of:
      1. The candidate's head (singularized) equals `anaphor_head`
         (singularized).
      2. `anaphor_head` is an acronym; the candidate's surface matches that
         acronym's expansion OR the candidate's surface ends with the
         acronym as a token.
      3. `anaphor_head` is an ORG head word (e.g. "Department"); it appears
         as a token in the candidate's surface, or in the acronym
         expansion of the candidate's head.
    """
    anaphor_sing = _singularize_head(anaphor_head)
    candidate_head_sing = _singularize_head(candidate.head)

    # Rule 1: exact head match (on singularized forms).
    if anaphor_sing == candidate_head_sing:
        return True

    # Rule 2: anaphor is an acronym; candidate's surface is its expansion.
    if anaphor_sing in acronym_dict:
        expansion = acronym_dict[anaphor_sing]
        if _normalize_surface(candidate.surface) == _normalize_surface(expansion):
            return True
        # Candidate might be an acronym form ("Kern County GSA") whose
        # trailing token is the anaphor's acronym (singularized).
        cand_tokens = candidate.surface.split()
        if cand_tokens and _singularize_head(cand_tokens[-1]) == anaphor_sing:
            return True

    # Rule 3: anaphor's head (singularized) is an ORG head word, and it
    # appears as a token (singularized) somewhere in the candidate's surface
    # or in the candidate's acronym expansion.
    if anaphor_sing in _ORG_HEAD_SINGULARS:
        cand_tokens = candidate.surface.split()
        if any(_singularize_head(t) == anaphor_sing for t in cand_tokens):
            return True
        if candidate_head_sing in acronym_dict:
            expansion_tokens = acronym_dict[candidate_head_sing].split()
            if any(_singularize_head(t) == anaphor_sing for t in expansion_tokens):
                return True

    return False


def _normalize_surface(s: str) -> str:
    return re.sub(r"\s+", " ", s.strip().lower())


def _find_antecedent(
    mentions: list[Mention],
    anaphor_idx: int,
    prefer_section: Optional[str],
    acronym_dict: dict[str, str],
) -> Optional[int]:
    """Find the most recent full mention preceding `anaphor_idx` with a
    compatible head. Prefer same-section; fall back to any earlier section.

    Used for SINGULAR anaphors only.
    """
    anaphor = mentions[anaphor_idx]
    head = anaphor.head

    # First pass: same section.
    if prefer_section is not None:
        for j in range(anaphor_idx - 1, -1, -1):
            cand = mentions[j]
            if cand.kind != "full":
                continue
            if cand.section != prefer_section:
                continue
            if _heads_compatible(head, cand, acronym_dict):
                return j

    # Second pass: any earlier section.
    for j in range(anaphor_idx - 1, -1, -1):
        cand = mentions[j]
        if cand.kind != "full":
            continue
        if _heads_compatible(head, cand, acronym_dict):
            return j

    return None


def _find_all_antecedents(
    mentions: list[Mention],
    anaphor_idx: int,
    prefer_section: Optional[str],
    acronym_dict: dict[str, str],
) -> list[int]:
    """Find ALL compatible full-mention antecedents preceding `anaphor_idx`.

    Used for PLURAL anaphors like "the GSAs".

    Same scope rule as the singular case: prefer same-section; fall back to
    any earlier section if no in-section matches exist. When falling back,
    we return all compatible antecedents document-wide up to this point.

    We deduplicate by `entity_id` so that multiple mentions of the same
    entity (e.g., "Kern County GSA" mentioned twice before the plural
    anaphor) don't cause the plural to "resolve" to one entity counted
    twice. The returned indices are the FIRST mention index per entity.
    """
    anaphor = mentions[anaphor_idx]
    head = anaphor.head

    # Same-section candidates.
    same_section: list[int] = []
    for j in range(anaphor_idx):
        cand = mentions[j]
        if cand.kind != "full":
            continue
        if cand.section != prefer_section:
            continue
        if _heads_compatible(head, cand, acronym_dict):
            same_section.append(j)

    if same_section:
        return _dedupe_by_entity(same_section, mentions)

    # Fall back to any earlier section.
    fallback: list[int] = []
    for j in range(anaphor_idx):
        cand = mentions[j]
        if cand.kind != "full":
            continue
        if _heads_compatible(head, cand, acronym_dict):
            fallback.append(j)

    return _dedupe_by_entity(fallback, mentions)


def _dedupe_by_entity(
    indices: list[int],
    mentions: list[Mention],
) -> list[int]:
    """Keep only the first index for each distinct entity_id. Indices whose
    mention lacks an entity_id are kept as-is.
    """
    seen: set[str] = set()
    out: list[int] = []
    for idx in indices:
        eid = mentions[idx].entity_id
        if eid is None:
            out.append(idx)
            continue
        if eid in seen:
            continue
        seen.add(eid)
        out.append(idx)
    return out


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import argparse
    import csv
    import json
    import sys

    parser = argparse.ArgumentParser(
        description="Resolve in-document anaphora for named entities."
    )
    parser.add_argument("textfile", help="Path to a plain-text document.")
    parser.add_argument(
        "--acronyms",
        required=True,
        help="Path to a JSON file mapping acronym -> expansion "
             "(e.g. the output of acronym_extractor.py).",
    )
    parser.add_argument(
        "--output",
        default="-",
        help="Output file path (CSV). Default: stdout.",
    )
    args = parser.parse_args()

    with open(args.textfile, "r", encoding="utf-8") as f:
        text = f.read()
    with open(args.acronyms, "r", encoding="utf-8") as f:
        acronym_dict = json.load(f)

    mentions = resolve(text, acronym_dict)

    out = sys.stdout if args.output == "-" else open(args.output, "w", newline="", encoding="utf-8")
    writer = csv.writer(out)
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
    if out is not sys.stdout:
        out.close()
