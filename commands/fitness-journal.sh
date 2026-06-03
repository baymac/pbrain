#!/usr/bin/env bash
set -euo pipefail

# fitness-journal.sh
# Adaptive daily fitness journal — picks today's workout based on state and the
# user's configured set of activities, then generates a session in markdown.
#
# On first run the script bootstraps the user as a "full fitness coach":
#   1. Asks which activities they do  → writes activities config (JSON).
#   2. For each activity without a plan, interviews the user and writes a
#      personalised plan markdown file (gym plan included).
#   3. Suggests /diet-journal once plans are in place.
# Only after activities + all plans exist does it run the daily session flow.
# After each daily session is logged, it suggests /diet-journal (once, never
# blocks) unless today's food is already tracked.
#
# Default destination:  $VAULT_DIR/fitness/daily-tracking
# Activities config:    ~/.config/pbrain/fitness-activities.json
# Per-activity plans:   $VAULT_DIR/fitness/plans/<slug>.md
#                       (gym plan stays at $VAULT_DIR/fitness/Gym Plan.md)
# Overrides:
#   PBRAIN_VAULT                    — set the vault root
#   PBRAIN_FITNESS_DIR              — daily-tracking dir
#   PBRAIN_GYM_PLAN_FILE            — gym plan path
#                                     (default: $VAULT_DIR/fitness/Gym Plan.md)
#   PBRAIN_FITNESS_PLANS_DIR        — non-gym activity plans dir
#                                     (default: $VAULT_DIR/fitness/plans)
#   PBRAIN_FITNESS_ACTIVITIES_FILE  — activities JSON config
#                                     (default: ~/.config/pbrain/fitness-activities.json)

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

# Surface this user's standing preferences for /fitness-journal (emits nothing if none set).
pbrain_emit_prefs "fitness-journal" || true

TRACKING_DIR="${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}"
GYM_PLAN_FILE="${PBRAIN_GYM_PLAN_FILE:-$VAULT_DIR/fitness/Gym Plan.md}"
PLANS_DIR="${PBRAIN_FITNESS_PLANS_DIR:-$VAULT_DIR/fitness/plans}"
ACTIVITIES_FILE="${PBRAIN_FITNESS_ACTIVITIES_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/fitness-activities.json}"

TODAY="$(date +%Y-%m-%d)"
OUT_FILE="$TRACKING_DIR/$TODAY.md"
DIET_DIR="${PBRAIN_DIET_DIR:-$VAULT_DIR/fitness/diet-tracking}"

mkdir -p "$TRACKING_DIR" "$PLANS_DIR"

# ---------------------------------------------------------------------------
# PHASE 0 — first-run setup: ask the user which activities they do.
# ---------------------------------------------------------------------------
if [[ ! -f "$ACTIVITIES_FILE" ]]; then
  cat <<SETUP
FITNESS_JOURNAL_SETUP_ACTIVITIES
activities_file: $ACTIVITIES_FILE

INSTRUCTIONS — first-time setup (step 1 of 2). Do not generate any session yet.

Step 1 — Tell the user this is a one-time setup, then ask:
  "Quick setup before we start your fitness journal.

   What activities do you do (or want to track)?
   Examples: gym, football, basketball, swimming, running, cycling, yoga,
   climbing, tennis, padel, hiking, Apple Fitness+, home workouts, surfing…

   List everything that's actually part of your week. You can edit this list
   later by editing $ACTIVITIES_FILE."

Step 2 — Once the user lists their activities, write the config to:
  $ACTIVITIES_FILE
  Exact JSON shape:
  {
    "activities": ["Activity 1", "Activity 2", ...]
  }
  - Preserve readable casing (e.g. "Football", "Apple Fitness+", "Rock Climbing").
  - One entry per distinct activity. Deduplicate if the user repeats.
  - Do NOT include "Rest day", "Recovery", or "Walk/cardio" — those are always
    offered automatically alongside the user's activities.
  - Create the parent directory if needed (mkdir -p) before writing.

