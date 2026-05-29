#!/usr/bin/env bash
set -euo pipefail

# plan-my-day.sh
# Adaptive daily planner anchored on your goals. On first run, interviews you
# to build a "goals profile" (long-term horizon, current focus areas, working
# style, anti-patterns, personal anchors) — that profile becomes the lens for
# every subsequent daily plan.
#
# Flow:
#   1. No profile config       → interview, write profile JSON, exit.
#   2. Profile in place        → daily flow: read profile + today's fitness/
#                                 journal/recent-plans → generate a plan tied
#                                 back to the user's goals and focus areas.
#
# Default destination:  $VAULT_DIR/life/daily-planning
# Profile config:       ~/.config/pbrain/plan-profile.json
# Overrides:
#   PBRAIN_VAULT             — vault root
#   PBRAIN_PLAN_DIR          — daily-plan dir (write target)
#   PBRAIN_PLAN_PROFILE_FILE — goals profile JSON path
#   PBRAIN_FITNESS_DIR       — today's fitness entry (cross-ref)
#   PBRAIN_JOURNAL_DIR       — today's daily journal (cross-ref)

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

PLAN_DIR="${PBRAIN_PLAN_DIR:-$VAULT_DIR/life/daily-planning}"
FITNESS_DIR="${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}"
DAILY_DIR="${PBRAIN_JOURNAL_DIR:-$VAULT_DIR/life/daily-tracking}"
PROFILE_FILE="${PBRAIN_PLAN_PROFILE_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/plan-profile.json}"

TODAY="$(date +%Y-%m-%d)"
DOW="$(date +%A)"
NOW_TIME="$(date +%H:%M)"
OUT_FILE="$PLAN_DIR/$TODAY.md"

mkdir -p "$PLAN_DIR"

# ---------------------------------------------------------------------------
# PHASE 0 — first-run profile setup (build the goals lens).
# ---------------------------------------------------------------------------
if [[ ! -f "$PROFILE_FILE" ]]; then
  cat <<SETUP
PLAN_MY_DAY_SETUP_PROFILE
profile_file: $PROFILE_FILE

INSTRUCTIONS — first-time setup. Do not generate any plan yet. You're helping
the user lay down the goals lens that every future /plan-my-day will use.

Step 1 — Tell the user this is a one-time setup (re-runnable by deleting the
profile file). Frame it warmly: "Let's get a clear picture of what you're
trying to push forward right now — that way each daily plan is actually
anchored on what matters to you, not just a generic to-do list."

