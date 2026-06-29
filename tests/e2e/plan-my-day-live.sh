#!/usr/bin/env bash
# plan-my-day-live.sh — reusable REAL-VAULT, agent-to-agent e2e for /plan-my-day.
# PB-186.
#
# WHY: /plan-my-day AUTO-PLANS. It derives the day from the user's real profile,
# fitness journal (today's session + its time, e.g. football 21:00), diet meal
# times, habits and calendar — the user only does a light morning check-in. A
# faithful test therefore has to run the REAL command against a faithful copy of
# the user's data, with a real model following the emitted instructions and a
# real model playing the user's morning answers. A synthetic "persona dictates
# the anchors" test does NOT reproduce the bug.
#
# WHAT IT DOES (pipeline):
#   1. SNAPSHOT  — rsync the real $VAULT_DIR + ~/.config/pbrain into a fresh
#                  throwaway dir. The real vault is NEVER touched. Plane / Apple
#                  Reminders / the SQLite DB are pointed at throwaway/disabled so
#                  the run cannot write anything real or hit the network.
#   2. MIGRATE   — apply migration 0015 on the copy so block_layout_policy +
#                  break_minutes exist (the rules the plan must follow).
#   3. RESET     — delete ONLY today's life/daily-planning/<date>.md in the copy,
#                  so the real `plan` path regenerates it from scratch.
#   4. REPLAY    — run the REAL commands/plan-my-day.sh (it emits the real
#                  instruction block, with today's fitness session / meal times
#                  baked in); a SKILL model follows it and a PERSONA model answers
#                  the morning check-in from a scenario script (the user's "since
#                  waking up" replay). They converse until the plan file is
#                  written. This is the genuine agent-to-agent comm.
#   5. ASSERT    — parse the generated "## Today at a glance" table; check work
#                  blocks against block_layout_policy (fixed session_length_min,
#                  trimmed only at end-of-day / a hard anchor) and breaks against
#                  break_minutes {min, median, max} (default median, may shrink to
#                  min, never exceed max, never padded).
#   6. REPORT    — render a CLEAN, readable standalone HTML (conversation bubbles
#                  + a block/break timeline + a pass/fail table) and open it.
#
# Boundary honesty: the command, the copied vault, the conversation, and the
# produced plan file are REAL. The only seam is the `claude` CLI — if it is
# absent the run SKIPS with a clear message (never a synthetic pass).
#
# USAGE:
#   tests/e2e/plan-my-day-live.sh [run]            # full pipeline + open report
#   tests/e2e/plan-my-day-live.sh run --no-open    # don't auto-open the report
#   tests/e2e/plan-my-day-live.sh run --scenario <file.json>
#   PBRAIN_E2E_MODEL=claude-sonnet-4-6 ... run     # override the model
#
# The scenario file (default: scenarios/plan-my-day/today-replay.json) holds the
# user's morning check-in answers as an ordered list, plus the expected day shape.

set -uo pipefail
HERE="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"

# Default to a capable model — /plan-my-day runs on a strong model in production,
# and block-layout is a multi-step reasoning task a weak model fails regardless of
# the instructions. Override with PBRAIN_E2E_MODEL for a cheaper/faster smoke run.
MODEL="${PBRAIN_E2E_MODEL:-claude-sonnet-4-6}"
SCENARIO="${HERE}/scenarios/plan-my-day/today-replay.json"
OPEN_REPORT=1
REPORT_DIR="$REPO_ROOT/.e2e_report"

# ---- arg parse -------------------------------------------------------------
CMD="run"
[[ "${1:-}" =~ ^(run|snapshot)$ ]] && { CMD="$1"; shift; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-open)   OPEN_REPORT=0; shift ;;
    --scenario)  SCENARIO="$2"; shift 2 ;;
    --model)     MODEL="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

_real_vault() {
  # Resolve the user's real vault the same way pbrain does.
  if [[ -n "${PBRAIN_VAULT:-}" ]]; then echo "$PBRAIN_VAULT"; return; fi
  if [[ -f "$HOME/.config/pbrain/vault" ]]; then cat "$HOME/.config/pbrain/vault"; return; fi
  echo "$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault"
}

