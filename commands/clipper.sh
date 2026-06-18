#!/usr/bin/env bash
set -euo pipefail

# clipper.sh <platform> [save] <url>
# Save an online video as a clean, readable long-form transcript ("clip") in the
# vault. The SCRIPT does all the technical work — cookies, download, subtitle
# selection, VTT cleanup (strips inline tags + rolling-window duplication), and a
# local Parakeet-TDT-v3 transcription fallback when the video has no captions —
# then hands a clean transcript to Claude, whose ONLY job is to reframe it into
# readable prose (faithful, not summarized; see commands/templates/clipper/write.txt).
#
# Subcommands (platforms):
#   x  <url>   X / Twitter video. Uses your browser cookies by default (X gates
#              video + caption fetches behind a logged-in session).
#   yt <url>   YouTube video.
#
# A bare "save"/"this"/"video" token between the platform and the URL is ignored,
# so the natural phrasing "clipper x save this video <url>" works.
#
# Setup:
#   transcriber install   build + cache the local Parakeet v3 transcriber (one-time)
#   transcriber status    show transcriber binary + model presence
#
# Internal (pure, no vault — unit-testable):
#   parse-vtt <file>   print the cleaned, de-duplicated transcript text of a .vtt
#
# Default destination:  $VAULT_DIR/agent-work/clips/<platform>/<slug>.md
# Overrides:
#   PBRAIN_VAULT                    — vault root
#   PBRAIN_CLIPPER_DIR              — clips parent dir (<platform> are subdirs)
#   PBRAIN_CLIPPER_COOKIES_BROWSER  — browser for --cookies-from-browser
#                                     (default: brave; "none"/"" disables;
#                                      "brave:Profile 1" selects a profile)
#   PBRAIN_CLIPPER_COOKIES_FILE     — path to a Netscape cookies.txt (wins over
#                                     the browser cookie jar when set)
#   PBRAIN_CLIPPER_SUB_LANGS        — yt-dlp --sub-langs (default: en,en-orig,en-US,en-GB)
#
# No-caption fallback transcriber (FluidAudio / Parakeet TDT v3 — see below):
#   PBRAIN_CLIPPER_FLUIDAUDIO_BIN       — use a specific fluidaudiocli (skips the build)
#   PBRAIN_CLIPPER_FLUIDAUDIO_DIR       — clone+build dir (default: ~/.config/pbrain/fluidaudio)
#   PBRAIN_CLIPPER_FLUIDAUDIO_REF       — FluidAudio git tag to build (default: v0.15.4)
#   PBRAIN_CLIPPER_FLUIDAUDIO_MODEL_DIR — Parakeet v3 model dir to reuse (default: FluidAudio cache)

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK

# --- internal pure subcommand: parse-vtt (kept ABOVE vault.sh so the bats test
#     can exercise it without a vault or network) ------------------------------
if [[ "${1:-}" == "parse-vtt" ]]; then
  shift
  python3 - "${1:-}" <<'PY'
import sys, re
path = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    with open(path, encoding="utf-8", errors="replace") as f:
        raw = f.read()
except Exception:
    sys.exit(0)

TAGS = re.compile(r"<[^>]+>")          # <00:00:13.190> and <c>...</c> inline tags
WS = re.compile(r"\s+")

def clean(s):
    s = TAGS.sub("", s)
    s = s.replace("&nbsp;", " ")
    return WS.sub(" ", s).strip()

out, last = [], None
for ln in raw.splitlines():
    s = ln.strip()
    if not s:
        continue
    if "-->" in s:                     # cue timing (carries any align/position settings)
        continue
    if s.upper().startswith("WEBVTT"):
        continue
    if s.startswith("Kind:") or s.startswith("Language:") or s.startswith("NOTE"):
        continue
    if re.fullmatch(r"\d+", s):        # numeric cue ids (srt-style)
        continue
    t = clean(ln)
    if not t:
        continue
    if t == last:                      # collapse rolling-window auto-caption repeats
        continue
    out.append(t)
    last = t

