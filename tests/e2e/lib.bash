#!/usr/bin/env bash
# lib.bash — shared rig for the pbrain e2e framework (PB-89).
#
# This is the command-AGNOSTIC core that every per-command driver builds on:
#   - transcript helpers (the persona ↔ command chat, in chat form)
#   - assertions + subshell-safe failure capture
#   - persona voice: messy free-text utterances + an asserted intent parser
#   - the real env scaffold (temp vault/DB/config + persona prefs injection)
#   - generic scenario accessor (_sc)
#   - result emission for the HTML reporter, with a generic `tracking` channel
#     (tracking_kind ∈ plane-journal | vault-file | db-rows) so each command can
#     show ITS tracking artifact alongside the chat.
#
# A driver (e.g. harness.bash = /plan-my-work, journal.bash = /journal) sources
# this, calls e2e_env_setup, replays its command's loop using these helpers, then
# calls e2e_emit_result. Drivers own only their command's state machine.

set -uo pipefail

# --- run-scoped state shared by all drivers ---------------------------------
E2E_REAL_ROOT=""        # the real pbrain checkout (worktree) root
E2E_WORK=""             # per-run tempdir
E2E_SCENARIO_FILE=""    # scenario json
E2E_PERSONA_FILE=""     # persona md (prefs + e2e_voice bank)
E2E_PERSONA_NAME=""     # persona label on the human turns
E2E_TRANSCRIPT=""       # chat transcript file
E2E_PARSE_FAILS=""      # intent-parse mismatches (subshell-safe; folded into verdict)
E2E_RESULT=""           # result JSON path for the reporter
E2E_FAILURES=()         # assertion failures this run
E2E_SEAMS=()            # SEAM callouts (boundaries the harness doesn't cross)

# --- transcript helpers (chat form) -----------------------------------------
_tr() { printf '%s\n' "$*" >>"$E2E_TRANSCRIPT"; }
e2e_user()  { _tr "🧑 $E2E_PERSONA_NAME: $*"; }   # a human turn
e2e_say()   { _tr "🤖 $1: $2"; }                   # a command turn: e2e_say <cmd> <text>
e2e_cmd()   { _tr "   \$ $*"; }
e2e_note()  { _tr "   · $*"; }
e2e_seam()  { E2E_SEAMS+=("$*"); _tr "   ⚠ SEAM (real-run only, not verified here): $*"; }

# --- assertions -------------------------------------------------------------
e2e_assert() {  # e2e_assert "<desc>" <cmd...>   (cmd's exit status is the check)
  local desc="$1"; shift
  if "$@"; then _tr "   ✓ $desc"; return 0; fi
  E2E_FAILURES+=("$desc"); _tr "   ✗ $desc"; return 1
}

# --- generic scenario accessor ----------------------------------------------
_sc() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2],""))' "$E2E_SCENARIO_FILE" "$1"; }

# --- persona voice: free-text utterances + asserted intent ------------------
# A persona prefs file may carry an `e2e_voice:` bank, one row per stage:
#     <stage>  <intent>  | <messy human utterance>
# The utterance is shown in the transcript (real human chat); the intent column
# (go|hold|confirm) is GROUND TRUTH. _say emits the utterance, runs the intent
# parser on it, and ASSERTS the parse matches the ground truth — so a free-text
# line the parser would misread is a CAUGHT failure, never a silently-wrong gate.
# Routing then uses the ground-truth intent, keeping the suite deterministic
# while still exercising (and proving) the parser.

# _persona_line <stage> → "<intent>\t<utterance>" (default: hold + a vague line).
_persona_line() {
  local stage="$1" row
  row="$(grep -E "^[[:space:]]+$stage[[:space:]]+(go|hold|confirm)[[:space:]]*\|" \
           "$E2E_PERSONA_FILE" 2>/dev/null | head -1)"
  if [[ -z "$row" ]]; then printf 'hold\thmm not sure, hold off\n'; return; fi
  local intent utter
  intent="$(sed -E 's/^[[:space:]]+[a-z]+[[:space:]]+(go|hold|confirm).*/\1/' <<<"$row")"
  utter="$(sed -E 's/^[^|]*\|[[:space:]]*//' <<<"$row")"
  printf '%s\t%s\n' "$intent" "$utter"
}