Step 2 — Interview the user. Ask in 2–3 batches (not all at once, not one at
a time). Cover everything below — skip a sub-question only if it clearly
doesn't apply to them.

  Horizon goals (3–12 months out)
  - What are 1–5 things you're actively trying to build, become, or achieve
    over the next 3–12 months? (career, learning, body, relationships,
    creative, financial — any mix.) Phrase each as a concrete outcome, not a
    vague aspiration.
  - For each: rough deadline or "ongoing"? what does success look like?

  Current focus areas (what's live RIGHT NOW)
  - Of those goals, which 1–3 are you actively pushing this month?
    (We'll surface these at the top of every plan.)
  - For each active focus, what's the next concrete move you'd take this week?

  Working style
  - Typical weekday: when do you actually do focused work? (morning, evening,
    flexible, only after kids sleep, etc.)
  - Realistic focused-work hours per day on a normal day?
  - Preferred deep-work block length? (45 / 60 / 90 / 120 min)
  - Energy peak: morning person, afternoon, night owl, mixed?
  - Anything that wrecks your day if it slips? (sleep, exercise, sunlight,
    talking to no one, etc.)

  Anti-patterns to actively avoid
  - What behaviours sabotage you? (doomscrolling, late nights, alcohol mid-
    week, skipping meals, news binges, social-media spirals, gaming benders.)
  - We'll add these to a "Avoiding today" block whenever they're relevant.

  Personal anchors (the non-work stuff)
  - Relationships you want to stay close to? (parents, siblings, partner,
    specific friends — just first names or labels, no contact info needed.)
  - Creative pursuit(s)? (music, writing, painting, photography, woodworking,
    DJ, etc. — whatever you actually practise.)
  - Health / movement non-negotiables? (daily walk, gym N times a week,
    yoga, meditation, etc.)

Step 3 — Write the profile to:
  $PROFILE_FILE

  Exact JSON shape (use empty arrays / null for anything the user skipped or
  doesn't apply):

  {
    "created": "$TODAY",
    "horizon_goals": [
      {
        "goal": "concrete outcome",
        "deadline": "YYYY-MM or ongoing",
        "success_looks_like": "..."
      }
    ],
    "current_focus": [
      {
        "goal": "matches one of horizon_goals.goal",
        "this_week_move": "..."
      }
    ],
    "working_style": {
      "focus_window": "e.g. 9am-1pm + 8pm-10pm",
      "focused_hours_per_day": 4,
      "deep_work_block_min": 90,
      "energy_peak": "morning|afternoon|evening|mixed",
      "day_wreckers": ["sleep<7h", "no exercise", "no sunlight"]
    },
    "anti_patterns": ["doomscrolling", "late nights", "..."],
    "personal_anchors": {
      "relationships": ["mom", "partner", "best friend"],
      "creative_pursuits": ["music", "writing"],
      "health_habits": ["daily walk", "gym 4x/week"]
    },
    "notes": "free-form anything important not captured above"
  }

  - mkdir -p the parent dir before writing.
  - Use the user's actual words where possible — don't sanitize their voice.
  - If the user gave fewer than 3 horizon goals, that's fine. Don't pad.
  - If the user couldn't name a current_focus yet, leave the array empty.
    The daily flow will gently prompt them to set one over time.

Step 4 — Confirm: "Goals profile saved at $PROFILE_FILE. Edit it any time
(or delete it to redo this interview). Now re-run /plan-my-day and I'll
plan today against these goals."
SETUP
  exit 0
fi

# Validate profile JSON.
PROFILE_VALID="$(python3 - "$PROFILE_FILE" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as fh:
        json.load(fh)
    print("ok")
except Exception:
    print("bad")
PYEOF
)"

if [[ "$PROFILE_VALID" != "ok" ]]; then
  cat <<ERR
PLAN_MY_DAY_CONFIG_ERROR
profile_file: $PROFILE_FILE

The plan profile at $PROFILE_FILE is malformed JSON. Either fix it manually,
or delete it and re-run /plan-my-day to redo the goals interview.
ERR
  exit 1
fi

PROFILE_JSON="$(cat "$PROFILE_FILE")"

# ---------------------------------------------------------------------------
# PHASE 1 — today's plan already exists → review/update mode.
# ---------------------------------------------------------------------------
if [[ -f "$OUT_FILE" ]]; then
  echo "PLAN_MY_DAY_EXISTING"
  echo "file: $OUT_FILE"
  echo ""
  cat "$OUT_FILE"
  echo ""
  echo "---"
  echo "Today's day plan already exists. Show it to the user and ask if they want to update the 'How it went' section, add more items, or revise blocks."
  exit 0
fi

# ---------------------------------------------------------------------------
# PHASE 2 — daily flow.
# ---------------------------------------------------------------------------
FITNESS_TODAY="$(cat "$FITNESS_DIR/$TODAY.md" 2>/dev/null || echo "MISSING")"
DAILY_TODAY="$(cat "$DAILY_DIR/$TODAY.md" 2>/dev/null || echo "MISSING")"

RECENT_PLANS="$(python3 - "$PLAN_DIR" <<'PYEOF'
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
print("\n\n".join(parts) if parts else "(no previous plans)")
PYEOF
)"

CADENCE_SIGNAL="$(python3 - "$PLAN_DIR" <<'PYEOF'
import os, glob, re, datetime, sys
d = sys.argv[1]
files = sorted(glob.glob(os.path.join(d, "*.md")))[-30:]

keywords = {
    "mom": [r"\bmom\b", r"\bmother\b"],
    "dad": [r"\bdad\b", r"\bfather\b"],
    "siblings": [r"\bsister\b", r"\bbrother\b", r"\bsibling"],
    "friends": [r"\bfriend", r"\bcall a friend"],
    "creative": [r"\bcreative\b", r"\bmusic\b", r"\bwrit(?:e|ing)\b", r"\bpaint\b", r"\bdraw\b", r"\bphoto", r"\bdj\b", r"\brecord a set\b"],
    "walk": [r"\bwalk\b"],
    "deep_work": [r"\bdeep work\b", r"\bfocus block\b"],
}

last_seen = {k: None for k in keywords}
today = datetime.date.today()

for f in files:
    base = os.path.basename(f).replace(".md", "")
    try:
        date = datetime.date.fromisoformat(base)
    except Exception:
        continue
    try:
        with open(f) as fh:
            text = fh.read().lower()
    except Exception:
        continue
    for k, pats in keywords.items():
        if any(re.search(p, text) for p in pats):
            if last_seen[k] is None or date > last_seen[k]:
                last_seen[k] = date

lines = []
for k, d_ in last_seen.items():
    if d_ is None:
        lines.append(f"- {k}: not seen in last 30 plans")
    else:
        gap = (today - d_).days
        lines.append(f"- {k}: last mentioned {gap} day(s) ago ({d_.isoformat()})")
print("\n".join(lines))
PYEOF
)"