text = WS.sub(" ", " ".join(out)).strip()
print(text)
PY
  exit 0
fi

source "$_SCRIPT_DIR/../lib/vault.sh"

pbrain_emit_prefs "clipper" || true

CLIPS_DIR="${PBRAIN_CLIPPER_DIR:-$VAULT_DIR/agent-work/clips}"
SUB_LANGS="${PBRAIN_CLIPPER_SUB_LANGS:-en,en-orig,en-US,en-GB}"

# --- FluidAudio (Parakeet TDT 0.6b v3) transcriber --------------------------
# When a video has no caption track, we transcribe its audio locally with
# FluidAudio's Parakeet TDT v3 CoreML model (the same model Muesli uses). There
# is no prebuilt CLI, so we build `fluidaudiocli` from source once and cache it;
# the v3 model auto-downloads to the FluidAudio cache on first use, or is reused
# in place if it's already there (e.g. installed by Muesli). v3 is the CLI's
# default model — we never select another.
FA_REF="${PBRAIN_CLIPPER_FLUIDAUDIO_REF:-v0.15.4}"
FA_DIR="${PBRAIN_CLIPPER_FLUIDAUDIO_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/fluidaudio}"
FA_BIN_REL="FluidAudio/.build/release/fluidaudiocli"
FA_MODEL_DIR="${PBRAIN_CLIPPER_FLUIDAUDIO_MODEL_DIR:-$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml}"

# Resolve a usable fluidaudiocli binary (env override → PATH → our cached build).
# Prints the path and returns 0, or prints nothing and returns 1.
_clipper_fa_bin() {
  if [[ -n "${PBRAIN_CLIPPER_FLUIDAUDIO_BIN:-}" && -x "${PBRAIN_CLIPPER_FLUIDAUDIO_BIN}" ]]; then
    printf '%s' "$PBRAIN_CLIPPER_FLUIDAUDIO_BIN"; return 0
  fi
  local p
  for p in fluidaudiocli fluidaudio; do
    if command -v "$p" >/dev/null 2>&1; then command -v "$p"; return 0; fi
  done
  [[ -x "$FA_DIR/$FA_BIN_REL" ]] && { printf '%s' "$FA_DIR/$FA_BIN_REL"; return 0; }
  return 1
}

# Build + cache the fluidaudiocli binary from source (one-time). Emits progress
# lines; returns non-zero on failure. Needs git + swift (Xcode CLT).
_clipper_fa_build() {
  command -v git   >/dev/null 2>&1 || { echo "  git not found — install the Xcode command line tools (xcode-select --install)."; return 1; }
  command -v swift >/dev/null 2>&1 || { echo "  swift not found — install Xcode / the Swift toolchain."; return 1; }
  mkdir -p "$FA_DIR"
  if [[ ! -d "$FA_DIR/FluidAudio/.git" ]]; then
    echo "  cloning FluidInference/FluidAudio@$FA_REF …"
    rm -rf "$FA_DIR/FluidAudio"
    git -C "$FA_DIR" clone --depth 1 --branch "$FA_REF" \
      https://github.com/FluidInference/FluidAudio.git FluidAudio || return 1
  fi
  echo "  building fluidaudiocli (one-time, ~1–3 min, no external deps) …"
  ( cd "$FA_DIR/FluidAudio" && swift build -c release --product fluidaudiocli ) || return 1
  [[ -x "$FA_DIR/$FA_BIN_REL" ]] || return 1
  echo "  built: $FA_DIR/$FA_BIN_REL"
  return 0
}

