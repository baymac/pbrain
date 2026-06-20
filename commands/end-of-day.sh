#!/usr/bin/env bash
set -euo pipefail

# end-of-day.sh
# Bookend to /plan-my-day. Gathers today's plan, journal, fitness, and diet
# entries; emits a context block instructing Claude to walk a structured
# close-of-day reflection and fill the existing "How it went" section of the
# plan-my-day file in place. No sibling files — the plan file is the single
# record for the day.
#
# Overrides:
#   PBRAIN_VAULT             — vault root
#   PBRAIN_PLAN_DIR          — daily-plan dir (read + write target)
#   PBRAIN_JOURNAL_DIR       — today's daily journal (cross-ref)
#   PBRAIN_FITNESS_DIR       — today's fitness session (cross-ref)
#   PBRAIN_DIET_DIR          — today's diet log (cross-ref)
#   PBRAIN_THOUGHTS_DIR      — today's captured thoughts (cross-ref, summary feed)

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

# Surface this user's standing preferences for /end-of-day (emits nothing if none set).
pbrain_emit_prefs "end-of-day" || true

PLAN_DIR="${PBRAIN_PLAN_DIR:-$VAULT_DIR/life/daily-planning}"
DAILY_DIR="${PBRAIN_JOURNAL_DIR:-$VAULT_DIR/life/daily-tracking}"
FITNESS_DIR="${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}"
DIET_DIR="${PBRAIN_DIET_DIR:-$VAULT_DIR/fitness/diet-tracking}"
THOUGHTS_DIR="${PBRAIN_THOUGHTS_DIR:-$VAULT_DIR/life/thought-tracking}"

TODAY="$(date +%Y-%m-%d)"
# Optional target date — close a PAST day (e.g. "for previous day") with
# `--date YYYY-MM-DD` or a bare YYYY-MM-DD positional. Defaults to today. The
# slash command resolves natural language ("previous day", "yesterday", a
# weekday) to a concrete YYYY-MM-DD before calling. Every downstream path,
# the habit rollup, and the laptop report key off this date.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --date) TODAY="${2:-$TODAY}"; shift 2 2>/dev/null || shift ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) TODAY="$1"; shift ;;
    *) shift ;;
  esac
