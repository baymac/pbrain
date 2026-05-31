#!/usr/bin/env bash
set -euo pipefail

# diet-journal.sh
# Interactive daily diet journal with macro tracking. Acts as a nutrition
# coach on first run: gathers state + conditions, builds a personalised diet
# plan, then every day either logs what was eaten OR suggests meals from the
# plan — always with a macros table comparing actual to target.
#
# First-run bootstrap:
#   1. No profile config       → interview user (state, conditions, prefs, goals).
#   2. Profile but no plan     → build full diet plan markdown from profile.
#   3. Both in place           → daily flow.
#
# Daily flow:
#   - If today's entry exists  → update mode (append meals, recompute macros).
#   - Else                     → log mode (user dumps food)  OR  suggest mode
#                                (coach proposes meals from plan, user picks,
#                                followed up with satisfaction check).
#
# Default destinations:
#   Profile config:  ~/.config/pbrain/diet-profile.json
#   Diet plan:       $VAULT_DIR/fitness/Diet Plan.md
#   Daily entries:   $VAULT_DIR/fitness/diet-tracking/YYYY-MM-DD.md
#
# Overrides:
#   PBRAIN_VAULT              — vault root
#   PBRAIN_DIET_DIR           — daily-entries dir
#   PBRAIN_FITNESS_DIR        — today's fitness entry (cross-ref)
#   PBRAIN_DIET_PROFILE_FILE  — profile JSON path
#   PBRAIN_DIET_PLAN_FILE     — diet plan markdown path

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

# Surface this user's standing preferences for /diet-journal (emits nothing if none set).
pbrain_emit_prefs "diet-journal" || true

DIET_DIR="${PBRAIN_DIET_DIR:-$VAULT_DIR/fitness/diet-tracking}"
FITNESS_DIR="${PBRAIN_FITNESS_DIR:-$VAULT_DIR/fitness/daily-tracking}"
DIET_PLAN_FILE="${PBRAIN_DIET_PLAN_FILE:-$VAULT_DIR/fitness/Diet Plan.md}"
PROFILE_FILE="${PBRAIN_DIET_PROFILE_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/diet-profile.json}"

TODAY="$(date +%Y-%m-%d)"
OUT_FILE="$DIET_DIR/$TODAY.md"

mkdir -p "$DIET_DIR"

# ---------------------------------------------------------------------------
# PHASE 0 — first-run profile setup.
# ---------------------------------------------------------------------------
if [[ ! -f "$PROFILE_FILE" ]]; then
  cat <<SETUP
DIET_JOURNAL_SETUP_PROFILE
profile_file: $PROFILE_FILE

INSTRUCTIONS — first-time diet setup (step 1 of 2). Do not log or analyse any
food yet. You are the user's nutrition coach for this conversation.

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

  Medical / special-diet needs (ask explicitly — this drives the whole plan)
  - Any diagnosed conditions that affect diet? (diabetes type 1/2, pre-
    diabetes, PCOS, hypertension, high cholesterol, fatty liver, kidney
    issues, IBS / Crohn's / IBD, GERD, thyroid, cancer / oncology diet,
    pregnancy, breastfeeding, eating-disorder history, anything else.)
  - Any medications that interact with food (blood thinners, statins, MAOIs,
    SSRIs with weight effects, metformin, insulin, etc.)?
  - Allergies and intolerances (lactose, gluten, nuts, shellfish, eggs, soy,
    fructose, FODMAP issues, etc.)?
  - Recent labs you remember — lipids, HbA1c, fasting glucose, ferritin,
    vitamin D, B12 (anything you want the plan to address)?

  Dietary preferences + culture
  - Veg / non-veg / vegan / pescatarian / flexitarian?
  - Religious or ethical restrictions (halal, kosher, no beef, no pork)?
  - Cuisine context — what kind of food do you actually eat at home (Indian,
    Mediterranean, East Asian, mixed)? What's a normal lunch / dinner for you?
  - Any foods you strongly dislike or refuse?

  Lifestyle + constraints
  - Who cooks — you / partner / takeout-heavy?
  - Time you can spend on meal prep on a weekday?
  - Budget sensitivity (lean / moderate / no constraint)?
  - Eating out / travel frequency?
  - How often do you drink alcohol?

  Habits + history
  - Typical eating window (e.g. 8am–9pm, intermittent fasting)?
  - Caffeine intake?
  - Hydration habit?
  - Anything you've tried before that worked or backfired?
  - One sentence on your relationship with food — relaxed / anxious / restrictive / chaotic?