# --- argument parsing -------------------------------------------------------
PLATFORM="${1:-}"; shift || true
case "$PLATFORM" in
  x|twitter) PLATFORM="x" ;;
  yt|youtube) PLATFORM="yt" ;;
  transcriber)
    # One-time setup / status for the local Parakeet v3 transcriber.
    ACTION="${1:-status}"   # after the shift above, $1 is install|status
    FA_BIN="$(_clipper_fa_bin || true)"
    case "$ACTION" in
      status)
        echo "CLIPPER_TRANSCRIBER_STATUS"
        echo "binary: ${FA_BIN:-(not built)}"
        echo "ref: $FA_REF"
        echo "model: parakeet-tdt-0.6b-v3"
        echo "model_dir: $FA_MODEL_DIR"
        echo "model_present: $([[ -d "$FA_MODEL_DIR" ]] && echo yes || echo no)"
        echo ""
        echo "INSTRUCTIONS: Relay this in one line. If binary is '(not built)', the user can"
        echo "run '/clipper transcriber install' once to build it. If model_present is no,"
        echo "the Parakeet v3 model downloads automatically on the first transcription."
        exit 0 ;;
      install)
        echo "CLIPPER_TRANSCRIBER_INSTALL"
        if [[ -n "$FA_BIN" ]]; then
          echo "  already available: $FA_BIN"
        elif ! _clipper_fa_build; then
          echo ""
          echo "INSTRUCTIONS: The fluidaudiocli build failed (see the lines above — usually a"
          echo "missing Swift toolchain / Xcode command line tools). Relay the blocker to the"
          echo "user and stop. Don't retry blindly."
          exit 0
        fi
        echo "model: parakeet-tdt-0.6b-v3 ($([[ -d "$FA_MODEL_DIR" ]] && echo 'present, will reuse' || echo 'will download on first transcription'))"
        echo ""
        echo "INSTRUCTIONS: The local Parakeet v3 transcriber is ready. Tell the user in one"
        echo "line, then they can re-run '/clipper <platform> <url>' on a caption-less video."
        exit 0 ;;
      *)
        echo "usage: clipper transcriber install|status" >&2
        exit 2 ;;
    esac ;;
  ""|help|-h|--help)
    cat <<'USAGE'
CLIPPER_USAGE
clipper saves an online video as a clean, readable transcript in the vault.

  /clipper x <url>            save an X / Twitter video
  /clipper yt <url>           save a YouTube video
  /clipper transcriber install   build the local Parakeet v3 transcriber (one-time)
  /clipper transcriber status    show transcriber + model status

The phrasing "clipper x save this video <url>" also works (filler words ignored).
USAGE
    exit 0 ;;
  *)
    echo "CLIPPER_UNKNOWN_PLATFORM"
    echo "platform: $PLATFORM"
    echo ""
    echo "INSTRUCTIONS: '$PLATFORM' isn't a supported clipper platform. Today clipper"
    echo "supports 'x' (X / Twitter) and 'yt' (YouTube). Tell the user the supported"
    echo "platforms and ask for the video URL. Stop here."
    exit 0 ;;
esac

# First http(s) token among the remaining args is the URL; "save/this/video" etc.
# are ignored fillers so natural phrasing works.
URL=""
for a in "$@"; do
  if [[ "$a" =~ ^https?:// ]]; then URL="$a"; break; fi
done

if [[ -z "$URL" ]]; then
  echo "CLIPPER_NO_URL"
  echo "platform: $PLATFORM"
  echo ""
  echo "INSTRUCTIONS: No video URL was provided. Ask the user for the $PLATFORM video"
  echo "URL in one line, then re-run: clipper.sh $PLATFORM <url>. Stop here."
  exit 0
fi

# Platform URL sanity check (a warning, not a hard stop — yt-dlp is the judge).
URL_HOST="$(printf '%s' "$URL" | sed -E 's#^https?://([^/]+)/?.*#\1#' | tr 'A-Z' 'a-z')"
URL_WARN=""
case "$PLATFORM" in
  x)  [[ "$URL_HOST" =~ (^|\.)(x\.com|twitter\.com)$ ]] || URL_WARN="That doesn't look like an x.com / twitter.com URL." ;;
  yt) [[ "$URL_HOST" =~ (^|\.)(youtube\.com|youtu\.be)$ ]] || URL_WARN="That doesn't look like a youtube.com / youtu.be URL." ;;