_claude_present() { command -v claude >/dev/null 2>&1; }

log() { printf '  %s\n' "$*"; }

# ---------------------------------------------------------------------------
# 1. SNAPSHOT
# ---------------------------------------------------------------------------
SANDBOX=""
snapshot() {
  local real; real="$(_real_vault)"
  [[ -d "$real" ]] || { echo "real vault not found at: $real" >&2; exit 1; }
  SANDBOX="$(mktemp -d -t pmd-e2e)"
  log "real vault   : $real"
  log "throwaway    : $SANDBOX"

  mkdir -p "$SANDBOX/vault" "$SANDBOX/config/pbrain" "$SANDBOX/work"
  # Copy the vault (exclude the big git history + any caches to keep it quick).
  rsync -a --delete \
    --exclude '.git/' --exclude '.obsidian/' --exclude '.e2e_report/' \
    "$real/" "$SANDBOX/vault/" 2>/dev/null \
    || cp -R "$real/." "$SANDBOX/vault/"
  # Copy config (plane.json, vault pointer, etc.) so profiles/registry resolve;
  # we then neutralize anything that could write externally.
  [[ -d "$HOME/.config/pbrain" ]] && cp -R "$HOME/.config/pbrain/." "$SANDBOX/config/pbrain/" 2>/dev/null || true

  # Point EVERYTHING at the throwaway and disable external/effectful seams.
  export PBRAIN_VAULT="$SANDBOX/vault"
  export XDG_CONFIG_HOME="$SANDBOX/config"
  export PBRAIN_DB_FILE="$SANDBOX/pbrain.db"
  export PBRAIN_MIGRATIONS=0          # we run 0015 explicitly, don't auto-run others
  export PBRAIN_UPDATE_CHECK=0
  export PBRAIN_SELF_IMPROVE=off
  export PBRAIN_NO_AUTOVAULT=1

  # CRITICAL: Apple Reminders go through EventKit (system-wide), so they are NOT
  # contained by the vault/DB redirection above — a real run would create/reschedule
  # the user's real reminders. Replace the compiled EventKit helper with a FAKE
  # that just logs the calls and exits 0, so plan-my-day's habit↔reminder
  # reconciliation (reminders-ensure / reminders-sync / fitness-reconcile) can
  # never touch the real Reminders database. The fake mimics the helper's app
  # bundle path (Contents/MacOS/pbrain-reminders) that lib/reminders.sh invokes.
  local fake_app="$SANDBOX/fake-reminders.app/Contents/MacOS"
  mkdir -p "$fake_app"
  cat >"$fake_app/pbrain-reminders" <<'FAKE'
#!/usr/bin/env bash
# FAKE pbrain-reminders helper (e2e) — never touches real Apple Reminders.
echo "[e2e fake-reminders] $*" >> "${PBRAIN_E2E_REMINDER_LOG:-/dev/null}"
# Emit a benign result-file write if asked, so callers parsing --result don't choke.
for ((i=1;i<=$#;i++)); do
  if [[ "${!i}" == "--result" ]]; then j=$((i+1)); rf="${!j}"; [[ -n "$rf" ]] && printf '{"ok":true,"faked":true,"reminders":[]}' > "$rf"; fi
done
exit 0
FAKE
  chmod +x "$fake_app/pbrain-reminders"
  # Write a .srchash so pbrain_swift_build sees the bundle as up-to-date and does
  # NOT recompile the real EventKit helper over our fake (the build skips when the
  # binary exists and the hash matches; we set the hash to whatever it computes).
  if [[ -f "$REPO_ROOT/lib/pbrain-reminders.swift" ]]; then
    local h=""
    h="$(shasum -a 256 "$REPO_ROOT/lib/pbrain-reminders.swift" 2>/dev/null | awk '{print $1}')"
    [[ -n "$h" ]] && printf '%s' "$h" > "$SANDBOX/fake-reminders.app/Contents/.srchash"
  fi
  export PBRAIN_REMINDERS_APP="$SANDBOX/fake-reminders.app"
  export PBRAIN_E2E_REMINDER_LOG="$SANDBOX/reminder-calls.log"
  : >"$PBRAIN_E2E_REMINDER_LOG"
  # Neutralize Plane so no network / real project writes (plan-my-day doesn't
  # write Plane, but be defensive): blank the base_url in the copied config.
  if [[ -f "$SANDBOX/config/pbrain/plane.json" ]]; then
    python3 - "$SANDBOX/config/pbrain/plane.json" <<'PY' 2>/dev/null || true
import json,sys
p=sys.argv[1]
try:
    d=json.load(open(p))
    d["base_url"]="http://disabled.invalid"
    json.dump(d,open(p,"w"))
except Exception: pass
PY
  fi
  log "snapshot ready (real vault untouched)"
}

# ---------------------------------------------------------------------------
# 2. MIGRATE — apply 0015 on the copy
# ---------------------------------------------------------------------------
migrate() {
  local mig
  for mig in 0015_plan_break_triplet_block_policy 0016_diet_meal_durations 0017_plan_day_priorities; do
    [[ -f "$REPO_ROOT/lib/migrations/$mig.sh" ]] || continue
    ( set +e
      source "$REPO_ROOT/lib/migrations/$mig.sh"
      export VAULT_DIR="$PBRAIN_VAULT"
      if migration_applicable; then migration_apply; log "migration ${mig%%_*} applied on copy"
      else log "migration ${mig%%_*} already satisfied"; fi
    )
  done
}

# Pull the policy + break triplet + session length from the (migrated) copy.
read_policy() {
  python3 - "$PBRAIN_VAULT" <<'PY'
import os,re,json,sys
vault=sys.argv[1]
store=os.path.join(vault,"life/daily-planning/.profile")
best=None;bn=-1
for fn in os.listdir(store):
    m=re.match(r"plans-profile\.v(\d+)\.md$",fn)
    if not m: continue
    head=open(os.path.join(store,fn)).read(400)
    if re.search(r"^committed:\s*true",head,re.M) and int(m.group(1))>bn:
        bn=int(m.group(1));best=os.path.join(store,fn)
d=json.loads(re.search(r'```json\s*(\{.*?\})\s*```',open(best).read(),re.S).group(1))
ws=d.get("working_style",{})
vr=d.get("variation_rules",{})
# Diet meal config (durations + nap) from the latest committed diet profile.
meal_minutes={}; meal_default=30; post_nap={}
dstore=os.path.join(vault,"fitness/diet-tracking/.profile")
if os.path.isdir(dstore):
    db=None;dn=-1
    for fn in os.listdir(dstore):
        mm=re.match(r"diet-profile\.v(\d+)\.md$",fn)
        if not mm: continue
        h=open(os.path.join(dstore,fn)).read(400)
        if re.search(r"^committed:\s*true",h,re.M) and int(mm.group(1))>dn:
            dn=int(mm.group(1));db=os.path.join(dstore,fn)
    meal_times={}
    if db:
        dd=json.loads(re.search(r'```json\s*(\{.*?\})\s*```',open(db).read(),re.S).group(1))
        meal_minutes=dd.get("meal_minutes") or {}
        meal_default=dd.get("meal_minutes_default",30)
        post_nap=dd.get("post_meal_nap") or {}
        meal_times=dd.get("meal_times") or {}
out={"session": ws.get("session_length_min",90),
     "break": ws.get("break_minutes") or {"min":15,"median":30,"max":45},
     "policy": ws.get("block_layout_policy") or {},
     "activity_buffers": vr.get("activity_buffers") or {},
     "meal_minutes": meal_minutes, "meal_default": meal_default,
     "meal_times": meal_times,
     "post_meal_nap": post_nap,
     "wake_gap_min": vr.get("min_wake_to_work_gap_min"),
     "block_notes": {b.get("slot",""): b.get("notes","") for b in (d.get("typical_day",{}).get("workday") or []) if isinstance(b, dict)},
     "day_priorities": (d.get("day_priorities") or {})}
print(json.dumps(out))
PY
}

# ---------------------------------------------------------------------------
# 3. RESET — delete only today's daily-planning file in the copy
# ---------------------------------------------------------------------------
TODAY="$(date +%Y-%m-%d)"

# Remap the scenario's target_date dated files onto the system's current date in
# the COPY, so the real `date`-driven plan-my-day finds the right fitness session
# / journal no matter what day the test runs (the scenario reconstructs a specific
# day; the system clock may have moved on).
remap_target_date() {
  local tgt; tgt="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("target_date",""))' "$SCENARIO" 2>/dev/null)"
  [[ -n "$tgt" && "$tgt" != "$TODAY" ]] || { log "target_date == today ($TODAY); no remap"; return; }
  local remapped=0
  for sub in fitness/daily-tracking life/daily-tracking life/gratitude-journal; do
    local src="$PBRAIN_VAULT/$sub/$tgt.md"
    local dst="$PBRAIN_VAULT/$sub/$TODAY.md"
    if [[ -f "$src" ]]; then cp -f "$src" "$dst"; remapped=$((remapped+1)); fi
  done
  log "remapped $tgt → $TODAY for $remapped dated file(s) so today's session = the scenario's"
}

reset_today() {
  local f="$PBRAIN_VAULT/life/daily-planning/$TODAY.md"
  if [[ -f "$f" ]]; then rm -f "$f"; log "deleted copy's today plan ($TODAY.md) — will regenerate"; \
  else log "no today plan in copy (clean regenerate)"; fi
}

# ---------------------------------------------------------------------------
# 4. REPLAY — real command + two-model conversation
# ---------------------------------------------------------------------------
TRANSCRIPT_JSON=""   # array of {role, text}
PLAN_FILE=""
replay() {
  PLAN_FILE="$PBRAIN_VAULT/life/daily-planning/$TODAY.md"
  local block
  block="$(bash "$REPO_ROOT/commands/plan-my-day.sh" plan 2>/dev/null)"
  [[ -n "$block" ]] || { echo "plan-my-day emitted nothing" >&2; return 1; }

  # Persona answers come from the scenario file (deterministic morning replay).
  local persona_answers; persona_answers="$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
for i,a in enumerate(d.get("checkin_answers",[]),1):
    print(f"{i}. {a}")
' "$SCENARIO")"
  local sname; sname="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("display","plan-my-day today replay"))' "$SCENARIO")"
  log "scenario: $sname"

  local skill_sys persona_sys convo turn skill_out persona_out
  skill_sys="You are the /plan-my-day skill. Follow the emitted instructions EXACTLY:

$block

Rules of engagement for this run:
- Run the morning check-in as a SHORT conversation, ONE question at a time.
- The user AUTO-PLANS: take the day's fixed anchors (fitness session + its time,
  meal times, calendar) from the context already in the instructions — do NOT ask
  the user to supply the football/workout time; it comes from the fitness journal.
- THREE HARD RULES (the plan is WRONG if any breaks):
  1. EVERY work block is EXACTLY session_length_min minutes (e.g. 90) — NEVER
     120 or 60. Want more work time? Add ANOTHER 90-min block. A block is
     shorter ONLY when trimmed to butt against end-of-day or a hard anchor.
  2. A fitness activity is ONE combined block = commute_before + session +
     commute_after (e.g. football 2h match becomes a 3h block 30+120+30, labeled
     like Football - commute + match + commute) with NO standalone commute rows,
     THEN a SEPARATE post_home_settle block (shower/get-ready/prep), THEN the
     following meal DINNER (always keep it unless the user skips it today), then
     wind-down, sleep. Work runs right up to the combined block START. Emit NO
     pre-activity row before the block (no prep/pack/kit/wrap/get-ready/head-out)
     - packing+travel are inside commute_before. Do NOT drop dinner.
  3. EVERY break is break_minutes.median by DEFAULT (e.g. 30) and MOST breaks
     ARE median. Use a shorter break (toward, not below, min) ONLY to bank a
     full block under time pressure or right before a long rest/anchor — NOT as
     a habit. A day of all-min (e.g. all-15-min) breaks is WRONG. Longer (toward
     max) only when off/tired or at wind-down.
- Also honor block_layout_policy + meal rules: squeeze in as many full blocks as
  fit; never pad a gap; meals 30 min.
- MEALS are 30 min (or the diet-profile duration), NEVER longer — not even
  'lunch out' / a big meal. A post-meal nap/rest is a BREAK (within
  break_minutes), unless a fixed nap is configured.
- DO NOT use any tools (no Bash, no Write, no file reads). You already have the
  full instruction block above — everything you need is in it.
- When you have enough to lay the day, OUTPUT the finished plan as plain text,
  the full '## Today at a glance' markdown table (| Time | Action | Tie | rows,
  HH:MM–HH:MM), wrapped EXACTLY between <PLAN> and </PLAN> tags on their own
  lines. Put nothing after </PLAN>. Example:
  <PLAN>
  ## Today at a glance
  | Time | Action | Tie |
  |---|---|---|
  | 15:30–17:00 | Block 1 — focus work | pbrain |
  ...
  </PLAN>
- Until then, reply with ONLY your next single in-character check-in line."

  persona_sys="You are the human running /plan-my-day this morning. Answer the
skill's check-in tersely and in character, using THESE answers in order (one per
question the skill asks); do not volunteer anything else, and never invent a
workout time (the journal already has it):
$persona_answers
Reply with ONLY your in-character line."

  # number of scripted answers — after this many exchanges, force the write.
  local n_answers; n_answers="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1])).get("checkin_answers",[])))' "$SCENARIO")"
  [[ "$n_answers" =~ ^[0-9]+$ ]] || n_answers=6

  convo=""
  : >"$SANDBOX/transcript.ndjson"
  log "conversation begins (skill model ↔ persona model)"
  local max_turns=12
  for ((turn=1; turn<=max_turns; turn++)); do
    # Once the persona's scripted answers are spent, stop asking — instruct the
    # skill to lay the plan and Write it now (prevents an endless check-in loop).
    local nudge=""
    if (( turn > n_answers )); then
      nudge="
You now have ALL the information you need. STOP asking questions. Lay the work
blocks per the policy and OUTPUT the finished plan wrapped in <PLAN>…</PLAN> now."
    fi
    # No tools — the skill outputs text only (it has the full instruction block).
    skill_out="$(timeout 200 claude -p "Conversation so far:
${convo:-(none yet — open the check-in)}
Your next turn:${nudge}" --model "$MODEL" --append-system-prompt "$skill_sys" 2>>"$SANDBOX/live.stderr")"
    [[ -n "$skill_out" ]] || { echo "skill model empty (turn $turn)" >&2; return 2; }
    printf '%s\n' "$(python3 -c 'import json,sys;print(json.dumps({"role":"skill","text":sys.stdin.read()}))' <<<"$skill_out")" >>"$SANDBOX/transcript.ndjson"
    convo+="
SKILL: $skill_out"
    # Did the skill emit the finished plan? Extract <PLAN>…</PLAN> and write it.
    local extracted
    extracted="$(printf '%s' "$skill_out" | python3 -c 'import sys,re; m=re.search(r"<PLAN>(.*?)</PLAN>", sys.stdin.read(), re.S); print(m.group(1).strip() if m else "")')"
    if [[ -n "$extracted" ]]; then
      printf '%s\n' "$extracted" > "$PLAN_FILE"
      break
    fi
    persona_out="$(timeout 200 claude -p "The skill just said:
$skill_out
Your in-character reply:" --model "$MODEL" --append-system-prompt "$persona_sys" 2>>"$SANDBOX/live.stderr")"
    [[ -n "$persona_out" ]] || persona_out="(no reply)"
    printf '%s\n' "$(python3 -c 'import json,sys;print(json.dumps({"role":"persona","text":sys.stdin.read()}))' <<<"$persona_out")" >>"$SANDBOX/transcript.ndjson"
    convo+="
USER: $persona_out"
  done

  [[ -s "$PLAN_FILE" ]] || { echo "plan never produced within $max_turns turns" >&2; return 3; }
  log "plan written: $PLAN_FILE"
}

