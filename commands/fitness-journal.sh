#!/usr/bin/env bash
set -euo pipefail

# fitness-journal.sh
# Flexible daily fitness journal — logger-first. The user says what they did in
# plain words; we parse it into the activity's per-activity KPIs, tolerate
# partial/missing data, and write the day's file. We never prescribe onto a session
# they are REPORTING. But when they PLAN AHEAD a session not done yet (accept the
# owed/scheduled session, or ask "plan it" / "what should I do"), we GENERATE a
# complete, ready-to-follow session: gym uses Block/Day rotation + progressive
# overload + training-gap deload; non-gym uses concrete KPI targets.
#
# Base config lives in the VERSIONED PROFILE STORE (lib/profiles.sh) under
# the tracking dir:
#   <tracking-dir>/.profile/fitness-profile.vN.md   — overall fitness profile
#       (sleep bed/wake times + hours, steps/day, health-tracker metrics)
#   <tracking-dir>/.profile/fitness-library.vN.md   — activity library
#       (activities + stable metadata + occurrence per week|month + per-activity
#        `kpis` — what to log for each, e.g. gym→sets, swim→distance, dance→min)
#   <tracking-dir>/.profile/activities/<slug>.vN.md — per-activity profiles
#       (fixed days-of-week, goals, focus areas; gym keeps its Block/Day tables
#        which DRIVE generated gym sessions; equipment captured here ONCE)
#
# KPIs are USER-EXTENSIBLE (the profile defines which KPIs each activity has)
# and BACKWARD-COMPATIBLE: when a library activity has no `kpis`, the daily flow
# derives sensible archetype defaults on the fly and offers to save them — no
# migration required.
#
# First run bootstraps the profile + library + per-activity profiles via
# interview; daily runs open with "what did you do today?", parse the
# description into the activity's KPIs, and log it. The training-gap band and
# fixed-day schedule DRIVE on-request plan generation (which session is owed, gym
# rotation/deload); generation fires only when the user is planning a session ahead.
#
# `fitness-journal.sh profile show|new|commit [base]` manages the profiles:
# drafts are editable, committed versions are final (changes mint the next
# version). Migration 0003 rebuilds the old plans/json into this store.
#
# Default destination:  $VAULT_DIR/fitness/daily-tracking
# Overrides:
#   PBRAIN_VAULT        — set the vault root
#   PBRAIN_FITNESS_DIR  — daily-tracking dir (the store lives inside it)
#   (PBRAIN_GYM_PLAN_FILE / PBRAIN_FITNESS_PLANS_DIR /
#    PBRAIN_FITNESS_ACTIVITIES_FILE only matter to migration 0003 now.)

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

# Surface this user's standing preferences for /fitness-journal (emits nothing if none set).
pbrain_emit_prefs "fitness-journal" "$(pbrain_profile_latest_any "$(pbrain_profile_store "${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}")" fitness-profile)" || true

TRACKING_DIR="${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}"
STORE="$(pbrain_profile_store "$TRACKING_DIR")"
ACT_STORE="$STORE/activities"

TODAY="$(date +%Y-%m-%d)"
DOW="$(date +%a)"
# Authoritative, fully-spelled local date — the LLM must copy this verbatim and
# never compute the weekday itself (it gets it wrong). %e is space-padded day
# (BSD-portable); tr squeezes the gap so single-digit days read cleanly.
TODAY_HUMAN="$(date '+%A, %B %e, %Y' | tr -s ' ')"
OUT_FILE="$TRACKING_DIR/$TODAY.md"
DIET_DIR="${PBRAIN_DIET_DIR:-$VAULT_DIR/fitness/diet-tracking}"

mkdir -p "$TRACKING_DIR"

# Canonical activity slug (matches the old plans/<slug>.md convention).
_fitness_slug() {
  python3 - "${1:-}" <<'PYEOF' 2>/dev/null || printf '%s\n' "activity"
import re, sys
name = sys.argv[1] if len(sys.argv) > 1 else ""
print(re.sub(r"[^a-z0-9]+", "-", name.strip().lower()).strip("-") or "activity")
PYEOF
}

