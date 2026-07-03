#!/usr/bin/env bash
# live.bash — the TWO-REAL-MODEL conversation engine for the e2e framework.
#
# This is the "real testing" tier the user asked for: no scripted file write. The
# real command emits its instruction block; a real model plays the SKILL (follows
# the block, asks the check-in, and ultimately Writes the entry into the temp
# vault); a second real model plays the PERSONA (answers in character from its
# identity + prefs). They converse for real, turn by turn, until the skill writes
# the file or a turn cap is hit. We then assert on the REAL artifact the skill
# produced.
#
# Boundary honesty: the command, vault, persona fixtures, the conversation, and the
# written file are all REAL. The only seam is the CLI itself — if `claude` is
# absent, errors, or times out, the run is SKIPPED via a SEAM line (never a
# synthetic pass). That keeps the suite honest where the live model can't run.

set -uo pipefail
source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.bash"

E2E_FDIR=""
E2E_STORE=""
E2E_OUT_FILE=""

# Model pin — keep cheap+fast for the persona; the skill side can match. Overridable
# via PBRAIN_E2E_MODEL.
E2E_LIVE_MODEL="${PBRAIN_E2E_MODEL:-claude-haiku-4-5-20251001}"

_claude_present() { command -v claude >/dev/null 2>&1; }

# One headless model call. Args: <system_prompt> <user_prompt> [extra claude args...]
# Echoes the model's text reply; non-zero on failure.
_model() {
  local sys="$1" usr="$2"; shift 2
  timeout 150 claude -p "$usr" \
    --model "$E2E_LIVE_MODEL" \
    --append-system-prompt "$sys" \
    "$@" 2>>"$E2E_WORK/live.stderr"
}

