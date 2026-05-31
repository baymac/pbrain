#!/usr/bin/env bash
set -euo pipefail

# organize-clippings.sh
# Walk through every clipping and move each into one of the user's chosen
# top-level vault folders (or any subpath underneath). Renames when the
# current filename is messy or generic.
#
# Destinations are discovered dynamically from the vault — every top-level
# dir except agent-work/ and Clippings/ is a candidate. The user picks the
# subset to use at the start of the session, or pre-sets it with
# PBRAIN_CLIPPINGS_TARGETS.
#
# Decision policy:
#   - High confidence (>= ~70/30 split): just move it, announce the choice.
#   - Close call (between ~40/60 and ~60/40): present 2-3 options, let user pick.
#
# Default source:  $VAULT_DIR/Clippings
# Overrides:
#   PBRAIN_VAULT              — set the vault root
#   PBRAIN_CLIPPINGS_DIR      — set the clippings source directory directly
#   PBRAIN_CLIPPINGS_TARGETS  — comma-separated list of top-level dirs to use
#                               as destinations (e.g. "life,notes,software-dev"),
#                               or "all" to skip the interactive prompt and use
#                               every discovered dir.
#
# Usage:
#   /organize-clippings

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

# Surface this user's standing preferences for /organize-clippings (emits nothing if none set).
pbrain_emit_prefs "organize-clippings" || true

CLIPPINGS_DIR="${PBRAIN_CLIPPINGS_DIR:-$VAULT_DIR/Clippings}"
PRESET_TARGETS="${PBRAIN_CLIPPINGS_TARGETS:-}"

if [[ ! -d "$CLIPPINGS_DIR" ]]; then
  echo "ORGANIZE_CLIPPINGS_NONE"
  echo "No Clippings directory at $CLIPPINGS_DIR — nothing to do."
  exit 0
fi

CLIPPING_FILES="$(find "$CLIPPINGS_DIR" -maxdepth 1 -type f -name "*.md" | sort)"
if [[ -z "$CLIPPING_FILES" ]]; then
  echo "ORGANIZE_CLIPPINGS_EMPTY"
  echo "Clippings folder is empty — nothing to organize."
  exit 0
fi

# Build a preview of each clipping: filename, full frontmatter, body preview.
CLIPPINGS_PAYLOAD="$(python3 - "$CLIPPINGS_DIR" <<'PYEOF'
import os, glob, re, sys

clippings_dir = sys.argv[1]
files = sorted(glob.glob(os.path.join(clippings_dir, "*.md")))

chunks = []
for f in files:
    name = os.path.basename(f)
    try:
        with open(f, encoding="utf-8") as fh:
            content = fh.read()
    except Exception as e:
        chunks.append(f"=== {name} ===\n(error reading: {e})\n")
        continue

    # Split frontmatter from body
    fm = ""
    body = content
    m = re.match(r"^---\n(.*?)\n---\n(.*)$", content, re.DOTALL)
    if m:
        fm = m.group(1).strip()
        body = m.group(2).strip()

    # Strip markdown image lines and trim
    body_clean = re.sub(r"!\[.*?\]\(.*?\)", "", body)
    body_clean = re.sub(r"\n{3,}", "\n\n", body_clean).strip()
    preview = body_clean[:800]
    if len(body_clean) > 800:
        preview += "\n…(truncated)"

    chunk = f"=== {name} ===\n"
    if fm:
        chunk += f"frontmatter:\n{fm}\n\n"
    chunk += f"body_preview:\n{preview}\n"
    chunks.append(chunk)

print("\n".join(chunks))
PYEOF
)"

# Discover candidate top-level dirs dynamically, plus their subdir tree (depth 2)
# and a sample of files at each level. Hard exclusions: agent-work/, Clippings/,
# anything starting with "." or "_".
DESTINATIONS_PAYLOAD="$(python3 - "$VAULT_DIR" "$(basename "$CLIPPINGS_DIR")" <<'PYEOF'
import os, sys

vault = sys.argv[1]
clippings_basename = sys.argv[2]
EXCLUDE = {"agent-work", clippings_basename}

def is_hidden(name: str) -> bool:
    return name.startswith(".") or name.startswith("_")

def list_dirs(path: str):
    try:
        return sorted(
            n for n in os.listdir(path)
            if os.path.isdir(os.path.join(path, n)) and not is_hidden(n)
        )
    except Exception:
        return []

def list_md_files(path: str):
    try:
        return sorted(
            n for n in os.listdir(path)
            if n.endswith(".md") and not is_hidden(n)
        )
    except Exception:
        return []

top_dirs = [
    d for d in list_dirs(vault)
    if d not in EXCLUDE
]

lines = []
for d in top_dirs:
    full = os.path.join(vault, d)
    files = list_md_files(full)
    subdirs = list_dirs(full)
    lines.append(f"- {d}/")
    if files:
        sample = files[:6]
        more = "" if len(files) <= 6 else f" …(+{len(files)-6} more)"
        lines.append(f"    files: {', '.join(sample)}{more}")
    for sd in subdirs:
        sd_full = os.path.join(full, sd)
        sd_files = list_md_files(sd_full)
        sd_subdirs = list_dirs(sd_full)
        descriptor = f"    {d}/{sd}/"
        if sd_files:
            sample = sd_files[:5]
            more = "" if len(sd_files) <= 5 else f" …(+{len(sd_files)-5} more)"
            descriptor += f"  files: {', '.join(sample)}{more}"
        if sd_subdirs:
            descriptor += f"  subdirs: {', '.join(sd_subdirs)}"
        lines.append(descriptor)