cat <<PROMPT
PLAN_MY_DAY_SESSION
date: $TODAY
day_of_week: $DOW
current_time: $NOW_TIME (24h, local)
output_file: $OUT_FILE
profile_file: $PROFILE_FILE

=== GOALS PROFILE ===
$PROFILE_JSON

=== TODAY'S FITNESS JOURNAL ===
$FITNESS_TODAY

=== TODAY'S DAILY JOURNAL ===
$DAILY_TODAY

=== CADENCE SIGNAL (last 30 plans) ===
$CADENCE_SIGNAL

=== RECENT DAY PLANS (last 7) ===
$RECENT_PLANS

---
INSTRUCTIONS — follow these steps in order. Keep the tone warm and concise.

Step 0 — Preflight checks (do these silently, then surface in one short message):
  - If TODAY'S FITNESS JOURNAL == "MISSING": "Your fitness journal isn't done yet — running /fitness-journal first means I can slot your workout into the day. Want to do that first, or plan around it?" Wait for their answer. If they say plan now, ask: "Roughly when's your physical activity today, and what is it? (e.g. gym 4pm, football 7pm, rest day)"
  - If TODAY'S DAILY JOURNAL == "MISSING": gently mention "Heads up: today's /journal is empty too — you can fill it in later." Do not block.
  - If both exist, skip the preflight nudges.
  - If the profile's \`current_focus\` array is empty, mention once: "You haven't pinned a current focus in your profile yet — want to name 1–3 things you're actively pushing this month? I'll save them so I can anchor future plans on them." Don't block planning today either way.

Step 1 — Show the user their lens, briefly:
  Print 2-3 lines max — their current_focus goals as bullets (or, if empty,
  list horizon_goals). Frame as the anchor for today, NOT as a quiz.
  Example:
    "Anchoring on:
     • Ship pbrain v1 (this week: publish repo + write blog post)
     • Drop 3 kg by July (this week: 4 gym sessions + diet streak)
     • Learn jazz piano (this week: 4×30 min practice)"