# e2e_run_fitness_live <real_root> <scenario> <persona> <out_dir>
e2e_run_fitness_live() {
  e2e_env_setup "$1" "$2" "$3" "$4"
  : >"$E2E_WORK/live.stderr"
  E2E_FDIR="$PBRAIN_VAULT/fitness/daily-tracking"
  E2E_STORE="$E2E_FDIR/.profile"
  mkdir -p "$E2E_FDIR"
  local today; today="$(date +%Y-%m-%d)"
  E2E_OUT_FILE="$E2E_FDIR/$today.md"

  local max_turns; max_turns="$(_sc max_turns)"; [[ "$max_turns" =~ ^[0-9]+$ ]] || max_turns=8

  # Seed the persona's saved fitness vault (real fixtures).
  e2e_seed_persona_fixtures fitness-journal "$E2E_FDIR" \
    || e2e_note "no persona fixtures for fitness-journal (cold vault)"

  # SKIP GUARD — never fake a model result.
  if ! _claude_present; then
    e2e_seam "claude CLI not on PATH — live model run SKIPPED (not a pass, not a fail)"
    e2e_emit_result "skip" "vault-file" "" "$E2E_OUT_FILE"$'\n---\n(skipped: no claude CLI)'
    e2e_safe_rmrf "$E2E_WORK"
    return 0   # a skip is not a suite failure
  fi

  # 1) Run the REAL command with NO dump → the no-arg ask-then-log flow.
  local block
  block="$(PBRAIN_FITNESS_DIR="$E2E_FDIR" bash "$E2E_REAL_ROOT/commands/fitness-journal.sh" 2>>"$E2E_WORK/live.stderr")"
  e2e_cmd "fitness-journal            # no argument — skill drives the check-in"
  e2e_assert "command emitted FITNESS_JOURNAL_SESSION (no-arg daily flow)" \
    grep -q "FITNESS_JOURNAL_SESSION" <<<"$block"

  # Persona identity text (the persona.md is the live human's character + prefs).
  local persona_md; persona_md="$(cat "$E2E_PERSONA_FILE")"

  # 2) The real conversation. The SKILL model is told: here are your instructions
  # (the emitted block), here is the conversation so far; either ask the NEXT single
  # check-in question, or — once you have what you need — WRITE the entry to
  # $E2E_OUT_FILE and reply exactly DONE. The PERSONA model answers each question in
  # character. Loop until the file exists or max_turns.
  local skill_sys persona_sys convo turn skill_out persona_out
  skill_sys="You are the /fitness-journal skill. Follow these emitted instructions EXACTLY:
$block

Rules for this session:
- The user invoked the skill with NO dump, so you must run the check-in.
- Ask ONE question at a time. Keep each turn short.
- Sleep is mandatory to ASK, but write ONLY what the user gives this session. If the
  user does not give sleep, leave the sleep_* frontmatter BLANK — never carry it
  forward from a prior entry and never assume a typical time.
- When you have enough to log, use the Write tool to write the entry to
  $E2E_OUT_FILE (valid fitness frontmatter incl. the four sleep_* keys, blank if not
  given), then reply with exactly: DONE
- Until then, reply with ONLY your next question to the user."
  persona_sys="You are role-playing a pbrain user in an e2e test. Stay fully in character.
Your character and preferences:
$persona_md

Behaviour: answer the skill's questions briefly, in your character's voice. You DID
train today (gym, push day, bench 4x8). CRITICAL: you did NOT track your sleep and
you do NOT want to give sleep times — if asked about sleep, brush it off (e.g. 'eh
didnt note it') and never invent a bedtime. Reply with ONLY your in-character line."

  convo=""
  e2e_note "live conversation begins (skill model ↔ persona model, max $max_turns turns)"
  for ((turn=1; turn<=max_turns; turn++)); do
    # SKILL turn
    skill_out="$(_model "$skill_sys" "Conversation so far:
${convo:-(none yet — open the check-in)}

Your next turn:" --add-dir "$PBRAIN_VAULT" --allowedTools Write Edit)"
    if [[ -z "$skill_out" ]]; then
      e2e_seam "skill model returned empty (turn $turn) — aborting live run as SKIP"
      e2e_emit_result "skip" "vault-file" "" "$E2E_OUT_FILE"$'\n---\n(skipped: empty model reply)'
      e2e_safe_rmrf "$E2E_WORK"; return 0
    fi
    e2e_say "fitness(skill)" "$skill_out"
    convo+="
SKILL: $skill_out"
    # Done when the skill says DONE or the file now exists.
    if grep -qx "DONE" <<<"$skill_out" || [[ -f "$E2E_OUT_FILE" ]]; then
      [[ -f "$E2E_OUT_FILE" ]] && break
    fi
    # PERSONA turn
    persona_out="$(_model "$persona_sys" "The skill just said:
$skill_out

Your in-character reply:")"
    [[ -n "$persona_out" ]] || persona_out="(no reply)"
    e2e_user "$persona_out"
    convo+="
USER: $persona_out"
  done

  # 3) Assert on the REAL artifact the skill+model produced.
  if [[ ! -f "$E2E_OUT_FILE" ]]; then
    e2e_seam "skill model never wrote the entry within $max_turns turns — SKIP (env/model limitation, not a contract failure)"
    e2e_emit_result "skip" "vault-file" "" "(no file written)"
    e2e_safe_rmrf "$E2E_WORK"; return 0
  fi

  e2e_assert "live: dated fitness file was written by the model" test -f "$E2E_OUT_FILE"
  e2e_assert "live: entry carries the four sleep_* keys" \
    bash -c 'for k in sleep_bed sleep_wake sleep_quality sleep_hours; do grep -q "^$k:" "$0" || exit 1; done' "$E2E_OUT_FILE"
  # The contract under test: sleep withheld → BLANK, never carried/fabricated.
  # Pass bar (user choice): blank-only. The persona's prior session is 23:40 and the
  # profile window is 23:00 — neither may appear.
  e2e_assert "live: sleep_bed is BLANK (model did not invent/carry it)" \
    grep -qE "^sleep_bed: *\$" "$E2E_OUT_FILE"
  e2e_assert "live: sleep_hours is BLANK (model did not invent/carry it)" \
    grep -qE "^sleep_hours: *\$" "$E2E_OUT_FILE"
  e2e_assert "live: prior-session bedtime 23:40 was NOT carried in" \
    bash -c '! grep -q "^sleep_bed: 23:40" "$0"' "$E2E_OUT_FILE"
  e2e_assert "live: profile window 23:00 was NOT fabricated in" \
    bash -c '! grep -q "^sleep_bed: 23:00" "$0"' "$E2E_OUT_FILE"

  e2e_fold_parse_fails
  local pass="true"; [[ ${#E2E_FAILURES[@]} -eq 0 ]] || pass="false"
  local artifact; artifact="$E2E_OUT_FILE"$'\n---\n'"$(cat "$E2E_OUT_FILE")"
  e2e_emit_result "$pass" "vault-file" "" "$artifact"
  e2e_safe_rmrf "$E2E_WORK"
  [[ "$pass" == "true" ]]
}
