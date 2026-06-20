#!/usr/bin/env bash
set -euo pipefail

# diet-journal.sh
# Interactive daily diet journal with macro tracking. Acts as a nutrition
# coach on first run: gathers state + conditions, computes macro targets, and
# writes ONE versioned diet profile (the old profile JSON + diet plan merged);
# then every day either logs what was eaten OR suggests meals from the
# profile — always with a macros table comparing actual to target.
#
# Base config lives in the VERSIONED PROFILE STORE (lib/profiles.sh) under
# the diet-tracking dir:
#   <diet-dir>/.profile/diet-profile.vN.md  — body/state/conditions/prefs PLUS
#       computed targets, macro approach, meal slots + times, and the full
#       guidance body (foods to favour/avoid, per-slot structure, etc.)
#   <diet-dir>/.profile/food-library.vN.md  — named-foods library (LIVING doc:
#       rows append in place; version bumps only on structural rebuilds)
#
# `diet-journal.sh profile show|new|commit [diet-profile|food-library]`
# manages versions: drafts are editable, committed versions are final.
# Migration 0004 merges the old diet-profile.json + Diet Plan.md into v1;
# migration 0006 auto-moves the old Food Library.md.
#
# Daily flow:
#   - If today's entry exists  → update mode (append meals, recompute macros).
#   - Else                     → log mode (user dumps food)  OR  suggest mode
#                                (coach proposes meals, user picks).
#   Meal times are anchored to TODAY'S FITNESS SESSION (pre/post-workout
#   nutrition lands relative to the real session time).
#
# Default destinations:
#   Daily entries:   $VAULT_DIR/fitness/diet-tracking/YYYY-MM-DD.md
#   Profile store:   $VAULT_DIR/fitness/diet-tracking/.profile/
#
# Overrides:
#   PBRAIN_VAULT               — vault root
#   PBRAIN_DIET_DIR            — daily-entries dir (the store lives inside it)
#   PBRAIN_FITNESS_DIR         — today's fitness entry (cross-ref)
#   PBRAIN_DIET_PROFILE_FILE   — explicit profile file (bypasses the store;
#                                a legacy raw-JSON file still parses)
#   PBRAIN_FOOD_LIBRARY_FILE   — explicit food-library file (bypasses the store)

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

# Surface this user's standing preferences for /diet-journal (emits nothing if none set).
pbrain_emit_prefs "diet-journal" "${PBRAIN_DIET_PROFILE_FILE:-$(pbrain_profile_latest_any "$(pbrain_profile_store "${PBRAIN_DIET_DIR:-$VAULT_DIR/fitness/diet-tracking}")" diet-profile)}" || true

DIET_DIR="${PBRAIN_DIET_DIR:-$VAULT_DIR/fitness/diet-tracking}"
FITNESS_DIR="${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}"
STORE="$(pbrain_profile_store "$DIET_DIR")"
FIT_STORE="$(pbrain_profile_store "$FITNESS_DIR")"

TODAY="$(date +%Y-%m-%d)"
DOW="$(date +%a)"
OUT_FILE="$DIET_DIR/$TODAY.md"

mkdir -p "$DIET_DIR"

# ---------------------------------------------------------------------------
# `profile` subcommand — manage the versioned diet profiles.
#   profile show | profile new [diet-profile|food-library] | profile commit [base]
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "profile" ]]; then
  ACTION="${2:-show}"
  BASE="${3:-diet-profile}"
  case "$ACTION" in
    show)
      echo "DIET_PROFILE_SHOW"
      for b in diet-profile food-library; do
        f="$(pbrain_profile_latest "$STORE" "$b")"
        d="$(pbrain_profile_draft "$STORE" "$b")"
        echo ""
        echo "=== $b (committed: ${f:-none}; draft: ${d:-none}) ==="
        [[ -n "$f" ]] && cat "$f"
      done
      echo ""
      echo "---"
      echo "INSTRUCTIONS: Present the profile above as a short human-readable summary"
      echo "(goal + targets line, meal structure with times, key conditions/restrictions,"
      echo "then a one-line food-library count). Do not dump raw JSON. Committed"
      echo "profiles are final — to change one: /diet-journal profile new [base]."
      exit 0
      ;;
    new)
      DRAFT="$(pbrain_profile_draft "$STORE" "$BASE")"
      if [[ -n "$DRAFT" ]]; then
        echo "DIET_PROFILE_DRAFT_OPEN"
        echo "draft: $DRAFT"
        echo "A draft of $BASE is already open. Iterate on it with the user and, when they"
        echo "confirm, finalize with: bash \"$_SCRIPT_DIR/diet-journal.sh\" profile commit $BASE"
        exit 0
      fi
      NEW_PATH="$(pbrain_profile_new "$STORE" "$BASE")" || exit 1
      echo "DIET_PROFILE_NEW"
      echo "draft: $NEW_PATH"
      echo ""
      echo "INSTRUCTIONS: A new DRAFT version of $BASE was minted (copied from the"
      echo "previous version when one existed). Walk the user through what they want to"
      echo "change, edit the draft file directly (keep the fenced JSON block valid and"
      echo "the frontmatter version/committed lines intact), iterate until they are"
      echo "happy, then finalize with:"
      echo "  bash \"$_SCRIPT_DIR/diet-journal.sh\" profile commit $BASE"
      echo "Once committed the version is FINAL — further changes mint the next version."
      exit 0
      ;;
    commit)
      OUT="$(pbrain_profile_commit "$STORE" "$BASE")" || exit 1
      echo "DIET_PROFILE_COMMITTED"
      echo "file: $OUT"
      echo "This version is now final. Future changes: /diet-journal profile new $BASE"
      exit 0
      ;;
    *)
      echo "usage: diet-journal.sh profile show|new|commit [diet-profile|food-library]" >&2
      exit 2
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Staged migration 0004 — merge the old diet-profile.json + Diet Plan.md into
# one versioned diet profile. Pending only when old data exists and the store
# is empty; recorded once the rebuild lands. An EXPLICIT profile override that
# points at a real file wins outright — the user told us which file to use,
# so the store migration is not this run's business.
# ---------------------------------------------------------------------------
if [[ ! -f "${PBRAIN_DIET_PROFILE_FILE:-/nonexistent}" ]] \
   && declare -F pbrain_migration_pending >/dev/null \
   && pbrain_migration_pending 0004_diet_profile_combine; then
  OLD_PROFILE_FILE="${PBRAIN_DIET_PROFILE_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/diet-profile.json}"
  OLD_PLAN_FILE="$VAULT_DIR/fitness/Diet Plan.md"
  echo "DIET_JOURNAL_MIGRATION"
  echo "store: $STORE"
  echo "backup_dir: $VAULT_DIR/.pbrain/backup"
  echo ""
  echo "=== OLD DIET PROFILE ($OLD_PROFILE_FILE) ==="
  cat "$OLD_PROFILE_FILE" 2>/dev/null || echo "(none)"
  echo ""
  echo "=== OLD DIET PLAN ($OLD_PLAN_FILE) ==="
  cat "$OLD_PLAN_FILE" 2>/dev/null || echo "(none)"
  cat <<MIGRATE

