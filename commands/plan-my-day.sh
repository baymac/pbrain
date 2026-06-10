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
#   PBRAIN_PLAN_PROFILE_FILE — goals profile markdown path (vault; JSON in a fenced block)
#   PBRAIN_FITNESS_DIR       — today's fitness entry (cross-ref)
#   PBRAIN_JOURNAL_DIR       — today's daily journal (cross-ref)
#   PBRAIN_WEEKLY_DIR        — weekly reviews (Monday nudge cross-ref)

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

# Surface this user's standing preferences for /plan-my-day (emits nothing if none set).
pbrain_emit_prefs "plan-my-day" || true

PLAN_DIR="${PBRAIN_PLAN_DIR:-$VAULT_DIR/life/daily-planning}"
FITNESS_DIR="${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}"
DAILY_DIR="${PBRAIN_JOURNAL_DIR:-$VAULT_DIR/life/daily-tracking}"
PROFILE_FILE="${PBRAIN_PLAN_PROFILE_FILE:-$VAULT_DIR/life/Goals Profile.md}"
WEEKLY_DIR="${PBRAIN_WEEKLY_DIR:-$VAULT_DIR/life/weekly-tracking}"

TODAY="$(date +%Y-%m-%d)"
DOW="$(date +%A)"
NOW_TIME="$(date +%H:%M)"
OUT_FILE="$PLAN_DIR/$TODAY.md"

mkdir -p "$PLAN_DIR"

# Migration: earlier versions stored the profile as ~/.config/pbrain/plan-profile.json.
# If the new vault markdown profile is absent but the old JSON exists, convert it
# in place (wrap the JSON in a fenced block) so existing users aren't re-interviewed.
_OLD_PROFILE="${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/plan-profile.json"
if [[ ! -f "$PROFILE_FILE" && -f "$_OLD_PROFILE" ]]; then
  mkdir -p "$(dirname "$PROFILE_FILE")"
  python3 - "$_OLD_PROFILE" "$PROFILE_FILE" "$TODAY" <<'PYEOF' 2>/dev/null || true
import json, sys
old, new, today = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(old) as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)
created = data.get("created", today)
body = json.dumps(data, indent=2, ensure_ascii=False)
with open(new, "w") as fh:
    fh.write(f"---\ntype: profile\ndate: {created}\ntags: []\n---\n\n")
    fh.write("# Goals profile\n\n")
    fh.write("The lens every `/plan-my-day` plans against. Edit freely; the structured data lives in the JSON block below.\n\n")
    fh.write("```json\n" + body + "\n```\n")
PYEOF
  [[ -f "$PROFILE_FILE" ]] && echo "Migrated goals profile to $PROFILE_FILE (from $_OLD_PROFILE)."
fi
unset _OLD_PROFILE

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
  - Break activities: between work blocks you'll get a ~30-min break — what
    restful things do you actually like doing in those? (e.g. short walk,
    a couple of games, prep + eat a light snack, stretch, sit outside.) These
    become a menu the daily plan rotates through automatically between blocks.

  Anti-patterns to actively avoid
  - What behaviours sabotage you? (doomscrolling, late nights, alcohol mid-
    week, skipping meals, news binges, social-media spirals, gaming benders.)
  - We'll add these to a "Avoiding today" block whenever they're relevant.

  Daily time anchors (the fixed skeleton your day revolves around)
  - What time do you typically work out or do physical activity? (rough start time)
  - What time do you usually eat lunch?
  - What time do you usually have dinner?
  - Do you do a regular walk? Morning, after dinner, or not at all — and roughly when?
  - What time do you usually wake up?
  - What time do you aim to be in bed?
  - On a normal workday, how many focused work hours do you realistically get in?

  Personal anchors (the non-work stuff)
  - Relationships you want to stay close to? (parents, siblings, partner,
    specific friends — just first names or labels, no contact info needed.)
  - Creative pursuit(s)? (music, writing, painting, photography, woodworking,
    DJ, etc. — whatever you actually practise.)
  - Health / movement non-negotiables? (daily walk, gym N times a week,
    yoga, meditation, etc.)