Step 3 — Confirm: "Saved your activities. Now I'll build a plan for each one
so we have something to work from each session — give me a moment."
Then re-run /fitness-journal to continue with plan creation.
SETUP
  exit 0
fi

# Load + validate activities.
ACTIVITIES_LIST="$(python3 - "$ACTIVITIES_FILE" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
    acts = data.get("activities", [])
    cleaned = [str(a).strip() for a in acts if str(a).strip()]
    if not cleaned:
        print("__EMPTY__")
    else:
        print(" | ".join(cleaned))
except Exception:
    print("__INVALID__")
PYEOF
)"

if [[ "$ACTIVITIES_LIST" == "__INVALID__" || "$ACTIVITIES_LIST" == "__EMPTY__" ]]; then
  cat <<ERR
FITNESS_JOURNAL_CONFIG_ERROR
activities_file: $ACTIVITIES_FILE

The activities config at $ACTIVITIES_FILE is missing entries or malformed JSON.
Expected shape:
  { "activities": ["Football", "Swimming", ...] }

Either fix the file manually, or delete it and re-run /fitness-journal to redo
the first-time setup.
ERR
  exit 1
fi

# ---------------------------------------------------------------------------
# PHASE 1 — for every configured activity, ensure a plan file exists.
# ---------------------------------------------------------------------------
# Outputs a list "Activity<TAB>plan_path" for each missing plan, one per line.
MISSING_PLANS="$(python3 - "$ACTIVITIES_FILE" "$GYM_PLAN_FILE" "$PLANS_DIR" <<'PYEOF'
import json, os, re, sys
acts_file, gym_plan, plans_dir = sys.argv[1], sys.argv[2], sys.argv[3]
def slug(s):
    s = re.sub(r'[^a-z0-9]+', '-', s.lower()).strip('-')
    return s or 'activity'
with open(acts_file) as fh:
    data = json.load(fh)
acts = [str(a).strip() for a in data.get("activities", []) if str(a).strip()]
for a in acts:
    if a.strip().lower() == 'gym':
        path = gym_plan
    else:
        path = os.path.join(plans_dir, slug(a) + '.md')
    if not os.path.isfile(path):
        print(f"{a}\t{path}")
PYEOF
)"

if [[ -n "$MISSING_PLANS" ]]; then
  cat <<PLANS
FITNESS_JOURNAL_SETUP_PLANS
activities_file: $ACTIVITIES_FILE
plans_dir: $PLANS_DIR
gym_plan_file: $GYM_PLAN_FILE

=== ACTIVITIES NEEDING A PLAN ===
$MISSING_PLANS

INSTRUCTIONS — first-time setup (step 2 of 2). Build one plan per activity.

You are acting as the user's full-stack fitness coach. For each activity in
the list above (format: "Activity<TAB>plan_path"), interview the user and
write a plan markdown file to its plan_path. Process them one at a time —
finish one activity before moving to the next. Be concise; don't dump generic
templates — tailor every plan to the user's actual answers.

GENERAL FLOW (per activity)

  1. Ask 4–7 targeted assessment + goal questions. Pick what makes sense for
     the activity — examples below. Keep it conversational, not a survey.
  2. Once you have the answers, write the plan file at the given plan_path.
     mkdir -p the parent dir first.
  3. Tell the user the plan is saved and move on to the next missing activity.