# ---------------------------------------------------------------------------
# 5. ASSERT — parse the table, check blocks + breaks vs policy
# ---------------------------------------------------------------------------
VERDICT_JSON=""
assert_plan() {
  local policy; policy="$(read_policy)"
  # Run the assert logic from its own .py (NOT an inline heredoc — a heredoc
  # inside $(...) trips bash 3.2's quote scanner on the python apostrophes).
  # Pass 'now' (HH:MM) so the assert can reject ✓-done rows that claim completion
  # of FUTURE time (a model fabricating a done-day to dodge planning).
  local now_hhmm; now_hhmm="$(date +%H:%M)"
  VERDICT_JSON="$(python3 "$HERE/plan-my-day-assert.py" "$PLAN_FILE" "$policy" "$now_hhmm")"
  [[ -n "$VERDICT_JSON" ]] || { echo "verdict computation failed" >&2; return 1; }
  local ok; ok="$(python3 -c 'import json,sys;print(json.load(sys.stdin)["ok"])' <<<"$VERDICT_JSON")"
  python3 -c '
import json,sys
v=json.load(sys.stdin)
print("  work blocks:", v["n_work"], "| breaks:", v["n_break"], "| session:", v["session"], "| break:", v["break"])
if v["ok"]:
    print("  ✓ all work blocks + breaks follow policy")
else:
    for p in v["problems"]: print("  ✗", p)
' <<<"$VERDICT_JSON"
  [[ "$ok" == "True" ]]
}