Step 2 — Once you have answers, write the profile to:
  $PROFILE_FILE
  Exact JSON shape (use null for anything the user skipped):

  {
    "created": "$TODAY",
    "weight_kg": 0,
    "height_cm": 0,
    "age": 0,
    "sex": "male|female|other",
    "activity_level": "sedentary|light|moderate|high|very_high",
    "goal": "fat_loss|muscle_gain|maintain|recomp|condition_management",
    "conditions": ["..."],
    "medications": ["..."],
    "allergies": ["..."],
    "intolerances": ["..."],
    "dietary_preference": "omnivore|vegetarian|vegan|pescatarian|...",
    "restrictions": ["..."],
    "cuisine_context": "...",
    "cooking_capacity": "low|moderate|high",
    "budget": "lean|moderate|unconstrained",
    "eating_window": "...",
    "alcohol_freq": "...",
    "caffeine": "...",
    "notes": "free-form summary of anything important not captured above"
  }

  - mkdir -p the parent dir before writing.
  - If the user has a condition like diabetes or kidney disease, capture
    enough detail in "notes" that a plan can be built (e.g. HbA1c if given,
    insulin regimen, eGFR / protein restriction, etc.).
  - Do not invent numbers. If the user didn't give a weight, use 0 and note it.

Step 3 — Confirm: "Profile saved. Now I'll build your diet plan against this
— sit tight." Then re-run /diet-journal to continue with plan creation.
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
DIET_JOURNAL_CONFIG_ERROR
profile_file: $PROFILE_FILE

The diet profile at $PROFILE_FILE is malformed JSON. Either fix it manually,
or delete it and re-run /diet-journal to redo the profile setup.
ERR
  exit 1
fi

PROFILE_JSON="$(cat "$PROFILE_FILE")"

# ---------------------------------------------------------------------------
# PHASE 1 — build the diet plan from profile.
# ---------------------------------------------------------------------------
if [[ ! -f "$DIET_PLAN_FILE" ]]; then
  mkdir -p "$(dirname "$DIET_PLAN_FILE")"
  cat <<PLAN
DIET_JOURNAL_SETUP_PLAN
profile_file: $PROFILE_FILE
plan_file: $DIET_PLAN_FILE

=== PROFILE ===
$PROFILE_JSON

INSTRUCTIONS — first-time diet setup (step 2 of 2). Build a personalised diet
plan from the profile above. You are the user's nutrition coach.

Step 1 — Compute daily macro targets from the profile.
  - BMR via Mifflin-St Jeor.
  - TDEE = BMR × activity multiplier (sedentary 1.2, light 1.375, moderate
    1.55, high 1.725, very_high 1.9).
  - Calories: TDEE adjusted for goal (fat_loss −15–20%, muscle_gain +5–10%,
    recomp ≈ TDEE, maintain = TDEE, condition_management = TDEE unless
    condition demands otherwise).
  - Protein: 1.6–2.2 g/kg for active goals; 1.2–1.6 g/kg for general; clamp
    by kidney condition if present.
  - Fat: 0.8–1.0 g/kg minimum, then fill remaining calories.
  - Carbs: remainder. For diabetes / PCOS / pre-diabetes, bias toward lower
    GL and emphasise distribution across meals — do not just slash carbs.
  - Fiber: 25g (women) / 35g (men) baseline; +5–10g for metabolic conditions.
  - Water: 30–40 ml/kg, +500–1000ml on heavy training days.