PER-ACTIVITY GUIDANCE (use as a starting point, adapt to the user)

  GYM (write to $GYM_PLAN_FILE)
    Ask:
    - Top 3 body parts / muscle groups they most want to strengthen.
    - Any weak or underdeveloped areas they've been avoiding or undertraining.
    - Any injuries, pain points, or movements to avoid.
    - Days per week available + session length.
    - Equipment access (full gym / home / dumbbells only / bands / etc.).
    - Experience level (months/years lifting) + current main lifts if known.
    - Primary goal: hypertrophy / strength / general fitness / sport support
      (e.g. supporting their football). If they listed football/basketball/
      similar, lean toward lower-body power, posterior chain, core, mobility.
    Then build a structured plan with:
    - 2 blocks (Block 1 weeks 1–4, Block 2 weeks 5–8) with progression intent.
    - A/B/C/D day split that hits all major muscle groups across the week.
      If they flagged underdeveloped areas, give those extra volume / priority
      placement (first exercise of the day, heavier compound focus).
    - Per day: muscle group order + exercises with sets × reps + rest target.
    - Warmup + cooldown templates.
    - Progression rule (e.g. add 2.5kg when all reps clean; deload after 4w).
    - Notes section calling out the user's weak areas and how this plan
      addresses them.
    Format must be compatible with the /fitness-journal session generator
    which parses week/block/day from frontmatter and exercises from headings.

  TEAM / PITCH SPORTS (football, basketball, tennis, padel, rugby, etc.)
    Ask:
    - Position(s) and playing frequency (matches/training per week).
    - Self-rated levels (1–10) across the skills that matter for that sport
      — e.g. football: dribbling, passing, shooting, first touch, defending,
      heading, weak foot, pace, stamina, decision-making. Basketball:
      shooting, ball-handling, finishing, defense, conditioning, IQ.
    - Where they want to be in 3 months — top 2–3 areas to level up.
    - Body state: any chronic niggles, recurring injuries, recovery time.
    - Specific scenarios they want to drill (1v1, finishing, set pieces, etc.).
    Then build a plan with:
    - Current state snapshot (the self-ratings).
    - 2–3 prioritised focus areas with the "why" for each.
    - Weekly structure: which days are skill, which are conditioning, which
      are matches/games, which are recovery.
    - 4–6 specific drills per priority area (with reps/duration/progression).
    - Conditioning targets (e.g. 90-min stamina, repeat-sprint ability).
    - Weak-side / weak-foot work if relevant.
    - Mental / decision-making cues.
    - 3-month milestone markers ("by month 3: weak foot 6→8, stamina 7→9").

  ENDURANCE (running, cycling, swimming)
    Ask: current volume + paces/times, target event or pace, weak link
    (aerobic base / threshold / form / strength), days/week available,
    injury history, terrain access.
    Plan: weekly structure (long / tempo / easy / intervals / rest), zones
    or RPE targets, technique focus, cross-training, build/recover cycles,
    milestone benchmarks.

  TECHNIQUE / SKILL SPORTS (climbing, surfing, skating, etc.)
    Ask: level (e.g. grade, comfort), strengths/weaknesses (power /
    technique / endurance / mental), session frequency, injuries, goals.
    Plan: weekly mix of technique vs strength vs conditioning, specific
    drills per weakness, progression targets, complementary off-board work.

  MIND/BODY (yoga, mobility, pilates)
    Ask: current flexibility/mobility level, target areas (hips / shoulders
    / back / hamstrings), style preference, frequency, any pain points.
    Plan: weekly sequence rotation, target poses/holds, breathwork,
    progression markers, integration with their other activities.

  APP-DRIVEN (Apple Fitness+, Peloton, etc.) / HOME / FREESTYLE
    Ask: time budget per session, preferred modalities (HIIT / strength /
    yoga / dance / cycling), goals, days/week.
    Plan: weekly rotation suggestion, how it complements their other
    activities, intensity guidance.

