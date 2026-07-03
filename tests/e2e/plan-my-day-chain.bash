#!/usr/bin/env bash
# plan-my-day-chain.bash — CHAIN MODE for the live e2e (PB-165).
#
# Sourced by plan-my-day-live.sh when --chain / PBRAIN_E2E_CHAIN=1. It turns the
# single plan-my-day replay into the CONNECTED pipeline the user asked for:
#
#   extract_facts  → read the user's REAL today files (journal / fitness / diet /
#                    plan) into a facts blob, BEFORE anything is deleted. Facts
#                    only — the persona later rephrases them naturally.
#   reset_outputs  → delete today's OUTPUT for each touched command in the SNAPSHOT
#                    (guarded), so each regenerates via its NEW-day token.
#   chain_replay   → run journal → fitness-journal → diet-journal LIVE, in order,
#                    each persona INSPIRED by the facts, each writing its dated file;
#                    then hand off to the engine's existing `replay` for plan-my-day,
#                    which now reads the fresh fitness `**When**` + diet anchors.
#
# It relies on functions/vars from the parent engine: SANDBOX, TODAY, MODEL,
# log(), _safe_rmrf(), and the parent's `replay` (for the plan-my-day leg). The
# whole run is pinned to TARGET_DATE via PBRAIN_TODAY_OVERRIDE (exported already).
#
# Everything runs inside the throwaway SANDBOX — the real vault is never touched.

# --------------------------------------------------------------------------
# Fact extraction. Reads the real (snapshotted) today files and prints a compact,
# human-readable facts block used to build each persona's system prompt. Read-only.
# --------------------------------------------------------------------------
CHAIN_FACTS=""          # populated by extract_facts
_vault() { echo "$SANDBOX/vault"; }

extract_facts() {
  local v; v="$(_vault)"
  CHAIN_FACTS="$(python3 "$HERE/plan-my-day-facts.py" "$v" "$TODAY" 2>>"$SANDBOX/live.stderr")"
  log "extracted facts from real $TODAY files:"
  local l
  while IFS= read -r l; do [[ -n "$l" ]] && log "    - $l"; done <<<"$CHAIN_FACTS"
}

# --------------------------------------------------------------------------
# Reset the OUTPUT files for every command in the chain, so each regenerates via
# its NEW-day token. Guarded delete; profiles/libraries are kept.
# --------------------------------------------------------------------------
reset_outputs() {
  local v; v="$(_vault)"
  local targets=(
    "life/daily-tracking/$TODAY.md"      # journal
    "fitness/daily-tracking/$TODAY.md"   # fitness
    "fitness/diet-tracking/$TODAY.md"    # diet
    "life/daily-planning/$TODAY.md"      # plan-my-day
  )
  local rel f
  for rel in "${targets[@]}"; do
    f="$v/$rel"
    if [[ -f "$f" ]]; then
      rm -f "$f" && log "reset (will regenerate): $rel"
    fi
  done
}