Step 2 — Adapt the plan to conditions and restrictions. Be specific.
  - Diabetes / pre-diabetes: low-GI carbs, pair carbs with protein/fat, no
    sugary drinks, post-meal walks, callout on hypoglycemia if on insulin.
  - Hypertension: DASH leanings — potassium-rich, low-sodium, limit processed.
  - High cholesterol: emphasise fiber + omega-3 + plant sterols, limit
    saturated fat and ultra-processed.
  - Kidney issues: respect protein cap, watch potassium / phosphorus.
  - IBS / FODMAP: list specific trigger foods to avoid based on user input.
  - GERD: smaller meals, no eating <3h before bed, avoid known triggers.
  - PCOS: focus on insulin sensitivity (similar to pre-diabetes) + inositol
    if discussed.
  - Cancer / oncology diet: defer to oncologist for restrictions, focus on
    protein adequacy, calorie density, hydration, food safety; flag this
    is supportive not prescriptive.
  - Pregnancy / breastfeeding: extra calories + folate / iron / iodine
    focus, avoid raw fish / unpasteurised etc.
  - Allergies / intolerances: hard-exclude every item the user listed.
  - Religious / ethical restrictions: respect 100%, don't suggest alternatives
    they didn't ask for.

Step 3 — Write the plan markdown to $DIET_PLAN_FILE in EXACTLY this shape:

  ---
  created: $TODAY
  weight_kg: {from profile}
  height_cm: {from profile}
  age: {from profile}
  goal: {from profile}
  conditions: [{from profile}]
  dietary_preference: {from profile}
  daily_calories: {kcal}
  protein_g: {g}
  carbs_g: {g}
  fat_g: {g}
  fiber_g: {g}
  water_l: {l}
  ---

  # Diet Plan

  > {one-paragraph summary of the strategy: deficit/surplus rationale, key
  > condition-aware adjustments, what success looks like in 4–8 weeks.}

  ## Daily macro targets

  | Macro | Target | Why |
  |---|---|---|
  | Calories | {N} kcal | {derivation: TDEE basis + goal adjustment} |
  | Protein | {N} g ({g/kg} g/kg) | {recovery / preservation rationale} |
  | Carbs | {N} g | {training fuel / condition-aware notes} |
  | Fat | {N} g | {hormone health / sat-fat cap if relevant} |
  | Fiber | {N} g | {gut + metabolic health} |
  | Water | {N} L | {baseline + training adjustment} |

  ## Condition-specific guidance

  {bullet list per condition the user has; concrete dietary rules, not generic
  advice. If no conditions, write "(none — general healthy-eating principles
  apply)".}

  ## Foods to favour

  - {grouped: protein sources, carb sources, fats, vegetables, fruits, fluids — tailored to cuisine_context and restrictions}

  ## Foods to limit or avoid

  - {hard excludes from allergies / intolerances / restrictions / conditions, plus soft limits like ultra-processed snacks, sugary drinks, late-night heavy eating}

  ## Meal structure (typical day)

  ### Breakfast (~{kcal} kcal · P {g} / C {g} / F {g})
  - Anchor: {macros to hit}
  - Options:
    - {meal idea 1 with rough portions}
    - {meal idea 2}
    - {meal idea 3}

  ### Lunch (~{kcal} kcal · P {g} / C {g} / F {g})
  - Anchor: ...
  - Options: ...

  ### Dinner (~{kcal} kcal · P {g} / C {g} / F {g})
  - Anchor: ...
  - Options: ...

  ### Snacks (~{kcal} kcal across 1–2 snacks)
  - Pre/post training focus where relevant
  - Options: ...

  ## Training day vs rest day

  - Training day: {extra carbs + timing notes around session}
  - Rest day: {slightly lower carbs, same protein, etc.}
  - Link to /fitness-journal — if today's session is heavy / leg day / long
    football, bump carbs accordingly.

  ## Hydration + supplements

  - Water target: {L/day}
  - Caffeine guidance: {timing}
  - Supplements (only mention if profile suggests need): {vitamin D, B12 for
    vegans, omega-3, magnesium, creatine if relevant to goals, etc.}

  ## Sample day

  | Meal | Items | Cals | P | C | F | Fiber |
  |---|---|---|---|---|---|---|
  | Breakfast | ... | ... | ... | ... | ... | ... |
  | Lunch | ... | ... | ... | ... | ... | ... |
  | Snack | ... | ... | ... | ... | ... | ... |
  | Dinner | ... | ... | ... | ... | ... | ... |
  | **Total** | | **{kcal}** | **{P}** | **{C}** | **{F}** | **{fiber}** |

  ## Notes

  - {plan caveats: this is not medical advice; calorie/macro estimates are
    starting points; revisit weight every 2–3 weeks and adjust}
  - {anything the coach wants to remind the user — e.g. "your iron history
    means make beef / lentils a fixture", "post-football refuel within 90
    min", etc.}

Step 4 — After writing, tell the user:
  "Diet plan saved at $DIET_PLAN_FILE.
   Re-run /diet-journal whenever you want to either log what you ate today,
   or have me suggest a meal that fits your remaining macros. I'll keep the
   macros table updated as you eat."
PLAN
  exit 0
fi

DIET_PLAN_CONTENT="$(cat "$DIET_PLAN_FILE")"

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
plan_file: $DIET_PLAN_FILE

=== EXISTING ENTRY ===
$EXISTING_ENTRY

=== DIET PLAN ===
$DIET_PLAN_CONTENT

=== TODAY'S FITNESS ===
${FITNESS_TODAY:-(no fitness entry for today yet)}

---
INSTRUCTIONS — today's diet entry already exists. The user is coming back to
add more food, swap something, or refine.

Step 1 — Show a one-line summary of what's already logged (the meal names +
the running macro totals from the existing table), then ask:
  "What's the update — did you eat something new, want to log a meal you're
  about to have, swap something, or want me to suggest the next meal to fit
  your remaining macros?"