# _parse_intent "<utterance>" → go | hold | confirm  (the inferer under test).
_parse_intent() {
  local t; t="$(tr '[:upper:]' '[:lower:]' <<<"$1")"
  if grep -qE '\b(merge|land)\b' <<<"$t" && ! grep -qE "\b(dont|don't|do not|not|never|no)\b[^.]*\b(merge|land)\b" <<<"$t"; then
    printf 'confirm\n'; return
  fi
  if grep -qE "\b(dont|don't|do not|not yet|not |never|wait|hold|stop|idk|hmm|hmmm|nah|no )\b" <<<"$t"; then
    printf 'hold\n'; return
  fi
  if grep -qE "\b(go|yes|yep|yeah|ye|yup|lgtm|sure|kk|ok|okay|fine|ahead)\b" <<<"$t" \
     || grep -qE '\b(do it|ship it|run it|run the|build it|open the pr)\b' <<<"$t"; then
    printf 'go\n'; return
  fi
  printf 'hold\n'
}

# _say <stage> → emits the persona's line as chat, checks the intent parse, and
# returns the ground-truth intent on stdout. Subshell-safe: the transcript line
# and any parse-mismatch go to FILES; e2e_emit_result folds $E2E_PARSE_FAILS into
# the verdict (a write to E2E_FAILURES here would be lost in command-sub).
_say() {
  local stage="$1" line intent utter parsed
  line="$(_persona_line "$stage")"
  intent="${line%%$'\t'*}"; utter="${line#*$'\t'}"
  _tr "🧑 $E2E_PERSONA_NAME: $utter"
  parsed="$(_parse_intent "$utter")"
  if [[ "$parsed" == "$intent" ]]; then
    _tr "   ✓ intent parse matches ground truth ($stage: '$utter' → $intent)"
  else
    _tr "   ✗ intent parse MISMATCH ($stage: '$utter' → parsed=$parsed, expected=$intent)"
    printf '%s\n' "intent parse mismatch ($stage: '$utter' → $parsed != $intent)" >>"$E2E_PARSE_FAILS"
  fi
  printf '%s\n' "$intent"
}
_say_advances() { local i; i="$(_say "$1")"; [[ "$i" == "go" || "$i" == "confirm" ]]; }

# --- env scaffold (real temp vault / DB / config + persona prefs) -----------
# e2e_env_setup <real_root> <scenario_file> <persona_file> <out_dir>
# Sets the shared run-scoped state, creates the temp dirs, injects persona prefs,
# and exports the quiet PBRAIN_* flags. Drivers add their own extras after.
# Sets E2E_SNAME / E2E_PNAME for the caller.
E2E_SNAME=""; E2E_PNAME=""
e2e_env_setup() {
  E2E_REAL_ROOT="$1"; E2E_SCENARIO_FILE="$2"; E2E_PERSONA_FILE="$3"
  local outdir="$4"
  E2E_SNAME="$(basename "$E2E_SCENARIO_FILE" .json)"
  # Persona name: a per-persona dir is .../<name>/persona.md (the new layout), so
  # take the PARENT dir name there; a flat <name>.md (legacy) uses its basename.
  if [[ "$(basename "$E2E_PERSONA_FILE")" == "persona.md" ]]; then
    E2E_PNAME="$(basename "$(dirname "$E2E_PERSONA_FILE")")"
  else
    E2E_PNAME="$(basename "$E2E_PERSONA_FILE" .md)"
  fi
  E2E_PERSONA_NAME="$E2E_PNAME"

  E2E_WORK="$(mktemp -d)"
  E2E_TRANSCRIPT="$E2E_WORK/transcript.txt"
  E2E_PARSE_FAILS="$E2E_WORK/parse-fails.txt"
  E2E_RESULT="$outdir/${E2E_SNAME}__${E2E_PNAME}.result.json"
  E2E_FAILURES=(); E2E_SEAMS=()
  : >"$E2E_TRANSCRIPT"; : >"$E2E_PARSE_FAILS"
  mkdir -p "$outdir"

  export XDG_CONFIG_HOME="$E2E_WORK/config"; mkdir -p "$XDG_CONFIG_HOME/pbrain"
  export PBRAIN_VAULT="$E2E_WORK/vault"; mkdir -p "$PBRAIN_VAULT"
  export PBRAIN_DB_FILE="$E2E_WORK/pbrain.db"
  export PBRAIN_MIGRATIONS=0 PBRAIN_UPDATE_CHECK=0 PBRAIN_SELF_IMPROVE=off PBRAIN_NO_AUTOVAULT=1
  # Persona prefs injection (real seam): the persona file IS the _global prefs.
  export PBRAIN_PREFS_DIR="$E2E_WORK/prefs"; mkdir -p "$PBRAIN_PREFS_DIR/_global"
  cp "$E2E_PERSONA_FILE" "$PBRAIN_PREFS_DIR/_global/prefs.md"

  _tr "# e2e run — scenario: $E2E_SNAME | persona: $E2E_PNAME"
  _tr "# expect: $(_sc expect)"
  _tr ""
}