Step 2 — Ask all preference questions at once, in one message:
  "Quick check-in before we plan today:
  1. Energy/mood right now? (1–10 + one word)
  2. Top 3 things for today, ranked — **now** (start with this), **next** (after now is done), **later** (if there's time). Each can come from your focus areas above or anything else pressing.
  3. Any locked-in commitments? (meetings, calls, appointments — with times)
  4. Roughly how many focused work hours do you have today?
  5. Anything you specifically want to AVOID today? (defaults to your profile's anti_patterns if you skip)
  6. Mood for creative work today? (yes / maybe / not today)"

Step 3 — Cadence sweep. Use CADENCE SIGNAL + profile's personal_anchors.relationships to decide if any touchpoints should be surfaced today. Rules of thumb (only suggest if the contact appears in personal_anchors.relationships):
    - parents (mom/dad) gap >= 6 days → suggest a call
    - siblings gap >= 14 days → suggest a quick check-in
    - friends gap >= 7 days → suggest reaching out to one named friend from the profile
    - creative gap >= 4 days AND user said yes/maybe in q6 → suggest a creative block tied to their craft from personal_anchors.creative_pursuits
    - walk gap >= 2 days AND "daily walk" or similar is in personal_anchors.health_habits → suggest one
  Phrase as suggestions, not commands. Skip anything the profile doesn't endorse.

Step 4 — Generate the day plan and write it to: $OUT_FILE.
  STRUCTURE: lead with a consolidated **Today at a glance** table (time range + action + tie). All subjective detail — coaching, eating, breaks, rest, avoids — comes AFTER the table as supporting sections. The table is the operating doc; the sections are reference.

  Time-range rules:
  - Anchor the schedule to working_style.focus_window + the fitness session time + any locked-in commitments from q3.
  - Use concrete ranges (e.g. "10:30 AM–12:00 PM" in 12h, or "10:30–12:00" in 24h) whenever you can derive them from the profile, fitness journal, or user input. Don't write "Morning / Midday" labels — pick real ranges.
  - If the user gave specific times, honor them. Otherwise derive from current time + focus_window + deep_work_block_min.
  - Include in the table: each work block (Now/Next/Later), the fitness anchor, every meal window, post-work walk if surfaced, wind-down start, bed-by. Every row's "Tie" column maps back to a current_focus goal, a profile category (Fit body, Rest, Eating, Relationships, Creative), or "—" if standalone.
  - Keep the table tight — one line per action, no wrapped text. Time | Action | Tie.

  Every Work row should tie back to a current_focus goal where possible (annotate the Tie column with the short goal name).

  ---
  type: plan
  date: $TODAY
  day_of_week: $DOW
  status: planned
  energy: {1-10 from q1}
  focus_today: [{current_focus goal names that any of the q2 top 3 items tie back to — empty array if none}]
  tags: []
  ---

  # Day Plan — $TODAY ($DOW)

  > {one short coaching note tuned to today's energy, top 3 picks, and fitness intent. 1-2 sentences. No platitudes. Tie back to a goal if natural.}

  ## Today at a glance

  | Time | Action | Tie |
  |---|---|---|
  | {HH:MM–HH:MM} | {concrete action — e.g. "Pbrain plugin install fix"} | {goal name or category} |
  | {HH:MM–HH:MM} | {next action} | {tie} |
  | ... | ... | ... |

  (Rows in chronological order. Use 24h or 12h consistently — match what's in the user's journal/fitness file.)

  ## Anchoring on

  - {bullet per focus_today goal — name + the concrete this-week move from the profile. If focus_today is empty (none of today's top 3 tie back to a focus area), write a single line: "Today's work isn't tied to a current focus area — that's fine, just noting it." Don't pad.}

  (All sections below are supporting detail — the schedule lives in the table above. Sections add the "how / what to watch for", not the "when".)

  ## Anchors

  - {fitness session — note the focus + RPE / duration from the fitness journal, not the time (which is in the table)}
  - {each locked-in commitment from q3 with brief context, not the time}

  ## Work

  - **Now:** {q2 top — concrete task + a sentence on scope or what "done" means. Annotate "→ <goal>" if it ties to a current_focus area.}
  - **Next:** {q2 second — concrete task + scope. Annotate "→ <goal>" if applicable.}
  - **Later:** {q2 third — concrete task + scope. Annotate "→ <goal>" if applicable.}
  - Cap on focused hours today: {q4 number} — that's the ceiling, not the floor.

  ## Breaks & movement

  - {2-4 bullets: posture breaks, short walks, sunlight, stretches — describe the move, not the clock}
  - {if walk cadence gap surfaced, include an outdoor walk}

  ## Eating

  - {breakfast — what to eat, not when}
  - {lunch — what to eat}
  - {dinner — what to eat}
  - Hydration: {target, e.g. 3L water}
  - {if today is a training day per fitness journal, note refuel timing relative to the gym session}

  ## Relationships

  - {only include items surfaced in Step 3 — if no gaps are due, write "Nothing urgent today" and skip the bullets}
  - {format each as a checkbox: "- [ ] Call mom (8 days)"}

  ## Creative

  - {if yes/maybe in q6, suggest 1 concrete block tied to a craft from profile.personal_anchors.creative_pursuits — "30-60 min music practice", "Draft one section after dinner", "Edit 10 photos", etc.}
  - {if not today, write "Skipping creative today — recharge"}

  ## Rest

  - {1-2 lines on what NOT to do in the wind-down, tied to q5 and profile.anti_patterns. Times for wind-down and bed live in the table above.}

  ## Avoiding today

  - {union of q5 answers + profile.anti_patterns relevant for today, deduped — one bullet each}

  ## Notes

  - {1-3 bullets: anything else worth flagging — interaction between fitness + work, weather, anything from the daily journal, day-wrecker signals}

  ---

  ## How it went (fill at end of day)

  ### What I actually did
  -

  ### Wins
  -

  ### What slipped
  -

  ### Goal progress (vs the focus_today goals above)
  -

  ### Energy curve
  - Morning:
  - Afternoon:
  - Evening:

  ### Tomorrow seed
  -

Step 5 — After writing, confirm: "Saved → $OUT_FILE"
  Then offer one short follow-up: "Want me to adjust any block, or are we good?"
PROMPT