esac

# --- yt-dlp preflight -------------------------------------------------------
if ! command -v yt-dlp >/dev/null 2>&1; then
  echo "CLIPPER_NO_YTDLP"
  echo ""
  echo "INSTRUCTIONS: clipper needs yt-dlp to fetch the video's captions, and it isn't"
  echo "installed. Tell the user to install it (e.g. 'brew install yt-dlp' or"
  echo "'pip install -U yt-dlp'), then re-run. Stop here."
  exit 0
fi

# --- cookie args ------------------------------------------------------------
COOKIE_ARGS=()
COOKIE_DESC="none"
COOKIES_FILE="${PBRAIN_CLIPPER_COOKIES_FILE:-}"
COOKIES_BROWSER="${PBRAIN_CLIPPER_COOKIES_BROWSER-brave}"
if [[ -n "$COOKIES_FILE" ]]; then
  COOKIE_ARGS=(--cookies "$COOKIES_FILE")
  COOKIE_DESC="file:$COOKIES_FILE"
elif [[ -n "$COOKIES_BROWSER" && "$COOKIES_BROWSER" != "none" ]]; then
  COOKIE_ARGS=(--cookies-from-browser "$COOKIES_BROWSER")
  COOKIE_DESC="browser:$COOKIES_BROWSER"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/clipper.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# --- metadata ---------------------------------------------------------------
META_JSON="$WORK/meta.json"
if ! yt-dlp ${COOKIE_ARGS[@]+"${COOKIE_ARGS[@]}"} --skip-download --dump-single-json --no-warnings \
       "$URL" > "$META_JSON" 2> "$WORK/meta.err"; then
  echo "CLIPPER_FETCH_FAILED"
  echo "platform: $PLATFORM"
  echo "url: $URL"
  echo "cookies: $COOKIE_DESC"
  echo ""
  echo "--- yt-dlp error ---"
  tail -n 15 "$WORK/meta.err" 2>/dev/null || true
  echo ""
  echo "INSTRUCTIONS: yt-dlp couldn't read this video. Common causes: the post is"
  echo "private/age-gated/region-locked, the URL is wrong, or the cookie source"
  echo "($COOKIE_DESC) is stale or the browser holds a lock on its cookie DB (close"
  echo "the browser, or set PBRAIN_CLIPPER_COOKIES_BROWSER to another browser /"
  echo "PBRAIN_CLIPPER_COOKIES_FILE to a cookies.txt). Relay the gist of the error to"
  echo "the user and stop — don't fabricate a transcript."
  exit 0
fi

# Pull display fields + slug; write slug/desc to files (no fragile shell quoting).
cat > "$WORK/meta.py" <<'PY'
import json, sys, re

meta_path, work = sys.argv[1], sys.argv[2]
try:
    with open(meta_path, encoding="utf-8", errors="replace") as f:
        d = json.load(f)
except Exception:
    d = {}

def g(*keys):
    for k in keys:
        v = d.get(k)
        if v not in (None, ""):
            return v
    return ""

title = str(g("title", "fulltitle") or "")
uploader = str(g("uploader", "uploader_id", "channel", "creator") or "")
url = str(g("webpage_url", "original_url") or "")
desc = str(g("description") or "")
dur = g("duration")
upload_date = str(g("upload_date") or "")
lang = str(g("language") or "")

def fmt_dur(s):
    try:
        s = int(float(s))
    except Exception:
        return ""
    h, m, sec = s // 3600, (s % 3600) // 60, s % 60
    return (f"{h}:{m:02d}:{sec:02d}" if h else f"{m}:{sec:02d}")

# slug from the title (fall back to uploader, then "clip")
STOP = set("a an the and or but if then to of for in on at by with from as is are was "
           "were be this that i you we they it my your our".split())
