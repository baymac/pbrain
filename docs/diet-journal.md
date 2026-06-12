# /diet-journal

Daily diet journal + nutrition coach. Acts as a coach on first run (state + condition interview → **one versioned diet profile** with macro targets, meal structure, and meal times), then every day either logs what you ate or suggests meals against your remaining macros. Always shows a macros table comparing actual to target.

Base config lives in the **versioned profile store** under your diet-tracking dir:

```
$VAULT_DIR/fitness/diet-tracking/.profile/
├── diet-profile.vN.md   # body/state/conditions/prefs + targets + meal slots/times + full guidance body
└── food-library.vN.md   # named-foods library (living document — rows append in place)
```

A **committed** profile version is final — changes mint the next version (`profile new` → edit the draft → `profile commit`).

## First-run setup (one interview)

Asks about body state (weight/height/age/activity), goals, **medical conditions** (diabetes, hypertension, kidney issues, IBS, PCOS, oncology diet, pregnancy, etc.), medications, allergies, intolerances, dietary preferences (veg/non-veg/vegan/halal/kosher), cuisine context, cooking capacity, budget, eating window, **meal times**, alcohol/caffeine habits, and supplements. Computes BMR + TDEE + macro targets (condition-aware — low-GI for diabetes, sodium cap for hypertension, protein cap for kidney issues, FODMAP exclusions for IBS), presents them for your confirmation, then writes the committed v1 profile.

The profile body covers: daily macro targets with derivation, condition-specific guidance, foods to favour/limit, meal structure with macro splits **and times** per slot, training-day vs rest-day adjustments, hydration + supplements, and a sample day.

## Migrating from older pbrain

If you had the old split setup (`~/.config/pbrain/diet-profile.json` + `fitness/Diet Plan.md`), the first run after upgrading merges them into one versioned profile — **part by part**: you confirm your stats (targets recompute if they changed), confirm the meal structure, and answer the new meal-times questions. The old plan file is parked in `$VAULT_DIR/.pbrain/backup/`. One-time; recorded in the migration ledger. The old `Food Library.md` moves into the store automatically.

## Daily flow

Just describe what you ate. No upfront mode selection — the command opens with "What have you eaten today so far?" and infers what to do next.

**Logging meals:** describe naturally. Named items in your food library resolve to saved macros without re-describing. The command logs each item, estimates macros, and recomputes totals.

**Plan the rest of today:** after logging (or on a blank day), the command offers to plan remaining meal slots. It filters your food library by `Meal type`, avoids repeats from the past 2 days, respects standing preferences and conditions, and builds a timed slot-by-slot plan with projected end-of-day totals. Iterate up to 2 swaps before locking it in.

**Fitness-anchored meal times:** your profile stores default times per slot; on training days the relevant slots shift around the **real session time** (read from today's `/fitness-journal` entry, falling back to the activity's typical time in your fitness library) — pre-workout fuel 60–90 min before, post-workout protein within ~90 min after.

**Blank day:** say "nothing yet" and it plans the full day from scratch.

**Existing entry:** add new meals, swap items, or plan remaining slots. Recomputes totals and the "remaining" row in place.

Every entry includes:

- Meal-by-meal macros table (calories, protein, carbs, fat, fiber) with `Total / Target / Remaining` rows.
- A dedicated **Supplements** section that doubles as a daily checklist — your regular regimen is pre-listed as `planned`, items you take marked `taken`. Supplements marked `active: false` in the Food Library are excluded; they only appear when you explicitly mention taking one.
- Hydration and late-eating notes.
- Nutrition Analysis rating per category, including a **Condition adherence** row tied to your profile.
- Patterns across recent days, and a short coach note.

Supplements that carry real calories (protein powder, mass gainer) also get a row in the meals table so their macros count; pure micronutrients sit in the Supplements section only.

## Food library

A growing reference of the named items you eat — log "protein shake" without re-describing the recipe, and keep **one place to see everything you eat**. Three sections: **Home / regular foods**, **Junk / outside food**, and **Supplements** (dose, timing, key nutrients). Each entry carries a **Meal type** column (`breakfast`, `lunch`, `dinner`, `snack`, `post-workout`, `any`, or comma-separated) that the day-planner uses to filter items per slot.

It's a **living document**: new rows are appended in place (no version bump); recurring staples you describe are offered for saving once — written only on a yes. Edit the file directly any time; it's a normal Obsidian note.

## Managing the profile

```bash
/diet-journal profile show          # human-readable summary of profile + library
/diet-journal profile new           # mint a new draft of the diet profile
/diet-journal profile commit        # finalize the open draft
/diet-journal profile new food-library   # structural rebuild of the library (rare)
```

**Default destination:** `$VAULT_DIR/fitness/diet-tracking/YYYY-MM-DD.md`

**Overrides:**

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_DIET_DIR` | Daily-entries dir; the `.profile` store lives inside it |
| `PBRAIN_FITNESS_DIR` | Where today's fitness entry + fitness library are read from (cross-ref) |
| `PBRAIN_DIET_PROFILE_FILE` | Explicit profile file, bypassing the store (a legacy raw-JSON file still parses) |
| `PBRAIN_FOOD_LIBRARY_FILE` | Explicit food-library file, bypassing the store |

**Note:** Macro estimates from food descriptions are coach-grade, not lab-grade. This is not medical advice — for diagnosed conditions, your doctor's restrictions override this profile.