Step 3 — Write the profile to:
  $PROFILE_FILE

  This is an Obsidian note. Write it in EXACTLY this shape: standard frontmatter,
  a short intro line, then the structured data in a fenced JSON block (use empty
  arrays / null for anything the user skipped or doesn't apply):

  ---
  type: profile
  date: $TODAY
  tags: []
  ---

  # Goals profile

  The lens every /plan-my-day plans against. Edit freely; the structured data lives in the JSON block below.

  \`\`\`json
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
      "break_block_min": 30,
      "break_activities": ["short walk", "2 games", "prep + eat a light snack"],
      "energy_peak": "morning|afternoon|evening|mixed",
      "day_wreckers": ["sleep<7h", "no exercise", "no sunlight"]
    },
    "daily_anchors": {
      "wake_time": "HH:MM",
      "workout_time": "HH:MM",
      "lunch_time": "HH:MM",
      "dinner_time": "HH:MM",
      "walk_time": "HH:MM or null",
      "bed_target": "HH:MM",
      "focused_hours_per_day": 5
    },
    "anti_patterns": ["doomscrolling", "late nights", "..."],
    "personal_anchors": {
      "relationships": ["mom", "partner", "best friend"],
      "creative_pursuits": ["music", "writing"],
      "health_habits": ["daily walk", "gym 4x/week"]
    },
    "notes": "free-form anything important not captured above"
  }
  \`\`\`

  - mkdir -p the parent dir before writing.
  - Keep the fenced JSON code block exactly as shown — the commands that read this profile parse the JSON out of it.
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

# Extract + validate the profile JSON (carried in a fenced JSON block in the note).
PROFILE_JSON="$(pbrain_profile_json "$PROFILE_FILE")"

if [[ -z "$PROFILE_JSON" ]]; then
  cat <<ERR
PLAN_MY_DAY_CONFIG_ERROR
profile_file: $PROFILE_FILE

The goals profile at $PROFILE_FILE has no readable JSON block (or it is malformed).
Either fix the JSON code block manually, or delete the file and re-run
/plan-my-day to redo the goals interview.
ERR
  exit 1
fi

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

TIMING_SIGNAL="$(python3 - "$PLAN_DIR" <<'PYEOF'
import os, glob, re, sys, collections
plan_dir = sys.argv[1]
files = sorted(glob.glob(os.path.join(plan_dir, "*.md")))[-21:]
categories = {
    "workout": [r"\b(gym|workout|fitness|apple fitness|lower body|upper body|push|pull|legs|cardio|football)\b"],
    "lunch": [r"\blunch\b"],
    "dinner": [r"\bdinner\b"],
    "walk": [r"\b(outdoor walk|night walk|evening walk|morning walk)\b"],
    "wind_down": [r"\b(wind-down|low-light close|hygiene, bed|bed)\b"],
}
times = collections.defaultdict(list)
for f in files:
    try:
        fh = open(f)
        text = fh.read()
        fh.close()
    except Exception:
        continue
    for m in re.finditer(r"\|\s*(\d{1,2}):(\d{2})[^|]*\|([^|]+)\|", text):
        start_h, start_m, action = m.group(1), m.group(2), m.group(3).lower()
        start_min = int(start_h) * 60 + int(start_m)
        for cat, patterns in categories.items():
            if any(re.search(p, action) for p in patterns):
                times[cat].append(start_min)
                break
def fmt(cat):
    lst = times.get(cat, [])
    if not lst:
        return "unknown"
    avg = sum(lst) / len(lst)
    h = int(avg) // 60
    m_val = int(avg) % 60
    spread = (max(lst) - min(lst)) // 60 if len(lst) > 1 else 0
    return "%02d:%02d (+/-%dh from %d plans)" % (h, m_val, spread, len(lst))
for cat in ["workout", "lunch", "dinner", "walk", "wind_down"]:
    print("- %s: %s" % (cat, fmt(cat)))
PYEOF
)"

# Weekly-review nudge: Mondays only. Measures the calendar span since the last
# weekly review covered through (parsed from the review's "Dates: X → Y" line,
# falling back to the ISO-week Sunday of the filename) and nudges once >= 7 days
# have elapsed. The span is calendar-based, so plan-my-day days you skipped
# still count toward the 7 — a sparse planning week won't under-count. With no
# prior review, it anchors on your oldest plan-my-day entry instead. The plan
# count in the window is reported for the message but isn't a hard gate.
WEEKLY_REVIEW_SIGNAL="$(python3 - "$WEEKLY_DIR" "$PLAN_DIR" <<'PYEOF'
import os, sys, re, glob, datetime
weekly_dir, plan_dir = sys.argv[1], sys.argv[2]
today = datetime.date.today()
if today.weekday() != 0:  # 0 == Monday
    print("none")
    sys.exit(0)

THRESHOLD = 7  # days of elapsed span (gaps included) before nudging

def week_sunday(label):
    m = re.match(r"(\d{4})-W(\d{2})$", label)
    if not m:
        return None
    try:
        monday = datetime.date.fromisocalendar(int(m.group(1)), int(m.group(2)), 1)
    except ValueError:
        return None
    return monday + datetime.timedelta(days=6)

# Latest date any weekly review covered through.
last_review = None
for f in glob.glob(os.path.join(weekly_dir, "*.md")):
    covered = None
    try:
        with open(f) as fh:
            m = re.search(r"Dates:\s*\d{4}-\d{2}-\d{2}\s*→\s*(\d{4}-\d{2}-\d{2})", fh.read())
        if m:
            covered = datetime.date.fromisoformat(m.group(1))
    except (OSError, ValueError):
        covered = None
    if covered is None:  # fall back to the ISO-week Sunday from the filename
        covered = week_sunday(os.path.basename(f)[:-3])
    if covered and (last_review is None or covered > last_review):
        last_review = covered

# Plan-my-day entries (YYYY-MM-DD.md), and which fall after the last review.
plan_dates = []
for f in glob.glob(os.path.join(plan_dir, "*.md")):
    try:
        plan_dates.append(datetime.date.fromisoformat(os.path.basename(f)[:-3]))
    except ValueError:
        pass
plan_dates.sort()
unreviewed = [d for d in plan_dates if last_review is None or d > last_review]

# Anchor the span on the last review covered-through date, else oldest plan.
anchor = last_review if last_review is not None else (unreviewed[0] if unreviewed else None)
if anchor is None:
    print("none")  # nothing reviewed and nothing planned yet
    sys.exit(0)

days = (today - anchor).days
count = len(unreviewed)
last_label = last_review.isoformat() if last_review is not None else "never"
if days >= THRESHOLD or (last_review is None and count >= THRESHOLD):
    print(f"due {days} {count} {last_label}")
else:
    print("current")  # < 7 days since the last review — too soon to nudge
PYEOF
)"

# Habits surfacing. Every helper is a no-op (empty output) when the user hasn't
# set anything up, so this costs nothing until they opt in. (Reminders are NOT
# surfaced or fired here: /remind creates Apple Reminders (EKReminder), which are
# NOT Calendar events and are not read here; /remind-blocking overlays are
# time-sensitive and stay self-contained in their own poller, by design.)
# Today's Apple Calendar events (any commitments the user placed on the calendar),
# recurrences expanded for today. These are HARD time anchors the day is built
# around. No-op (empty) if osascript/Calendar is unavailable.
CALENDAR_TODAY="$(pbrain_calendar_today "$TODAY" || true)"
[[ -n "${CALENDAR_TODAY//[[:space:]]/}" ]] || CALENDAR_TODAY="(none)"
# Sync recent habit-tracking md into the DB so the rollup reflects them.
pbrain_habits_sync_range 7 || true
HABITS_ROLLUP="$(pbrain_habits_rollup "$TODAY" || true)"
[[ -n "${HABITS_ROLLUP//[[:space:]]/}" ]] || HABITS_ROLLUP="(no habit data)"
if [[ -f "$(pbrain_habits_profile_file)" ]]; then HABITS_SETUP_NEEDED=no; else HABITS_SETUP_NEEDED=yes; fi
HABITS_CMD="$(pbrain_habits_cmd 2>/dev/null || true)"
HABITS_TRACK_FILE="$(pbrain_habit_track_file "$TODAY" 2>/dev/null || echo "$VAULT_DIR/life/habit-tracking/$TODAY.md")"
# If a habits profile exists, today's tracker is created automatically (no offer).
# track-init is idempotent — re-running on an existing file is a no-op.
HABITS_TRACK_CREATED=no
if [[ "$HABITS_SETUP_NEEDED" == no ]]; then
  if [[ ! -f "$HABITS_TRACK_FILE" ]]; then HABITS_TRACK_CREATED=yes; fi
  pbrain_habit_track_init "$TODAY" >/dev/null 2>&1 || true
  # Habit↔reminder upkeep (best-effort, silent, degrades without Reminders access):
  # ensure today's one-shots exist for linked habits, then pull any the user
  # already ticked off in the Reminders app back into today's tracker.
  if [[ -n "${HABITS_CMD//[[:space:]]/}" ]]; then
    bash "$HABITS_CMD" reminders-ensure --date "$TODAY" >/dev/null 2>&1 || true
    bash "$HABITS_CMD" reminders-sync   --date "$TODAY" >/dev/null 2>&1 || true
    pbrain_habits_sync_range 1 >/dev/null 2>&1 || true   # re-mirror any pulled marks
    HABITS_ROLLUP="$(pbrain_habits_rollup "$TODAY" || true)"
    [[ -n "${HABITS_ROLLUP//[[:space:]]/}" ]] || HABITS_ROLLUP="(no habit data)"
  fi
fi
HABITS_TODAY_MD="$(cat "$HABITS_TRACK_FILE" 2>/dev/null || echo "MISSING")"
REMIND_CMD="$(pbrain_reminders_cmd)"

# Laptop-tracking opt-in state (the tracker is OFF by default). active = the
# LaunchAgent has been installed; declined = the user said no (or disabled it),
# recorded in the nudge-off marker; not_setup = never touched → nudge ONCE.
LAPTOP_CMD="$_SCRIPT_DIR/laptop-tracking.sh"
LAPTOP_PLIST="$HOME/Library/LaunchAgents/com.pbrain.tracker.plist"
LAPTOP_NUDGE_OFF="${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/tracker-nudge-off"
if [[ -f "$LAPTOP_PLIST" ]]; then
  LAPTOP_TRACKING_STATE=active
elif [[ -f "$LAPTOP_NUDGE_OFF" ]]; then
  LAPTOP_TRACKING_STATE=declined
else
  LAPTOP_TRACKING_STATE=not_setup
fi

cat <<PROMPT
PLAN_MY_DAY_SESSION
date: $TODAY
day_of_week: $DOW
current_time: $NOW_TIME (24h, local)
output_file: $OUT_FILE
profile_file: $PROFILE_FILE
weekly_review_signal: $WEEKLY_REVIEW_SIGNAL
habits_setup_needed: $HABITS_SETUP_NEEDED
habits_track_file: $HABITS_TRACK_FILE
habits_track_created: $HABITS_TRACK_CREATED
laptop_tracking_state: $LAPTOP_TRACKING_STATE
laptop_tracking_cmd: $LAPTOP_CMD

=== GOALS PROFILE ===
$PROFILE_JSON

=== TODAY'S FITNESS JOURNAL ===
$FITNESS_TODAY

=== TODAY'S DAILY JOURNAL ===
$DAILY_TODAY

=== TIMING SIGNAL (learned anchor times from last 21 plans) ===
$TIMING_SIGNAL

=== CADENCE SIGNAL (last 30 plans) ===
$CADENCE_SIGNAL

=== RECENT DAY PLANS (last 7) ===
$RECENT_PLANS

=== TODAY'S CALENDAR (Apple Calendar — hard time anchors for today) ===
$CALENDAR_TODAY

=== HABITS (this week / month vs each habit's criteria) ===
$HABITS_ROLLUP

=== TODAY'S HABIT TRACKER ===
$HABITS_TODAY_MD

---
INSTRUCTIONS — follow these steps in order. Keep the tone warm and concise.

Step 0 — Preflight checks (do these silently, then surface in one short message):
  - PREFERENCE OVERRIDE (check FIRST): if the injected USER PREFERENCES block
    (global or per-command) says to skip the fitness-journal gate/nudge, SKIP
    the FITNESS GATE entirely — go straight to Step 1/Step 2 and just ask once
    "Roughly when's your physical activity today, and what is it?" if you need
    it for the plan. A standing preference always overrides this gate.
  - FITNESS GATE (do this BEFORE anything in Step 1 or Step 2): If TODAY'S
    FITNESS JOURNAL == "MISSING", your first message must be ONLY about the
    fitness journal — do NOT show the Step 1 lens or the Step 2 check-in
    questions yet. Ask: "Your fitness journal isn't done yet — running
    /fitness-journal first means I can slot your workout into the day. Want to
    do that first, or plan around it?" Then STOP and wait for their answer.
      - If they choose to do the fitness journal first: let them go run
        /fitness-journal and finish it. Do not start planning. When they come
        back (the fitness file now exists), THEN proceed to Step 1 (lens) and
        Step 2 (check-ins) as normal.
      - If they say they'll skip it / plan around it / continue: ask once
        "Roughly when's your physical activity today, and what is it? (e.g.
        gym 4pm, football 7pm, rest day)", take their answer, and only THEN
        proceed to Step 1 and Step 2.
    The daily-journal nudge and weekly-review nudge below may ride along in
    this same first message, but the Step 1 lens and Step 2 questions never do.
  - If TODAY'S FITNESS JOURNAL exists, there is no gate — go straight through
    Step 1 and Step 2 in the normal flow.
  - If TODAY'S DAILY JOURNAL == "MISSING": gently mention "Heads up: today's /journal is empty too — you can fill it in later." Do not block.
  - If both exist, skip the preflight nudges.
  - WEEKLY REVIEW (Mondays only) — read \`weekly_review_signal\` above:
      - \`none\` → not a Monday, or nothing to review yet: say nothing.
      - \`current\` → fewer than 7 days since the last weekly review: say nothing.
      - \`due <days> <plans> <last_date|never>\` → it's Monday and \`<days>\` calendar days (gaps included) have passed since your last weekly review — over a week of activity, with \`<plans>\` day-plans logged in that window. Suggest once, don't block. Phrase with the real numbers, e.g.: "It's Monday and it's been <days> days since your last weekly review (\`<last_date>\`), with <plans> day-plans since — want to run /weekly-review first? A few minutes, and it gives today's plan that context. Or I plan now and you do it later." If \`<last_date>\` is \`never\`, say it's been <days> days of planning with no weekly review yet. If they say plan now, continue; offer to remind them at the end.
  - If the profile's \`current_focus\` array is empty, mention once: "You haven't pinned a current focus in your profile yet — want to name 1–3 things you're actively pushing this month? I'll save them so I can anchor future plans on them." Don't block planning today either way.
  - CALENDAR — read the TODAY'S CALENDAR block above. These are the user's Apple Calendar events for today (created via /remind or set directly in Calendar), with recurrences already expanded. They are HARD ANCHORS — the day is built around them. Surface today's TIMED items in your first message as fixed points (e.g. "On your calendar today: standup 9:30, dentist 14:00"). Note any ALLDAY items as context, and mention FREQUENT pings (e.g. "hourly stand-up reminder") only once, briefly. If it's "(none)", say nothing. These feed Step 4a as non-negotiable rows — do NOT ask the user to restate them; treat them like already-confirmed locked-in commitments.
  - HABITS — read the HABITS block + \`habits_setup_needed\` above:
      - If \`habits_setup_needed\` == yes: mention ONCE, don't block — "You haven't set up habit tracking yet — /habits lets you pick a few habits to build or cap, and I'll surface them here. Want to set it up later?" Skip this if the user's preferences say not to nag about habits. If the user tells you to stop asking about habits, that's a GLOBAL standing preference (it spans commands) — capture it in \`prefs/_global.md\` via the self-improve loop, not a per-command pref.
      - If a HABITS rollup is present: note anything that needs attention today — a limit habit at/over cap (⚠️), or a high-priority build habit lagging / untouched this week — and factor it into the plan (e.g. slot a short block for a lagging build habit). One line, not a lecture.
  - LAPTOP TRACKING — read \`laptop_tracking_state\` above. It's OFF by default:
      - \`not_setup\` → mention ONCE, don't block — "Want me to track where your laptop time goes (which apps, which sites)? /laptop-tracking start turns on a quiet background tracker and you'll get a daily breakdown. Or say no and I won't ask again." If they say yes, tell them to run \`/laptop-tracking start\` (then \`/laptop-tracking access\` to grant per-browser domain access). If they say no / not now / stop asking, run \`bash "\$laptop_tracking_cmd" decline\` so this never nudges again. Skip the nudge entirely if the user's preferences say not to nag about it.
      - \`active\` or \`declined\` → say NOTHING about laptop tracking.

Step 1 — Show the user their lens, briefly:
  Print 2-3 lines max — their current_focus goals as bullets (or, if empty,
  list horizon_goals). Frame as the anchor for today, NOT as a quiz.
  Example:
    "Anchoring on:
     • Ship pbrain v1 (this week: publish repo + write blog post)
     • Drop 3 kg by July (this week: 4 gym sessions + diet streak)
     • Learn jazz piano (this week: 4×30 min practice)"

Step 1.5 — Anchor confirmation (its own message, before Step 2):
  Read the profile JSON for a "daily_anchors" block. If present, use those values as defaults (label them "(profile)").
  If absent, use the TIMING SIGNAL averages above as inferred defaults (label them "(inferred from past plans)").
  Only include anchors that have a real value — skip any that are "unknown".
  Present a compact pre-filled list:

    "Here are your anchor times for today — all good, or anything different?
     • Workout: {time} {(profile) or (inferred)}
     • Lunch: {time} {source}
     • Dinner: {time} {source}
     • Walk: {time or 'none'} {source}
     • Bed: {time} {source}
    (Say what's different, e.g. 'dinner at 11:30pm, no walk today' — or 'all good'.)"

  Wait for their reply. Store the confirmed anchor times as the fixed skeleton for Step 4.
  Track which anchors differ from the profile's daily_anchors (or that the profile has no daily_anchors yet) — Step 5 will offer to save any changes.

Step 2 — Run the check-in as an INTERVIEW, not an exam. Do NOT dump a numbered
  list of questions in one message. Instead, have a short back-and-forth: lead with
  the morning, then let each answer steer what you ask next, asking ONE thing (or a
  tight, naturally-related pair) per turn and waiting for the reply before moving on.
  Keep it warm and brief — a conversation, not a form.

  HOW TO RUN IT:
  - OPEN with the morning, always first: "Before we plan — what time did you wake up,
    and what time did you go to bed last night? Also, what have you got done since waking?"
    Wait. This anchors the plan to the real day and gives you the sleep window.
  - THEN let it flow adaptively. Read each answer and ask the natural next thing. If an
    answer already covers a later topic (e.g. they mention "I've got a 4pm call" or "no
    energy today"), DON'T re-ask it — note it and move on. Skip anything already answered
    in passing. The goal is to feel heard, not interrogated.
  - You may bundle two closely-related things in one turn when it reads naturally
    (e.g. energy + how the body feels), but never more than that — no walls of questions.

  DATA POINTS TO COLLECT (these are the fields the rest of the plan needs — gather them
  through the conversation in whatever order fits, not as a fixed script). Referenced
  later as q1–q9:
  - q1 — wake time today.
  - q1b — bed time last night (collected in the same opening turn as q1). Compute sleep
    duration (bed → wake, adding 24h if bed > wake for the midnight crossing). If sleep
    < 7h OR working_style.day_wreckers contains "sleep" (case-insensitive), flag it in
    your reply: "You got Xh of sleep — that's one to watch today."
  - q2 — what they've already done since waking (the important parts: work, meals,
    exercise, errands). You'll backfill these as already-done (✓) rows.
  - q3 — energy/mood right now (1–10 + a word).
  - q4 — their TOP THINGS to get done today, named IN ORDER OF COMPLEXITY / PRIORITY
    (most complex or highest-priority first). This is the Now / Next / Later input: usually
    the top 3, but NOT capped — they can name 2, or 5. Ask for the things and their order,
    NOT for block counts or start times — YOU allocate those in Step 4. A "thing" can be
    any deliberate task: work, creative, seeing someone, a gym session. If they're unsure
    of order, infer it from focus_today priority + how hard each sounds, and confirm.
    On a low-energy day it's fine if they name only one thing or none.
    (How these become blocks: Step 4 splits them across as many work blocks as the day
    holds, giving the more complex / higher-priority things MORE blocks, tucking small
    ones into a shared block, and weaving 30-min breaks between blocks — then shows the
    proposed split for the user to adjust. You don't ask the user to place blocks or
    breaks one by one.)
  - q5 — any locked-in commitments not already mentioned (meetings, calls, appointments).
  - q6 — roughly how many focused hours they have today.
  - q7 — anything to specifically avoid today (defaults to profile anti_patterns if they
    don't volunteer one).
  - q8 — mood for creative work (yes / maybe / not today).
  - q9 — anything to declutter or tidy (inbox, desk, files, tabs — or none).

  q1/q1b and q2 anchor the plan to the real day: use q1 as the table's start time
  (overriding the profile/inferred wake time if it differs), and log each important thing
  from q2 as a ✓ row in the "Today at a glance" table. Sleep duration (q1b → q1) feeds
  the coaching note and Notes section if short. These q-labels carry through to Steps 3–4.

  Don't belabor it — if the user gives a lot up front, a couple of follow-ups is enough;
  don't ask all nine just to complete the set. Once you have what you need to build a
  real plan, move on.

  DECLUTTER OVERRIDE: the declutter point (q9) is opt-out. If the user's standing
  preferences say not to ask about decluttering, DON'T ask it at all. Otherwise work it in.
  If the user says "stop asking me to declutter" this session, the self-improve check at
  the end will offer to save that as a preference.

Step 3 — Cadence sweep. Use CADENCE SIGNAL + profile's personal_anchors.relationships to decide if any touchpoints should be surfaced today. Rules of thumb (only suggest if the contact appears in personal_anchors.relationships):
    - parents (mom/dad) gap >= 6 days → suggest a call
    - siblings gap >= 14 days → suggest a quick check-in
    - friends gap >= 7 days → suggest reaching out to one named friend from the profile
    - creative gap >= 4 days AND user said yes/maybe in q8 → suggest a creative block tied to their craft from personal_anchors.creative_pursuits
    - walk gap >= 2 days AND "daily walk" or similar is in personal_anchors.health_habits → suggest one
  Phrase as suggestions, not commands. Skip anything the profile doesn't endorse.

Step 4 — Generate the full day plan draft in memory (do NOT write to disk yet).
  STRUCTURE: lead with a consolidated **Today at a glance** table (time range + action + tie). All subjective detail — coaching, eating, breaks, rest, avoids — comes AFTER the table as supporting sections. The table is the operating doc; the sections are reference.

  Time-range rules — ANCHOR-FIRST approach:
  Step 4a — Use the confirmed anchors from Step 1.5 as the fixed skeleton rows. Then layer on top:
    1. CALENDAR EVENTS (from the TODAY'S CALENDAR block) and locked-in commitments from q5, plus explicit block times from q4 — these are absolute, never shift them. A calendar TIMED item must appear in the table at its exact time window with its title; tie it to a goal/category or "—". Two calendar items that overlap → keep both and flag the conflict to the user. Don't invent calendar items that aren't in the block.
    2. The confirmed anchors (workout, lunch, dinner, walk, bed) — these are non-negotiable skeleton rows, scheduled AROUND the fixed calendar/commitment rows above.
    Maximum 15–30 min variance from any confirmed anchor time. More than that is a plan error. Calendar items have ZERO variance — they sit exactly where the calendar says.
    The skeleton arc is: wake → workout → post-workout/lunch → blocks → dinner → walk → wind-down → bed. Fill gaps with transitions, breaks, meals.
  Step 4b — CRITICAL: The table ALWAYS starts at the user's actual wake time today (q1), NOT at current_time. If q1 differs from the profile/inferred wake time, q1 wins. current_time is only for surfacing reminders — it must NEVER influence where the plan begins. Even if /plan-my-day is run at 13:00 and wake time is 07:30, the first table row is 07:30. The plan spans the full day: wake → bed. BACKFILL the morning: everything the user reported in q2 (what they've already done since waking) goes into the table as already-done rows at its real time, marked with a ✓ in the Action cell — so the table reflects the whole real day, not just what's ahead.

  ALLOCATE BLOCKS FROM TASKS (q4): the user gave a priority/complexity-ordered list of things to do, NOT pre-formed blocks. YOU turn that list into blocks:
    - Estimate each task's complexity/effort from its description + its focus_today priority + the order the user gave (earlier = more complex/important).
    - Give the more complex / higher-priority tasks MORE blocks (a deep task → 2–3 blocks; a medium task → 1 block; a small/light task → tuck it into the tail of another block or let one block hold 2 small things). Block count is proportional to complexity, not 1-per-task.
    - There is NO 3-block cap — lay in as many ~deep_work_block_min blocks as the wake→bed span and the q6 focused-hours ceiling allow. A full day might be 5–6 blocks; a low-energy day might be 1.
    - Default placement rhythm: morning block(s), then post-lunch, then evening (the Now / Next / Later arc — most complex/important first while fresh). Honor any time the user explicitly stated for a task.
    - Each block ≥ deep_work_block_min wide; total intentional block time ≤ q6 hours.
    - Label each block with its task(s) and tie it to the right goal/category in the Tie column.
    - PROPOSE the split and let the user adjust (Step 4d already shows the table for confirmation — make the block→task allocation visible there, e.g. "Lettuce got 2 blocks, Spotify tucked into Kickapp's tail — adjust?").
  Step 4b-breaks — BREAK BLOCKS: between every pair of CONSECUTIVE work/intentional blocks, weave in a ~break_block_min break row (default 30 min; from working_style.break_block_min, fallback 30). Each break's activity is drawn from working_style.break_activities (e.g. short walk, a couple of games, prep + eat a light snack, stretch) — ROTATE through the menu so consecutive breaks differ; don't repeat the same one back-to-back. Tie column = Rest (or Rest / Eating for a snack break, Rest / Fit body for a walk). These breaks are part of how gaps between blocks get filled — so two adjacent blocks become: block → break → block. If working_style.break_activities is empty/absent, fall back to a generic "Break — short walk / rest, no screens" row. Don't force a break before the very first block of the day or after the last (those gaps are filled by meals/transitions/wind-down as usual). Respect anti_patterns: if a break activity is on the avoid list today (e.g. EAFC over cap), pick a different one from the menu.
  Step 4c — Use 24h times throughout (HH:MM–HH:MM). Never use "Morning / Midday / Evening" labels. Every row must have both a start and end time. Maximum 15–30 min deviation from learned/stated anchors unless the user explicitly set a different time.
  - GAP-FREE & OVERLAP-FREE: the table must account for every span of time from wake to bed with NO gaps and NO overlaps. No two rows may overlap (one row ends exactly where/before the next begins); no unexplained empty time between rows. Fill any gap with an explicit rest / transition / meal / decompress row rather than leaving a hole. Already-done backfilled rows (from q2) follow the same rule — they tile cleanly alongside the planned rows. If a backfilled item and a planned anchor would overlap, adjust to remove the overlap and flag it to the user.
  - REQUIRED rows (every plan must include ALL of these if confirmed): wake/morning-start, workout, lunch, dinner, walk (if anchored), wind-down, bed. Missing any of these is a plan error.
  - Include in the table: every named block (Block 1, Block 2, … however many, with time windows), the break blocks woven between them, the fitness anchor, every meal window (breakfast if present, lunch, dinner), post-work walk if surfaced, wind-down start, bed-by. Every row's "Tie" column maps back to a current_focus goal, a profile category (Fit body, Rest, Eating, Relationships, Creative, Social), or "—" if standalone.
  - Keep the table tight — one line per action, no wrapped text. Time | Action | Tie.
  - Named blocks (Block 1, Block 2, …) should tie to a current_focus goal or profile category in the Tie column where possible.

  ---
  type: plan
  date: $TODAY
  day_of_week: $DOW
  status: planned
  energy: {1-10 from q3}
  sleep_hours: {computed from q1b and q1, e.g. 7.5 — omit if q1b not given}
  focus_today: [{current_focus goal names that any of the q4 blocks tie back to — empty array if none}]
  tags: []
  ---

  # Day Plan — $TODAY ($DOW)

  > {one short coaching note tuned to today's energy, top 3 picks, fitness intent, and sleep if short (< 7h). 1-2 sentences. No platitudes. Tie back to a goal if natural.}

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
  - {each locked-in commitment from q5 with brief context, not the time — skip if none}

  ## Blocks

  - {ONE bullet per block the user named in q4 — however many (Block 1, Block 2, Block 3, Block 4, …). For each: **Block N (HH:MM–HH:MM):** type (work/creative/social/etc), concrete description + what "done" looks like. Time window must match the table row exactly. Minimum deep_work_block_min wide. Annotate "→ <goal/category>" if it ties back. Don't pad to a fixed count and don't cap at 3 — list exactly the blocks that exist today.}
  - {The 30-min break blocks woven between them live in the table; you don't need a bullet each here, but you may add one line noting the break rhythm, e.g. "Each block is separated by a 30-min break (walk / 2 games / snack prep) — the rhythm, not a quota."}
  - Cap on intentional block time today: {q6 number}h — ceiling, not floor.

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

  - {if yes/maybe in q8, suggest 1 concrete block tied to a craft from profile.personal_anchors.creative_pursuits — "30-60 min music practice", "Draft one section after dinner", "Edit 10 photos", etc. If creative was already named as one of the q4 tasks/blocks, just reference it here — don't double-list.}
  - {if not today, write "Skipping creative today — recharge"}

  ## Rest

  - {1-2 lines on what NOT to do in the wind-down, tied to q7 and profile.anti_patterns. Times for wind-down and bed live in the table above.}

  ## Avoiding today

  - {union of q7 answers + profile.anti_patterns relevant for today, deduped — one bullet each}

  ## Notes

  - {1-3 bullets: anything else worth flagging — interaction between fitness + work, weather, anything from the daily journal, day-wrecker signals}

  ## Declutter

  - {q9: if the user named a tidy/declutter task, write it as a checkbox — "- [ ] Clear inbox to zero". If they said none, or q9 was dropped per their preferences, write "—". /end-of-day reads this section and ticks it off.}

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

Step 4d — Show the full **Today at a glance** table to the user and ask for confirmation:
  Show the table, then briefly name how you split the tasks into blocks (e.g. "Lettuce got 2 blocks since it's the deep one, Spotify's tucked into Kickapp's tail, 30-min breaks between each"), then ask: "Does this look right? You can re-split the blocks, change any times, swap or drop rows — just tell me what to adjust. Say 'looks good' to save."
  Wait for their response. Apply any edits they request (time changes, new rows, renamed actions, dropped rows). Repeat the updated table if changes were made.
  Once the user says it looks good (or gives no objections), write the complete plan — table + all sections — to $OUT_FILE.

Step 5 — After writing, confirm: "Saved → $OUT_FILE"

Step 5b — Anchor profile update (only if anchors changed or profile has no daily_anchors yet):
  If today's confirmed anchors from Step 1.5 differ from the profile's daily_anchors, OR the profile has no daily_anchors block at all:
  Offer once: "Today's anchor times differ from your profile — want me to save these as your new defaults?"
  On yes: read $PROFILE_FILE, parse the JSON block, update (or add) the "daily_anchors" keys with today's confirmed values, write the file back. Only update the keys the user touched today — do not wipe other keys. Keep all other profile fields and the markdown prose intact. The JSON block must remain valid.
  On no or if anchors matched exactly: skip silently.

Step 5c — Reschedule habit reminders to planned times (silent, best-effort):
  Look at the plan table you just wrote. For any row whose action corresponds
  to a habit from today's tracker AND the row has an explicit start time,
  align that habit's one-shot Apple Reminder to the planned time:
    bash "$HABITS_CMD" reminders-reschedule --habit "<name>" --time "HH:MM" --date $TODAY
  Only call this for habits that appear at a specific clock time in the plan.
  Ignore habits with no explicit time slot. NOT_LINKED / NOT_FOUND responses
  mean the habit has no reminder — skip silently. No user output for this step.

Step 6 — Reminders (only if relevant — don't force it):
  If anything time-bound came up while planning (a call/appointment at a set
  time, "pay X today", "don't forget Y at 6") and it isn't already a pending
  reminder, offer ONCE to set it so it pings as a notification:
    bash "$REMIND_CMD" add --text "<clean text>" --due "<YYYY-MM-DD HH:MM>" [--repeat daily|weekdays|weekly|monthly]
  Resolve the due time relative to today ($TODAY) + the current time. Set it
  only on a yes. Don't pester — at most one short offer covering all of them.

Step 7 — Habit check-in (only if \`habits_setup_needed\` == no). At the very end:
  PREFERENCE OVERRIDE: if the injected USER PREFERENCES block says not to nag /
  ask about habits, skip this whole step — don't show the checklist or ask.
  a) Today's tracker is ALREADY created — the command auto-builds it whenever a
     habits profile exists, so there is NO offer to make and nothing to ask. Just
     state it in one line: if \`habits_track_created\` == yes, "Set up today's
     habit tracker."; if \`no\`, "Today's habit tracker is ready." (it already
     existed). Never ask "Want me to set up today's habit tracker?" again.
  b) Show the user today's habit checklist from TODAY'S HABIT TRACKER — just the
     table rows, concise. Then ask ONCE:
       "Any you've already done today? Name them and I'll mark them now (e.g.
        'meditation, walked'). Or skip — run /habits anytime through the day to
        check and mark more, or just leave it and /end-of-day consolidates."
  c) On any named habits, mark each one:
       bash "$HABITS_CMD" mark --habit "<name>" --date $TODAY
     Then push those marks to Apple Reminders (best-effort, silent on failure):
       bash "$HABITS_CMD" reminders-sync --date $TODAY
     Confirm what was marked. One round only — don't loop asking for more.
  Don't force marking — the tracker is auto-created; marking is one ask, no loop.
PROMPT

# Habit extraction (silent if no habits profile): logs the tracked habits the
# user said they did / will do today. Self-improvement capture runs after.
pbrain_emit_habits_extract "plan-my-day" || true
pbrain_emit_self_improve "plan-my-day" "$PROFILE_FILE" "goals profile" || true