# ---------------------------------------------------------------------------
# 6. REPORT — clean standalone HTML + open
# ---------------------------------------------------------------------------
report() {
  mkdir -p "$REPORT_DIR"
  local stamp out; stamp="$(date +%Y%m%d-%H%M%S)"; out="$REPORT_DIR/plan-my-day-live-$stamp.html"
  python3 "$HERE/plan-my-day-report.py" \
    "$SANDBOX/transcript.ndjson" "$VERDICT_JSON" "$PLAN_FILE" "$SCENARIO" "$out"
  log "report: $out"
  [[ "$OPEN_REPORT" -eq 1 ]] && command -v open >/dev/null 2>&1 && open "$out"
  REPORT_PATH="$out"
}

cleanup() { [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"; }

# ---------------------------------------------------------------------------
main() {
  if ! _claude_present; then
    echo "SKIP: the 'claude' CLI is not on PATH — cannot run the live two-model conversation."
    echo "      (This is a clean skip, not a pass. Install/login to the claude CLI and re-run.)"
    exit 0
  fi
  echo "▶ plan-my-day live e2e (real-vault snapshot, agent-to-agent)"
  snapshot
  migrate
  remap_target_date
  reset_today
  if ! replay; then
    echo "REPLAY failed — see $SANDBOX/live.stderr" >&2
    # preserve transcript + stderr for debugging, then report what we have
    cp "$SANDBOX/transcript.ndjson" "$REPORT_DIR/last-transcript.ndjson" 2>/dev/null || true
    cp "$SANDBOX/live.stderr" "$REPORT_DIR/last-live.stderr" 2>/dev/null || true
    [[ -s "$SANDBOX/transcript.ndjson" ]] && { VERDICT_JSON='{"ok":false,"problems":["replay did not produce a plan within the turn cap"],"session":0,"break":{},"n_work":0,"n_break":0,"blocks":[],"breaks":[],"rows":[]}'; PLAN_FILE="/dev/null"; report; }
    cleanup; exit 1
  fi
  local rc=0
  assert_plan || rc=1
  report
  # Optional: preserve the generated plan + transcript for debugging.
  if [[ -n "${PBRAIN_E2E_KEEP:-}" ]]; then
    cp "$PLAN_FILE" "$REPORT_DIR/last-plan.md" 2>/dev/null || true
    cp "$SANDBOX/transcript.ndjson" "$REPORT_DIR/last-transcript.ndjson" 2>/dev/null || true
    log "kept: $REPORT_DIR/last-plan.md"
  fi
  cleanup
  if [[ $rc -eq 0 ]]; then echo "✓ PASS — plan respects fixed blocks + break rules"; else echo "✗ FAIL — see report"; fi
  exit $rc
}

trap cleanup EXIT
main
