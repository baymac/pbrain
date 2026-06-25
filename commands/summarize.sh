#!/usr/bin/env bash
set -euo pipefail

# summarize.sh <type> [summarize] <vault-folder-or-path>
# Point at a vault folder, read the notes / transcripts inside, and produce a
# faithful, prompt-driven summary written under agent-work/. The SCRIPT does the
# mechanical work — resolve the input path, walk it, concatenate every .md/.txt
# file into one RAW CORPUS, pick the output path — and hands the corpus to
# Claude, whose ONLY job is to reframe it into prose following the per-type
# summarize prompt (see commands/templates/summarize/<type>.txt).
#
# Mirrors /clipper's shape: a SUBCOMMAND per content type, each carrying its own
# summarize prompt template. First type:
#   webinar <folder>   summarize a (trading) webinar transcript folder using the
#                      webinar summarize prompt (keep all tools / strategies /
#                      markets; strip course-selling + interpersonal filler).
#
# A bare "summarize"/"this"/"folder" token between the type and the path is
# ignored, so natural phrasing "summarize webinar this folder <path>" works.
#
# Input: a vault folder (path or Obsidian-style link), resolved relative to the
#   vault root. Absolute paths are accepted only when they live inside the vault.
# Output: $VAULT_DIR/agent-work/summaries/<type>/<slug>.md
#
# Internal (pure, no vault — unit-testable):
#   gather <dir>   print the concatenated RAW CORPUS for a folder, with one
#                  "--- <relative path> ---" header before each file's text.
#                  Walks .md + .txt recursively, sorted; silent + non-fatal on a
#                  missing dir (so the bats tests exercise it without a vault).
#
# Overrides:
#   PBRAIN_VAULT          — vault root
#   PBRAIN_SUMMARIZE_DIR  — summaries parent dir (<type> subdirs live under it)
#   PBRAIN_SUMMARIZE_EXTS — comma-separated file extensions to gather
#                           (default: md,txt)

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK

# --- internal pure subcommand: gather (kept ABOVE vault.sh so the bats test can
#     exercise it without a vault) --------------------------------------------
if [[ "${1:-}" == "gather" ]]; then
  shift
  python3 - "${1:-}" "${PBRAIN_SUMMARIZE_EXTS:-md,txt}" <<'PY'
import os, sys

root = sys.argv[1] if len(sys.argv) > 1 else ""
exts = tuple(
    "." + e.strip().lstrip(".").lower()
    for e in (sys.argv[2] if len(sys.argv) > 2 else "md,txt").split(",")
    if e.strip()
)
if not root or not os.path.isdir(root):
    sys.exit(0)

files = []
for dirpath, dirnames, filenames in os.walk(root):
    # Skip dotdirs (e.g. .obsidian, .git) for stable, content-only output.
    dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
    for name in sorted(filenames):
        if name.startswith("."):
            continue
        if exts and not name.lower().endswith(exts):
            continue
        files.append(os.path.join(dirpath, name))

chunks = []
for path in files:
    rel = os.path.relpath(path, root)
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            body = f.read()
    except Exception:
        continue
    chunks.append("--- %s ---\n%s" % (rel, body.strip()))

print(("\n\n".join(chunks)).strip())
PY
  exit 0
fi

source "$_SCRIPT_DIR/../lib/vault.sh"

pbrain_emit_prefs "summarize" || true

SUMMARIES_DIR="${PBRAIN_SUMMARIZE_DIR:-$VAULT_DIR/agent-work/summaries}"
TODAY="$(date +%Y-%m-%d)"

# --- arg routing ------------------------------------------------------------
TYPE="${1:-}"
case "$TYPE" in
  ""|help|-h|--help)
    cat <<'USAGE'
SUMMARIZE_USAGE
summarize reads a vault folder and writes a faithful, prompt-driven summary
under agent-work/summaries/<type>/.

  /summarize webinar <folder>   summarize a (trading) webinar transcript folder

Input is a vault folder (path or Obsidian link). Output lands at
$VAULT_DIR/agent-work/summaries/<type>/<slug>.md (override PBRAIN_SUMMARIZE_DIR).
USAGE
    echo ""
    echo "INSTRUCTIONS: Relay the supported content types in one line and ask"
    echo "the user which folder to summarize. Stop here."
    exit 0 ;;
  webinar)
    : ;;  # supported
  *)
    echo "SUMMARIZE_UNKNOWN_TYPE"
    echo "type: $TYPE"
    echo ""
    echo "INSTRUCTIONS: '$TYPE' is not a known summarize content type. The only"
    echo "type so far is 'webinar'. Tell the user in one line and ask them to"
    echo "re-run as: summarize webinar <folder>. Stop here."
    exit 0 ;;
esac
shift

# First non-filler argument is the input folder; bare "summarize/this/the/folder"
# tokens are ignored so natural phrasing works.
INPUT=""
for a in "$@"; do
  case "$a" in
    summarize|this|the|that|folder|notes|transcripts|please|of) continue ;;
  esac
  INPUT="$a"
  break
done

if [[ -z "$INPUT" ]]; then
  echo "SUMMARIZE_NO_INPUT"
  echo "type: $TYPE"
  echo ""
  echo "INSTRUCTIONS: No input folder was provided. Ask the user which vault"
  echo "folder to summarize in one line, then re-run: summarize $TYPE <folder>."
  echo "Stop here."
  exit 0