base = title or uploader or "clip"
words = re.sub(r"[^a-z0-9\s]", " ", base.lower()).split()
keep = [w for w in words if w not in STOP and len(w) > 1][:8]
if len(keep) < 2:
    keep = [w for w in words if len(w) > 1][:8] or ["clip"]
slug = "-".join(keep) or "clip"

with open(work + "/slug", "w") as f:
    f.write(slug)
with open(work + "/title", "w") as f:
    f.write(title)
with open(work + "/desc.txt", "w") as f:
    f.write(desc.strip())

print("title: " + (title or "(untitled)"))
print("author: " + (uploader or "(unknown)"))
fallback_url = sys.argv[3] if len(sys.argv) > 3 else ""
print("source_url: " + (url or fallback_url or "(unknown)"))
print("duration: " + (fmt_dur(dur) or "(unknown)"))
print("upload_date: " + (upload_date or "(unknown)"))
print("language: " + (lang or "(unknown)"))
PY
META_DISPLAY="$(python3 "$WORK/meta.py" "$META_JSON" "$WORK" "$URL")"
SLUG="$(cat "$WORK/slug" 2>/dev/null || echo clip)"
[[ -n "$SLUG" ]] || SLUG="clip"

# --- subtitles --------------------------------------------------------------
yt-dlp ${COOKIE_ARGS[@]+"${COOKIE_ARGS[@]}"} --skip-download --write-subs --write-auto-subs \
  --sub-langs "$SUB_LANGS" --sub-format vtt --no-warnings \
  -o "$WORK/sub.%(ext)s" "$URL" > "$WORK/sub.log" 2>&1 || true

# Prefer a manual track (sub.en.vtt) over an auto one (sub.en-orig.vtt), then any.
SUBFILE=""
for cand in "$WORK/sub.en.vtt" "$WORK/sub.en-orig.vtt" "$WORK/sub.en-US.vtt" "$WORK/sub.en-GB.vtt"; do
  [[ -f "$cand" ]] && { SUBFILE="$cand"; break; }
done
if [[ -z "$SUBFILE" ]]; then
  SUBFILE="$(ls "$WORK"/sub.*.vtt 2>/dev/null | head -n1 || true)"
fi

TRANSCRIPT=""
SOURCE_KIND=""
if [[ -n "$SUBFILE" && -s "$SUBFILE" ]]; then
  TRANSCRIPT="$(bash "$_SCRIPT_DIR/clipper.sh" parse-vtt "$SUBFILE" || true)"
  case "$SUBFILE" in
    *sub.en.vtt|*sub.en-US.vtt|*sub.en-GB.vtt) SOURCE_KIND="captions" ;;
    *) SOURCE_KIND="auto-captions" ;;
  esac
fi

# --- transcription fallback (no caption track) → Parakeet v3 via FluidAudio --
FA_BIN=""
if [[ -z "$TRANSCRIPT" ]]; then
  FA_BIN="$(_clipper_fa_bin || true)"
  if [[ -n "$FA_BIN" ]] && command -v ffmpeg >/dev/null 2>&1; then
    # Extract audio to wav; FluidAudio resamples internally, AVFoundation reads wav.
    if yt-dlp ${COOKIE_ARGS[@]+"${COOKIE_ARGS[@]}"} -x --audio-format wav --no-warnings \
         -o "$WORK/audio.%(ext)s" "$URL" > "$WORK/audio.log" 2>&1 && [[ -f "$WORK/audio.wav" ]]; then
      # Pin the cached v3 model dir when present so we reuse it (and only it);
      # otherwise let the CLI auto-download v3 (its default) to the cache.
      MD_ARGS=()
      [[ -d "$FA_MODEL_DIR" ]] && MD_ARGS=(--model-dir "$FA_MODEL_DIR")
      if "$FA_BIN" transcribe "$WORK/audio.wav" ${MD_ARGS[@]+"${MD_ARGS[@]}"} \
           --output-json "$WORK/fa.json" > "$WORK/fa.log" 2>&1 && [[ -f "$WORK/fa.json" ]]; then
        TRANSCRIPT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("text",""))' "$WORK/fa.json" 2>/dev/null || true)"
        TRANSCRIPT="$(printf '%s' "$TRANSCRIPT" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
        [[ -n "$TRANSCRIPT" ]] && SOURCE_KIND="transcribed-audio (parakeet-tdt-0.6b-v3)"
      fi
    fi
  fi
