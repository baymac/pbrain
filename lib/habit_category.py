"""Canonical habit categories ("parts") + normalization helpers — stdlib only.

A habit's ``category`` is a SINGLE slug (one part per habit). The seven canonical
parts have a fixed display order; any other slug is a valid CUSTOM part (the
profile is a living document — new parts cost no code change), shown after the
canonical ones alphabetically and title-cased. An empty / absent category is
"uncategorized" and always sorts last.

Used by:
  - commands/habits.sh   add / edit  — normalize the user's --category|--part
  - lib/habits.sh        norm()      — emit category + label + order into status
  - (the rollup groups purely off those emitted fields — no import needed there)
"""
import re

# (slug, label) in fixed display order — the seven parts PB-27 names.
CANONICAL = [
    ("wellness", "Wellness"),
    ("fitness-activity", "Fitness activity"),
    ("bad-habits", "Bad habits"),
    ("looks", "Looks"),
    ("cleanliness", "Cleanliness"),
    ("work", "Work"),
    ("diet", "Diet"),
]
CANONICAL_LABELS = {slug: lbl for slug, lbl in CANONICAL}
CANONICAL_ORDER = {slug: i for i, (slug, _) in enumerate(CANONICAL)}

# Friendly aliases that don't slugify straight to a canonical slug, so a natural
# phrasing from the model ("fitness", "hygiene") still lands on the right part.
_ALIASES = {
    "fitness": "fitness-activity",
    "fitness-activities": "fitness-activity",
    "activity": "fitness-activity",
    "exercise": "fitness-activity",
    "bad-habit": "bad-habits",
    "vices": "bad-habits",
    "vice": "bad-habits",
    "appearance": "looks",
    "grooming": "looks",
    "hygiene": "cleanliness",
    "clean": "cleanliness",
    "career": "work",
    "nutrition": "diet",
}

# Sort buckets — canonical first (in their fixed order), then custom
# (alphabetical), then uncategorized.
_CUSTOM_BUCKET = 100
_UNCATEGORIZED_BUCKET = 1000


def normalize(value):
    """Slugify a free-form part name to its canonical slug when known, else the
    plain slug (a valid custom part). Empty / None -> "" (uncategorized)."""
    s = re.sub(r"[^a-z0-9]+", "-", str(value or "").strip().lower()).strip("-")
    if not s:
        return ""
    if s in CANONICAL_ORDER:
        return s
    return _ALIASES.get(s, s)


def label(slug):
    """Display label for a category slug ("" -> 'Uncategorized')."""
    s = normalize(slug)
    if not s:
        return "Uncategorized"
    if s in CANONICAL_LABELS:
        return CANONICAL_LABELS[s]
    return " ".join(w.capitalize() for w in s.split("-"))


def order(slug):
    """A JSON-friendly sort index: canonical parts keep their fixed order
    (0..6), custom parts cluster after them, uncategorized sorts last. Ties
    (custom parts, or any same-bucket pair) break on the label."""
    s = normalize(slug)
    if not s:
        return _UNCATEGORIZED_BUCKET
    if s in CANONICAL_ORDER:
        return CANONICAL_ORDER[s]
    return _CUSTOM_BUCKET
