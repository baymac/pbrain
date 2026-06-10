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
#   PBRAIN_VAULT               — vault root
#   PBRAIN_DIET_DIR            — daily-entries dir
#   PBRAIN_FITNESS_DIR         — today's fitness entry (cross-ref)
#   PBRAIN_DIET_PROFILE_FILE   — profile JSON path
#   PBRAIN_DIET_PLAN_FILE      — diet plan markdown path
#   PBRAIN_FOOD_LIBRARY_FILE   — named-foods library markdown (log by name; nutrient reference)

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
FOOD_LIBRARY_FILE="${PBRAIN_FOOD_LIBRARY_FILE:-$VAULT_DIR/fitness/Food Library.md}"
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
  - Any supplements you take regularly (vitamins, minerals, protein powder,
    creatine, omega-3, etc.) — with dose + timing if you know it?
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
    "supplements": ["name — dose — timing", "..."],
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

# Food library — a growing reference of named items the user eats, so they can
# log "protein shake" without re-describing it, and so there's one place to see
# everything they eat. Three sections: home/regular foods, junk/outside food,
# and supplements (vitamins/minerals/ergogenics with their dose + values).
# Create an empty stub the first time (idempotent); Claude fills it over time.
if [[ ! -f "$FOOD_LIBRARY_FILE" ]]; then
  mkdir -p "$(dirname "$FOOD_LIBRARY_FILE")"
  cat > "$FOOD_LIBRARY_FILE" <<LIBEOF
---
type: food-library
created: $TODAY
tags: []
---

# Food Library

Named items you eat, with macros — so you can log by name ("protein shake")
instead of re-describing the recipe each time, and so there's one place to see
everything you eat. This is for **nutrient tracking**, not real recipes: the
description just needs enough detail to estimate macros.

## Home / regular foods

| Item | Description | Serving | Cals | P (g) | C (g) | F (g) | Fiber (g) | Meal type |
|---|---|---|---|---|---|---|---|---|

## Junk / outside food

| Item | Description | Serving | Cals | P (g) | C (g) | F (g) | Fiber (g) | Meal type |
|---|---|---|---|---|---|---|---|---|

## Supplements

Vitamins, minerals, and ergogenic aids you take regularly — so a supplement can
be logged by name and its adherence tracked day to day. **Key nutrients** holds
the active dose(s) (e.g. "2000 IU D3", "5g creatine monohydrate", "EPA 360 /
DHA 240 mg"); the macro columns matter only for supplements that meaningfully
add calories (protein powder, mass gainer) and are ~0 for pure micronutrients.
**Timing** drives when each appears in the daily checklist (morning, with-meal,
pre-workout, post-workout, bedtime, any).

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

=== FOOD LIBRARY ($FOOD_LIBRARY_FILE) ===
$FOOD_LIBRARY_CONTENT

=== TODAY'S FITNESS ===
${FITNESS_TODAY:-(no fitness entry for today yet)}

---
INSTRUCTIONS — today's diet entry already exists. The user is coming back to
add more food, swap something, or refine.

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
     - Update each Nutrition Analysis category if the new food shifts it
       (protein hit hits target / fiber moves up / etc.).
     - If a newly-described item looks like a recurring staple and isn't in the
       library yet, offer ONCE to add it (home/regular vs junk/outside section)
       — see the FOOD LIBRARY step at the end. Write only on a yes.

  B) UPDATING / CORRECTING AN EXISTING MEAL
     - Replace the row(s) cleanly. Recompute totals.

  B2) LOGGING A SUPPLEMENT
     - Mark its row in the ## Supplements section as "taken" (add the row if
       the regimen list didn't already carry it). Reuse the dose + timing from
       the FOOD LIBRARY Supplements section for any named supplement.
     - If the supplement carries meaningful calories (protein powder, mass
       gainer), ALSO add/keep a row in the Meals table so macros count. Pure
       micronutrients (vitamins, creatine, omega-3, magnesium) do NOT touch the
       macro totals.
     - If it's a new recurring supplement not in the library, offer ONCE to add
       it — see the FOOD LIBRARY step at the end. Write only on a yes.

  C) SUGGESTING THE NEXT MEAL
     - Compute remaining macros = plan targets − current totals.
     - Propose 2 meal options that fit the remaining macros AND today's
       context (post-workout? evening? available cooking time?). Each option
       shows its macro line.
     - Ask: "Either of these work, or want me to adjust?" Iterate up to 2
       refinements before locking in.
     - Once chosen, add it as a planned meal (status: planned) so the
       user can confirm later when they actually eat it.

  D) PLAN REST OF DAY
     - Identify which meal slots are still unlogged (absent from the table, or
       only marked "planned"). Infer standard slots from the diet plan meal
       structure and what is already eaten (e.g. if breakfast is eaten and it
       is mid-afternoon, remaining slots might be: dinner, evening snack).
     - For each empty slot, filter food library items by "Meal type" column —
       pick items tagged for that slot OR tagged "any". Library entries without
       a Meal type column (older entries) are treated as "any" for all slots.
       If no library items fit a slot, fall back to the Diet Plan meal structure.
     - Avoid repeating items the user ate in the last 2 days (check RECENT DIET
       HISTORY for variety — rotate across eligible options).
     - Respect all standing preferences (e.g. no roti at lunch, shake only on
       gym/football days). Cross-reference today's fitness entry: post-workout
       protein timing, training type, day load.
     - Build a full plan for remaining slots with estimated timings:
         | Slot | Time | Items | Cals | P (g) | C (g) | F (g) | Fiber (g) | Status |
       End with projected end-of-day totals vs plan targets.
     - Present it: "Here is a plan for the rest of today — does this work, or
       want to swap anything?" Iterate up to 2 swaps before locking in.
     - Once confirmed, write all planned slots into the entry as new rows with
       status "planned". Recompute totals.

