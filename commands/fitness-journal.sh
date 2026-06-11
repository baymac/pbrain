#!/usr/bin/env bash
set -euo pipefail

# fitness-journal.sh
# Adaptive daily fitness journal — picks today's workout from your fixed
# activity schedule and generates a session in markdown.
#
# Base config lives in the VERSIONED PROFILE STORE (lib/profiles.sh) under
# the tracking dir:
#   <tracking-dir>/.profile/fitness-profile.vN.md   — overall fitness profile
#       (sleep bed/wake times + hours, steps/day, health-tracker metrics)
#   <tracking-dir>/.profile/fitness-library.vN.md   — activity library
#       (activities + stable metadata + occurrence per week|month)
#   <tracking-dir>/.profile/activities/<slug>.vN.md — per-activity profiles
#       (fixed days-of-week, goals, focus areas; gym keeps its Block/Day
#        parseable structure; equipment is captured here ONCE)
#
# First run bootstraps all three via interview; daily runs pre-select today's
# activity from the fixed days (user can override), apply training-gap rules
# (no progression after 7-13 idle days, deload after 14+), and log the session.
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
pbrain_emit_prefs "fitness-journal" || true

TRACKING_DIR="${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}"
STORE="$(pbrain_profile_store "$TRACKING_DIR")"
ACT_STORE="$STORE/activities"