PLAN FILE FORMAT (write each plan file in this shape)

  ---
  activity: {Activity}
  created: $TODAY
  focus_areas: [{top 2–3 focus areas}]
  weekly_target: {sessions/week or duration/week}
  ---

  # {Activity} — Plan

  ## Current state

  {summary of self-assessment from the user's answers — be specific, quote
  numbers where they gave them}

  ## Goals (next 3 months)

  - {prioritised goal 1}
  - {prioritised goal 2}
  - {prioritised goal 3}

  ## Weekly structure

  {table or bullet list showing what happens on which days/sessions}

  ## Focus areas

  ### {Focus 1}
  - Why: {what's currently weak / why it matters}
  - Drills / approach: {2–4 specific items}
  - Progression: {how to know it's working}

  ### {Focus 2}
  …

  ## Milestones

  - Month 1: {marker}
  - Month 2: {marker}
  - Month 3: {marker}

  ## Notes

  - {anything the coach (you) wants to remind the user — injury cautions,
    interactions with their other activities, recovery emphasis, etc.}

GYM PLAN ADDITIONAL FORMAT

  In addition to the above sections, the gym plan must include a parseable
  block structure that /fitness-journal can read for daily session generation:

  ## Block 1 (Weeks 1–4)

  ### Day A — {Focus}
  | Exercise | Sets × Reps | Notes |
  |---|---|---|
  | ... | ... | ... |

  ### Day B — {Focus}
  …

  ### Day C — {Focus}
  …

  ### Day D — {Focus}
  …

  ## Block 2 (Weeks 5–8)

  (same shape as Block 1, with progression / variation)

WHEN ALL MISSING PLANS ARE WRITTEN

  Tell the user:
    "All plans saved under $PLANS_DIR (gym plan at $GYM_PLAN_FILE).
     Next, run /diet-journal to set up the food side — nutrition is half of
     getting stronger and recovering well. After that, run /fitness-journal
     again to plan today's session against your new plans."
PLANS
  exit 0
fi

# ---------------------------------------------------------------------------
# PHASE 2 — daily session flow (activities + plans all in place).
# ---------------------------------------------------------------------------
if [[ -f "$OUT_FILE" ]]; then
  echo "FITNESS_JOURNAL_EXISTING"
  echo "file: $OUT_FILE"
  echo ""
  cat "$OUT_FILE"
  echo ""
  echo "---"
  echo "Today's entry already exists. Show it to the user and ask if they want to update the 'Log your sets here' section or add notes."
  exit 0
fi

# Always-available non-activity options appended to the user's list.
MENU="$ACTIVITIES_LIST | Recovery/stretching | Walk/cardio | Rest day"

RECENT_SESSIONS="$(python3 - "$TRACKING_DIR" <<'PYEOF'
import os, glob, sys
d = sys.argv[1]
files = sorted(glob.glob(os.path.join(d, "*.md")))[-7:]
parts = []
for f in files:
    try:
        with open(f) as fh:
            parts.append(f"=== {os.path.basename(f)} ===\n{fh.read()}")
    except Exception:
        pass
print("\n\n".join(parts) if parts else "(no previous sessions)")
PYEOF
)"

GYM_PLAN="$(cat "$GYM_PLAN_FILE" 2>/dev/null || echo "(no gym plan found)")"

# Bundle non-gym plans so the session generator can reference them.
OTHER_PLANS="$(python3 - "$ACTIVITIES_FILE" "$PLANS_DIR" <<'PYEOF'
import json, os, re, sys
acts_file, plans_dir = sys.argv[1], sys.argv[2]
def slug(s):
    s = re.sub(r'[^a-z0-9]+', '-', s.lower()).strip('-')
    return s or 'activity'
with open(acts_file) as fh:
    data = json.load(fh)
out = []
for a in data.get("activities", []):
    name = str(a).strip()
    if not name or name.lower() == 'gym':
        continue
    p = os.path.join(plans_dir, slug(name) + '.md')
    if os.path.isfile(p):
        try:
            with open(p) as fh:
                out.append(f"=== {name} ({p}) ===\n{fh.read()}")
        except Exception:
            pass
print("\n\n".join(out) if out else "(no per-activity plans found)")
PYEOF
)"

# Suggest /diet-journal after the session is logged — but only if today's food
# isn't already tracked. Suggest once, never block (mirrors the morning sequence).
if [[ -f "$DIET_DIR/$TODAY.md" ]]; then
  DIET_SUGGESTION="(Today's /diet-journal entry already exists — no need to suggest it.)"
else
  DIET_SUGGESTION="Then suggest once, don't block: \"Want to log today's food with /diet-journal? Nutrition is half of recovery.\" If they skip, that's fine."