Step 3 — Rewrite the entry file in place at $OUT_FILE, preserving the same
format as the existing entry. Always recompute the totals row and the
"Remaining vs plan" row.

Step 4 — End with one short line on how the day's tracking is shaping up
relative to the plan (e.g. "Protein is on track, carbs running 80g short
for a training day — the suggested dinner closes that gap.").

Step 5 — Confirm: "Updated → $OUT_FILE"

Step 6 — FOOD LIBRARY upkeep:
  Scan ALL food items currently in today's meal table (not just what was
  described in this message — include items from prior runs of this command
  that are already in the file). For each item that looks like a recurring
  staple and is NOT already in the FOOD LIBRARY, offer once per item:
  "Want me to save '<item>' to your food library so you can just say the name
  next time?" On a yes, append a row to $FOOD_LIBRARY_FILE under the right
  section — **Home / regular foods** for things they make/eat normally,
  **Junk / outside food** for takeout / treats / restaurant items — with a brief
  description (enough to estimate macros), a serving, Cals/P/C/F/Fiber, and a
  **Meal type** value. Meal type values: breakfast, lunch, dinner, snack,
  post-workout, any — use comma-separated for items that fit multiple slots
  (e.g. "breakfast, snack"). Keep columns aligned.
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
plan_file: $DIET_PLAN_FILE

=== DIET PROFILE ===
$PROFILE_JSON

=== DIET PLAN ===
$DIET_PLAN_CONTENT

=== FOOD LIBRARY ($FOOD_LIBRARY_FILE) ===
$FOOD_LIBRARY_CONTENT

=== RECENT DIET HISTORY (last 5 days) ===
$RECENT_DIET

=== TODAY'S FITNESS ENTRY ===
${FITNESS_TODAY:-(no fitness entry for today yet)}

---
INSTRUCTIONS — daily diet flow. The user has a plan; this session either logs
what they ate, or coaches them through eating to the plan.

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
took today as "taken". IMPORTANT: only include supplements where `active: true`
in the Food Library — supplements with `active: false` are optional and must
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
  - Identify standard meal slots from the diet plan structure (Breakfast,
    Snack 1, Lunch, Snack 2 / Post-workout, Dinner). Skip slots already eaten.
  - For each empty slot, filter FOOD LIBRARY items by "Meal type" column —
    items tagged for that slot OR tagged "any". Library entries without a
    Meal type column (older entries) are treated as "any". If the library has
    no entries for a slot, use the Diet Plan meal structure options for that slot.
  - Vary selection: avoid items the user ate in the last 2 days (check RECENT
    DIET HISTORY). Rotate across eligible library items for variety.
  - Respect all standing preferences (e.g. no roti at lunch, shake only on
    gym/football days) and conditions (gut-friendly on antibiotic days, etc.).
  - Cross-reference today's fitness entry: is there a post-workout slot that
    needs protein within 90 min? Is it a football day needing carb loading?
  - Build a full plan with estimated timings based on the user's eating window:
      | Slot | Time | Items | Cals | P (g) | C (g) | F (g) | Fiber (g) | Status |
    End with projected end-of-day totals vs plan targets.
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
  **Late eating (after 9pm):** {yes — what / no}

  ---

  ## Supplements

  | Supplement | Dose | Timing | Status | Note |
  |---|---|---|---|---|
  | {name} | {dose, e.g. 2000 IU} | {morning / with-meal / post-workout / bedtime} | taken / planned / skipped | {brief, optional} |

  {Pull only `active: true` rows from the FOOD LIBRARY Supplements section —
  reuse the saved dose + timing. List these as "planned" so the section doubles
  as a checklist; mark "taken" for any the user confirms today. NEVER include
  supplements with `active: false` — they are optional and must only appear if
  the user explicitly says they took one. If the user takes none and the library
  has no active supplements, write "(none)". Supplements with meaningful calories
  (protein powder) ALSO get a row in the Meals table so their macros count
  toward totals — micronutrient supplements (vitamins, creatine, omega-3) do NOT
  affect the macro totals.}

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

Step 6 — FOOD LIBRARY upkeep:
  Scan ALL food items currently in today's meal table (not just what was
  described in this message — include items already in the file from prior runs
  of this command). For each item that looks like a recurring staple and is NOT
  already in the FOOD LIBRARY, offer once per item: "Want me to save '<item>'
  to your food library so you can just say the name next time?" On a yes, append
  a row to $FOOD_LIBRARY_FILE under **Home / regular foods** (things they
  make/eat normally) or **Junk / outside food** (takeout / treats / restaurant),
  with a brief description, serving, Cals/P/C/F/Fiber, and a **Meal type** value.
  Meal type values: breakfast, lunch, dinner, snack, post-workout, any — use
  comma-separated for items that fit multiple slots (e.g. "breakfast, snack").
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
pbrain_emit_self_improve "diet-journal" "$DIET_PLAN_FILE" "diet plan" || true