# --------------------------------------------------------------------------
# One live sub-conversation for a command that emits an INSTRUCTION block the
# agent follows to write a dated file. Generic: drives skill-model ↔ persona-model
# until the target file exists (or a turn cap). Reuses the parent's live plumbing
# style. Returns 0 if the file was written.
#   $1 = human label   $2 = command path   $3 = first user utterance
#   $4 = path (relative to vault) the file should land at
# --------------------------------------------------------------------------
_chain_leg() {
  local label="$1" cmd="$2" opening="$3" rel="$4"
  local v; v="$(_vault)"
  local target="$v/$rel"
  local persona_sys="You are the HUMAN using a journaling CLI. Today's REAL facts:
$CHAIN_FACTS

Rules: answer in character, in your own natural words. NEVER invent times or
numbers that contradict the facts. If a fact is not given it is fine to be vague.
Keep replies short, like a real person doing a quick check-in."

  # The skill model does NOT write files directly: headless claude -p would need
  # write permission and stalls on the approval prompt. Instead, exactly like the
  # plan-my-day leg, it emits the finished dated-file CONTENT between <FILE>..</FILE>
  # and THIS ENGINE writes it. Robust and permission-free.
  local skill_sys="You are the assistant running the pbrain /$label command. Follow
the command's emitted INSTRUCTIONS faithfully, using the facts the user gives you.
Do NOT call any tools. When you have enough to write today's entry, OUTPUT the FULL
file content (frontmatter + body, exactly what should be saved to $rel) wrapped
between <FILE> and </FILE> tags on their own lines; put nothing after </FILE>.
Until then, reply with ONLY your next single short check-in line."

  log "── chain leg: $label ──"
  local block; block="$(PBRAIN_TODAY_OVERRIDE="$TARGET_DATE" bash "$cmd" "$opening" 2>>"$SANDBOX/live.stderr")"
  local convo="COMMAND OUTPUT (follow these instructions):
$block

The user just said: $opening"

  local turn skill_out persona_out extracted
  for turn in 1 2 3 4 5 6; do
    skill_out="$(timeout 200 claude -p "$skill_sys

$convo

Reply with your next check-in line, OR the final <FILE>...</FILE> block." --model "$MODEL" 2>>"$SANDBOX/live.stderr")"
    printf '{"leg":"%s","turn":%d,"role":"skill","text":%s}\n' "$label" "$turn" \
      "$(SKILL="$skill_out" python3 -c 'import json,os;print(json.dumps(os.environ["SKILL"]))')" \
      >> "$SANDBOX/transcript.ndjson"
    extracted="$(SKILL="$skill_out" python3 -c '
import re,os
s=os.environ.get("SKILL","")
m=re.search(r"<FILE>\s*\n?(.*?)\n?\s*</FILE>", s, re.DOTALL)
print(m.group(1) if m else "", end="")')"
    if [[ -n "$extracted" ]]; then
      mkdir -p "$(dirname "$target")"
      printf '%s\n' "$extracted" > "$target"
      log "  ✓ $label wrote $rel (engine-written from <FILE> block)"
      return 0
    fi
    persona_out="$(timeout 200 claude -p "$persona_sys

The assistant said: $skill_out

Reply as the human (short)." --model "$MODEL" 2>>"$SANDBOX/live.stderr")"
    printf '{"leg":"%s","turn":%d,"role":"persona","text":%s}\n' "$label" "$turn" \
      "$(PERS="$persona_out" python3 -c 'import json,os;print(json.dumps(os.environ["PERS"]))')" \
      >> "$SANDBOX/transcript.ndjson"
    convo="$convo

ASSISTANT: $skill_out
USER: $persona_out"
  done
  log "  ✗ $label did not emit a <FILE> block within the turn cap"
  return 1
}

# --------------------------------------------------------------------------
# The full chain: journal → fitness → diet → (then the parent's plan-my-day leg).
# --------------------------------------------------------------------------
chain_replay() {
  local fj="$REPO_ROOT/commands/journal.sh"
  local ff="$REPO_ROOT/commands/fitness-journal.sh"
  local fd="$REPO_ROOT/commands/diet-journal.sh"

  _chain_leg journal "$fj" "morning brain dump" "life/daily-tracking/$TODAY.md" || true
  _chain_leg fitness-journal "$ff" "logging today's session" "fitness/daily-tracking/$TODAY.md" || true
  # diet is optional — only if a committed diet profile exists (else it'd emit SETUP)
  if ls "$SANDBOX"/vault/fitness/diet-tracking/.profile/diet-profile*.md >/dev/null 2>&1; then
    _chain_leg diet-journal "$fd" "logging today's meals" "fitness/diet-tracking/$TODAY.md" || true
  else
    log "── chain leg: diet skipped (no committed diet profile in snapshot) ──"
  fi
  # Finally the plan-my-day leg via the engine's existing replay (reads the fresh
  # fitness **When** + diet anchors we just regenerated).
  log "── chain leg: plan-my-day (engine replay) ──"
  replay
}