TODAY="$(date +%Y-%m-%d)"
DOW="$(date +%a)"
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
    {"id": "<slug>", "name": "<Name>", "occurrence": {"per": "week", "times": N},
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
to plan today's session." Stop here.
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
    {"id": "<slug>", "name": "<Name>", "occurrence": {"per": "week", "times": N},
     "days": ["Mon", "Thu"], "equipment": "...", "location": "...",
     "typical_time": "HH:MM", "duration_min": N, "notes": "..."}]}
  \`\`\`

  - <slug> = lowercase, non-alphanumerics → "-" (e.g. "Apple Fitness+" →
    "apple-fitness").
  - Do NOT include "Rest day", "Recovery", or "Walk/cardio" as activities —
    those are always offered automatically.
  - The library is a LIVING document — new activities are appended in place
    later; the version only bumps on a structural rebuild.

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

if [[ -z "${ACTIVITY_ROWS//[[:space:]]/}" ]]; then
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

if [[ -n "${MISSING_PROFILES//[[:space:]]/}" ]]; then
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
    Then build a structured profile with:
    - 2 blocks (Block 1 weeks 1–4, Block 2 weeks 5–8) with progression intent.
    - A/B/C/D day split covering all major muscle groups across the week,
      extra volume for flagged weak areas (first slot, compound focus).
    - Per day: muscle group order + exercises with sets × reps + rest target.
    - Warmup + cooldown templates.
    - Progression rule (e.g. add 2.5kg when all reps clean; deload after 4w).
    - Notes on weak areas and how the split addresses them.
    The Block/Day structure MUST stay parseable by the session generator:

    ## Block 1 (Weeks 1–4)

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

  (GYM additionally carries the parseable ## Block / ### Day tables described
  above, between "## Weekly structure" and "## Focus areas".)

WHEN ALL PROFILES ARE WRITTEN

  Tell the user:
    "All activity profiles saved under $ACT_STORE.
     Next, run /diet-journal to set up the food side — nutrition is half of
     recovery. Then run /fitness-journal again to plan today's session."
PROFILES
  exit 0
fi

# ---------------------------------------------------------------------------
# PHASE 2 — daily session flow (profiles all in place).
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
# whose frontmatter carries `day: <A-D>`). Bands drive the progression rule.
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
day_of_week: $DOW
output_file: $OUT_FILE
training_gap_days: $TRAINING_GAP_DAYS
training_gap_band: $TRAINING_GAP_BAND
preselected_today: $PRESELECTED

=== OVERALL FITNESS PROFILE ($FITNESS_PROFILE_FILE) ===
$FITNESS_PROFILE_CONTENT

=== FITNESS LIBRARY ($LIBRARY_FILE) ===
$LIBRARY_CONTENT

=== RECENT SESSIONS (last 7) ===
$RECENT_SESSIONS

=== ACTIVITY PROFILES ($ACT_STORE) ===
$ACTIVITY_PROFILES

---
INSTRUCTIONS — follow these steps in order.

Step 1 — Ask all state questions at once, exactly like this:
  "Quick check-in before we plan today:"
  1. Energy level? (1–10)
  2. Soreness? Which muscles? (1–10)
  3. Sleep: what time did you get to bed, what time did you wake up, and
     quality 1–10?
  4. Stress? (low / medium / high)
  5. Any pain or injury?
  6. Bodyweight today? (kg — skip if you don't have it)
  From the bed + wake times, INFER sleep hours (add 24h when bed time is
  after midnight crossing, e.g. bed 23:30 wake 07:00 → 7.5h). Compare against
  the profile's normal sleep window and mention a notable deviation in one
  line (e.g. "1.5h short of your usual — we'll keep volume sane today").

Step 2 — Propose today's activity from the schedule, then confirm:
  preselected_today above lists what the user's fixed days say for $DOW.
  - Exactly one activity → "Today is $DOW — your schedule says {activity}.
    Go with that, or override?"
  - Multiple → list them, ask which (or something else).
  - "(none scheduled today)" → "Nothing on the schedule today — recovery,
    a walk, rest, or something off-plan?"
  The full menu stays available either way: $MENU

Step 3 — Ask 2–4 follow-up questions tailored to the chosen activity. Use
your judgment. Guidance:
  - Team / pitch sport: duration, kickoff/start time, location, level.
  - Swimming: pool or open water, duration, strokes, distance target.
  - Running / Cycling: duration or distance, route/terrain, intensity.
  - Climbing: gym or outdoor, session length, focus.
  - Yoga / Mobility / Recovery: duration, style or focus.
  - Gym: "How much time do you have?" (equipment access is already in the
    activity profile — do NOT ask about it).
  - Apple Fitness+ / Home: duration, workout type if known.
  - Walk/cardio: duration, type.
  - Rest day: no follow-up.

Step 4 — Apply adaptive coaching rules before confirming intent:
  - Sleep < 6h AND soreness > 7 AND stress = high → recommend a downgrade
    (e.g. gym → recovery/lighter, contact sport → walk).
  - Heavy-leg soreness > 7 AND intent loads legs → flag it, suggest swap or
    lighter volume.
  - Any body part / movement pattern not trained in last 5+ sessions → mention.
  - Energy < 4 → suggest shorter session or rest.
  Also pull priorities from the chosen activity's profile — surface a
  neglected focus area. If you recommend a change, explain briefly and let
  the user confirm or override.

---

Step 5A — IF INTENT = GYM:

  Use the gym activity profile above as the source of truth for
  block/day/exercises.

  Determine next session:
  - Parse frontmatter (week, block, day) from recent sessions to find the
    last completed day letter (A/B/C/D).
  - Cycle: A→B→C→D→A. After completing D, increment week. Week 5 starts Block 2.
  - Use Block 1 exercises for weeks 1–4, Block 2 for weeks 5–8.
  - Session number = total gym sessions completed so far + 1.

  Determine weights — TRAINING-GAP RULE FIRST (training_gap_band above):
  - band "no_progression" (7–13 days since the last gym session): tell the
    user "You've been away for $TRAINING_GAP_DAYS days — weights stay the
    same, no progression this session. Focus on form and getting back into
    it." Repeat the LAST LOGGED weight for every exercise. Skip the
    progressive-overload rules below for this session.
  - band "deload" (14+ days): tell the user "You've been away for
    $TRAINING_GAP_DAYS days — suggesting a deload session. Drop weights ~20%,
    treat it as a re-entry week." Apply −20% to every last logged weight,
    ROUNDED to the nearest 2.5kg, and add a Notes-section line:
    "Deload — first session back after $TRAINING_GAP_DAYS-day gap".
  - band "normal" or "unknown": standard progressive overload —
    * last session completed all reps cleanly → +2.5kg (barbell), +1–2kg (DB/cable)
    * reps missed last time → repeat the same weight
    * exercise never done before → start conservative (RPE 6, light).

  Generate the file in EXACTLY this format — match spacing, table structure,
  and section order precisely:

  ---
  type: fitness
  date: $TODAY
  week: {N}
  block: {N}
  day: {letter}
  focus: {muscle groups matching the gym profile day}
  bodyweight: {kg or leave blank if skipped}
  sleep_bed: {HH:MM from Step 1}
  sleep_wake: {HH:MM from Step 1}
  sleep_quality: {1-10 from Step 1}
  sleep_hours: {inferred, e.g. 7.5}
  status: planned
  tags: []
  ---

  # Day {letter} — {Focus}
  **Week {N} · Block {N} · Session {N}** | ~{estimated duration} min

  > {one coaching note tailored to today's state — RPE guidance, fatigue cue,
  or mindset note. 1-2 sentences. Mention the gap band if not normal.}

  ---

  ## Warmup ({X} min)

  | | |
  |---|---|
  | {exercise} | {reps/duration + cue} |
  (4-5 warmup items relevant to today's muscle groups)

  ---

  ## Workout

  ### {Muscle Group 1}

  | Exercise | Sets × Reps | Weight | Notes |
  |---|---|---|---|
  | {exercise} | {sets × reps} | **{weight}** | {short form cue} |

  Rest {X}s between sets.

  (repeat per muscle group in today's day plan)

  ---

  ## Cooldown ({X} min)

  - {stretches relevant to today's muscles} (3-5 items)

  ---

  ## Log your sets here

  | Exercise | Set 1 | Set 2 | Set 3 | Notes |
  |---|---|---|---|---|
  | {every exercise from the workout} | | | | |

  ---

  ## Notes

  - {1-3 contextual notes; include the deload line when band = deload}
  - Next session: {next day from rotation} → Day {next letter} ({next focus})

---

Step 5B — IF INTENT = REST DAY:
  Use this minimal template (same sleep_* frontmatter fields as 5A, minus
  week/block/day):

  ---
  type: fitness
  date: $TODAY
  focus: Rest
  sleep_bed: {HH:MM}
  sleep_wake: {HH:MM}
  sleep_quality: {1-10}
  sleep_hours: {X.X}
  status: planned
  tags: []
  ---

  # Rest day — $TODAY

  > {one short note based on state — sleep priority, hydration, light movement cue.}

  - Light walk if you feel up to it
  - Mobility / stretching (5–10 min)
  - Hydrate and eat enough protein

Step 5C — IF INTENT IS ANY OTHER ACTIVITY (including Recovery/stretching and
Walk/cardio):

  Look up that activity's profile in the ACTIVITY PROFILES section above and
  use its focus areas to shape today's session — drill choice, intensity
  emphasis, what to track. Don't ignore the profile.

  Skeleton (add/remove fields to fit the activity; keep the sleep_* fields):

  ---
  type: fitness
  date: $TODAY
  focus: {activity name}
  duration_min: {minutes}
  {extra activity-relevant fields, e.g. location, kickoff, distance_km}
  sleep_bed: {HH:MM}
  sleep_wake: {HH:MM}
  sleep_quality: {1-10}
  sleep_hours: {X.X}
  status: planned
  tags: []
  ---

  # {Activity} — $TODAY

  **Duration** {minutes} min{ · **Where** {location}}{ · **When** {time}}

  > {one short coaching note tailored to today's state. 1-2 sentences.}

  ---

  ## Pre-session

  - {2–4 activity-specific prep bullets: hydration, fuel, warmup, gear}

  ## Session focus

  - {what to work on today — from the activity profile focus areas + state}

  ---

  ## Post-session review (fill after)

  Build a 1–10 rating matrix appropriate to the activity, reusing the metrics
  from the activity profile's current-state self-ratings so progress tracks
  over time.

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

Step 6B — "Train" scored habit. If "Train" is a tracked [scored] habit (it
  appears in the HABIT EXTRACTION block below) AND the user actually LOGGED a
  completed/partial session this conversation (real sets in "Log your sets
  here", or they said they finished/partly-did the activity) — not merely
  generated today's plan with status: planned — then build the --session JSON
  and mark it ONCE per the session_volume instructions in that block:
    - strength: planned = Σ(target sets × reps) from the workout table, actual
      = Σ(logged reps); mode "strength".
    - duration (run/walk/cardio): planned = target minutes, actual = actual
      minutes; mode "duration".
    - binary (yoga/sport/recovery, no numeric target): mode "binary", status
      only (completed=100, partial=50).
  Use status completed | partial | skipped. If the session is only PLANNED (no
  actuals yet), do NOT mark — /end-of-day marks Train when the day closes. The
  mark is idempotent (one cell/day), so an end-of-day re-mark just updates it.
PROMPT

# Habit extraction (silent if no habits profile) + self-improvement capture.
pbrain_emit_habits_extract "fitness-journal" || true
pbrain_emit_self_improve "fitness-journal" "$STORE" "fitness profiles (overall profile, library, per-activity profiles under this store)" || true