# Seed the persona's per-command fixtures into the real temp vault, if any. A
# persona dir holds fixtures/<command>/ — a ready-made vault subtree (profile,
# library, prior sessions). Copying it makes the real skill run against this
# persona's pre-populated vault instead of an inline stub. No-op when the persona
# has no fixtures for this command (first-run/setup path). Returns 0 if seeded.
# e2e_seed_persona_fixtures <command> <dest_dir_under_vault>
e2e_seed_persona_fixtures() {
  local command="$1" dest="$2"
  local persona_dir; persona_dir="$(dirname "$E2E_PERSONA_FILE")"
  local fx="$persona_dir/fixtures/$command"
  [[ -d "$fx" ]] || return 1
  mkdir -p "$dest"
  # copy contents (including dotfiles like .profile) into dest
  cp -R "$fx/." "$dest/"
  e2e_note "seeded $E2E_PNAME's $command fixtures into the vault ($(cd "$fx" && find . -type f | wc -l | tr -d ' ') files)"
  return 0
}

# Fold subshell-recorded parse mismatches into the failure list. Call once before
# computing pass/fail.
e2e_fold_parse_fails() {
  if [[ -s "$E2E_PARSE_FAILS" ]]; then
    while IFS= read -r pf; do [[ -n "$pf" ]] && E2E_FAILURES+=("$pf"); done <"$E2E_PARSE_FAILS"
  fi
}

# --- result emission --------------------------------------------------------
# e2e_emit_result <pass:true|false|skip> <tracking_kind> <tracking_json_path> <artifact>
#   tracking_kind: plane-journal | vault-file | db-rows
#   tracking_json_path: a file of JSON-lines (plane-journal/db-rows) or ""
#   artifact: a string (vault-file: "<path>\n---\n<contents>"); or ""
#   pass "skip": a real third state (e.g. live model unavailable) — recorded as
#     skipped:true and NOT counted as a failure (the report badges it distinctly).
# Writes the base result JSON, then _emit_arrays_json fills failures/seams
# precisely (one element per entry, no space-splitting).
e2e_emit_result() {
  local pass="$1" kind="$2" tjson="$3" artifact="$4"
  python3 - "$E2E_RESULT" "$E2E_SNAME" "$E2E_PNAME" "$pass" "$E2E_TRANSCRIPT" \
           "$(_sc expect)" "$(_sc display)" "$kind" "${tjson:-}" "${artifact:-}" <<'PY'
import json, sys
(out, sname, pname, passed, tpath, expect, display, kind, tjson, artifact) = sys.argv[1:11]
transcript = open(tpath).read() if tpath else ""
tracking = []
if tjson:
    try:
        tracking = [json.loads(l) for l in open(tjson) if l.strip()]
    except Exception:
        tracking = []
skipped = (passed == "skip")
json.dump({
    "scenario": sname, "persona": pname,
    "passed": (passed == "true") or skipped,
    "skipped": skipped,
    "expect": expect, "display": display or sname,
    "transcript": transcript,
    "tracking_kind": kind, "tracking": tracking, "artifact": artifact,
    "failures": [], "seams": [],
}, open(out, "w"), indent=2)
PY
  _emit_arrays_json
  cp "$E2E_TRANSCRIPT" "${E2E_RESULT%.result.json}.transcript.txt"
}

# Overwrite failures/seams precisely (NUL-delimited so spaces in descriptions
# don't split), keeping the rest of the result JSON intact.
_emit_arrays_json() {
  {
    printf '%s\0' "$E2E_RESULT"
    printf 'FAILURES\0'; local f; for f in "${E2E_FAILURES[@]:-}"; do printf '%s\0' "$f"; done
    printf 'SEAMS\0'; for f in "${E2E_SEAMS[@]:-}"; do printf '%s\0' "$f"; done
  } | python3 -c '
import json, sys
parts = [p.decode() for p in sys.stdin.buffer.read().split(b"\x00")]
path = parts[0]
i = parts.index("FAILURES"); j = parts.index("SEAMS")
data = json.load(open(path))
data["failures"] = [p for p in parts[i+1:j] if p]
data["seams"] = [p for p in parts[j+1:] if p]
json.dump(data, open(path, "w"), indent=2)
'
}