done
if ! [[ "$TODAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "Bad date '$TODAY' — expected YYYY-MM-DD." >&2; exit 1
fi
# Day-of-week for the target date (not necessarily today). macOS `date -j`.
DOW="$(date -j -f "%Y-%m-%d" "$TODAY" +%A 2>/dev/null || date +%A)"
ISO_WEEK="$(python3 -c "import datetime; d=datetime.date.fromisoformat('$TODAY'); y,w,_=d.isocalendar(); print(f'{y}-W{w:02d}')")"
# Boundary flags: is the target date the last day of its ISO week (Sunday) /
# its calendar month? Drives the once-per-boundary review nudge at close.
WEEK_END="$(python3 -c "import datetime; d=datetime.date.fromisoformat('$TODAY'); print('yes' if d.weekday()==6 else 'no')")"
MONTH_END="$(python3 -c "import datetime; d=datetime.date.fromisoformat('$TODAY'); print('yes' if (d+datetime.timedelta(days=1)).month!=d.month else 'no')")"

PLAN_FILE="$PLAN_DIR/$TODAY.md"
JOURNAL_FILE="$DAILY_DIR/$TODAY.md"
GRATITUDE_FILE="${PBRAIN_GRATITUDE_DIR:-$VAULT_DIR/life/gratitude-journal}/$TODAY.md"
THOUGHTS_FILE="$THOUGHTS_DIR/$TODAY.md"
PLAN_STORE="$(pbrain_profile_store "$PLAN_DIR")"
WEEKLY_GOALS_FILE="$(pbrain_profile_latest_for_period "$PLAN_STORE" weekly-goals "$ISO_WEEK" || true)"
FITNESS_FILE="$FITNESS_DIR/$TODAY.md"
DIET_FILE="$DIET_DIR/$TODAY.md"

mkdir -p "$PLAN_DIR"

read_or_missing() {
  local f="$1"
  if [[ -f "$f" ]]; then
    cat "$f"
  else
    echo "(no entry for this day)"
  fi
}

exists() {
  [[ -f "$1" ]] && echo yes || echo no
}

# Detect whether the plan's "How it went" section is still on its template
# placeholders (bare "-" bullets) so we can warn the user if they're about to
# overwrite a filled close.
already_closed() {
  local f="$1"
  [[ -f "$f" ]] || { echo no; return; }
  awk '
    /^## How it went/ {in_sec=1; next}
    /^---$/ && in_sec {exit}
    in_sec {
      # any non-empty line that is not a header and not the placeholder "-"
      gsub(/^[ \t]+|[ \t]+$/, "", $0)
      if ($0 == "" || $0 ~ /^#/ || $0 == "-") next
      print "filled"
      exit
    }
  ' "$f" | grep -q filled && echo yes || echo no
}

CLOSED="$(already_closed "$PLAN_FILE")"

# Habits surfacing. No-ops (empty output) until the user opts in. (Reminders are
# NOT surfaced or fired here: /remind reminders live on Apple Calendar, and
# /remind-blocking overlays are time-sensitive and self-contained in their own
# poller — neither should pollute the end-of-day reflection.)
# Sync recent habit-tracking md into the DB so the rollup reflects today's marks.
pbrain_habits_sync_range 7 || true
HABITS_ROLLUP="$(pbrain_habits_rollup "$TODAY" || true)"
[[ "$HABITS_ROLLUP" =~ [^[:space:]] ]] || HABITS_ROLLUP="(no habit data)"
if [[ -f "$(pbrain_habits_profile_file)" ]]; then HABITS_SETUP_NEEDED=no; else HABITS_SETUP_NEEDED=yes; fi
HABITS_CMD="$(pbrain_habits_cmd 2>/dev/null || true)"
HABITS_TRACK_FILE="$(pbrain_habit_track_file "$TODAY" 2>/dev/null || true)"

# Laptop-tracking finalize: render today's usage md deterministically here so the
# close has the day's numbers. No-op (and silent) unless /laptop-tracking was set
# up (its DB exists). The render never clobbers an existing report on a read
# failure. We grep the "Wrote <path>" line out of the subcommand's other output.
LAPTOP_CMD="$_SCRIPT_DIR/laptop-tracking.sh"
LAPTOP_REPORT_FILE=""
if [[ -n "${PBRAIN_TRACKER_DB_FILE:-}" && -f "$PBRAIN_TRACKER_DB_FILE" && -f "$LAPTOP_CMD" ]]; then
  _lt_out="$(PBRAIN_SELF_IMPROVE=off bash "$LAPTOP_CMD" report "$TODAY" 2>/dev/null | grep -E '^Wrote ' || true)"
  [[ -n "$_lt_out" ]] && LAPTOP_REPORT_FILE="${_lt_out#Wrote }"
fi

# Plane reconcile context: this week's goal-project ids + the issues Plane shows
# completed TODAY (for unplanned-row detection). Degrades to []/empty so an
# unconfigured Plane (or an unreachable one) costs nothing.
PLANE_CONFIGURED="$(pbrain_plane_configured && echo yes || echo no)"
WEEKLY_PIDS=""
if [[ -n "$WEEKLY_GOALS_FILE" ]]; then
  WEEKLY_PIDS="$(pbrain_profile_json "$WEEKLY_GOALS_FILE" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: d={}
print(",".join(g.get("plane_project") for g in d.get("goals",[]) if g.get("plane_project")))' 2>/dev/null || true)"
fi
COMPLETED_TODAY_JSON="[]"
if [[ "$PLANE_CONFIGURED" == "yes" ]]; then
  COMPLETED_TODAY_JSON="$(pbrain_projects_completed_today_json "$WEEKLY_PIDS" "$TODAY" 2>/dev/null || echo '[]')"
fi
PM_CMD="$(pbrain_projects_manager_cmd 2>/dev/null || true)"

cat <<PROMPT
END_OF_DAY_SESSION
date: $TODAY ($DOW)
is_today: $([[ "$TODAY" == "$(date +%Y-%m-%d)" ]] && echo yes || echo no)
iso_week: $ISO_WEEK
week_end: $WEEK_END
month_end: $MONTH_END
plan_file: $PLAN_FILE (exists: $(exists "$PLAN_FILE"), already_closed: $CLOSED)
weekly_goals_file: ${WEEKLY_GOALS_FILE:-(not set up)}
plane_configured: $PLANE_CONFIGURED
weekly_pids: ${WEEKLY_PIDS:-(none)}
project_manager_cmd: ${PM_CMD:-(unavailable)}
completed_in_plane_today: $COMPLETED_TODAY_JSON
journal_file: $JOURNAL_FILE (exists: $(exists "$JOURNAL_FILE"))
gratitude_file: $GRATITUDE_FILE (exists: $(exists "$GRATITUDE_FILE"))
thoughts_file: $THOUGHTS_FILE (exists: $(exists "$THOUGHTS_FILE"))
fitness_file: $FITNESS_FILE (exists: $(exists "$FITNESS_FILE"))
diet_file: $DIET_FILE (exists: $(exists "$DIET_FILE"))
habits_setup_needed: $HABITS_SETUP_NEEDED
laptop_report_file: ${LAPTOP_REPORT_FILE:-(none)}
laptop_cmd: $LAPTOP_CMD (tracker_db: $([[ -n "${PBRAIN_TRACKER_DB_FILE:-}" && -f "${PBRAIN_TRACKER_DB_FILE:-}" ]] && echo present || echo absent))

--- PLAN ---
$(read_or_missing "$PLAN_FILE")

--- JOURNAL ---
$(read_or_missing "$JOURNAL_FILE")

--- THOUGHTS ---
$(read_or_missing "$THOUGHTS_FILE")

--- FITNESS ---
$(read_or_missing "$FITNESS_FILE")

--- DIET ---
$(read_or_missing "$DIET_FILE")

--- HABITS (this week / month vs each habit's criteria) ---
$HABITS_ROLLUP
--- END CONTEXT ---

INSTRUCTIONS: This is a COMPLETION PASS, not a reflection journal. Take what
the day's tables + tracker already record, ask ONLY specific gap-filling
questions (NEVER open-ended "how did it go / what did you learn" prompts),
make sure all the day's trackings are complete, then write a lean executive
summary into the "## How it went" section of the plan file in place. The plan
file is the single record for the day — no sibling close files.

Step 0 — Preflight:
  - If plan_file exists == no: tell the user "No /plan-my-day for today — I'll
    write a free-form close at the top of a new $PLAN_FILE." Skip the Phase B
    Q1 table walk (there's no table); still run Q2–Q5 and write the summary.
  - If already_closed == yes: tell the user "Today's plan already has a
    filled-in 'How it went'. Want me to overwrite, append a note, or skip?"
    Wait for direction.

Step 1 — PHASE A: reconcile silently, then recap. Skim every section above and
pull what's already known WITHOUT asking — work-tracker rows already resolved
(Status != planned), backfilled "✓" rows in "## Today at a glance", diet rows already
"eaten", the fitness session status, habit marks already in the rollup, the
laptop report, and anything in the journal/thoughts. Print ONE compact recap —
"Here's your day so far: …" (a few lines, no table dump) — so the user can just
confirm by exception. Then ask only the gaps in Phase B.

Step 2 — PHASE B: ask ONLY the gaps, ONE domain per message, waiting for each
answer. Every question is SPECIFIC — list the actual unresolved items. Do NOT
ask open-ended reflection questions.
  Q1) DAILY PLANNING — from "## Today at a glance" + "## Work tracker", take every
     already-resolved row as-is. For the REST, list them by name and ask in ONE
     message: "Still open from today's plan — {task / block names}: which got
     done, partial, not started, or n/a?" If every row is already resolved, skip
     this question.
  Q2) FITNESS + SLEEP — combine in ONE message:
     - If the fitness session status is still "planned": "Did today's {activity}
       session happen?"
     - SLEEP, ONLY IF \`is_today\` == yes: "On track to sleep on time tonight
       (bed ~{sleep_bed from the fitness frontmatter or profile})? If not, why?"
       (This tonight-intention feeds the "### Sleep" line — it is NOT the
       Sleep-well habit score, which is last night's logged data.) When
       \`is_today\` == no (closing a past day), skip the tonight question.
  Q3) DIET — ask ONLY IF diet_file exists == yes. List the meal rows not yet
     "eaten": "Not logged yet — {slot names}. What did you have, or skip?" If
     EVERY row is already "eaten": "Diet log looks complete — any snack/shake to
     add?" Use the answer in Step 4a.
  Q4) HABITS — ask ONLY IF habits_setup_needed == no: From the HABITS block,
     collect (a) today's due BUILD habits marked "⏳" / "not yet today" and
     (b) today's LIMIT habits. Ask in ONE message: "Habits check — {due build
     habits}: which did you do? And {limit habits}: anything to flag?" Use ONLY
     this explicit answer in Step 4e — do NOT infer habits from the rest of the
     conversation.
  Q5) OPEN QUESTIONS — ask ONLY IF the journal above contains unresolved open
     questions (an "Open questions" section or "?"-terminated lines). List them:
     "This morning you asked: {questions} — did any resolve? (skip any that
     didn't)". Fold the answers into the executive summary; skip this question
     silently when the journal has none.

If a Phase B answer makes it clear the day went sideways (illness, crisis,
just-rough), keep the remaining questions minimal and the summary soft.

Step 3 — Use the Edit tool to replace the existing "## How it went" section
of $PLAN_FILE in place. Match the section exactly as it appears in the file
(headers may be "## How it went" or "## How it went (fill at end of day)").
The new section is a LEAN executive summary — no energy curve, no open-ended
reflection — in this exact shape:

  ## How it went

  ### Executive summary
  - {2–5 bullets: small wins across work, diet, fitness, relationships —
     synthesized from the filled tables + journal + thoughts + Q5 answers.
     Omit any category with nothing logged. Concrete, in the user's voice.}

  ### Scoreboard
  *(omit any domain with nothing logged — never invent a number)*

  **Habits (scored)**
  | Habit | Score | Priority | Basis |
  |-------|-------|----------|-------|
  | {name — from HABIT_SCORES read-back (Step 4e)} | {the 0–1 score verbatim from HABIT_SCORES, e.g. 0.8; — if null} | {priority} | {terse basis, e.g. "4 clean / 1 unclean", "bed 23:40 vs 23:30 · 7.2h", "2h10 work / 35m social", "8/12 tasks"} |

  **Habits (other due today)**
  - {one line each: ✅/⏳/⚠️ name — used/target, from the rollup; omit if none due}
  - {if autostatus reported missed>0 or skipped>0, ONE summary line:
     "Today: N missed · M skipped" — from the "AUTOSTATUS missed=N skipped=M"
     output in Step 4e. Omit when both are 0.}

  **Diet**
  - {Cals X / target Y (net ±Z) · P x/t · C x/t · F x/t · Fiber x/t — from the closed diet log}

  **Fitness**
  - {{activity} — actual/planned volume (Train 0.NN) · {status}}

  **Work**
  - {Focus N% — work Xm / social Ym / entertainment Zm · AFK Wm over Vh blocks}

  ### Goal progress (vs the focus_today goals above)
  - {one bullet per focus_today goal — net positive / flat / negative with a
     sentence of why, drawing from the filled tables + cross-ref files}

  ### Sleep
  - {Q2 tonight-intention: target bed vs reality, the reason if running late.
     When is_today == no, write last night's logged sleep instead.}

  ### Carry-forward
  - {auto-derived in Step 3c — leave the bullets for that step to fill}

Step 3b — Fill BOTH tables. Use the Edit tool on $PLAN_FILE in place.
  - "## Work tracker": fill the \`Status\`, \`Done at\`, \`% complete\`, and
    \`Est rating\` columns for each row from Q1 (and the already-resolved rows
    from Phase A):
      Task completed → Done at: HH:MM, Status: done, % complete: 100
      Task partially done → Status: partial, % complete: {rough %}
      Task not touched → Status: not started
      Task not applicable today → Status: n/a
    \`Est rating\` = a terse calibration note on whether the Est held (e.g.
    "held", "under by ~1h", "over by ~2h") — fill it when you can judge from the
    Done at / % complete, else leave blank.
  - "## Today at a glance": prefix each block that actually happened with "✓ "
    in the Action cell (the table's existing done-row convention). Leave blocks
    that didn't happen unprefixed.
  Skip either silently if that section isn't in the plan. (Legacy plans may carry
  a "## Task log" instead — treat it as the work tracker for reconcile.)

Step 3c — CARRY-FORWARD. From the filled "## Work tracker", collect every row with
Status "not started" or "partial". Write them as the bullets of the
"### Carry-forward" subsection (from Step 3) — one bullet per carried task,
phrased as a ready-to-schedule task ("{task} (carried from $TODAY)"). This is
auto-derived — do NOT ask the user for a "tomorrow seed". If no task slipped,
write a single "- (nothing carried)" bullet. /plan-my-work reads this next day.

Step 4 — Propagate the close into the cross-ref files. This is bookkeeping
the user expects to be automatic — do all of these whenever the inputs apply,
without re-asking. Use the Edit tool on each file.

4a) DIET FILE (\$DIET_FILE) — ONLY if diet_file exists == yes, driven by Q3's
    answer (the unlogged-meals reply):

  • For every meal row whose status is "planned"/"planned (revise)"/"proposed":
    - If the user described what they actually ate for that slot → replace
      Items + recompute Cals/P/C/F/Fiber against the new items, flip Status to
      "eaten". Add new rows for snacks/shakes the user mentioned that aren't
      in the table yet (e.g. an 8 PM protein shake).
    - If the user skipped that meal entirely → flip Status to "skipped" and
      zero out the macros.
  • Recompute the **Total (actual)** row and the **Net vs target** row.
    Header for that row should read "Total (actual)" — not "Total (so far)".
  • Update the **Hydration** / **Late eating (after 9pm)** lines from Q3.
  • REBUILD the **Nutrition Analysis** table against actuals — don't leave
    stale notes referencing the planned dinner. Each row's note must reflect
    what actually happened today, with ✅/⚠️/❌ recalibrated to actual numbers.
    Add a **Calorie total** row if the day finished significantly under/over.
  • REMOVE any "Suggested next meal(s)" / "Suggested improvement" section
    entirely — that section was forward-looking and is stale at close. Replace
    it with a short "## Carry-forward for tomorrow" list (3–5 bullets) drawn
    from the actual day's gaps.
  • Update the **Coach note** at the bottom to reflect the day that actually
    happened — name the real wins + the real gaps, not the projected ones.

4b) FITNESS FILE (\$FITNESS_FILE) — from Q2's answer about the session (plus any
    movement mentioned elsewhere):

  • If the planned session happened → flip frontmatter "status: planned" to
    "status: completed" and fill the "## Logged" section with the actuals the user
    reports (against the targets in "## Planned"). Don't touch "## Planned" or any
    "## Logged" actuals the user already filled.
  • If the planned session was skipped → frontmatter "status: skipped" with a
    one-line reason in the body.
  • If the user mentions ADDITIONAL movement beyond the planned session (walks,
    ring closes, extra cardio, yoga, kickboxing, etc.) → append a section
    titled "## Other movement today" at the bottom with bullets for each
    item. Include rough timing if the user said it. Don't invent items.

4c) JOURNAL FILE (\$JOURNAL_FILE) — leave alone. The journal is the user's
    own raw voice from earlier in the day; the close does not edit it.

4e) HABITS — read the HABITS block + \`habits_setup_needed\`:
    - If \`habits_setup_needed\` == yes: mention ONCE (unless prefs say not to
      nag) — "You haven't set up habit tracking yet — /habits picks a few habits
      to build or cap. Worth a look." Don't block the close.
    - If a rollup is present: note standouts in one line (a limit habit over
      cap, a high-priority build habit that lagged). Marking today's habits
      uses the HABIT EXTRACTION block below — but use ONLY the user's explicit
      answer from Step 2 Q4 (not auto-inference from the rest of the
      conversation). Mark what they confirmed; leave everything else unmarked.
    - SCORED DEFAULTS — end-of-day is the BACKSTOP that marks ALL FOUR scored
      defaults from the day's data (do these AFTER Step 3b filled the task-log
      actuals + the ✓ blocks, and 4a/4b updated diet/fitness — they read those,
      not Q4). Each mark is idempotent (one cell/day): if /plan-my-day,
      /diet-journal or /fitness-journal already marked it, re-marking just
      reflects the closed value. Only mark a default that is actually a tracked
      [scored] habit AND has its input data:
      • "Work the plan" (weighted_completion) — if the plan has a "## Work tracker"
        table (or a legacy "## Task log"), build the --items JSON from EVERY row
        (priority, difficulty, status as filled in 3b) and mark it per the HABIT
        EXTRACTION block. No tracker → skip.
      • "Train" (session_volume) — if a fitness session was logged or closed
        today (4b), build the --session JSON (mode/status/planned/actual from
        the session log vs the activity plan) and mark it per the session_volume
        instructions. No movement today → skip.
      • "Eat clean" (meal_ratio) — if diet_file exists and was reconciled in 4a,
        count CLEAN vs UNCLEAN meals from the closed diet log and mark it with
        --good <clean> --bad <unclean> per the HABIT EXTRACTION block. No diet
        log → skip.
      • "Sleep well" (deviation) — if the fitness frontmatter carries last
        night's sleep, mark it with --actual-time <sleep_bed> --actual-hours
        <sleep_hours> (this scores LAST night — the same data /fitness-journal
        uses, distinct from Q2's tonight-intention). No sleep data → skip.
      • "Deep work" (focus_ratio) — scores how focused the day's WORK BLOCKS
        actually were (work time vs distraction time on the laptop), NOT whether
        the tasks got done (that's "Work the plan"). Run this ONLY IF \`laptop_cmd\`
        reports tracker_db: present AND "Deep work" is a tracked scored habit:
        1. From "## Today at a glance", collect the time ranges of the day's WORK
           blocks ONLY — skip every LIFE anchor (meals, fitness, walk, wind-down,
           calendar events). If there are no work blocks, skip the rest.
        2. Run: bash "$LAPTOP_CMD" focus-breakdown --date $TODAY --windows "HH:MM-HH:MM,HH:MM-HH:MM"
           (comma-joined work windows). Read the \`FOCUS_BREAKDOWN {…}\` JSON line.
        3. If its "unknown" list is non-empty, propose a category for each key in
           ONE compact message (e.g. "github.com→work, x.com→social,
           youtube.com→entertainment, Notion→work" — categories are work / social
           / entertainment / neutral). Ask the user to confirm or correct in one
           reply, then persist with:
             bash "$LAPTOP_CMD" categorize --set "key=cat,key=cat,…"
           and RE-RUN focus-breakdown so every key is now classified.
        4. Mark with the per-category minutes from the (final) breakdown:
             bash "$HABITS_CMD" mark --name "Deep work" --date $TODAY \\
               --focus '{"work":N,"social":N,"entertainment":N,"neutral":N}'
           The evaluator computes work / (work + distraction); AFK is neutral.
           If work+distraction is 0 (no classifiable active time), skip the mark.
      THEN run the auto-status pass so scheduled-but-undone habits are RECORDED
      (not silently dropped) — this must run AFTER all the marking above and
      BEFORE reminders-sync/consolidate:
        bash "$HABITS_CMD" autostatus --date $TODAY
      For every build habit due today with no mark, it writes status=missed; a
      habit already marked done/skipped is left as-is; limit habits and off-day
      (not-due) habits are never touched. It prints "AUTOSTATUS missed=<n>
      skipped=<n>" — keep those two numbers for the Scoreboard line below.
      THEN reconcile the linked Apple Reminders BEFORE consolidating (so a habit
      completed only by ticking its Apple Reminder is pulled into today's marks
      and lands in the consolidated file + the scores below — not left out):
        bash "$HABITS_CMD" reminders-sync --date $TODAY --sweep
      See 4f for what this does + the one line to surface. No-op (and silent)
      when no habits profile / no linked reminders exist.
      THEN consolidate:
        bash "$HABITS_CMD" consolidate --date $TODAY
      Consolidate syncs today's tracking file ($HABITS_TRACK_FILE) into the
      analysis DB and keeps the day's done / skipped / missed rows (only the
      untouched "not yet" rows are pruned), so weekly/monthly reviews have
      accurate data. Run it once, after autostatus + marking + the reminders
      pull above.
      THEN run the scores read-back (AFTER marking + reminders-sync + consolidate
      so the DB is current):
        bash "$HABITS_CMD" scores --date $TODAY
      Parse the line beginning with "HABIT_SCORES " and parse its JSON array.
      Use this to fill the "### Scoreboard" Habits (scored) table verbatim:
        - Score column: the 0–1 "score" field verbatim (e.g. 0.8); "—" when score is null.
        - Priority column: the "priority" field verbatim.
        - Basis column: derive a terse note from what you already know:
            meal_ratio    → "X clean / Y unclean" meals
            deviation     → "bed HH:MM vs HH:MM · N.Nh" (from fitness frontmatter)
            weighted_completion → "N/M tasks" or "X/Y pts" (from the work tracker)
            session_volume      → "Nkg / Mkg planned" or "completed / skipped"
            focus_ratio         → "Xm work / Ym social" (from focus-breakdown)
          For any habit with score: null → write "— (not marked)" in Basis.
      The non-scored habits under "Habits (other due today)" come from the
      HABITS_ROLLUP already in context (the rollup lines that are NOT scored
      habits). Omit "Habits (other due today)" if there are none due today.
      The Diet, Fitness, and Work rows come from what 4a/4b/4e computed above —
      fill those rows only when the relevant data exists; omit the entire
      subsection otherwise. Never invent a number.

4f) REMINDERS — a daily build habit can be LINKED to a per-day Apple Reminder
    that pbrain keeps in TWO-WAY sync (the reminder is just a notification +
    checkbox; pbrain owns the data). The sync itself runs in 4e (BEFORE
    consolidate) — this section just explains it + the one line to surface. No-op
    when no habits profile exists — don't mention reminders then.
    SYNC (silent bookkeeping — do NOT ask; the command was already issued in 4e):
         bash "$HABITS_CMD" reminders-sync --date $TODAY --sweep
       It reconciles today's linked habits with their one-shot reminders both
       ways: a reminder you ticked off in the Apple Reminders app marks the habit
       done here, and a habit you closed today completes its reminder. With
       --sweep (end-of-day only), any one-shot still pending after that — a habit
       you didn't do and didn't tick — has its stale Apple Reminder deleted so it
       doesn't linger overdue. It prints "SYNCED pulled=<n> pushed=<n> swept=<n>".
       Surface ONE line only if something moved (e.g. "Synced 2 habit reminders,
       cleared 1 undone."); stay silent on "pulled=0 pushed=0 swept=0" or when
       reminders aren't set up.
    Do NOT proactively offer to set up new reminder links here — linking is
    opt-in, per habit, only when the user asks (or at /habits add/setup). If the
    user does ask, use: bash "$HABITS_CMD" reminder --id <hid> --link --time HH:MM
    (or --decline). If a reminder op reports Reminders access isn't granted, tell
    the user to run /remind access once, then move on.
    Reminders ONLY — a Calendar event has no "done" state, so never touch
    calendar items here.

4h) WEEKLY-GOAL ROLLUP — if \`weekly_goals_file\` is a real path (not "(not set up)"),
    update the weekly-goals draft in place based on today's work-tracker actuals.
    Goals are now PROJECT-level: match each work-tracker row to a goal by its
    PROJECT, not by task text — the "Plane id" column carries "<project_id>:<iid>",
    so its project_id matches the goal's "plane_project".
    - For each work-tracker row with Status = done whose project matches a goal's
      plane_project: set that goal's "status" to "in_progress" (if not already
      "done" for the period — a weekly project goal spans many days).
    - For rows with Status = partial: set "status": "in_progress" if it was "active".
    - Leave goals with no matching done row unchanged. (Legacy task-level goals
      with a "tie" but no "plane_project": fall back to matching by tie/text.)
    Use the Edit tool to update the JSON block in $WEEKLY_GOALS_FILE in place.
    Only edit if weekly_goals_file is a real path. Skip silently otherwise.

4k) PLANE SYNC + UNPLANNED DETECTION — push today's work-tracker statuses back to
    Plane and pull in anything you finished in Plane but never planned. Run ONLY
    IF \`plane_configured\` == yes (skip silently otherwise). All writes are
    idempotent (set-not-append), so re-running a close is safe.
    1. PUSH: collect every "## Work tracker" row whose "Plane id" is a real tie
       (contains ":") and whose Status was filled in 3b. Map work-tracker Status →
       Plane status: done→done · partial/in-progress→doing · not started→todo ·
       n/a/dropped→dropped. (Note: /plan-my-work `task execute` may already have
       authored in-progress/done rows live mid-day and pushed them to Plane — the
       mapping handles them idempotently, so this pass just confirms them.)
       Push each row with the project manager (idempotent —
       skip rows whose Plane status already matches, so you don't thrash):
         bash "${PM_CMD:-/project-manager}" move "<pid>:<iid>" --to <status>
       (for a done row, the manager stamps completed_at automatically.) Relay a
       one-line summary of how many were pushed.
    2. UNPLANNED: read \`completed_in_plane_today\` (JSON array of issues Plane
       marked done TODAY). For each whose tie is NOT already a row in the work
       tracker, APPEND an "unplanned" row: Block "—" | {title} | {project} |
       {tie} | (priority/est from Plane if known, else —) | done | {completion
       time or —} | 100 | | "unplanned (done in Plane)". Dedupe against existing
       ties so re-running never double-adds. These unplanned-done rows also count
       toward "Work the plan" — re-run that mark in 4e if you added any.
    Surface ONE line: "Synced N tasks to Plane; M unplanned done pulled in."

4g) LAPTOP USAGE — if \`laptop_report_file\` is a path (not "(none)"), today's
    laptop-usage report was already rendered to that file. Read it and weave ONE
    grounded line into the close (e.g. "5h 12m active, mostly Chrome — 2h on
    github.com"). Don't paste the whole table. If it's "(none)", say nothing
    about laptop usage (the tracker isn't set up). If you computed a "Deep work"
    focus score in 4e, fold it into this same line with the breakdown, e.g.
    "Focus 78% across 3h of work blocks — 2h10 work, 35m social (x.com), 15m
    entertainment; 20m AFK." (one line, not a second laptop section).

4i) BOUNDARY REVIEW NUDGE — a once-per-boundary pointer, non-blocking:
    - If \`week_end\` == yes: add ONE line — "That closes the week. /weekly-review
      when you're ready." Skip if a weekly review for this ISO week already exists.
    - If \`month_end\` == yes: add ONE line — "Last day of the month. /monthly-review
      to zoom out." Skip if a monthly review for this month already exists.
    Just the pointer — do NOT run the review here or block the close on it.

Do these silently as part of writing the close — surface one short summary
line per file you touched in your final message. Do NOT skip 4a/4b because
they feel like extra work; this is the entire point of the new flow.

Don't go beyond what the user said — these updates are bookkeeping, not
new analysis or new prescriptions.

Step 4j — COMPLETENESS NOTE (silent unless something's missing): if no journal
(journal_file exists == no) or no gratitude (gratitude_file exists == no) was
written today, add ONE neutral line that the summary is thinner for it (e.g.
"No journal today, so the summary is light."). This is a note, NOT a nag — never
push the user to go back and write them.

Step 5 — Print the plan file path and ONE line of warmth. Examples:
  "Locked in. Sleep well."
  "Tomorrow's already lighter for having closed today."
  "That's a real day. Rest up."

Do NOT write three paragraphs of reflection at the user. The user already
reflected — your job is to record, not pile on.

Hard rules:
- Quote the user's own words where possible — don't paraphrase into corporate voice.
- Do NOT prescribe action items, accountability frameworks, or pep talks.
- Do NOT call the day a "win" or a "loss." Neutral language only.
- Do NOT create a sibling close file. The plan file is the record.
PROMPT

# Habit extraction (silent if no habits profile): logs the tracked habits the
# user evidenced doing/skipping today. Self-improvement capture runs after.
pbrain_emit_habits_extract "end-of-day" || true
pbrain_emit_self_improve "end-of-day" || true