fi

# --- resolve the input folder against the vault -----------------------------
# Accept: an absolute path inside the vault, or a vault-relative path / Obsidian
# link. Strip a leading "vault/" and surrounding [[ ]] / quotes. Resolve to an
# absolute path and verify it sits inside the vault and is a directory.
RESOLVE_OUT="$(python3 - "$VAULT_DIR" "$INPUT" <<'PY'
import os, sys

vault = os.path.realpath(sys.argv[1])
raw = sys.argv[2].strip()

# Strip Obsidian wiki-link brackets and surrounding quotes.
if raw.startswith("[[") and raw.endswith("]]"):
    raw = raw[2:-2].strip()
raw = raw.strip("\"'").strip()
# Normalize a leading "vault/" prefix (the user may paste the display path).
for pre in ("vault/", "./"):
    if raw.startswith(pre):
        raw = raw[len(pre):]

cand = raw if os.path.isabs(raw) else os.path.join(vault, raw)
cand = os.path.realpath(cand)

# Must live inside the vault.
if cand != vault and not cand.startswith(vault + os.sep):
    print("OUTSIDE")
    sys.exit(0)
if not os.path.isdir(cand):
    print("MISSING")
    sys.exit(0)

print("OK\t%s\t%s" % (cand, os.path.basename(cand.rstrip(os.sep)) or "summary"))
PY
)"
RESOLVE_STATUS="$(printf '%s' "$RESOLVE_OUT" | head -n1 | cut -f1)"

if [[ "$RESOLVE_STATUS" == "OUTSIDE" ]]; then
  echo "SUMMARIZE_NOT_FOUND"
  echo "type: $TYPE"
  echo "input: $INPUT"
  echo "reason: outside-vault"
  echo ""
  echo "INSTRUCTIONS: The path resolves outside the vault — summarize only reads"
  echo "vault folders. Tell the user in one line and ask for a vault folder."
  echo "Stop here."
  exit 0
fi
if [[ "$RESOLVE_STATUS" != "OK" ]]; then
  echo "SUMMARIZE_NOT_FOUND"
  echo "type: $TYPE"
  echo "input: $INPUT"
  echo "reason: missing"
  echo ""
  echo "INSTRUCTIONS: No such vault folder. Tell the user the path wasn't found"
  echo "in one line and ask them to re-check it. Stop here."
  exit 0
fi

IN_DIR="$(printf '%s' "$RESOLVE_OUT" | head -n1 | cut -f2)"
SLUG_BASE="$(printf '%s' "$RESOLVE_OUT" | head -n1 | cut -f3)"

# Slug the folder name: lowercase, non-alnum → dash, collapse + trim dashes.
SLUG="$(printf '%s' "$SLUG_BASE" \
  | tr 'A-Z' 'a-z' \
  | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
[[ -n "$SLUG" ]] || SLUG="summary"

# --- gather the corpus ------------------------------------------------------
CORPUS="$(bash "$_SCRIPT_DIR/summarize.sh" gather "$IN_DIR")"
FILE_COUNT="$(printf '%s\n' "$CORPUS" | grep -cE '^--- .* ---$' || true)"

if [[ -z "$CORPUS" || "$FILE_COUNT" -eq 0 ]]; then
  echo "SUMMARIZE_EMPTY"
  echo "type: $TYPE"
  echo "input_dir: $IN_DIR"
  echo ""
  echo "INSTRUCTIONS: The folder has no .md / .txt files to summarize. Tell the"
  echo "user in one line and ask for a folder that contains notes/transcripts."
  echo "Stop here."
  exit 0
fi

WORDS="$(printf '%s' "$CORPUS" | wc -w | tr -d ' ')"

# --- output path (non-destructive; collision-suffixed) ----------------------
TYPE_DIR="$SUMMARIES_DIR/$TYPE"
mkdir -p "$TYPE_DIR"
OUT_FILE="$TYPE_DIR/$SLUG.md"
if [[ -f "$OUT_FILE" ]]; then
  OUT_FILE="$TYPE_DIR/$SLUG-$TODAY.md"
  n=2
  while [[ -f "$OUT_FILE" ]]; do
    OUT_FILE="$TYPE_DIR/$SLUG-$TODAY-$n.md"
    n=$((n + 1))
  done
fi

# --- hand the corpus to Claude ----------------------------------------------
echo "SUMMARIZE_WRITE"
echo "type: $TYPE"
echo "source_folder: $IN_DIR"
echo "file_count: $FILE_COUNT"
echo "corpus_words: $WORDS"
echo "captured: $TODAY"
echo "output_file: $OUT_FILE"
echo ""
echo "=== RAW CORPUS (every .md/.txt under the folder, file-by-file) ==="
printf '%s\n' "$CORPUS"
echo "=== END CORPUS ==="
echo ""

# Reframing instructions live in commands/templates/summarize/<type>.txt.
export OUT_FILE TYPE TODAY
envsubst '$OUT_FILE $TYPE $TODAY' < "$_SCRIPT_DIR/templates/summarize/$TYPE.txt"