---
INSTRUCTIONS — one-time migration to the new diet profile store. Do not log
or analyse any food yet. Tell the user: pbrain now keeps the diet profile and
the diet plan as ONE versioned profile; you'll walk their existing setup
across (a few minutes, their data carries over).

Step 1 — Validate the old data PART BY PART (not in one go):
  - Body stats: confirm current weight (it drifts — recompute targets if it
    changed), height, age, activity level, goal.
  - Conditions / medications / allergies / restrictions: still accurate?
  - Meal structure: confirm the slots still match how they actually eat.
  - NEW — meal TIMES (the old data has none): for each slot, roughly what
    time do they eat it? Anchor defaults around their fitness schedule
    (training days shift the post-workout meal).
  Quote each part back so they confirm against real content; update or drop
  per their answers.

Step 2 — Recompute targets if anything material changed (same rules as
setup: Mifflin-St Jeor BMR, TDEE activity multipliers, goal adjustment,
macro split per approach). Otherwise carry the old targets over.

Step 3 — Write ONE file (mkdir -p "$STORE" first):

  $STORE/diet-profile.v1.md
  ---
  type: diet-profile
  date: $TODAY
  tags: []
  version: 1
  committed: true
  ---

  # Diet profile

  \`\`\`json
  { ...ALL old profile fields (created, weight_kg, height_cm, age, sex,
    activity_level, goal, conditions, medications, allergies, intolerances,
    dietary_preference, restrictions, cuisine_context, cooking_capacity,
    budget, eating_window, alcohol_freq, caffeine, supplements, notes)...,
    "targets": {"calories": N, "protein_g": N, "carbs_g": N, "fat_g": N,
                "fiber_g": N, "water_l": N},
    "macro_approach": "standard|keto|low_carb",
    "meal_pattern": "...",
    "meal_slots": ["Breakfast", "Lunch", "Dinner"],
    "meal_times": {"Breakfast": "09:00", "Lunch": "13:30", "Dinner": "20:30"} }
  \`\`\`

  Then the guidance body carried over from the old plan (update where the
  user changed something): ## Daily macro targets (table) /
  ## Condition-specific guidance / ## Foods to favour /
  ## Foods to limit or avoid / ## Meal structure (typical day) — one
  ### section per slot / ## Training day vs rest day /
  ## Hydration + supplements / ## Sample day / ## Notes.

Step 4 — Park the old plan so nothing is lost (do NOT delete):
  mkdir -p "$VAULT_DIR/.pbrain/backup"
  mv "$OLD_PLAN_FILE" "$VAULT_DIR/.pbrain/backup/" 2>/dev/null
  (Leave $OLD_PROFILE_FILE in place — superseded, not harmful.)

Step 5 — Record the migration so it never re-runs:
  bash "$_SCRIPT_DIR/../lib/migrations.sh" record 0004_diet_profile_combine

Step 6 — Confirm: "Diet profile migrated → $STORE. Re-run /diet-journal to
log today's food." Stop here.
MIGRATE
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolution — explicit override file, else latest committed in the store.
# ---------------------------------------------------------------------------
PROFILE_FILE="${PBRAIN_DIET_PROFILE_FILE:-}"
if [[ -n "$PROFILE_FILE" && ! -f "$PROFILE_FILE" ]]; then PROFILE_FILE=""; fi
[[ -n "$PROFILE_FILE" ]] || PROFILE_FILE="$(pbrain_profile_latest "$STORE" diet-profile)"

# ---------------------------------------------------------------------------
# PHASE 0 — first-run setup (no committed diet profile anywhere).
# ---------------------------------------------------------------------------
if [[ -z "$PROFILE_FILE" ]]; then
  DRAFT="$(pbrain_profile_draft "$STORE" diet-profile)"
  if [[ -n "$DRAFT" ]]; then
    echo "DIET_PROFILE_DRAFT_OPEN"
    echo "draft: $DRAFT"
    echo ""
    cat "$DRAFT"
    echo ""
    echo "---"
    echo "A diet-profile draft is already open (shown above). Review it with the user,"
    echo "apply any edits they want (keep the fenced JSON valid), then finalize with:"
    echo "  bash \"$_SCRIPT_DIR/diet-journal.sh\" profile commit diet-profile"
    echo "Daily logging starts once the profile is committed."
    exit 0
  fi
  cat <<SETUP
DIET_JOURNAL_SETUP_PROFILE
store: $STORE
profile_v1: $STORE/diet-profile.v1.md

INSTRUCTIONS — first-time diet setup. Do not log or analyse any food yet.
You are the user's nutrition coach for this conversation.

Step 1 — Tell the user this is a one-time setup, then interview them. Ask the
questions in 2–3 batches (not all at once, not one at a time). Be warm, not
clinical. Cover everything below — skip a sub-question only if it clearly
doesn't apply.

  Body + state
  - Weight (kg) and height (cm)?
  - Age and sex (for BMR estimation)?
  - Bodyweight goal direction — fat loss / muscle gain / maintain / recomp?
  - Roughly how active are you on a typical week (factoring in your /fitness
    activities if you've set them up)?
  - Sleep average, stress level — anything that affects appetite or recovery?

  Medical / special-diet needs (ask explicitly — this drives the whole profile)
  - Any diagnosed conditions that affect diet? (diabetes type 1/2, pre-
    diabetes, PCOS, hypertension, high cholesterol, fatty liver, kidney
    issues, IBS / Crohn's / IBD, GERD, thyroid, cancer / oncology diet,
    pregnancy, breastfeeding, eating-disorder history, anything else.)
  - Any medications that interact with food (blood thinners, statins, MAOIs,
    SSRIs with weight effects, metformin, insulin, etc.)?
  - Allergies and intolerances (lactose, gluten, nuts, shellfish, eggs, soy,
    fructose, FODMAP issues, etc.)?
  - Recent labs you remember — lipids, HbA1c, fasting glucose, ferritin,
    vitamin D, B12 (anything you want the profile to address)?

  Dietary preferences + culture
  - Veg / non-veg / vegan / pescatarian / flexitarian?
  - Religious or ethical restrictions (halal, kosher, no beef, no pork)?
  - Cuisine context — what kind of food do you actually eat at home? What's a
    normal lunch / dinner for you?
  - Any foods you strongly dislike or refuse?

  Lifestyle + constraints
  - Who cooks — you / partner / takeout-heavy?
  - Time you can spend on meal prep on a weekday?
  - Budget sensitivity (lean / moderate / no constraint)?
  - Eating out / travel frequency?
  - How often do you drink alcohol?

  Habits + history
  - Typical eating window (e.g. 8am–9pm, intermittent fasting)?
  - Meal TIMES: roughly when do you eat each meal on a normal day? (These
    anchor the daily schedule; training days shift them around the session.)
  - Caffeine intake?
  - Hydration habit?
  - Any supplements you take regularly — with dose + timing if known?
  - Anything you've tried before that worked or backfired?
  - One sentence on your relationship with food — relaxed / anxious /
    restrictive / chaotic?

Step 2 — Compute daily macro targets from the answers.
  - BMR via Mifflin-St Jeor.
  - TDEE = BMR × activity multiplier (sedentary 1.2, light 1.375, moderate
    1.55, high 1.725, very_high 1.9).
  - Calories: TDEE adjusted for goal (fat_loss −15–20%, muscle_gain +5–10%,
    recomp ≈ TDEE, maintain = TDEE, condition_management = TDEE unless a
    condition demands otherwise).
  - Macro formula — key off the dietary preference:
    * keto: carbs hard cap 20–50g net (30g if unspecified); protein
      1.6–2.0 g/kg (moderate — excess gluconeogenesis); fat = fill remaining
      calories; fiber 25–35g from non-starchy veg (not counted in net carbs).
    * low_carb: carbs 50–100g; protein 1.6–2.0 g/kg; fat = fill.
    * standard: protein 1.6–2.2 g/kg active / 1.2–1.6 g/kg general, clamped
      by kidney condition; fat 0.8–1.0 g/kg minimum then fill; carbs =
      remainder. For diabetes/PCOS/pre-diabetes bias toward lower GL and
      distribute carbs across meals — do not just slash them.
  - Fiber: 25g (women) / 35g (men) baseline; +5–10g for metabolic conditions.
  - Water: 30–40 ml/kg, +500–1000ml on heavy training days.

  Meal slots — derive from the eating window + goal:
  - OMAD → ["Dinner"]; 16:8/IF → ["Lunch","Snack","Dinner"]; 2-meal →
    ["Lunch","Dinner"]; "3 meals"/"no snacks" → ["Breakfast","Lunch","Dinner"];
    grazing/5-meal → ["Meal 1".."Meal 5"]; fat_loss default (no window
    given) → ["Breakfast","Lunch","Dinner"] (no snacks); otherwise →
    ["Breakfast","Snack 1","Lunch","Snack 2","Dinner"].
  Condition-driven structure adjustments on top:
  - glucose_sensitive (diabetes/pre-diabetes/PCOS): if the window does not
    already force a multi-meal pattern, NOTE that 4–5 smaller meals reduce
    glucose spikes — a suggestion, not an override; add a post-meal-walk note
    after each carb-heavy slot.
  - GERD: final slot 3+ hours before bed; smaller portions there; triggers
    in foods-to-avoid.
  - gut_sensitive (IBS/FODMAP/Crohn): FODMAP triggers in foods-to-avoid;
    snack options default low-FODMAP.

  Per-condition dietary guidance (keep all that apply): diabetes (low-GI,
  pair carbs with protein/fat, no sugary drinks, hypoglycemia callout if on
  insulin), hypertension (DASH leanings), high cholesterol (fiber + omega-3 +
  plant sterols, sat-fat cap), kidney (protein cap, potassium/phosphorus),
  IBS/FODMAP (specific triggers), GERD, PCOS (insulin sensitivity), oncology
  (defer to oncologist; protein adequacy, calorie density, food safety —
  supportive not prescriptive), pregnancy/breastfeeding (extra calories,
  folate/iron/iodine, avoid raw/unpasteurised), allergies (hard-exclude),
  religious/ethical restrictions (respect 100%).

Step 3 — Present the computed targets + meal structure + times to the user
in a compact summary and iterate until they confirm. THEN write the profile:

  $STORE/diet-profile.v1.md   (mkdir -p "$STORE" first)
  ---
  type: diet-profile
  date: $TODAY
  tags: []
  version: 1
  committed: true
  ---

  # Diet profile

  \`\`\`json
  {"created": "$TODAY", "weight_kg": 0, "height_cm": 0, "age": 0,
   "sex": "male|female|other",
   "activity_level": "sedentary|light|moderate|high|very_high",
   "goal": "fat_loss|muscle_gain|maintain|recomp|condition_management",
   "conditions": [], "medications": [], "allergies": [], "intolerances": [],
   "dietary_preference": "omnivore|vegetarian|vegan|...",
   "restrictions": [], "cuisine_context": "...",
   "cooking_capacity": "low|moderate|high",
   "budget": "lean|moderate|unconstrained",
   "eating_window": "...", "alcohol_freq": "...", "caffeine": "...",
   "supplements": ["name — dose — timing"],
   "notes": "free-form summary of anything important",
   "targets": {"calories": 0, "protein_g": 0, "carbs_g": 0, "fat_g": 0,
               "fiber_g": 0, "water_l": 0},
   "macro_approach": "standard|keto|low_carb",
   "meal_pattern": "...",
   "meal_slots": ["..."],
   "meal_times": {"slot": "HH:MM"}}
  \`\`\`

  Then the guidance body, in EXACTLY these sections:

  > {one-paragraph strategy summary: deficit/surplus rationale, key
  > condition-aware adjustments, what success looks like in 4–8 weeks.}

  ## Daily macro targets

  | Macro | Target | Why |
  |---|---|---|
  | Calories | {N} kcal | {TDEE basis + goal adjustment} |
  | Protein | {N} g ({g/kg}) | {rationale} |
  | Carbs | {N} g | {training fuel / condition notes} |
  | Fat | {N} g | {hormone health / sat-fat cap} |
  | Fiber | {N} g | {gut + metabolic health} |
  | Water | {N} L | {baseline + training adjustment} |

  ## Condition-specific guidance
  {bullets per condition; "(none — general healthy-eating principles apply)"}

  ## Foods to favour
  {grouped: protein, carbs, fats, vegetables, fruits, fluids — tailored to
  cuisine_context and restrictions}

  ## Foods to limit or avoid
  {hard excludes + soft limits}

  ## Meal structure (typical day)
  One ### section per slot, in meal_slots order, with the slot time:
  ### {Slot} — {HH:MM} (~{kcal} kcal · P {g} / C {g} / F {g})
  - Anchor: {macros for this slot}
  - Options: {3 meal ideas with rough portions}

  ## Training day vs rest day
  - Training day: {extra carbs + timing around the session}
  - Rest day: {slightly lower carbs, same protein}
  - The daily flow reads today's /fitness-journal session and shifts the
    pre/post-workout slots to land around the real session time.

  ## Hydration + supplements
  {water target, caffeine guidance, supplements only if warranted}

  ## Sample day
  | Meal | Items | Cals | P | C | F | Fiber |  (one row per slot + Total)

  ## Notes
  {caveats: not medical advice; revisit weight every 2–3 weeks; coach
  reminders}

Step 4 — After writing, confirm:
  "Diet profile saved (v1, committed) → $STORE/diet-profile.v1.md.
   Re-run /diet-journal whenever you want to log what you ate or have me
   suggest the next meal against remaining macros. Change the profile later
   with /diet-journal profile new."
SETUP
  exit 0
fi

# Extract + validate the profile JSON (fenced block; legacy raw JSON also parses).
PROFILE_JSON="$(pbrain_profile_json "$PROFILE_FILE")"
if [[ -z "$PROFILE_JSON" ]]; then
  cat <<ERR
DIET_JOURNAL_CONFIG_ERROR
profile_file: $PROFILE_FILE

The diet profile has no readable JSON block (or it is malformed). Fix the
fenced JSON in that file, or mint a fresh version with
/diet-journal profile new diet-profile.
ERR
  exit 1
fi

# Derive meal structure + macro approach. Stored profile values win; the old
# eating_window derivation is only the fallback for profiles that predate them.
_MEAL_META="$(python3 - "$PROFILE_FILE" <<'PYEOF'
import json, re, sys
with open(sys.argv[1]) as fh:
    text = fh.read()
m = re.search(r"```json\s*\n(.*?)```", text, re.DOTALL)
p = json.loads(m.group(1) if m else text)

slots = p.get("meal_slots") or []
pattern = p.get("meal_pattern") or ""
macro = p.get("macro_approach") or ""
times = p.get("meal_times") or {}

if not slots:
    ew = (p.get("eating_window") or "").lower().strip()
    goal = (p.get("goal") or "").lower()
    if "omad" in ew or "one meal" in ew:
        slots, pattern = ["Dinner"], "OMAD (1 meal/day)"
    elif any(x in ew for x in ["16:8", "18:6", "20:4"]) or "intermittent" in ew:
        slots, pattern = ["Lunch", "Snack", "Dinner"], "IF/16:8 — no breakfast"
    elif "2 meal" in ew or "two meal" in ew:
        slots, pattern = ["Lunch", "Dinner"], "2-meal window"
    elif "no snack" in ew or "3 meal" in ew or "three meal" in ew:
        slots, pattern = ["Breakfast", "Lunch", "Dinner"], "3 meals, no snacks"
    elif "graze" in ew or "5 meal" in ew or "five meal" in ew:
        slots, pattern = ["Meal 1", "Meal 2", "Meal 3", "Meal 4", "Meal 5"], "5-meal grazing"
    elif goal == "fat_loss":
        slots, pattern = ["Breakfast", "Lunch", "Dinner"], "3 meals, no snacks (fat-loss default)"
    else:
        slots, pattern = ["Breakfast", "Snack 1", "Lunch", "Snack 2", "Dinner"], "3 meals + snacks (default)"

if not macro:
    dp = (p.get("dietary_preference") or "").lower()
    if "keto" in dp:
        macro = "keto"
    elif "low_carb" in dp or "low carb" in dp:
        macro = "low_carb"
    else:
        macro = "standard"

conds = " ".join(p.get("conditions") or []).lower()
flags = []
if any(x in conds for x in ["diabetes", "pre-diabetes", "prediabetes", "pcos"]):
    flags.append("glucose_sensitive")
if any(x in conds for x in ["gerd", "reflux", "acid"]):
    flags.append("gerd")
if any(x in conds for x in ["ibs", "fodmap", "crohn", "ibd", "colitis"]):
    flags.append("gut_sensitive")

print("MEAL_SLOTS=" + "|".join(slots))
print("MEAL_PATTERN=" + (pattern or "(custom)"))
print("MACRO_APPROACH=" + macro)
print("CONDITION_FLAGS=" + ",".join(flags))
print("MEAL_TIMES=" + ", ".join(f"{k} {v}" for k, v in times.items()))
PYEOF
)"
MEAL_SLOTS="$(echo "$_MEAL_META" | grep '^MEAL_SLOTS=' | cut -d= -f2-)"
MEAL_PATTERN="$(echo "$_MEAL_META" | grep '^MEAL_PATTERN=' | cut -d= -f2-)"
MACRO_APPROACH="$(echo "$_MEAL_META" | grep '^MACRO_APPROACH=' | cut -d= -f2-)"
CONDITION_FLAGS="$(echo "$_MEAL_META" | grep '^CONDITION_FLAGS=' | cut -d= -f2-)"
MEAL_TIMES="$(echo "$_MEAL_META" | grep '^MEAL_TIMES=' | cut -d= -f2-)"
unset _MEAL_META
[[ -n "${MEAL_TIMES//[[:space:]]/}" ]] || MEAL_TIMES="(none stored — estimate from the eating window)"

DIET_PROFILE_CONTENT="$(cat "$PROFILE_FILE")"

# Food library — explicit override, else latest in the store, else the store
# v1 path. Whichever path wins, a missing file gets the stub created in place
# (committed; it is a LIVING document that grows in place) — an explicit
# override path is auto-created too, matching the pre-store behavior.
FOOD_LIBRARY_FILE="${PBRAIN_FOOD_LIBRARY_FILE:-}"
if [[ -z "$FOOD_LIBRARY_FILE" ]]; then
  FOOD_LIBRARY_FILE="$(pbrain_profile_latest_any "$STORE" food-library)"
fi
[[ -n "$FOOD_LIBRARY_FILE" ]] || FOOD_LIBRARY_FILE="$STORE/food-library.v1.md"
if [[ ! -f "$FOOD_LIBRARY_FILE" ]]; then
  mkdir -p "$(dirname "$FOOD_LIBRARY_FILE")"
  cat > "$FOOD_LIBRARY_FILE" <<LIBEOF
---
type: food-library
created: $TODAY
tags: []
version: 1
committed: true
---

# Food Library

Named items you eat, with macros — so you can log by name ("protein shake")
instead of re-describing the recipe each time, and so there's one place to see
everything you eat. This is for **nutrient tracking**, not real recipes: the
description just needs enough detail to estimate macros. A living document —
new rows are appended in place; the version only bumps on a structural rebuild.

## Home / regular foods

| Item | Shortcut | Description | Serving | Cals | P (g) | C (g) | F (g) | Fiber (g) | Meal type |
|---|---|---|---|---|---|---|---|---|---|

## Junk / outside food

| Item | Shortcut | Description | Serving | Cals | P (g) | C (g) | F (g) | Fiber (g) | Meal type |
|---|---|---|---|---|---|---|---|---|---|

## Supplements

Vitamins, minerals, and ergogenic aids you take regularly — so a supplement can
be logged by name and its adherence tracked day to day. **Key nutrients** holds
the active dose(s) (e.g. "2000 IU D3", "5g creatine monohydrate"); the macro
columns matter only for supplements that meaningfully add calories (protein
powder, mass gainer) and are ~0 for pure micronutrients. **Timing** drives when
each appears in the daily checklist.

| Supplement | Form | Dose | Timing | Key nutrients | Cals | P (g) | C (g) | F (g) |
|---|---|---|---|---|---|---|---|---|
LIBEOF
fi
FOOD_LIBRARY_CONTENT="$(cat "$FOOD_LIBRARY_FILE" 2>/dev/null || echo "(no food library yet)")"

RECENT_DIET="$(python3 - "$DIET_DIR" "$TODAY" <<'PYEOF'
import os, glob, sys
d, today = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(d, "*.md")))
files = [f for f in files if os.path.basename(f) != f"{today}.md"][-5:]
parts = []
for f in files:
    try:
        with open(f) as fh:
            parts.append(f"=== {os.path.basename(f)} ===\n{fh.read()}")
    except Exception:
        pass
print("\n\n".join(parts) if parts else "(no past diet entries yet)")
PYEOF
)"

FITNESS_TODAY=""
FITNESS_FILE="$FITNESS_DIR/$TODAY.md"
if [[ -f "$FITNESS_FILE" ]]; then
  FITNESS_TODAY="$(cat "$FITNESS_FILE")"
fi

# Fitness anchors for meal timing: the library (typical session times +
# durations per activity) — today's actual session time, when logged, wins.
FITNESS_LIBRARY_FILE="$(pbrain_profile_latest "$FIT_STORE" fitness-library)"
FITNESS_LIBRARY_CONTENT=""
[[ -n "$FITNESS_LIBRARY_FILE" ]] && FITNESS_LIBRARY_CONTENT="$(cat "$FITNESS_LIBRARY_FILE" 2>/dev/null || true)"
[[ "$FITNESS_LIBRARY_CONTENT" =~ [^[:space:]] ]] || FITNESS_LIBRARY_CONTENT="(no fitness library — anchor meals on the profile meal_times alone)"

MEAL_TIMING_RULES="MEAL TIMING (fitness-anchored): the profile's meal_times are the rest-day
defaults: $MEAL_TIMES. On a training day, shift the relevant slots around the
REAL session: prefer the session time from TODAY'S FITNESS ENTRY (frontmatter
or the **When** line); if the entry has no time, use the typical_time of
today's ($DOW) scheduled activity from the FITNESS LIBRARY. Place pre-workout
fuel 60–90 min before the session and the post-workout protein meal within
~90 min after it; keep every other slot near its default time. Use these
anchored times in any meal table you build today."

# ---------------------------------------------------------------------------
# PHASE 2 — today's entry exists → update mode.
# ---------------------------------------------------------------------------
if [[ -f "$OUT_FILE" ]]; then
  EXISTING_ENTRY="$(cat "$OUT_FILE")"
  cat <<UPDATE
DIET_JOURNAL_UPDATE
date: $TODAY
output_file: $OUT_FILE
profile_file: $PROFILE_FILE
meal_pattern: $MEAL_PATTERN
macro_approach: $MACRO_APPROACH
meal_times: $MEAL_TIMES

=== EXISTING ENTRY ===
$EXISTING_ENTRY

=== DIET PROFILE ===
$DIET_PROFILE_CONTENT

=== FOOD LIBRARY ($FOOD_LIBRARY_FILE) ===
$FOOD_LIBRARY_CONTENT

=== TODAY'S FITNESS ===
${FITNESS_TODAY:-(no fitness entry for today yet)}

=== FITNESS LIBRARY (session times for meal anchoring) ===
$FITNESS_LIBRARY_CONTENT

---
INSTRUCTIONS — today's diet entry already exists. The user is coming back to
add more food, swap something, or refine.

$MEAL_TIMING_RULES

Step 1 — Show a one-line summary of what's already logged (the meal names +
the running macro totals from the existing table), then ask:
  "What's the update — did you eat something new, take a supplement, want to
  log a meal you're about to have, swap something, want me to suggest the next
  meal, or plan the rest of today's meals?"

Step 2 — Based on intent:

  A) LOGGING A NEW MEAL OR ITEM
     - If the item matches a row in the FOOD LIBRARY above (by name, e.g.
       "protein shake"), reuse its macros directly — don't re-ask for detail.
     - Otherwise take their description and estimate macros for each item.
     - Add a new row to the meal table, recompute the day's running totals.
     - Update each Nutrition Analysis category if the new food shifts it.
     - If a newly-described item looks like a recurring staple and isn't in the
       library yet, offer ONCE to add it — see the FOOD LIBRARY step at the
       end. Write only on a yes.

  B) UPDATING / CORRECTING AN EXISTING MEAL
     - Replace the row(s) cleanly. Recompute totals.

  B2) LOGGING A SUPPLEMENT
     - Mark its row in the ## Supplements section as "taken" (add the row if
       the regimen list didn't already carry it). Reuse the dose + timing from
       the FOOD LIBRARY Supplements section for any named supplement.
     - If the supplement carries meaningful calories (protein powder, mass
       gainer), ALSO add/keep a row in the Meals table so macros count. Pure
       micronutrients do NOT touch the macro totals.
     - If it's a new recurring supplement not in the library, offer ONCE to
       add it. Write only on a yes.

  C) SUGGESTING THE NEXT MEAL
     - Compute remaining macros = profile targets − current totals.
     - Propose 2 meal options that fit the remaining macros AND today's
       context (post-workout? evening? available cooking time?). Each option
       shows its macro line.
     - Ask: "Either of these work, or want me to adjust?" Iterate up to 2
       refinements before locking in.
     - Once chosen, add it as a planned meal (status: planned) so the
       user can confirm later when they actually eat it.

  D) PLAN REST OF DAY
     - Read the ## Meal structure section of the DIET PROFILE above to get
       this user's slot names — do not assume a fixed 5-slot day (OMAD has 1
       slot, 16:8 has 3, etc.). Identify which slots are still unlogged
       (absent from the table or only marked "planned").
     - For each empty slot, filter food library items by "Meal type" column —
       pick items tagged for that slot OR tagged "any". Library entries
       without a Meal type column (older entries) are treated as "any". If no
       library items fit a slot, fall back to the profile meal structure.
     - Avoid repeating items the user ate in the last 2 days (check RECENT
       DIET HISTORY — rotate across eligible options).
     - Respect all standing preferences and conditions. Cross-reference
       today's fitness entry: post-workout protein timing, training type.
     - Build a full plan for remaining slots using the FITNESS-ANCHORED slot
       times (rules above):
         | Slot | Time | Items | Cals | P (g) | C (g) | F (g) | Fiber (g) | Status |
       End with projected end-of-day totals vs profile targets.
     - Present it: "Here is a plan for the rest of today — does this work, or
       want to swap anything?" Iterate up to 2 swaps before locking in.
     - Once confirmed, write all planned slots into the entry as new rows with
       status "planned". Recompute totals.

Step 3 — Rewrite the entry file in place at $OUT_FILE, preserving the same
format as the existing entry. Always recompute the totals row and the
"Remaining vs target" row. If macro_approach is "keto" or "low_carb", the
Nutrition Analysis table uses "Net carbs / ketosis" instead of "Carb quality".

Step 4 — End with one short line on how the day's tracking is shaping up
relative to the targets.

Step 5 — Confirm: "Updated → $OUT_FILE"

Step 6 — FOOD LIBRARY upkeep:
  Scan ALL food items currently in today's meal table (not just what was
  described in this message — include items from prior runs that are already
  in the file). For each item that looks like a recurring staple and is NOT
  already in the FOOD LIBRARY, offer once per item:
  "Want me to save '<item>' to your food library so you can just say the name
  next time?" On a yes, append a row to $FOOD_LIBRARY_FILE under the right
  section — **Home / regular foods** for things they make/eat normally,
  **Junk / outside food** for takeout / treats / restaurant items — with a
  brief description (enough to estimate macros), a serving, Cals/P/C/F/Fiber,
  a **Shortcut** (2-3 letter alias the user can type instead of the full name —
  suggest one, let the user override; e.g. "ps" for protein shake), and a
  **Meal type** value. Meal type values: breakfast, lunch, dinner,
  snack, post-workout, omad, any — comma-separated when an item fits multiple
  slots. Keep columns aligned. Append IN PLACE — the library is a living
  document, never mint a new version for new rows.
  Don't add one-off meals; only genuine repeat items. Never write without a yes.

  Supplements: if the user took a NEW regular supplement not in the FOOD
  LIBRARY **Supplements** section, offer once the same way, then append a row
  there — Supplement | Form | Dose | Timing | Key nutrients | Cals | P | C | F.
  Timing values: morning, with-meal, pre-workout, post-workout, bedtime, any.
  Macro columns ~0 for pure micronutrients. Only genuine repeats; yes only.
UPDATE
  pbrain_emit_habits_extract "diet-journal" || true
  exit 0
fi

# ---------------------------------------------------------------------------
# PHASE 3 — daily flow (no entry yet today).
# ---------------------------------------------------------------------------
cat <<PROMPT
DIET_JOURNAL_SESSION
date: $TODAY
output_file: $OUT_FILE
profile_file: $PROFILE_FILE
meal_pattern: $MEAL_PATTERN
macro_approach: $MACRO_APPROACH
meal_times: $MEAL_TIMES

=== DIET PROFILE ===
$DIET_PROFILE_CONTENT

=== FOOD LIBRARY ($FOOD_LIBRARY_FILE) ===
$FOOD_LIBRARY_CONTENT

=== RECENT DIET HISTORY (last 5 days) ===
$RECENT_DIET

=== TODAY'S FITNESS ENTRY ===
${FITNESS_TODAY:-(no fitness entry for today yet)}

=== FITNESS LIBRARY (session times for meal anchoring) ===
$FITNESS_LIBRARY_CONTENT

---
INSTRUCTIONS — daily diet flow. The user has a committed diet profile; this
session either logs what they ate, or coaches them through eating to it.

$MEAL_TIMING_RULES

Step 1 — Open with:
  "What have you eaten today so far? List anything — or say 'nothing yet'
  if the day is blank and you want me to plan from scratch."

  Do NOT force an a/b/c choice upfront. Let the user describe naturally.
  If they mention items in the FOOD LIBRARY above, resolve macros from there
  without re-asking. Ask at most one follow-up for any missing essential
  (e.g. hydration, supplements, late-night eating from last night).

Step 2 — Log whatever the user described. Add each item as an "eaten" row,
estimate macros (reuse FOOD LIBRARY values for named items). Recompute totals.
Pre-populate the ## Supplements section from the FOOD LIBRARY Supplements list
(the user's regular regimen) as "planned" rows, and mark any the user says they
took today as "taken". IMPORTANT: only include supplements where \`active: true\`
in the Food Library — supplements with \`active: false\` are optional and must
NOT be pre-populated; only add them if the user explicitly says they took one
today. If that library section is still empty but the DIET PROFILE lists
"supplements", seed the library Supplements section from the profile first (one
row each, estimating dose/timing/values), then use it.
Calorie-bearing supplements (protein powder) also get a Meals row; micronutrient
supplements do not affect macro totals.

Step 3 — After logging (or if the user said "nothing yet"):

  A) IF MEALS WERE LOGGED and there are still unlogged slots remaining today:
     After writing what they ate, offer: "Want me to plan the rest of today's
     meals around your remaining macros?"
     - On yes → run PLAN REST OF DAY (see below).
     - On no → just show the totals and analysis.

  B) IF NOTHING WAS LOGGED (blank day):
     Say: "Nothing logged yet — want me to plan all your meals for today?
     I will pull from your food library and rotate variety so it is not the
     same as recent days." Then run PLAN REST OF DAY.

  PLAN REST OF DAY:
  - Read the ## Meal structure section of the DIET PROFILE above to get this
    user's slot names — do not default to a fixed 5-slot day. Skip slots
    already eaten.
  - For each empty slot, filter FOOD LIBRARY items by "Meal type" column —
    items tagged for that slot OR tagged "any" (entries without the column
    are "any"). If the library has no entries for a slot, use the profile
    meal-structure options for that slot.
  - Vary selection: avoid items the user ate in the last 2 days (check RECENT
    DIET HISTORY). Rotate across eligible library items for variety.
  - Respect all standing preferences and conditions.
  - Cross-reference today's fitness entry: is there a post-workout slot that
    needs protein within 90 min? Is it a heavy session needing carb loading?
  - Build a full plan using the FITNESS-ANCHORED slot times (rules above):
      | Slot | Time | Items | Cals | P (g) | C (g) | F (g) | Fiber (g) | Status |
    End with projected end-of-day totals vs profile targets.
  - Present it: "Here is a plan for today — does this work, or want to swap
    anything?" Iterate up to 2 swaps before locking in.
  - Once confirmed, write all planned slots as "planned" rows in the entry.

Step 4 — Cross-reference for analysis (do this regardless of mode):
  - Today's fitness load vs today's intake (fuelled enough? protein post?)
  - Recurring patterns from RECENT DIET HISTORY (protein chronically low?
    late eating? hydration short? a condition-specific trigger appearing?).

Step 5 — Write the entry to $OUT_FILE in EXACTLY this format:

  ---
  type: diet
  date: $TODAY
  plan_calories: {targets.calories from the profile}
  plan_protein_g: {targets.protein_g}
  plan_carbs_g: {targets.carbs_g}
  plan_fat_g: {targets.fat_g}
  plan_fiber_g: {targets.fiber_g}
  tags: []
  ---

  # Diet Log — $TODAY

  ## Meals

  {One row per slot from the ## Meal structure section of the diet profile —
   do not add or remove slots; OMAD = 1 row, 16:8 = 3 rows, etc.}
  | Meal | Items | Cals | P (g) | C (g) | F (g) | Fiber (g) | Status |
  |---|---|---|---|---|---|---|---|
  | {slot name} | {items} | ... | ... | ... | ... | ... | eaten / planned / skipped |
  | **Total (so far)** | | **{cal}** | **{P}** | **{C}** | **{F}** | **{fiber}** | |
  | **Target** | | {cal} | {P} | {C} | {F} | {fiber} | |
  | **Remaining** | | {cal} | {P} | {C} | {F} | {fiber} | |

  **Hydration:** {L water so far / target}
  **Late eating (after 9pm):** {yes — what / no}

  ---

  ## Supplements

  | Supplement | Dose | Timing | Status | Note |
  |---|---|---|---|---|
  | {name} | {dose} | {timing} | taken / planned / skipped | {brief, optional} |

  {Pull only \`active: true\` rows from the FOOD LIBRARY Supplements section —
  reuse the saved dose + timing. List these as "planned" so the section doubles
  as a checklist; mark "taken" for any the user confirms today. NEVER include
  supplements with \`active: false\` — they only appear if the user explicitly
  says they took one. If the user takes none and the library has no active
  supplements, write "(none)". Calorie-bearing supplements ALSO get a Meals row
  so their macros count — micronutrient supplements do NOT affect totals.}

  ---

  ## Nutrition Analysis

  {If macro_approach is "keto" or "low_carb": replace "Carb quality" with
  "Net carbs / ketosis" — rate whether net carbs stayed within the profile cap.}
  | Category | Rating | Note |
  |---|---|---|
  | Protein | ✅ / ⚠️ / ❌ | {brief note tied to numbers} |
  | Good fats | ✅ / ⚠️ / ❌ | {brief note} |
  | Carb quality / Net carbs | ✅ / ⚠️ / ❌ | {whole-food vs refined, or net carbs vs cap} |
  | Fiber | ✅ / ⚠️ / ❌ | {brief note} |
  | Hydration | ✅ / ⚠️ / ❌ | {brief note} |
  | Junk / ultra-processed | ✅ / ⚠️ / ❌ | {brief note} |
  | Meal timing | ✅ / ⚠️ / ❌ | {vs the fitness-anchored times} |
  | Condition adherence | ✅ / ⚠️ / ❌ / n/a | {specific to the user's conditions} |

  ---

  ## Patterns (from recent history)

  {2-3 bullets across recent entries, or "(not enough history yet)"}

  ---

  ## Suggested next meal(s)

  {Only if the user asked for suggestions. 1–2 concrete options with macros,
  tied to remaining-macros + fitness context. Otherwise: a single sentence on
  what to prioritise for the rest of the day.}

  ---

  ## Coach note

  {2-3 specific, non-shaming improvements or wins — tied to numbers, not
  "eat healthier".}

Step 6 — FOOD LIBRARY upkeep:
  Scan ALL food items currently in today's meal table. For each item that
  looks like a recurring staple and is NOT already in the FOOD LIBRARY, offer
  once per item: "Want me to save '<item>' to your food library so you can
  just say the name next time?" On a yes, append a row to $FOOD_LIBRARY_FILE
  under **Home / regular foods** or **Junk / outside food**, with a brief
  description, serving, Cals/P/C/F/Fiber, a **Shortcut** (2-3 letter alias —
  suggest one, let the user override; e.g. "ps" for protein shake), and a
  **Meal type** value (breakfast, lunch, dinner, snack, post-workout, omad,
  any — comma-separated for multi-slot items). Append IN PLACE — the library
  is a living document; never mint a new version for new rows.
  Only genuine repeat items, never one-offs. Never write without a yes.

  Supplements: if the user mentioned a NEW regular supplement not in the FOOD
  LIBRARY **Supplements** section, offer once the same way, then append a row
  there — Supplement | Form | Dose | Timing | Key nutrients | Cals | P | C | F.
  Timing values: morning, with-meal, pre-workout, post-workout, bedtime, any.
  Macro columns ~0 for pure micronutrients. Only genuine repeats; yes only.

Step 7 — End with: "Saved → $OUT_FILE. Re-run /diet-journal later to add
meals or have me suggest the next one against remaining macros."
PROMPT

# Habit extraction: log any tracked habits the user evidenced (silent if no
# habits profile). Self-improvement: capture standing preferences / quality
# fixes the user raised this session (silent unless there was genuine feedback).
pbrain_emit_habits_extract "diet-journal" || true
pbrain_emit_self_improve "diet-journal" "$PROFILE_FILE" "diet profile" || true