# Also emit the bare list for downstream parsing.
print("ALL_CANDIDATES: " + ",".join(top_dirs))
print("")
print("\n".join(lines))
PYEOF
)"

# Pull the ALL_CANDIDATES line out so it appears only once in the session header.
ALL_CANDIDATES_LINE="$(printf '%s\n' "$DESTINATIONS_PAYLOAD" | head -1)"
DESTINATIONS_TREE="$(printf '%s\n' "$DESTINATIONS_PAYLOAD" | tail -n +3)"

echo "ORGANIZE_CLIPPINGS_SESSION"
echo "clippings_dir: $CLIPPINGS_DIR"
echo "vault_dir: $VAULT_DIR"
echo "preset_targets: ${PRESET_TARGETS:-(none — ask the user)}"
echo "$ALL_CANDIDATES_LINE"
echo ""
echo "=== CLIPPINGS TO PROCESS ==="
echo "$CLIPPINGS_PAYLOAD"
echo ""
echo "=== DISCOVERED DESTINATION DIRS (top-level, with subdir tree) ==="
echo "$DESTINATIONS_TREE"
echo ""

cat <<'PROMPT_END'
---
INSTRUCTIONS — pick destinations first, then process clippings one at a time.

Step 0 — Destination selection (once, before any moves):
  - Look at `preset_targets` and `ALL_CANDIDATES` above.
  - If `preset_targets` is "all", use every dir in ALL_CANDIDATES. Announce:
        "Using all top-level dirs except agent-work/ and Clippings/: <list>"
  - If `preset_targets` is a comma-separated list of dir names, use those
    (silently drop any that aren't in ALL_CANDIDATES, warn once). Announce them.
  - Otherwise (no preset), ask the user exactly:
        "Which top-level dirs should I file these clippings into?
         Available: <ALL_CANDIDATES joined with commas>
         Reply with a comma-separated subset, or 'all' for everything (still excludes agent-work/ and Clippings/)."
    Wait for their answer. Normalize: lowercase, strip whitespace, split on commas.
    If they say "all", expand to ALL_CANDIDATES. If an entry isn't in ALL_CANDIDATES,
    list it back and ask them to fix or drop it.

  Lock the resulting set as ALLOWED_TOP_DIRS. Every move below MUST start with
  one of these top-level dirs (subpaths underneath are unrestricted).

For each clipping (in the order listed):

Step 1 — Read its filename, frontmatter (especially title, description, source, tags),
and body preview. Form an opinion on the topic and best destination.

Step 2 — Pick destination:
  - Top-level dir MUST be one of ALLOWED_TOP_DIRS.
  - Subpath underneath is open-ended — reuse an existing subdir if it obviously
    fits, OR propose a new one (any depth) if the content warrants it. Examples:
    `side-quests/dj/sets/`, `software-dev/rust/async/`, `notes/books/non-fiction/`.
    Prefer reusing existing subdirs over creating new ones; only go deeper when
    the content is clearly a distinct sub-topic the user would want grouped.
  - NEVER target agent-work/ or Clippings/ even if somehow listed.
  - To decide which top-level dir fits, infer from the dir name and the sample
    files/subdirs shown above. Don't apply external categorization rules —
    learn from what the user has already put in each dir.

Step 3 — Decide filename:
  - If the current name is already clean, descriptive, and 3-6 words, keep it.
  - Otherwise (generic like "Post by @handle on X.md", or too long/verbose),
    propose a new name: 3-6 words, Title Case, content-derived, no trailing
    punctuation. Match the style of the user's existing files in the destination.
    Keep .md extension.
  - If a file with that name already exists in the destination, append " (2)" before
    .md, escalating to " (3)" etc.
  - If you rename the file, ALSO plan to rewrite the frontmatter `title:` field
    to the same short name (without .md) so Obsidian's inline title stays in sync.

Step 4 — Confidence check:
  - If you are >= ~70% sure on the destination AND filename: announce it concisely
    in one line ("→ moving OLD to DEST/NEW") and ask "ok?" — wait for a short ack
    ("ok"/"yes"/"y" or correction) before moving.
  - If it is a close call (between ~40/60 and ~60/40 confidence) between 2-3 paths:
    present them like:
        Close call on NAME:
          1. notes/books/ — fits because X
          2. life/reading/ — fits because Y
         Which one? (1/2 or other)
    Wait for user choice.
  - Either way, ALWAYS get a confirmation token before mv.

Step 5 — Execute the move with Bash:
    mkdir -p "{dest_dir}"
    mv "{clippings_dir}/{old_name}" "{dest_dir}/{new_name}"

  If you renamed the file, also rewrite the frontmatter `title:` field in the
  moved file to match the new name (without the .md extension). Use a small
  inline python3 heredoc that loads the file, replaces the `title:` line inside
  the leading `---` block (or inserts one if missing), and writes it back. Quote
  the value with double quotes and escape any embedded double quotes. Do not
  touch any other frontmatter field.

  Then announce: "✓ moved → {relative_path_from_vault}"

Step 6 — Move to the next clipping. Do not summarize between items; keep the loop tight.

When all clippings are processed, print a final summary:
  N moved, grouped by top-level dir, listed as relative paths from vault root.
PROMPT_END

# Self-improvement: capture standing preferences / quality fixes the user
# raised this session (silent unless there was genuine feedback).
pbrain_emit_self_improve "organize-clippings" || true