Step 2 — Based on intent:

  A) LOGGING A NEW MEAL OR ITEM
     - Take their description, estimate macros for each item, add a new row
       to the meal table, recompute the day's running totals.
     - Update each Nutrition Analysis category if the new food shifts it
       (protein hit hits target / fiber moves up / etc.).

  B) UPDATING / CORRECTING AN EXISTING MEAL
     - Replace the row(s) cleanly. Recompute totals.

  C) SUGGESTING THE NEXT MEAL
     - Compute remaining macros = plan targets − current totals.
     - Propose 2 meal options that fit the remaining macros AND today's
       context (post-workout? evening? available cooking time?). Each option
       shows its macro line.
     - Ask: "Either of these work, or want me to adjust?" Iterate up to 2
       refinements before locking in.
     - Once chosen, add it as a planned meal (mark with "(planned)") so the
       user can confirm later when they actually eat it.

Step 3 — Rewrite the entry file in place at $OUT_FILE, preserving the same
format as the existing entry. Always recompute the totals row and the
"Remaining vs plan" row.

Step 4 — End with one short line on how the day's tracking is shaping up
relative to the plan (e.g. "Protein is on track, carbs running 80g short
for a training day — the suggested dinner closes that gap.").

Step 5 — Confirm: "Updated → $OUT_FILE"
UPDATE
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
plan_file: $DIET_PLAN_FILE

=== DIET PROFILE ===
$PROFILE_JSON

=== DIET PLAN ===
$DIET_PLAN_CONTENT

=== RECENT DIET HISTORY (last 5 days) ===
$RECENT_DIET

=== TODAY'S FITNESS ENTRY ===
${FITNESS_TODAY:-(no fitness entry for today yet)}

---
INSTRUCTIONS — daily diet flow. The user has a plan; this session either logs
what they ate, or coaches them through eating to the plan.

Step 1 — Open with the choice:
  "How do you want to do today's diet log?
   (a) Log what you've eaten so far — I'll tot up macros and compare to plan.
   (b) Plan / suggest meals against your remaining macros — tell me what
       you've eaten so far (if anything) and I'll suggest the rest.
   (c) Both — log what's done and plan what's left."

Step 2 — Always have them describe naturally what they've eaten so far.
Don't force structure. Ask any missing essentials (hydration so far,
supplements taken, any late-night eating last night that should carry over).