fi

# --- no transcript at all ---------------------------------------------------
if [[ -z "$TRANSCRIPT" ]]; then
  echo "CLIPPER_NO_TRANSCRIPT"
  echo "platform: $PLATFORM"
  echo "$META_DISPLAY"
  echo "cookies: $COOKIE_DESC"
  echo "fluidaudio_bin: ${FA_BIN:-(not built)}"
  echo ""
  echo "--- tweet/description text (yt-dlp metadata) ---"
  cat "$WORK/desc.txt" 2>/dev/null || true
  echo ""
  if [[ -z "$FA_BIN" ]]; then
    echo "INSTRUCTIONS: This video has no caption track, and the local Parakeet v3"
    echo "transcriber isn't built yet, so there's nothing to clip faithfully. Tell the"
    echo "user to run '/clipper transcriber install' once (a ~1–3 min one-time build of"
    echo "fluidaudiocli; the Parakeet v3 model then downloads on first use), then re-run"
    echo "this same /clipper command. Offer to instead save just the post's own text"
    echo "(shown above) as a short note. Do NOT invent a transcript. Stop here."
  else
    echo "INSTRUCTIONS: This video has no caption track, and Parakeet v3 transcription"
    echo "produced nothing (see \$WORK/fa.log / audio.log — likely the audio couldn't be"
    echo "downloaded, or ffmpeg is missing). Relay the gist to the user; offer to save"
    echo "just the post's own text (shown above) as a short note. Do NOT invent a"
    echo "transcript. Stop here."
  fi
  exit 0
fi

# --- output path ------------------------------------------------------------
PLATFORM_DIR="$CLIPS_DIR/$PLATFORM"
mkdir -p "$PLATFORM_DIR"
OUT_FILE="$PLATFORM_DIR/$SLUG.md"
if [[ -f "$OUT_FILE" ]]; then
  OUT_FILE="$PLATFORM_DIR/$SLUG-$(date +%Y-%m-%d).md"
  n=2
  while [[ -f "$OUT_FILE" ]]; do
    OUT_FILE="$PLATFORM_DIR/$SLUG-$(date +%Y-%m-%d)-$n.md"
    n=$((n + 1))
  done
fi

WORDS="$(printf '%s' "$TRANSCRIPT" | wc -w | tr -d ' ')"
TODAY="$(date +%Y-%m-%d)"

echo "CLIPPER_SAVE"
echo "platform: $PLATFORM"
echo "$META_DISPLAY"
echo "transcript_source: $SOURCE_KIND"
echo "transcript_words: $WORDS"
echo "cookies: $COOKIE_DESC"
echo "captured: $TODAY"
echo "output_file: $OUT_FILE"
[[ -n "$URL_WARN" ]] && echo "url_warning: $URL_WARN"
echo ""
echo "=== POST / DESCRIPTION TEXT (context — author's own caption) ==="
cat "$WORK/desc.txt" 2>/dev/null || true
echo ""
echo "=== RAW TRANSCRIPT (cleaned: tags + rolling duplicates removed) ==="
printf '%s\n' "$TRANSCRIPT"
echo "=== END TRANSCRIPT ==="
echo ""

# Reframing instructions live in commands/templates/clipper/write.txt.
export OUT_FILE PLATFORM SOURCE_KIND TODAY
envsubst '$OUT_FILE $PLATFORM $SOURCE_KIND $TODAY' < "$_SCRIPT_DIR/templates/clipper/write.txt"

pbrain_emit_self_improve "clipper" || true
