#!/usr/bin/env bash
# journal.bash — the /journal driver for the pbrain e2e framework (PB-89).
#
# Second command on the framework, demonstrating that the rig generalizes beyond
# /plan-my-work. Unlike pmw (Plane-only, writes nothing to the vault), /journal
# writes a REAL markdown artifact to the vault (life/daily-tracking/<date>.md) —
# so the tracking channel here is tracking_kind=vault-file, and the report shows
# the actual file the command produced alongside the chat.
#
# Like pmw, journal.sh is a DISPATCHER: it emits a JSON-ish block
# (JOURNAL_SESSION on a fresh day, JOURNAL_SESSION_RESUME when today's file
# exists) carrying prose steps the AGENT follows to write the file. This driver
# replays the agent's role against the REAL journal.sh:
#   REAL  — commands/journal.sh, real $PBRAIN_VAULT, real persona prefs injection
#           (PBRAIN_PREFS_DIR), and the real dated markdown file it writes.
#   FAKED — nothing network; journal touches only the vault + prefs, already real
#           temp dirs.

set -uo pipefail
source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.bash"

E2E_JDIR=""        # the journal directory (real, under the temp vault)
E2E_OUT_FILE=""    # today's dated file

_journal_sh() {  # run the REAL journal.sh with the dump as its argument
  PBRAIN_JOURNAL_DIR="$E2E_JDIR" \
    bash "$E2E_REAL_ROOT/commands/journal.sh" "$@" 2>>"$E2E_WORK/journal.stderr"
}

# Append a timestamped entry under ## Log (creating the section if absent) —
# exactly what journal.sh's RESUME instructions tell the agent to do.
_append_log_entry() {  # <time> <text>
  python3 - "$E2E_OUT_FILE" "$1" "$2" <<'PY'
import sys
path, t, text = sys.argv[1], sys.argv[2], sys.argv[3]
doc = open(path).read()
entry = "### %s\n\n%s\n" % (t, text)
if "## Log" in doc:
    doc = doc.rstrip() + "\n\n" + entry
else:
    doc = doc.rstrip() + "\n\n## Log\n\n" + entry
open(path, "w").write(doc)
PY
}

# Write the fresh-day skeleton journal.sh's JOURNAL_SESSION instructs (Step 4).
_write_fresh() {  # <today> <focus> <notes> <decisions> <openq>
  python3 - "$E2E_OUT_FILE" "$@" <<'PY'
import sys
path, today, focus, notes, decisions, openq = sys.argv[1:7]
doc = ("---\ntype: daily\ndate: %s\ntags: []\n---\n\n"
       "## Focus\n\n%s\n\n## Notes\n\n%s\n\n## Decisions\n\n%s\n\n"
       "## Open questions\n\n%s\n" % (today, focus, notes, decisions, openq))
open(path, "w").write(doc)
PY
}