Step 3 — If intent includes SUGGESTING MEALS (b or c):
  - Pull remaining macros = plan targets − what's logged.
  - Cross-reference today's fitness entry: post-workout protein within ~90
    min? pre-football fuel needed? long endurance session = more carbs?
  - Propose 1–2 meal options per remaining meal slot that hit the macros
    AND respect the user's restrictions, conditions, cuisine context.
  - Each option shows its macro line: "~620 kcal · P 40 / C 70 / F 18".
  - Ask: "Either of these work, or do you want something different —
    quicker / lighter / a different cuisine / something you already have at
    home?"
  - Iterate up to 2 refinements before locking in. Mark unconfirmed meals
    as "(planned)" in the table so the user can mark them eaten later.

Step 4 — Cross-reference for analysis (do this regardless of mode):
  - Today's fitness load vs today's intake (fuelled enough? protein post?)
  - Recurring patterns from RECENT DIET HISTORY (protein chronically low?
    late eating? hydration short? a condition-specific trigger appearing?).

Step 5 — Write the entry to $OUT_FILE in EXACTLY this format:

  ---
  type: diet
  date: $TODAY
  plan_calories: {from plan}
  plan_protein_g: {from plan}
  plan_carbs_g: {from plan}
  plan_fat_g: {from plan}
  plan_fiber_g: {from plan}
  tags: []
  ---

  # Diet Log — $TODAY

  ## Meals

  | Meal | Items | Cals | P (g) | C (g) | F (g) | Fiber (g) | Status |
  |---|---|---|---|---|---|---|---|
  | Breakfast | {items} | ... | ... | ... | ... | ... | eaten / planned / skipped |
  | Lunch | ... | ... | ... | ... | ... | ... | ... |
  | Snack 1 | ... | ... | ... | ... | ... | ... | ... |
  | Dinner | ... | ... | ... | ... | ... | ... | ... |
  | **Total (so far)** | | **{cal}** | **{P}** | **{C}** | **{F}** | **{fiber}** | |
  | **Plan target** | | {cal} | {P} | {C} | {F} | {fiber} | |
  | **Remaining** | | {cal} | {P} | {C} | {F} | {fiber} | |

  **Hydration:** {L water so far / target}
  **Supplements:** {list or "none"}
  **Late eating (after 9pm):** {yes — what / no}

  ---

  ## Nutrition Analysis

  | Category | Rating | Note |
  |---|---|---|
  | Protein | ✅ / ⚠️ / ❌ | {brief note tied to numbers} |
  | Good fats | ✅ / ⚠️ / ❌ | {brief note} |
  | Carb quality | ✅ / ⚠️ / ❌ | {whole-food vs refined, GL if condition matters} |
  | Fiber | ✅ / ⚠️ / ❌ | {brief note} |
  | Hydration | ✅ / ⚠️ / ❌ | {brief note} |
  | Junk / ultra-processed | ✅ / ⚠️ / ❌ | {brief note} |
  | Meal timing | ✅ / ⚠️ / ❌ | {brief note} |
  | Condition adherence | ✅ / ⚠️ / ❌ / n/a | {specific to user's conditions, or n/a if none} |

  ---

  ## Patterns (from recent history)

  {2-3 bullets across recent entries, or "(not enough history yet)"}

  ---

  ## Suggested next meal(s)

  {Only if user asked for suggestions (mode b or c). 1–2 concrete options
  with macros, tied to remaining-macros + fitness context. Otherwise: a
  single sentence on what to prioritise for the rest of the day.}

  ---

  ## Coach note

  {2-3 specific, non-shaming improvements or wins — e.g. "Protein already
  at 110/150 g by lunch, you're on track for post-football refuel" — not
  "eat healthier".}

Step 6 — End with: "Saved → $OUT_FILE. Re-run /diet-journal later to add
meals or have me suggest the next one against remaining macros."
PROMPT

# Self-improvement: capture standing preferences / quality fixes the user
# raised this session (silent unless there was genuine feedback).
pbrain_emit_self_improve "diet-journal" "$DIET_PLAN_FILE" "diet plan" || true