# ---------------------------------------------------------------------------
# `profile` subcommand — manage the versioned fitness profiles.
#   profile show
#   profile new    [fitness-profile|fitness-library|activity <name>]
#   profile commit [fitness-profile|fitness-library|activity <name>]
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "profile" ]]; then
  ACTION="${2:-show}"
  BASE="${3:-fitness-profile}"
  P_STORE="$STORE"
  if [[ "$BASE" == "activity" ]]; then
    NAME="${4:-}"
    if [[ -z "$NAME" ]]; then
      echo "usage: fitness-journal.sh profile $ACTION activity <name>" >&2
      exit 2
    fi
    BASE="$(_fitness_slug "$NAME")"
    P_STORE="$ACT_STORE"
  fi
  case "$ACTION" in
    show)
      echo "FITNESS_PROFILE_SHOW"
      for b in fitness-profile fitness-library; do
        f="$(pbrain_profile_latest "$STORE" "$b")"
        d="$(pbrain_profile_draft "$STORE" "$b")"
        echo ""
        echo "=== $b (committed: ${f:-none}; draft: ${d:-none}) ==="
        [[ -n "$f" ]] && cat "$f"
      done
      if [[ -d "$ACT_STORE" ]]; then
        for af in "$ACT_STORE"/*.v*.md; do
          [[ -f "$af" ]] || continue
          echo ""
          echo "=== activity profile: $af ==="
          cat "$af"
        done
      fi
      echo ""
      echo "---"
      echo "INSTRUCTIONS: Present the profiles above as a short human-readable summary"
      echo "(overall profile: sleep window, steps, metrics; library: each activity with"
      echo "occurrence + fixed days; one line per activity profile: focus + days)."
      echo "Do not dump raw JSON. Committed profiles are final — to change one, run:"
      echo "  /fitness-journal profile new [fitness-profile|fitness-library|activity <name>]"
      exit 0
      ;;
    new)
      DRAFT="$(pbrain_profile_draft "$P_STORE" "$BASE")"
      if [[ -n "$DRAFT" ]]; then
        echo "FITNESS_PROFILE_DRAFT_OPEN"
        echo "draft: $DRAFT"
        echo "A draft of $BASE is already open. Iterate on it with the user and, when they"
        echo "confirm, finalize with: bash \"$_SCRIPT_DIR/fitness-journal.sh\" profile commit $BASE"
        exit 0
      fi
      NEW_PATH="$(pbrain_profile_new "$P_STORE" "$BASE")" || exit 1
      echo "FITNESS_PROFILE_NEW"
      echo "draft: $NEW_PATH"
      echo ""
      echo "INSTRUCTIONS: A new DRAFT version of $BASE was minted (copied from the previous"
      echo "version when one existed). Walk the user through what they want to change,"
      echo "edit the draft file directly (keep the fenced JSON block valid and the"
      echo "frontmatter version/committed lines intact), iterate until they are happy,"
      echo "then finalize with:"
      echo "  bash \"$_SCRIPT_DIR/fitness-journal.sh\" profile commit ${3:-fitness-profile}${4:+ $4}"
      echo "Once committed the version is FINAL — further changes mint the next version."
      exit 0
      ;;
    commit)
      OUT="$(pbrain_profile_commit "$P_STORE" "$BASE")" || exit 1
      echo "FITNESS_PROFILE_COMMITTED"
      echo "file: $OUT"
      echo "This version is now final. Future changes: /fitness-journal profile new"
      exit 0
      ;;
    *)
      echo "usage: fitness-journal.sh profile show|new|commit [fitness-profile|fitness-library|activity <name>]" >&2
      exit 2
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Staged migration 0003 — rebuild the old plans/json into the profile store.
# Pending only when old data exists and the store is empty; recorded (and so
# never re-run) once the rebuild lands.
# ---------------------------------------------------------------------------
if declare -F pbrain_migration_pending >/dev/null \
   && pbrain_migration_pending 0003_fitness_profiles; then
  OLD_ACTIVITIES_FILE="${PBRAIN_FITNESS_ACTIVITIES_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/fitness-activities.json}"
  OLD_GYM_PLAN="${PBRAIN_GYM_PLAN_FILE:-$VAULT_DIR/fitness/Gym Plan.md}"
  OLD_PLANS_DIR="${PBRAIN_FITNESS_PLANS_DIR:-$VAULT_DIR/fitness/plans}"
  echo "FITNESS_JOURNAL_MIGRATION"
  echo "store: $STORE"
  echo "backup_dir: $VAULT_DIR/.pbrain/backup"
  echo ""
  echo "=== OLD ACTIVITIES CONFIG ($OLD_ACTIVITIES_FILE) ==="
  cat "$OLD_ACTIVITIES_FILE" 2>/dev/null || echo "(none)"
  echo ""
  echo "=== OLD GYM PLAN ($OLD_GYM_PLAN) ==="
  cat "$OLD_GYM_PLAN" 2>/dev/null || echo "(none)"
  echo ""
  echo "=== OLD PER-ACTIVITY PLANS ($OLD_PLANS_DIR) ==="
  if [[ -d "$OLD_PLANS_DIR" ]]; then
    for pf in "$OLD_PLANS_DIR"/*.md; do
      [[ -f "$pf" ]] || continue
      echo "--- $pf ---"
      cat "$pf"
      echo ""
    done
  else
    echo "(none)"
  fi
  cat <<MIGRATE

---
INSTRUCTIONS — one-time migration to the new fitness profile store. Do not
plan any session yet. Tell the user: pbrain now keeps fitness config as
versioned profiles; you'll walk their existing setup across (a few minutes,
their data carries over — plus a few new questions).

Step 1 — Validate the old data PART BY PART (not in one go). For each old
activity and its plan above, ask: keep as is, update, or drop? Quote the
relevant part back so they confirm against real content, then ask per
activity: how many times per week (or per month) do you do this? Which FIXED
days of the week? Assign non-conflicting days: gym defaults to 4x/week (e.g.
Mon/Tue/Thu/Fri), spread the rest over free days — two activities should not
land on the same day unless the user explicitly wants it. Let the user
override any assignment.

Step 2 — Ask the NEW overall-profile questions the old data lacks:
  - What time do you usually get to bed, and what time do you wake up?
    (Infer sleep hours from the two, handling the midnight crossing.)
  - Roughly how many steps do you take per day?
  - Any other metrics from a health tracker (Whoop, Garmin, Apple Health)
    you want tracked here? (resting HR, HRV, anything they care about.)

Step 3 — Write the new profiles (mkdir -p first). ALL committed v1 files:

  $STORE/fitness-profile.v1.md — frontmatter (type: fitness-profile,
  date: $TODAY, tags: [], version: 1, committed: true), a heading, then:
  \`\`\`json
  {"created": "$TODAY",
   "sleep": {"bed_time": "HH:MM", "wake_time": "HH:MM", "hours": 0.0},
   "steps_per_day": 0,
   "health_metrics": {"source": "whoop|garmin|apple_health|none", "notes": "..."},
   "notes": "..."}
  \`\`\`

  $STORE/fitness-library.v1.md — same frontmatter discipline (type:
  fitness-library), JSON:
  \`\`\`json
  {"created": "$TODAY", "activities": [
    {"id": "<slug>", "name": "<Name>", "shortcut": "<2-3 letters>",
     "occurrence": {"per": "week", "times": N},
     "equipment": "...", "location": "...", "typical_time": "HH:MM",
     "duration_min": N, "notes": "stable metadata"}]}
  \`\`\`

  $ACT_STORE/<slug>.v1.md per kept activity — carry the old plan body over
  (Current state / Goals / Weekly structure / Focus areas / Milestones /
  Notes; the gym profile KEEPS its parseable "## Block N" + "### Day X"
  tables), frontmatter gains: days: [Mon, Thu, ...], occurrence: "N/week",
  version: 1, committed: true. Capture equipment access here (from the old
  plan or by asking once) — the daily session will never ask again.

Step 4 — Park the old files so nothing is lost (do NOT delete):
  mkdir -p "$VAULT_DIR/.pbrain/backup"
  mv "$OLD_GYM_PLAN" "$VAULT_DIR/.pbrain/backup/" 2>/dev/null; mv "$OLD_PLANS_DIR" "$VAULT_DIR/.pbrain/backup/plans" 2>/dev/null
  (Leave $OLD_ACTIVITIES_FILE in place — it is superseded, not harmful.)

Step 5 — Record the migration so it never re-runs:
  bash "$_SCRIPT_DIR/../lib/migrations.sh" record 0003_fitness_profiles

Step 6 — Confirm: "Fitness profiles migrated → $STORE. Re-run /fitness-journal
to log today's session." Stop here.
MIGRATE
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolution — latest committed profiles from the store.
# ---------------------------------------------------------------------------
FITNESS_PROFILE_FILE="$(pbrain_profile_latest "$STORE" fitness-profile)"
LIBRARY_FILE="$(pbrain_profile_latest "$STORE" fitness-library)"

# ---------------------------------------------------------------------------
# PHASE 0 — first-run setup: overall profile + activity library.
# ---------------------------------------------------------------------------
if [[ -z "$FITNESS_PROFILE_FILE" || -z "$LIBRARY_FILE" ]]; then
  # A draft minted via `profile new` must be finished, not clobbered by the
  # fresh-setup instructions below.
  for _b in fitness-profile fitness-library; do
    _D="$(pbrain_profile_draft "$STORE" "$_b")"
    if [[ -n "$_D" ]]; then
      echo "FITNESS_PROFILE_DRAFT_OPEN"
      echo "draft: $_D"
      echo ""
      cat "$_D"
      echo ""
      echo "---"
      echo "A $_b draft is already open (shown above). Review it with the user, apply"
      echo "any edits they want (keep the fenced JSON valid), then finalize with:"
      echo "  bash \"$_SCRIPT_DIR/fitness-journal.sh\" profile commit $_b"
      echo "The daily flow starts once the profile is committed."
      exit 0
    fi
  done
  unset _b _D
  cat <<SETUP
FITNESS_JOURNAL_SETUP_PROFILE
store: $STORE

INSTRUCTIONS — first-time setup (step 1 of 2). Do not generate any session yet.

Step 1 — Tell the user this is a one-time setup, then interview them in two
short batches (not one wall of questions):

  Batch A — overall fitness profile:
  - What time do you usually get to bed, and what time do you wake up?
    (Infer sleep hours from the two — handle the midnight crossing.)
  - Roughly how many steps do you take per day?
  - Any metrics from a health tracker (Whoop, Garmin, Apple Health) you want
    tracked here? (resting HR, HRV, recovery scores — whatever they care about.)

  Batch B — activities:
  - What activities do you do (or want to track)? Examples: gym, football,
    basketball, swimming, running, cycling, yoga, climbing, Apple Fitness+,
    home workouts…
  - For each: how many times per week (or per month)? Which FIXED days of the
    week? Assign non-conflicting days — gym defaults to 4x/week (e.g.
    Mon/Tue/Thu/Fri), spread other activities across the remaining days; two
    activities only share a day if the user explicitly wants that. Also ask
    equipment access, usual location, typical start time, typical duration.
  - What do you want to LOG for each activity (its KPIs)? Suggest sensible
    defaults and let the user trim or add: gym → sets (exercise/reps/weight);
    swimming → distance (km) + duration (min); running → distance + duration +
    intensity; cycling → distance + duration; dancing / yoga / meditation →
    duration (min); team sport → duration + notes; Apple Fitness+ / home →
    duration + workout type. Keep it light — the user can skip KPIs any day, and
    add more later. KPI types are one of: sets, number, distance, duration,
    rating (1–10), text.

Step 2 — Write BOTH files (mkdir -p "$STORE" first), committed v1:

  $STORE/fitness-profile.v1.md:
  ---
  type: fitness-profile
  date: $TODAY
  tags: []
  version: 1
  committed: true
  ---

  # Fitness profile

  \`\`\`json
  {"created": "$TODAY",
   "sleep": {"bed_time": "HH:MM", "wake_time": "HH:MM", "hours": 0.0},
   "steps_per_day": 0,
   "health_metrics": {"source": "whoop|garmin|apple_health|none", "notes": "..."},
   "notes": "..."}
  \`\`\`

  $STORE/fitness-library.v1.md:
  ---
  type: fitness-library
  date: $TODAY
  tags: []
  version: 1
  committed: true
  ---

  # Fitness library

  \`\`\`json
  {"created": "$TODAY", "activities": [
    {"id": "<slug>", "name": "<Name>", "shortcut": "<2-3 letters>",
     "occurrence": {"per": "week", "times": N},
     "days": ["Mon", "Thu"], "equipment": "...", "location": "...",
     "typical_time": "HH:MM", "duration_min": N, "notes": "...",
     "kpis": [{"id": "<slug>", "label": "<Display>",
               "type": "sets|number|distance|duration|rating|text",
               "unit": "<unit or null>"}]}]}
  \`\`\`

  - <slug> = lowercase, non-alphanumerics → "-" (e.g. "Apple Fitness+" →
    "apple-fitness").
  - \`kpis\` = what to log for that activity (from Batch B). Examples:
    gym → [{"id":"sets","label":"Sets","type":"sets","unit":null}];
    swimming → [{"id":"distance","label":"Distance","type":"distance","unit":"km"},
                {"id":"duration","label":"Duration","type":"duration","unit":"min"}];
    yoga → [{"id":"duration","label":"Duration","type":"duration","unit":"min"}].
    A \`sets\`-type KPI renders the per-exercise Log table; the others render as a
    KPI row (value or "—" when not logged). KPIs are optional and extensible.
  - Do NOT include "Rest day", "Recovery", or "Walk/cardio" as activities —
    those are always offered automatically.
  - The library is a LIVING document — new activities (and new KPIs of a known
    type on an existing activity) are appended in place later; the version only
    bumps on a structural rebuild.

Step 3 — Confirm: "Profile + library saved. Now I'll build a per-activity
profile for each activity — re-run /fitness-journal to continue."
SETUP
  exit 0
fi

FITNESS_PROFILE_CONTENT="$(cat "$FITNESS_PROFILE_FILE" 2>/dev/null || echo "(unreadable)")"
LIBRARY_CONTENT="$(cat "$LIBRARY_FILE" 2>/dev/null || echo "(unreadable)")"

# Library activities as "name<TAB>slug" lines (for phases 1+2).
ACTIVITY_ROWS="$(python3 - "$LIBRARY_FILE" <<'PYEOF' 2>/dev/null || true
import json, re, sys
try:
    with open(sys.argv[1]) as fh:
        text = fh.read()
except Exception:
    sys.exit(0)
m = re.search(r"```json\s*\n(.*?)```", text, re.DOTALL)
if not m:
    sys.exit(0)
try:
    data = json.loads(m.group(1))
except Exception:
    sys.exit(0)
for a in data.get("activities", []):
    name = str(a.get("name", "")).strip()
    if not name:
        continue
    slug = a.get("id") or re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    print(f"{name}\t{slug}")
PYEOF
)"

if [[ ! "$ACTIVITY_ROWS" =~ [^[:space:]] ]]; then
  cat <<ERR
FITNESS_JOURNAL_CONFIG_ERROR
library_file: $LIBRARY_FILE

The fitness library has no readable activities (empty list or malformed JSON
block). Fix the JSON in that file, or mint a fresh version with
/fitness-journal profile new fitness-library.
ERR
  exit 1
fi

ACTIVITIES_LIST="$(printf '%s\n' "$ACTIVITY_ROWS" | cut -f1 | paste -sd'|' - | sed 's/|/ | /g')"

# ---------------------------------------------------------------------------
# PHASE 1 — every library activity needs a committed per-activity profile.
# ---------------------------------------------------------------------------
MISSING_PROFILES=""
while IFS=$'\t' read -r _name _slug; do
  [[ -n "${_slug:-}" ]] || continue
  if [[ -z "$(pbrain_profile_latest "$ACT_STORE" "$_slug")" ]]; then
    MISSING_PROFILES+="$_name	$ACT_STORE/$_slug.v1.md"$'\n'
  fi
done <<< "$ACTIVITY_ROWS"

if [[ "$MISSING_PROFILES" =~ [^[:space:]] ]]; then
  cat <<PROFILES
FITNESS_JOURNAL_SETUP_ACTIVITY_PROFILES
library_file: $LIBRARY_FILE
activities_store: $ACT_STORE

=== LIBRARY ===
$LIBRARY_CONTENT

=== ACTIVITIES NEEDING A PROFILE (Activity<TAB>profile_path) ===
$MISSING_PROFILES
INSTRUCTIONS — first-time setup (step 2 of 2). Build one profile per activity.

You are acting as the user's full-stack fitness coach. For each activity in
the list above, interview the user and write a profile markdown file to its
profile_path. Process them one at a time — finish one activity before moving
to the next. Tailor every profile to the user's actual answers; no generic
templates.

GENERAL FLOW (per activity)

  1. Ask 4–7 targeted assessment + goal questions. Pick what makes sense for
     the activity — guidance below.
  2. Write the profile file at the given profile_path (mkdir -p the parent
     dir first). Pull occurrence + fixed days + equipment from the LIBRARY
     above into the frontmatter — do not re-ask what the library already knows.
  3. Tell the user it is saved and move to the next activity.

PER-ACTIVITY GUIDANCE (starting points, adapt to the user)

  GYM
    Ask:
    - Top 3 body parts / muscle groups they most want to strengthen.
    - Any weak or underdeveloped areas they have been avoiding.
    - Any injuries, pain points, or movements to avoid.
    - Session length. (Days/week + equipment come from the library.)
    - Experience level (months/years lifting) + current main lifts if known.
    - Primary goal: hypertrophy / strength / general fitness / sport support.
    - Do they want a structured reference plan to follow, or do they prefer to
      just log whatever they do each session? (This is a LOGGER — never force a
      plan on them.)
    Build a current-state + goals + focus-areas profile either way. If — and
    ONLY if — the user wants a structured reference plan, ALSO include an
    OPTIONAL Block/Day reference they can consult when they ask for planning
    help (we surface it on request; we never auto-prescribe a session from it):
    - 2 blocks (Block 1 weeks 1–4, Block 2 weeks 5–8) with progression intent.
    - A/B/C/D day split covering all major muscle groups across the week,
      extra volume for flagged weak areas.
    - Per day: muscle group order + exercises with sets × reps + rest target.
    - A progression note (e.g. add 2.5kg when all reps clean; deload after a gap).
    Keep that reference in this parseable shape so it's easy to read back:

    ## Block 1 (Weeks 1–4)   ← OPTIONAL reference only

    ### Day A — {Focus}
    | Exercise | Sets × Reps | Notes |
    |---|---|---|

    (Days B/C/D, then ## Block 2 (Weeks 5–8) in the same shape.)

  TEAM / PITCH SPORTS (football, basketball, tennis, padel, …)
    Ask: position(s) + playing frequency; self-rated 1–10 across the skills
    that matter (football: dribbling, passing, shooting, first touch,
    defending, weak foot, pace, stamina, decision-making); top 2–3 areas to
    level up in 3 months; chronic niggles / recovery; scenarios to drill.
    Profile: current-state snapshot, prioritised focus areas with the why,
    weekly structure (skill/conditioning/match/recovery days), 4–6 drills per
    priority with progression, conditioning targets, weak-side work, mental
    cues, 3-month milestones.

  ENDURANCE (running, cycling, swimming)
    Ask: current volume + paces, target event/pace, weak link, injury
    history, terrain access. Profile: weekly structure (long/tempo/easy/
    intervals/rest), zone or RPE targets, technique focus, build/recover
    cycles, milestones.

  TECHNIQUE / SKILL (climbing, surfing, skating, …)
    Ask: level, strengths/weaknesses (power/technique/endurance/mental),
    injuries, goals. Profile: weekly mix, drills per weakness, progression
    targets, complementary off-board work.

  MIND/BODY (yoga, mobility, pilates)
    Ask: current flexibility level, target areas, style preference, pain
    points. Profile: weekly sequence rotation, target poses/holds,
    breathwork, progression markers, integration with other activities.

  APP-DRIVEN (Apple Fitness+, Peloton) / HOME / FREESTYLE
    Ask: time budget, preferred modalities, goals. Profile: weekly rotation,
    how it complements the other activities, intensity guidance.

PROFILE FILE FORMAT (every activity)

  ---
  activity: {Activity}
  created: $TODAY
  days: [{fixed days from the library, e.g. Mon, Thu}]
  occurrence: {e.g. "4/week"}
  equipment: {from the library}
  focus_areas: [{top 2–3 focus areas}]
  version: 1
  committed: true
  ---

  # {Activity} — Profile

  ## Current state
  {specific self-assessment summary, quote numbers}

  ## Goals (next 3 months)
  - {prioritised goals}

  ## Weekly structure
  {what happens on which fixed days}

  ## Focus areas
  ### {Focus 1}
  - Why: …
  - Drills / approach: …
  - Progression: …

  ## Milestones
  - Month 1/2/3 markers

  ## Notes
  - {coach notes: injuries, interactions with other activities, recovery}

  (GYM MAY additionally carry the OPTIONAL parseable ## Block / ### Day tables
  described above, between "## Weekly structure" and "## Focus areas" — only when
  the user wanted a structured reference plan. It is a reference to consult on
  request, never an auto-generated prescription.)

WHEN ALL PROFILES ARE WRITTEN

  Tell the user:
    "All activity profiles saved under $ACT_STORE.
     Next, run /diet-journal to set up the food side — nutrition is half of
     recovery. Then run /fitness-journal again to log today's session."
PROFILES
  exit 0
fi

# ---------------------------------------------------------------------------
# PHASE 2 — daily LOGGER flow (profiles all in place). We compute the shared
# context (schedule hint, gap hint, recent sessions, activity profiles, KPIs)
# first, then branch: UPDATE an existing entry, or LOG a new one.
# ---------------------------------------------------------------------------

# Pre-select today's activity from the fixed days in the activity profiles
# (highest committed version per slug; frontmatter `days:` list, matched on
# 3-letter day prefixes). Output: one activity name per line scheduled today.
PRESELECTED="$(python3 - "$ACT_STORE" "$DOW" "$LIBRARY_FILE" <<'PYEOF' 2>/dev/null || true
import glob, json, os, re, sys
act_store, dow, lib_file = sys.argv[1], sys.argv[2], sys.argv[3]
dow3 = dow.strip().lower()[:3]

# slug -> display name from the library
names = {}
try:
    with open(lib_file) as fh:
        m = re.search(r"```json\s*\n(.*?)```", fh.read(), re.DOTALL)
    data = json.loads(m.group(1)) if m else {}
    for a in data.get("activities", []):
        slug = a.get("id") or re.sub(r"[^a-z0-9]+", "-", str(a.get("name", "")).lower()).strip("-")
        names[slug] = str(a.get("name", slug))
except Exception:
    pass

# Highest COMMITTED version per slug. The committed check happens during
# collection — an open draft (higher version, committed: false) must NOT
# shadow the committed version below it.
best = {}
for f in glob.glob(os.path.join(act_store, "*.v*.md")):
    base = os.path.basename(f)
    m = re.match(r"(.+)\.v(\d+)\.md$", base)
    if not m:
        continue
    slug, ver = m.group(1), int(m.group(2))
    try:
        with open(f) as fh:
            text = fh.read()
    except Exception:
        continue
    fm = re.match(r"^---\n(.*?)\n---", text, re.DOTALL)
    if not fm or re.search(r"^committed:\s*false\s*$", fm.group(1), re.MULTILINE):
        continue
    if slug not in best or ver > best[slug][0]:
        best[slug] = (ver, fm.group(1))

for slug, (_ver, front) in sorted(best.items()):
    dm = re.search(r"^days:\s*\[(.*?)\]\s*$", front, re.MULTILINE)
    if not dm:
        continue
    days = [d.strip().strip("\"").lower()[:3] for d in dm.group(1).split(",") if d.strip()]
    if dow3 in days:
        print(names.get(slug, slug))
PYEOF
)"
[[ -n "${PRESELECTED//[[:space:]]/}" ]] || PRESELECTED="(none scheduled today)"

# Training-gap detection: days since the last GYM session (a session file
# whose frontmatter carries `day: <A-D>`). The band drives generated gym sessions
# (no_progression 7–13d → repeat weights; deload 14+d → −20%; else progressive
# overload) when the user plans ahead. Degrades to "unknown" when no prior gym
# session is found.
TRAINING_GAP="$(python3 - "$TRACKING_DIR" "$TODAY" <<'PYEOF' 2>/dev/null || true
import datetime, glob, os, re, sys
d, today_s = sys.argv[1], sys.argv[2]
today = datetime.date.fromisoformat(today_s)
files = sorted(glob.glob(os.path.join(d, "*.md")), reverse=True)[:180]
for f in files:
    base = os.path.basename(f)[:-3]
    try:
        date = datetime.date.fromisoformat(base)
    except Exception:
        continue
    if date >= today:
        continue
    try:
        with open(f) as fh:
            head = fh.read(2000)
    except Exception:
        continue
    fm = re.match(r"^---\n(.*?)\n---", head, re.DOTALL)
    if fm and re.search(r"^day:\s*[A-Da-d]\s*$", fm.group(1), re.MULTILINE):
        gap = (today - date).days
        if gap < 7:
            band = "normal"
        elif gap <= 13:
            band = "no_progression"
        else:
            band = "deload"
        print(f"{gap} {band}")
        sys.exit(0)
print("unknown unknown")
PYEOF
)"
TRAINING_GAP_DAYS="${TRAINING_GAP%% *}"
TRAINING_GAP_BAND="${TRAINING_GAP##* }"

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

# Sleep is given-or-blank: it is mandatory to ASK (Step 1), written only from what
# the user gives THIS session, and otherwise left blank. There is deliberately no
# carry-forward from prior sessions and no profile-window fallback — a value the
# user did not give is an assumption, and an assumed sleep reading is false data.

# Bundle every activity profile (highest COMMITTED version per slug — an open
# draft must not shadow the committed version below it).
ACTIVITY_PROFILES="$(python3 - "$ACT_STORE" <<'PYEOF' 2>/dev/null || true
import glob, os, re, sys
act_store = sys.argv[1]
best = {}
for f in glob.glob(os.path.join(act_store, "*.v*.md")):
    m = re.match(r"(.+)\.v(\d+)\.md$", os.path.basename(f))
    if not m:
        continue
    slug, ver = m.group(1), int(m.group(2))
    try:
        with open(f) as fh:
            text = fh.read()
    except Exception:
        continue
    if re.search(r"^committed:\s*false\s*$", text[:400], re.MULTILINE):
        continue
    if slug not in best or ver > best[slug][0]:
        best[slug] = (ver, f, text)
out = []
for slug, (_v, f, text) in sorted(best.items()):
    out.append(f"=== {slug} ({f}) ===\n{text}")
print("\n\n".join(out) if out else "(no activity profiles found)")
PYEOF
)"

# Per-activity KPIs, resolved from the library. When an activity carries an
# explicit `kpis` array it's used as-is; when it doesn't (older libraries that
# predate KPIs), archetype defaults are DERIVED on the fly from the activity
# name/slug and flagged `"derived": true` so the daily flow can offer to persist
# them. This is the graceful, migration-free backward-compat path.
ACTIVITY_KPIS="$(python3 - "$LIBRARY_FILE" <<'PYEOF' 2>/dev/null || true
import json, re, sys
try:
    with open(sys.argv[1]) as fh:
        m = re.search(r"```json\s*\n(.*?)```", fh.read(), re.DOTALL)
    data = json.loads(m.group(1)) if m else {}
except Exception:
    data = {}

DUR = [{"id": "duration", "label": "Duration", "type": "duration", "unit": "min"}]
DEFAULTS = {
    "sets": [{"id": "sets", "label": "Sets", "type": "sets", "unit": None}],
    "swim": [{"id": "distance", "label": "Distance", "type": "distance", "unit": "km"},
             {"id": "duration", "label": "Duration", "type": "duration", "unit": "min"}],
    "run":  [{"id": "distance", "label": "Distance", "type": "distance", "unit": "km"},
             {"id": "duration", "label": "Duration", "type": "duration", "unit": "min"},
             {"id": "intensity", "label": "Intensity", "type": "rating", "unit": None}],
    "cycle":[{"id": "distance", "label": "Distance", "type": "distance", "unit": "km"},
             {"id": "duration", "label": "Duration", "type": "duration", "unit": "min"}],
    "sport":[{"id": "duration", "label": "Duration", "type": "duration", "unit": "min"},
             {"id": "notes", "label": "Notes", "type": "text", "unit": None}],
    "app":  [{"id": "duration", "label": "Duration", "type": "duration", "unit": "min"},
             {"id": "workout_type", "label": "Workout type", "type": "text", "unit": None}],
    "default": [{"id": "duration", "label": "Duration", "type": "duration", "unit": "min"},
                {"id": "notes", "label": "Notes", "type": "text", "unit": None}],
}

def derive(name, slug):
    s = (slug + " " + name).lower()
    if re.search(r"gym|weight|lift|strength|resistance|calisthen", s): return DEFAULTS["sets"]
    if re.search(r"swim", s): return DEFAULTS["swim"]
    if re.search(r"run|jog|sprint", s): return DEFAULTS["run"]
    if re.search(r"cycl|bike|spin|\bride\b", s): return DEFAULTS["cycle"]
    if re.search(r"yoga|mobilit|stretch|pilates|medit|breath|danc", s): return DUR
    if re.search(r"football|soccer|basketball|tennis|padel|cricket|hockey|volleyball|badminton|squash|rugby|sport", s): return DEFAULTS["sport"]
    if re.search(r"apple fitness|peloton|home|freestyle|\bclass\b", s): return DEFAULTS["app"]
    return DEFAULTS["default"]

out = {}
for a in data.get("activities", []):
    name = str(a.get("name", "")).strip()
    if not name:
        continue
    slug = a.get("id") or re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    kpis = a.get("kpis")
    if kpis:
        out[slug] = {"name": name, "kpis": kpis, "derived": False}
    else:
        out[slug] = {"name": name, "kpis": derive(name, slug), "derived": True}
print(json.dumps(out, indent=2, ensure_ascii=False) if out else "{}")
PYEOF
)"
[[ "$ACTIVITY_KPIS" =~ [^[:space:]] ]] || ACTIVITY_KPIS="{}"

# Suggest /diet-journal after the session is logged — but only if today's food
# isn't already tracked. Suggest once, never block (mirrors the morning sequence).
if [[ -f "$DIET_DIR/$TODAY.md" ]]; then
  DIET_SUGGESTION="(Today's /diet-journal entry already exists — no need to suggest it.)"
else
  DIET_SUGGESTION="Then suggest once, don't block: \"Want to log today's food with /diet-journal? Nutrition is half of recovery.\" If they skip, that's fine."
fi

# ── UPDATE mode: today's entry already exists ──────────────────────────────
# The user is coming back to add more, correct a KPI, log another activity, or
# ask for a plan. Show what's logged, take the update, rewrite in place.
if [[ -f "$OUT_FILE" ]]; then
  EXISTING_ENTRY="$(cat "$OUT_FILE")"
  cat <<UPDATE
FITNESS_JOURNAL_EXISTING
date: $TODAY
date_human: $TODAY_HUMAN
output_file: $OUT_FILE
training_gap_days: $TRAINING_GAP_DAYS
training_gap_band: $TRAINING_GAP_BAND

=== EXISTING ENTRY ===
$EXISTING_ENTRY

=== FITNESS LIBRARY ($LIBRARY_FILE) ===
$LIBRARY_CONTENT

=== PER-ACTIVITY KPIs (resolved; "derived": true ⇒ defaults, offer to save) ===
$ACTIVITY_KPIS

=== RECENT SESSIONS (last 7) ===
$RECENT_SESSIONS

=== ACTIVITY PROFILES ($ACT_STORE) ===
$ACTIVITY_PROFILES

---
INSTRUCTIONS — today's fitness entry already exists. The user is back to add to it
or refine it. It is logger-first — log what they actually did and never prescribe
onto a session they are reporting — BUT if they ask you to PLAN / generate the
session (case D below), build it fully. The entry uses two sections: ## Planned
(targets) and ## Logged (actuals).

Step 1 — Show a one-line summary of the entry's state (the activity, whether it's
  still \`planned\` or has ## Logged actuals), then ask:
  "What's the update — did the planned session (so I log actuals), did more,
  correcting a number, logged a second activity, or want help planning the rest?"

Step 2 — Based on intent:
  A) DID THE PLANNED SESSION → fill the ## Logged section from what they hit (add
     it if the entry was plan-ahead-only), and flip \`status: planned\` →
     \`completed\` (or \`partial\` if they fell short). Don't touch ## Planned.
  B) MORE OF THE SAME / CORRECTING A NUMBER → update the relevant cells in
     ## Logged (or ## Planned if they're adjusting the target). Partial is fine.
  C) A SECOND ACTIVITY today → append a new "# {Activity} — $TODAY" block below the
     first (its own summary line + ## Planned / ## Logged), so the file can hold
     more than one activity in a day.
  D) PLAN HELP → the user wants the session PLANNED / generated (e.g. the existing
     entry is a thin plan-ahead and they want it filled out properly). GENERATE a
     complete, ready-to-follow session and REPLACE the entry's ## Planned with it,
     keeping \`status: planned\`:
     - GYM: from ACTIVITY PROFILES (Block/Day) + RECENT SESSIONS (last weights) +
       the training-gap band ($TRAINING_GAP_BAND, $TRAINING_GAP_DAYS days). Pick the
       next day in the A→B→C→D rotation; set weights by the gap rule — "no_progression"
       (7–13 days off) repeat last weights, "deload" (14+) drop ~20% rounded to 2.5kg
       + a deload note, else progressive overload (+2.5kg barbell / +1–2kg DB on a
       clean last session, repeat on missed reps). Write a coaching note, a ## Warmup,
       a ## Planned GROUPED by muscle with sets × reps + a REAL weight + a cue, a
       ## Cooldown, and an empty pre-filled ## Logged set-log table (one row per
       exercise) to fill in later; add week/block/day to the frontmatter.
     - NON-GYM: concrete targets per KPI from PER-ACTIVITY KPIs + the profile's focus
       areas, plus warmup/cooldown if the profile defines them, and an empty ## Logged.
     If instead they only want light help (their OWN targets, no full generation),
     do that and never auto-assign weights — but a request to "plan it" means GENERATE.

Step 3 — Rewrite the entry in place at $OUT_FILE, preserving its format. Keep the
  \`activity:\`/\`focus:\` and \`sleep_*\` frontmatter intact (plan-my-day reads them).
  If any sleep_* field is BLANK, leave it BLANK unless the user gives the value
  now. Do NOT carry it forward from a prior entry, do NOT copy the profile's typical
  window, do NOT invent a value — a sleep reading the user did not give is false
  data, and a blank field is the honest state.
  Set \`status:\` to match reality: \`completed\` when ## Logged is filled and the
  session is done, \`partial\` if partly done, \`planned\` while still plan-only.

Step 4 — If an activity in the file had its KPIs DERIVED (it lacks \`kpis\` in the
  library, see the resolved KPIs above), offer ONCE: "Want me to save these KPIs
  to your fitness library so they stick?" On a yes, append the \`kpis\` array to
  that activity in $LIBRARY_FILE IN PLACE (living-doc, no new version).

Step 5 — Re-mark the "Train" habit if ## Logged actuals changed (Step 7B rules in
  the LOG flow — planned from ## Planned, actual from ## Logged), then confirm:
  "Updated → $OUT_FILE".
UPDATE
  pbrain_emit_habits_extract "fitness-journal" || true
  exit 0
fi

# ── LOG mode: no entry yet today ───────────────────────────────────────────
cat <<PROMPT
FITNESS_JOURNAL_SESSION
date: $TODAY
day_of_week: $DOW
date_human: $TODAY_HUMAN
output_file: $OUT_FILE
training_gap_days: $TRAINING_GAP_DAYS
training_gap_band: $TRAINING_GAP_BAND
preselected_today: $PRESELECTED

=== OVERALL FITNESS PROFILE ($FITNESS_PROFILE_FILE) ===
$FITNESS_PROFILE_CONTENT

=== FITNESS LIBRARY ($LIBRARY_FILE) ===
$LIBRARY_CONTENT

=== PER-ACTIVITY KPIs (resolved; "derived": true ⇒ archetype defaults) ===
$ACTIVITY_KPIS

=== RECENT SESSIONS (last 7) ===
$RECENT_SESSIONS

=== ACTIVITY PROFILES ($ACT_STORE) ===
$ACTIVITY_PROFILES

---
INSTRUCTIONS — this is a flexible LOGGER, not a prescriber. The user describes
what they did (or plan to do) in plain words; you parse it into the activity's
KPIs and write the day's file. Tolerate partial/missing data — a one-line log is
fine. Never auto-generate a prescribed workout; only OFFER to help them plan
their OWN. Follow these steps in order.

DATE — today is date_human above ($TODAY_HUMAN). Use it VERBATIM for the weekday
and date. NEVER compute or guess the day of the week yourself — copy day_of_week
($DOW) / date_human exactly. (This is the local machine time; it is authoritative.)

Step 1 — QUICK CHECK-IN (mostly skippable). If a standing preference above says to
  skip the check-in, SKIP the rest of this step — BUT sleep is the one mandatory
  field, so still ask the ONE sleep line (item 3) before moving to Step 2. Otherwise
  present the whole batch as one quick batch — the user may answer some, all, or
  none:
  "Quick check-in (or say 'skip'):"
  1. Energy level? (1–10)
  2. Soreness, pain, or injury? Which muscles (1–10), flag anything acute or a
     movement to work around. PRE-FILL from RECENT SESSIONS + the activity
     profiles' notes, e.g. "(Last few days: lower back 3/10 on the chest day,
     right knee 6/10 after football last night)".
  3. Sleep (ALWAYS ask — this is mandatory to surface, never silently filled):
     what time to bed, what time awake, and quality 1–10? Ask plainly, with NO
     prefilled default. Write ONLY what the user gives this session. Do NOT carry a
     value forward from a prior entry, do NOT offer the profile's typical window,
     do NOT assume any time — a value the user did not give is false data; a blank
     field is honest.
  4. Stress? (low / medium / high)
  5. Bodyweight today? (kg — skip if you don't have it)
  This is a LOGGER, not an interrogation — never block. Ask the sleep line ONCE; if
  the user skips or ignores it, leave sleep_* blank (Step 4c) — do not nag, do not
  invent. If the user just states what they DID or are PLANNING, ask the one sleep
  line and otherwise go straight to logging.
  IF THE USER SAYS "SKIP" (or ignores it): drop the rest — but still ask the one
  sleep line — move to Step 2, then ask
  ONCE — "Want me to skip this check-in from now on?" On a yes, fold this standing
  preference INTO the fitness profile (at $FITNESS_PROFILE_FILE): append
  "Skip the quick check-in (still confirm the one sleep line); go straight to the
  day's picture." to the top-level
  "prefs" array in its fenced JSON block (create the array if absent), editing the
  file IN PLACE — do NOT mint a new profile version. Never write it without an
  explicit yes. From then on the standing-pref check above (re-injected from the
  profile by pbrain_emit_prefs) suppresses it.

Step 2 — TODAY'S PICTURE, then ONE targeted question (no menu dump). From
  date_human, preselected_today ($PRESELECTED) and RECENT SESSIONS, give a tight
  situational read of where the user stands today — for example:
  - the weekday + whether it's a fixed training day ($DOW; fixed days from the
    library/activity profiles);
  - what's owed or carried over (e.g. yesterday's session was skipped, so Day B
    is still owed; or the gym block/day sequence puts the next session at Day C);
  - the most recent relevant session (e.g. "you played football last night").
  Then ask ONE question: "Planning to do {the owed / scheduled session}, or
  something else?" Do NOT print a numbered menu of every activity.
  - If they go with it → log/plan that (Step 3 on).
  - If they name their OWN activity or plan → log THAT instead, same way. They can
    dictate it set-by-set (manual) or describe it loosely and let you derive the
    KPIs (automatic) — follow their lead.

Step 3 — PARSE the description into the chosen activity's KPIs, EXPLODING it into
  two layers — PLANNED (the intended/target work) and LOGGED (the actuals):
  - Resolve the activity against the FITNESS LIBRARY (fuzzy by name/shortcut).
    If it's something not in the library, log it anyway under its plain name.
  - Look up that activity's KPIs in PER-ACTIVITY KPIs above. Pull every value the
    user mentioned into the matching KPI (e.g. "swam 2k in 45 min" → distance
    2.0 km, duration 47 min; "bench 3×8 at 60, then squats" → sets rows).
    Equipment is in the activity profile — do NOT ask about it.
  - SEPARATE plan from actual when the user gives both ("meant to do 3×8 but only
    got 8,8,6" → Planned: 3×8 @ {weight}, Logged: 8,8,6). When they only state
    what they DID, that is the LOGGED layer; mirror it (or the activity's typical
    target) as the Planned so both layers exist. When they only state a PLAN they
    haven't done yet, that is the Planned layer and there is no Logged yet.
  - TOLERATE MISSING: only fill KPIs the user actually gave; leave the rest "—".
    Don't pepper them to complete every KPI — at most ONE follow-up, only for
    something central they clearly meant to give. A one-line log is a complete log.
  - If the chosen activity's KPIs are "derived": true above (the library has no
    \`kpis\` for it yet), use the derived defaults now and remember to offer to
    save them in Step 7.

Step 4 — Fold in whatever state they gave, then set the four sleep_* fields by this
  precedence. plan-my-day and the Sleep-well habit read sleep_*, but a WRONG value is
  worse than a blank one — so NEVER write a sleep value the user did not give, and
  NEVER invent or carry one:
    a) SLEEP GIVEN THIS SESSION (asked in Step 1, or volunteered) — from bed + wake
       INFER sleep hours (add 24h across midnight, e.g. bed 23:30 wake 07:00 → 7.5h)
       and write all four. This is a fresh reading; no provenance note needed.
    b) ELSE leave all four sleep_* BLANK. This covers any case where the user did
       not give sleep this session — they skipped the question, or there's nothing
       on record. Do NOT carry a value forward from a prior entry, do NOT copy the
       profile's typical sleep window, do NOT assume a usual bedtime, do NOT infer a
       plausible value. A value the user did not give is false data; a blank field
       is the correct, honest state. The skill wants the data and asks for it — but
       if the user withholds it, that is fine, and the field stays blank.
  If a flag stands out — short sleep, high soreness on what they're loading, low
  energy — note it in ONE line and, if it fits, suggest scaling back. Never prescribe
  and never block; they decide.

Step 5 — GENERATE a plan-ahead session, or stay the logger (logger-first):
  From Step 2's answer, pick ONE case.

  • GENERATE — the user is PLANNING AHEAD a session NOT done yet: they accepted the
    owed / scheduled session, or asked "plan it" / "what should I do". Produce a
    COMPLETE, ready-to-follow session (NOT a thin target list) and write it with the
    GENERATED-SESSION layout in Step 6 (coaching note + warmup + a real weighted /
    target ## Planned + cooldown + an empty pre-filled ## Logged table to fill in
    later). By activity:

    GYM — use the gym activity profile (in ACTIVITY PROFILES) as the source of truth
    for block / day / exercises:
    - Next session: parse week/block/day from RECENT SESSIONS frontmatter to find the
      last completed day letter; cycle A→B→C→D→A (after D, increment week; week 5
      starts Block 2); Block 1 exercises for weeks 1–4, Block 2 for weeks 5–8.
      Session number = total gym sessions so far + 1.
    - Weights — TRAINING-GAP RULE FIRST (training_gap_band: $TRAINING_GAP_BAND,
      $TRAINING_GAP_DAYS days since the last gym session):
        · "no_progression" (7–13 days off): tell them weights stay the same, no
          progression this session — repeat the LAST LOGGED weight for every exercise.
        · "deload" (14+ days off): suggest a deload — drop weights ~20% (rounded to
          2.5kg), and add a Notes line "Deload — first session back after
          $TRAINING_GAP_DAYS-day gap".
        · "normal" / "unknown": progressive overload — last session all reps clean →
          +2.5kg barbell / +1–2kg DB/cable; reps missed last time → repeat the same
          weight; an exercise never done before → start conservative (RPE 6, light).
      Pull the last weights from the most recent gym file in RECENT SESSIONS.

    NON-GYM — generate concrete targets from the activity's KPIs (in PER-ACTIVITY
    KPIs) and the profile's focus areas: a real target per KPI (distance / duration /
    sets / etc.), plus a warmup and cooldown when the activity profile defines them.
    No weight machinery — just a complete, followable session.

  • LOG / light-offer — the user already DID the session, gave their OWN custom list
    ("something else" with specific exercises), or only wants a nudge: keep the
    flexible logger — Step 3's ## Planned / ## Logged from their words, tolerate
    partial, STANDARD layout in Step 6. Offer to sketch targets from the activity's
    focus areas ONLY if they ask; never auto-assign weights or rotate a prescribed
    split onto a session they are just logging.

Step 6 — WRITE the entry to $OUT_FILE. An entry has up to TWO sections —
  ## Planned (intended/target work) and ## Logged (actuals). WHICH appear, and the
  \`status:\`, depend on what the user did:
    - PLAN-AHEAD ONLY (planned but not done yet) → \`status: planned\`. A quick
      plan-ahead log writes ## Planned ONLY and omits ## Logged. A GENERATED session
      (Step 5 → GENERATE) instead uses the GENERATED-SESSION layout below and DOES
      include an empty pre-filled ## Logged table to fill in during/after the session.
    - LOGGED DIRECTLY / DONE → write BOTH ## Planned (what they set out to do) and
      ## Logged (what they actually hit); \`status: completed\` (or \`partial\` if
      they fell short or only did some of it). When they logged with no separate
      target, mirror the logged work as the plan (or pull a typical target from
      the activity profile) so ## Planned still reflects the intent.
  /end-of-day later flips a \`planned\` entry to \`completed\` (or \`skipped\`) when the
  day closes — so leave \`status: planned\` for anything not yet done.

  ---
  type: fitness
  date: $TODAY
  activity: {library name/slug of the chosen activity — plan-my-day reads this}
  focus: {gym → muscle groups; everything else → the activity name}
  duration_min: {N or leave blank}
  distance_km: {N or leave blank}
  status: planned | completed | partial | skipped
  sleep_bed: {HH:MM or blank}
  sleep_wake: {HH:MM or blank}
  sleep_quality: {1-10 or blank}
  sleep_hours: {X.X or blank}
  tags: []
  ---

  # {Activity} — $TODAY

  {KPI summary line of the values that exist (LOGGED if present, else PLANNED),
   e.g. "**Distance** 2.0 km · **Duration** 47 min". Omit the line if nothing
   numeric is set yet.}

  > {one short observation tied to what they planned/logged — a win, a nudge, a
  recovery cue. 1-2 sentences. Optional — drop it if there's nothing genuine.}

  ## Planned
  {The intended/target work. For a \`sets\`-type KPI (gym): a target table.
   For other KPIs: one target row per KPI. Use "—" where there is no target.}
  | Exercise | Target |                         ← gym (sets-type KPI)
  |---|---|
  | {exercise} | {sets × reps @ weight} |
  -- OR, non-gym activities --
  | KPI | Target |
  |---|---|
  | {label} | {target or —} |

  ## Logged
  {OMIT this whole section for a plan-ahead-only entry. Once there are actuals:
   for a \`sets\`-type KPI (gym), per-set actuals; for other KPIs, the logged
   value. Partial / blank cells are fine.}
  | Exercise | Set 1 | Set 2 | Set 3 | Notes |   ← gym (sets-type KPI)
  |---|---|---|---|---|
  | {exercise} | {wt × reps} | | | |
  -- OR, non-gym activities --
  | KPI | Logged |
  |---|---|
  | {label} | {value or —} |

  ## Notes
  - {free-form: how it felt, drills, context — whatever the user said. Optional.}

  REST DAY variant: write a minimal entry — \`focus: Rest\`, \`status: completed\`
  (or \`planned\` if planning a rest day ahead), a "# Rest day — $TODAY" heading and
  a one-line note; skip ## Planned / ## Logged.

  GENERATED-SESSION layout (use ONLY when Step 5 chose GENERATE) — the standard
  entry made complete and ready to follow. Same ## Planned / ## Logged contract, so
  the Train scoring (Step 7B) and /end-of-day still read it; it just adds week/block/
  day frontmatter (gym), a coaching note, a warmup, real weights/targets, a cooldown,
  and an empty ## Logged table to fill in later:

  ---
  type: fitness
  date: $TODAY
  week: {N}            # gym only — from the rotation
  block: {N}           # gym only
  day: {letter}        # gym only
  activity: {gym | the activity name}
  focus: {gym → today's muscle groups; else → the activity name}
  bodyweight: {kg or blank}        # gym
  duration_min: {N or blank}       # non-gym
  distance_km: {N or blank}        # non-gym
  status: planned
  sleep_bed: {HH:MM or blank}
  sleep_wake: {HH:MM or blank}
  sleep_quality: {1-10 or blank}
  sleep_hours: {X.X or blank}
  tags: []
  ---

  # {gym: Day {letter} — {Focus}   |   non-gym: {Activity} — $TODAY}
  {gym only: **Week {N} · Block {N} · Session {N}** | ~{estimated duration} min}

  > {one coaching note tied to today's state — RPE / fatigue / mindset cue; mention
     the gap band if it is not normal. 1-2 sentences.}

  ## Warmup ({X} min)
  | | |
  |---|---|
  | {exercise} | {reps/duration + cue} |
  (4-5 items relevant to today; for non-gym use the activity's warmup, or omit)

  ## Planned
  {gym: GROUP BY muscle, every exercise with sets × reps, a REAL weight, and a cue}
  ### {Muscle Group}
  | Exercise | Sets × Reps | Weight | Notes |
  |---|---|---|---|
  | {exercise} | {sets × reps} | **{weight}** | {short form cue} |
  Rest {X}s between sets.   (repeat the ### block per muscle group in today's day)
  -- non-gym: one target row per KPI --
  | KPI | Target |
  |---|---|
  | {label} | {concrete target} |

  ## Cooldown ({X} min)
  - {stretches / easy work relevant to today} (3-5 items)

  ## Logged
  {Empty, pre-filled so the user just fills cells in later. status stays planned.}
  | Exercise | Set 1 | Set 2 | Set 3 | Notes |   # gym — one row per planned exercise
  |---|---|---|---|---|
  | {every exercise from ## Planned} | | | | |
  -- non-gym --
  | KPI | Logged |
  |---|---|
  | {label} | — |

  ## Notes
  - {1-3 contextual notes; include the deload line when band = deload}
  - {gym only} Next session: {next day from rotation} → Day {next letter} ({next focus})

Step 7 — Confirm + KPI upkeep:
  - Confirm: "Saved → $OUT_FILE".
  - $DIET_SUGGESTION
  - If the logged activity's KPIs were DERIVED (lacked \`kpis\` in the library),
    offer ONCE: "Want me to save these KPIs to your fitness library so they stick
    next time?" On a yes, append the \`kpis\` array to that activity in
    $LIBRARY_FILE IN PLACE (living-doc — no new version). On a no, leave it; the
    defaults will derive again next time. Never write without a yes.
  - If the user wants to track a NEW KPI for an activity going forward (e.g. "also
    track RPE for gym"), append it to that activity's \`kpis\` (known type → in
    place; a structural rebuild goes through /fitness-journal profile new).

Step 7B — "Train" scored habit. If "Train" is a tracked [scored] habit (it
  appears in the HABIT EXTRACTION block below) AND the entry has a ## Logged
  section with real actuals (status \`completed\`/\`partial\`) — NOT a plan-ahead-only
  entry (status \`planned\` with no logged actuals — including a GENERATED session
  whose ## Logged table is still empty) — then build the --session
  JSON and mark it ONCE per the session_volume instructions in that block, taking
  PLANNED from ## Planned and ACTUAL from ## Logged:
    - strength: from a \`sets\`-type KPI — planned = Σ(target sets × reps) from
      ## Planned, actual = Σ(logged reps) from ## Logged; mode "strength".
    - duration (run/walk/cardio/dance/etc.): from the duration KPI — planned =
      target minutes from ## Planned, actual = logged minutes from ## Logged;
      mode "duration".
    - binary (yoga/sport/recovery, no numeric target): mode "binary", status only
      (completed=100, partial=50).
  Use status completed | partial | skipped. If the entry is only PLANNED (no
  ## Logged actuals), do NOT mark — /end-of-day marks Train when the day closes.
  The mark is idempotent (one cell/day), so an end-of-day re-mark just updates it.

Step 7C — Reconcile fitness-habit reminders to today's chosen activity (silent,
  best-effort, idempotent). This is the moment the day's activity is actually
  decided, so it must run HERE — not only in /plan-my-day, which can run before
  the activity is chosen or before a later swap. UNLESS today is a REST day,
  after writing the file run, with the activity name you put in the file's
  \`focus:\` field:
    bash "$_SCRIPT_DIR/habits.sh" fitness-reconcile --activity "<focus value>" --date $TODAY
  If the user stated or logged a SESSION TIME for the workout (e.g. "Apple
  Fitness at 2:45 PM"), pass it through as a 24h HH:MM with --time so the chosen
  habit's reminder is retimed to that slot instead of the activity default:
    bash "$_SCRIPT_DIR/habits.sh" fitness-reconcile --activity "<focus value>" --time 14:45 --date $TODAY
  Convert the user's time to 24h yourself (2:45 PM → 14:45); omit --time when no
  session time was given (it then falls back to the activity's typical_time).
  It sets the CHOSEN activity's habit reminder (even off its usual schedule) and
  cancels + auto-skips any scheduled-but-not-chosen fitness habit — e.g. logging
  Apple Fitness on a Gym day drops the stale Gym 12:30 reminder and marks Gym
  skipped (not missed). No matching habit / unresolvable activity → no-op. Skip
  this step entirely on a rest day.
PROMPT

# Habit extraction (silent if no habits profile).
pbrain_emit_habits_extract "fitness-journal" || true