# e2e_run_journal <real_root> <scenario> <persona> <out_dir>
e2e_run_journal() {
  e2e_env_setup "$1" "$2" "$3" "$4"
  : >"$E2E_WORK/journal.stderr"
  E2E_JDIR="$PBRAIN_VAULT/life/daily-tracking"
  mkdir -p "$E2E_JDIR"
  local today; today="$(date +%Y-%m-%d)"
  local now; now="$(date +%H:%M)"
  E2E_OUT_FILE="$E2E_JDIR/$today.md"

  local dump reflective followup preexisting
  dump="$(_sc dump)"
  reflective="$(_sc reflective)"
  followup="$(_sc followup)"
  preexisting="$(_sc preexisting)"

  # If the scenario seeds a pre-existing file, lay it down first (RESUME path).
  if [[ -n "$preexisting" && "$preexisting" != "False" ]]; then
    printf '%s\n' "$preexisting" >"$E2E_OUT_FILE"
    e2e_note "seeded a pre-existing journal for today (RESUME path)"
  fi

  # 1) The human's brain-dump.
  e2e_user "$dump"

  # 2) Run the REAL journal.sh with the dump; capture the emitted block.
  local block marker
  block="$(_journal_sh "$dump")"
  if [[ -n "$preexisting" && "$preexisting" != "False" ]]; then
    marker="JOURNAL_SESSION_RESUME"
  else
    marker="JOURNAL_SESSION"
  fi
  e2e_cmd "journal \"$dump\""
  e2e_assert "journal.sh emitted $marker" grep -q "$marker" <<<"$block"
  e2e_assert "dump ingested (dump_provided: yes)" grep -q "dump_provided: yes" <<<"$block"
  # PB-37: prefs reached the command (persona prefs injected). The prefs block is
  # emitted only when a prefs file exists — which we always inject.
  e2e_assert "persona prefs surfaced to journal (CHAT OUTPUT HYGIENE baseline)" \
    grep -qiE "preference|hygiene|prefs" <<<"$block"

  # 3) Reflective entries get exactly ONE follow-up; factual logs get none.
  if [[ "$reflective" == "True" || "$reflective" == "true" ]]; then
    e2e_say journal "one thing — $(_sc question)"
    e2e_user "$followup"
    e2e_note "reflective: exactly one follow-up asked"
  else
    e2e_say journal "got it."
    e2e_note "factual: no follow-up (quiet log)"
  fi

  # 4) Write the artifact the way the instructions say.
  if [[ -n "$preexisting" && "$preexisting" != "False" ]]; then
    _append_log_entry "$now" "$dump${followup:+ — $followup}"
    e2e_say journal "appended a timestamped entry under ## Log"
  else
    _write_fresh "$today" \
      "$(_sc focus)" "$dump" "$(_sc decisions)" "$(_sc openq)"
    # the first log line of the day also lands under ## Log
    _append_log_entry "$now" "$dump${followup:+ — $followup}"
    e2e_say journal "wrote today's journal with Focus/Notes/Decisions/Open questions + a Log entry"
  fi

  # --- assertions on the REAL artifact -------------------------------------
  e2e_assert "dated journal file exists" test -f "$E2E_OUT_FILE"
  e2e_assert "file has a ## Log section" grep -q "## Log" "$E2E_OUT_FILE"
  e2e_assert "file has a ### timestamp entry" grep -qE "^### [0-9]{2}:[0-9]{2}" "$E2E_OUT_FILE"
  if [[ -n "$preexisting" && "$preexisting" != "False" ]]; then
    # resume must NOT clobber the existing curated sections
    e2e_assert "resume preserved the pre-existing ## Focus line" \
      grep -q "PRESERVE-ME-FOCUS" "$E2E_OUT_FILE"
    e2e_assert "resume preserved the earlier ### 09:00 entry" \
      grep -q "### 09:00" "$E2E_OUT_FILE"
  else
    for sec in Focus Notes Decisions "Open questions"; do
      e2e_assert "fresh file has ## $sec" grep -q "## $sec" "$E2E_OUT_FILE"
    done
  fi
  # follow-up discipline: a factual scenario must have NO follow-up turn.
  if [[ "$reflective" != "True" && "$reflective" != "true" ]]; then
    local fups; fups="$(grep -c 'one thing —' "$E2E_TRANSCRIPT" || true)"
    e2e_assert "factual log → no follow-up question" test "$fups" -eq 0
  fi
  e2e_assert "no unexpected stderr from journal.sh" test ! -s "$E2E_WORK/journal.stderr"

  # Expectation: journal scenarios just expect the file to exist with a log
  # entry. `expect` is "logged" (vs pmw's done/park).
  e2e_assert "reached expected terminal ($(_sc expect))" _judge_journal

  e2e_fold_parse_fails
  local pass="true"; [[ ${#E2E_FAILURES[@]} -eq 0 ]] || pass="false"

  # Tracking channel = the real vault file.
  local artifact; artifact="$E2E_OUT_FILE"$'\n---\n'"$(cat "$E2E_OUT_FILE")"
  e2e_emit_result "$pass" "vault-file" "" "$artifact"
  rm -rf "$E2E_WORK"
  [[ "$pass" == "true" ]]
}

# journal terminal: "logged" iff the dated file exists with a ### entry.
_judge_journal() {
  local expect; expect="$(_sc expect)"
  case "$expect" in
    logged) test -f "$E2E_OUT_FILE" && grep -qE "^### [0-9]{2}:[0-9]{2}" "$E2E_OUT_FILE" ;;
    *) return 1 ;;
  esac
}
