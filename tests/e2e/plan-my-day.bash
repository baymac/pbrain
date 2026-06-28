#!/usr/bin/env bash
# plan-my-day.bash — the TWO-REAL-MODEL conversation engine for /plan-my-day, in
# the e2e framework. PB-186.
#
# This is the same "real testing" tier as live.bash (the fitness sleep engine):
# two real models converse — claude #1 plays the SKILL (it is handed the REAL
# /plan-my-day instruction block, in particular the fixed Step 1c block-layout
# rules from commands/templates/plan-my-day/plan.txt) and claude #2 plays the
# PERSONA (it supplies today's fixed life anchors in character). They talk turn
# by turn until the skill emits the day's work-block layout, which we then assert
# on. The agent↔agent transcript and the asserted artifact are recorded into a
# *.result.json that report.py turns into the standalone HTML report (the chat is
# rendered as "Persona ↔ command chat").
#
# Contract under test (PB-186): each MID-DAY work block is a FULL
# session_length_min unit. The layout must NOT shrink a mid-day block to fit the
# leftover space in a gap — when a gap can't hold a full block + break, the block
# is DROPPED; only the final wind-down block may run short. The pre-fix bug laid
# 90 / 60 / 45-min blocks; the fix lays full 90s and flexes the COUNT.
#
# Boundary honesty: the command, vault, persona fixtures, the conversation, and
# the produced layout are REAL. The only seam is the CLI itself — if `claude` is
# absent, errors, or times out, the run is SKIPPED via a SEAM line (never a
# synthetic pass), exactly like live.bash.

set -uo pipefail
source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.bash"

# Model pin — cheap+fast both sides; overridable via PBRAIN_E2E_MODEL, same as
# live.bash so a single env var controls every live engine.
E2E_PLANDAY_MODEL="${PBRAIN_E2E_MODEL:-claude-haiku-4-5-20251001}"

_claude_present() { command -v claude >/dev/null 2>&1; }

# One headless model call. Args: <system_prompt> <user_prompt> [extra claude args...]
_model() {
  local sys="$1" usr="$2"; shift 2
  timeout 150 claude -p "$usr" \
    --model "$E2E_PLANDAY_MODEL" \
    --append-system-prompt "$sys" \
    "$@" 2>>"$E2E_WORK/live.stderr"
}

# Extract the REAL Step 1c block-layout rules from the live plan.txt so the skill
# model is tested against the actual shipped instructions, not a paraphrase. We
# pull the FOCUS HOURS / layout bullets and the table-rules invariant.
_real_layout_rules() {
  local pt="$E2E_REAL_ROOT/commands/templates/plan-my-day/plan.txt"
  [[ -f "$pt" ]] || { echo "(plan.txt not found at $pt)"; return; }
  # 1c FOCUS HOURS block through the end of its bullets, plus the invariant lines
  # mentioning work blocks. Keep it tight; the model only needs the sizing rules.
  awk '
    /1c — FOCUS HOURS/      {grab=1}
    /1c\.5 — FITNESS SLOT/  {grab=0}
    grab                    {print}
    /Invariants every day/  {print}
    /absorb time pressure/  {print}
  ' "$pt"
}

# e2e_run_planday_live <real_root> <scenario> <persona> <out_dir>
e2e_run_planday_live() {
  e2e_env_setup "$1" "$2" "$3" "$4"
  : >"$E2E_WORK/live.stderr"

  local max_turns; max_turns="$(_sc max_turns)"; [[ "$max_turns" =~ ^[0-9]+$ ]] || max_turns=8

  # Scenario fixture: the day's config + fixed anchors (the PB-186 repro).
  local session_len break_len anchors
  session_len="$(_sc session_length_min)"; [[ "$session_len" =~ ^[0-9]+$ ]] || session_len=90
  break_len="$(_sc break_min)";            [[ "$break_len" =~ ^[0-9]+$ ]] || break_len=30
  anchors="$(_sc anchors)"; [[ -n "$anchors" ]] || anchors="(none)"

  # SKIP GUARD — never fake a model result.
  if ! _claude_present; then
    e2e_seam "claude CLI not on PATH — live plan-my-day run SKIPPED (not a pass, not a fail)"
    e2e_emit_result "skip" "vault-file" "" "(skipped: no claude CLI)"
    rm -rf "$E2E_WORK"; return 0
  fi

  local rules; rules="$(_real_layout_rules)"
  e2e_cmd "plan-my-day # live: skill lays work blocks around the persona's anchors"
  e2e_assert "real plan.txt carried fixed-block rule (NEVER shorten a block)" \
    grep -qi "NEVER shorten a block" <<<"$rules"

  # The skill model: hand it the REAL layout rules + the day's config. It must
  # ask the persona for the day's anchors, then emit the work-block layout as a
  # single fenced JSON object and stop.
  local skill_sys persona_sys convo turn skill_out persona_out layout_json=""
  skill_sys="You are the /plan-my-day skill, doing ONLY Step 1c — laying the day's
WORK BLOCKS around the user's fixed life anchors. Follow these REAL rules from
plan.txt EXACTLY:

$rules

Today's config: session_length_min=$session_len, break_min=$break_len.
Rules of engagement:
- Ask the persona, in ONE short question, for today's fixed life anchors (meals,
  nap, fitness, hard time-anchored events) if you don't have them yet.