fi

cat <<PROMPT
FITNESS_JOURNAL_SESSION
date: $TODAY
output_file: $OUT_FILE
activities_file: $ACTIVITIES_FILE

=== USER ACTIVITIES (from $ACTIVITIES_FILE) ===
$ACTIVITIES_LIST

=== RECENT SESSIONS (last 7) ===
$RECENT_SESSIONS

=== GYM PLAN ($GYM_PLAN_FILE) ===
$GYM_PLAN

=== PER-ACTIVITY PLANS ($PLANS_DIR) ===
$OTHER_PLANS

---
INSTRUCTIONS — follow these steps in order.

Step 1 — Ask all state questions at once, exactly like this:
  "Quick check-in before we plan today:"
  1. Energy level? (1–10)
  2. Soreness? Which muscles? (1–10)
  3. Sleep last night? (hours + quality 1–10)
  4. Stress? (low / medium / high)
  5. Any pain or injury?
  6. Bodyweight today? (kg — skip if you don't have it)

Step 2 — After their answers, ask:
  "What do you want today?"
  Options: $MENU
  (Everything before "Recovery/stretching" comes from the user's configured
  activity list; the last three are always available.)

Step 3 — Ask 2–4 follow-up questions tailored to the chosen activity. Use
your judgment based on what makes sense for that activity. Guidance:
  - Team / pitch sport (Football, Basketball, Tennis, Padel, etc.):
      duration, kickoff/start time, location, opponents/level if relevant.
  - Swimming: pool or open water, duration, primary strokes, distance target.
  - Running / Cycling: duration or distance, route or terrain, intensity
    (easy / tempo / intervals).
  - Climbing / Bouldering: gym or outdoor, session length, focus
    (bouldering / lead / endurance / projects).
  - Yoga / Mobility / Stretching / Recovery: duration, style or focus.
  - Gym: "How much time do you have? Any equipment unavailable?"
  - Apple Fitness+ / Home workout: duration, workout type if known.
  - Walk/cardio: duration, type (walk / jog / zone 2 / hike).
  - Rest day: no follow-up.

Step 4 — Apply adaptive coaching rules before confirming intent:
  - Sleep < 6h AND soreness > 7 AND stress = high → recommend a downgrade
    (e.g. gym → recovery/lighter, contact sport → walk).
  - Heavy-leg soreness > 7 AND intent loads legs (gym leg day, football,
    basketball, running, cycling) → flag it, suggest swap or deload.
  - Any body part / movement pattern not trained in last 5+ sessions → mention.
  - Energy < 4 → suggest shorter session or rest.
  Also pull priorities from the relevant plan above — if today's chosen
  activity has a focus area the user has been neglecting, surface it.
  If you recommend a change, explain why briefly and let the user confirm or override.

---

Step 5A — IF INTENT = GYM:

  Use the gym plan above as the source of truth for block/day/exercises.

  Determine next session:
  - Parse frontmatter (week, block, day) from recent sessions to find the last completed day letter (A/B/C/D)
  - Cycle: A→B→C→D→A. After completing D, increment week. Week 5 starts Block 2.
  - Use Block 1 exercises for weeks 1-4, Block 2 for weeks 5-8 (from gym plan above)
  - Session number = total gym sessions completed so far + 1

  Determine weights using progressive overload:
  - For each exercise, scan recent sessions for the last logged weight and reps
  - If last session completed all reps cleanly → add 2.5kg (barbell), 1-2kg (DB/cable)
  - If reps were missed last time → repeat same weight
  - If exercise never done before → start conservatively (use RPE 6 as guide, pick a light weight)

  Generate the file in EXACTLY this format — match spacing, table structure, and section order precisely:

  ---
  type: fitness
  date: $TODAY
  week: {N}
  block: {N}
  day: {letter}
  focus: {muscle groups matching gym plan day}
  bodyweight: {kg or leave blank if skipped}
  status: planned
  tags: []
  ---

  # Day {letter} — {Focus}
  **Week {N} · Block {N} · Session {N}** | ~{estimated duration} min

  > {one coaching note tailored to today's state — RPE guidance, fatigue cue, or mindset note. Keep it to 1-2 sentences.}

  ---

  ## Warmup ({X} min)

  | | |
  |---|---|
  | {exercise} | {reps/duration + cue} |
  | ... | ... |
  (4-5 warmup items relevant to today's muscle groups)

  ---

  ## Workout

  ### {Muscle Group 1}

  | Exercise | Sets × Reps | Weight | Notes |
  |---|---|---|---|
  | {exercise} | {sets × reps} | **{weight}** | {short form cue} |
  | ... | ... | ... | ... |

  Rest {X}s between sets.

  ### {Muscle Group 2}

  | Exercise | Sets × Reps | Weight | Notes |
  |---|---|---|---|
  | ... | ... | ... | ... |

  Rest {X}s between sets.

  (repeat for each muscle group in today's day plan)

  ---

  ## Cooldown ({X} min)

  - {stretch relevant to today's muscles}: {duration}
  - ...
  (3-5 items)

  ---

  ## Log your sets here

  | Exercise | Set 1 | Set 2 | Set 3 | Notes |
  |---|---|---|---|---|
  | {every exercise from the workout} | | | | |
  | ... | | | | |

  ---

  ## Notes

  - {1-3 contextual notes: progression cues, what to watch, interaction with other activities the user does}
  - Next session: {next day from rotation} → Day {next letter} ({next focus})

---

Step 5B — IF INTENT = REST DAY:
  Use this minimal template:

  ---
  type: fitness
  date: $TODAY
  focus: Rest
  status: planned
  tags: []
  ---

  # Rest day — $TODAY

  > {one short note based on state — sleep priority, hydration, light movement cue. 1-2 sentences.}

  - Light walk if you feel up to it
  - Mobility / stretching (5–10 min)
  - Hydrate and eat enough protein

Step 5C — IF INTENT IS ANY OTHER ACTIVITY (any of the user's configured
activities except Gym, or Recovery/stretching, or Walk/cardio):

  Look up that activity's plan in the PER-ACTIVITY PLANS section above and
  use its current focus areas to shape today's session — drill choice,
  intensity emphasis, what to track. Don't ignore the plan.

  Skeleton (add/remove fields to fit the activity):

  ---
  type: fitness
  date: $TODAY
  focus: {activity name}
  duration_min: {minutes}
  {extra activity-relevant fields, e.g. location, kickoff, distance_km, pool}
  status: planned
  tags: []
  ---

  # {Activity} — $TODAY

  **Duration** {minutes} min{ · **Where** {location} if relevant}{ · **When** {time} if relevant}

  > {one short coaching note tailored to today's state — calm, hydration, pacing, recovery cue, or mindset reminder. 1-2 sentences.}

  ---

  ## Pre-session

  - {2–4 activity-specific prep bullets: hydration, fuel, warmup, gear}

  ## Plan / focus

  - {what you're working on today — pulled from the activity's plan focus areas + today's state}

  ---

  ## Post-session review (fill after)

  Build a 1–10 rating matrix appropriate to the activity. Reuse the metrics
  from the activity's plan (current-state self-ratings) so progress can be
  tracked over time.

  | Metric | Rating (1–10) | Notes |
  |---|---|---|
  | ... |  |  |

  **What went well:**

  **What to improve:**

  **Body feedback:**

  **Recovery plan tonight:** (stretch / ice / hydration / sleep target)

---

Step 6 — Write the final content to: $OUT_FILE
  Then confirm: "Saved → $OUT_FILE"
  $DIET_SUGGESTION
PROMPT

# Habit extraction (silent if no habits profile) + self-improvement capture.
pbrain_emit_habits_extract "fitness-journal" || true
pbrain_emit_self_improve "fitness-journal" "$PLANS_DIR" "fitness plans (gym plan at $GYM_PLAN_FILE, plus per-activity plans under this dir)" || true