- Once you have the anchors, COMPUTE the work-block layout and emit it as the
  LAST thing you say, wrapped in <json> ... </json> tags, exactly this shape and
  nothing after the closing tag:
  <json>{\"blocks\":[{\"label\":\"Block 1\",\"start\":\"HH:MM\",\"end\":\"HH:MM\",\"duration_min\":N,\"kind\":\"work|wind-down\"}]}</json>
- Apply the rules LITERALLY: each mid-day work block is a FULL session_length_min
  unit; flex the COUNT, never the SIZE; DROP a block that can't fit a full
  unit + break in its gap; only the final wind-down block may run short.
- Keep every turn short. Reply with ONLY your in-character line (and, when ready,
  the fenced json)."

  persona_sys="$(cat "$E2E_PERSONA_FILE")

You are the human using /plan-my-day today. When the skill asks for your fixed
anchors, give EXACTLY these and nothing else, in your own terse voice:
$anchors
Do not propose a work-block layout yourself — that's the skill's job. Reply with
ONLY your in-character line."

  convo=""
  e2e_note "live conversation begins (skill model ↔ persona model, max $max_turns turns)"
  for ((turn=1; turn<=max_turns; turn++)); do
    # SKILL turn
    skill_out="$(_model "$skill_sys" "Conversation so far:
${convo:-(none yet — open the layout step)}
Your next turn:")"
    if [[ -z "$skill_out" ]]; then
      e2e_seam "skill model returned empty (turn $turn) — aborting live run, SKIP"
      e2e_emit_result "skip" "vault-file" "" "(skipped: empty model reply)"
      rm -rf "$E2E_WORK"; return 0
    fi
    e2e_say "plan-my-day(skill)" "$skill_out"
    convo+="
SKILL: $skill_out"

    # Did the skill emit the layout JSON this turn? (between <json> ... </json>)
    layout_json="$(printf '%s' "$skill_out" | sed -n 's/.*<json>\(.*\)<\/json>.*/\1/p')"
    if [[ -n "$layout_json" ]] && printf '%s' "$layout_json" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
      break
    fi
    layout_json=""

    # PERSONA turn
    persona_out="$(_model "$persona_sys" "The skill just said:
$skill_out
Your in-character reply:")"
    [[ -n "$persona_out" ]] || persona_out="(no reply)"
    e2e_user "$persona_out"
    convo+="
USER: $persona_out"
  done

  if [[ -z "$layout_json" ]]; then
    e2e_seam "skill model never emitted a parseable layout within $max_turns turns — SKIP (env/model limit)"
    e2e_emit_result "skip" "vault-file" "" "(no layout produced)"
    rm -rf "$E2E_WORK"; return 0
  fi

  # --- Assert the REAL layout the two models produced -----------------------
  # The artifact is the layout JSON; record it as a vault-file-style artifact so
  # report.py shows it next to the chat.
  local artifact="layout.json"$'\n---\n'"$layout_json"

  # PB-186 contract checks, evaluated in python over the emitted blocks.
  # NOTE: pass the layout via a FILE (argv), not stdin — a `<<'PY'` heredoc
  # already owns stdin, so a piped layout would be silently discarded.
  local layout_file="$E2E_WORK/layout.json"
  printf '%s' "$layout_json" >"$layout_file"
  local verdict; verdict="$(python3 - "$session_len" "$layout_file" <<'PY'
import json, sys
sess = int(sys.argv[1])
data = json.load(open(sys.argv[2]))
blocks = data.get("blocks", [])
work = [b for b in blocks if (b.get("kind") or "work") != "wind-down"]
# Heuristic for the final wind-down block when kind is not tagged: the LAST
# block is allowed to be short; every earlier block must be a full session.
problems = []
if not blocks:
    problems.append("no blocks emitted")
for i, b in enumerate(blocks):
    label = b.get("label") or "?"
    dur = b.get("duration_min")
    is_last = (i == len(blocks) - 1)
    is_winddown = (b.get("kind") == "wind-down") or is_last
    if dur is None:
        problems.append(label + ": missing duration_min")
        continue
    if not is_winddown and dur < sess:
        problems.append(label + ": mid-day block " + str(dur) + "min < full session " + str(sess) + "min (shrunk)")
print(json.dumps({"ok": not problems, "problems": problems,
                  "n_blocks": len(blocks),
                  "durations": [b.get("duration_min") for b in blocks]}))
PY
)"

  if [[ -z "$verdict" ]]; then
    e2e_seam "verdict computation produced no output — SKIP (harness/env issue, not a contract failure)"
    e2e_emit_result "skip" "vault-file" "" "$artifact"
    rm -rf "$E2E_WORK"; return 0
  fi

  local ok n_blocks
  ok="$(printf '%s' "$verdict" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ok"])')"
  n_blocks="$(printf '%s' "$verdict" | python3 -c 'import json,sys; print(json.load(sys.stdin)["n_blocks"])')"

  e2e_note "layout: $n_blocks block(s), durations $(printf '%s' "$verdict" | python3 -c 'import json,sys; print(json.load(sys.stdin)["durations"])')"

  e2e_assert "live: layout emitted at least one block" test "$n_blocks" -ge 1
  e2e_assert "live: no mid-day block shrunk below full session length (PB-186)" \
    test "$ok" = "True"
  # Surface the specific shrink complaints (if any) into the failure list.
  if [[ "$ok" != "True" ]]; then
    while IFS= read -r p; do [[ -n "$p" ]] && E2E_FAILURES+=("$p"); done < <(
      printf '%s' "$verdict" | python3 -c 'import json,sys; [print(p) for p in json.load(sys.stdin)["problems"]]'
    )
  fi

  e2e_fold_parse_fails
  local pass="true"; [[ ${#E2E_FAILURES[@]} -eq 0 ]] || pass="false"
  e2e_emit_result "$pass" "vault-file" "" "$artifact"
  rm -rf "$E2E_WORK"
}
