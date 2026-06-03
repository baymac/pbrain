# /diet-journal

Daily diet journal + nutrition coach. Acts as a coach on first run (state + condition interview → personalised diet plan with macro targets), then every day either logs what you ate or suggests meals against your remaining macros. Always shows a macros table comparing actual to plan.

## First-run setup (two-step bootstrap)

**Step 1 — Profile.** Asks about body state (weight/height/age/activity), goals, **medical conditions** (diabetes, hypertension, kidney issues, IBS, PCOS, cancer/oncology diet, pregnancy, etc.), medications, allergies, intolerances, dietary preferences (veg/non-veg/vegan/halal/kosher), cuisine context, cooking capacity, budget, eating window, alcohol/caffeine habits. Writes machine-readable JSON to:

```
~/.config/pbrain/diet-profile.json
```

**Step 2 — Plan.** Re-run `/diet-journal`. Reads the profile, computes BMR + TDEE + macro targets (with condition-aware adjustments — low-GI for diabetes, sodium cap for hypertension, protein cap for kidney issues, FODMAP exclusions for IBS, etc.), and writes a full diet plan to:

```
$VAULT_DIR/fitness/Diet Plan.md
```

The plan covers: daily macro targets with derivation, condition-specific guidance, foods to favour/limit, meal structure with macro splits per slot, training-day vs rest-day adjustments, hydration + supplements, and a sample day with macro table.

After step 2, the daily flow takes over.

## Daily flow

Three modes depending on state:

- **No entry today + you've eaten** → "log mode": describe naturally, coach estimates per-meal macros, tots them up, compares to plan, analyses nutrition + condition adherence.
- **No entry today + want suggestions** → "plan mode": tell the coach what's eaten so far (if anything), it computes remaining macros and suggests 1–2 meals per remaining slot that fit your macros, restrictions, conditions, and cuisine. Asks "either of these work, or want something different?" and iterates.
- **Entry already exists** → "update mode": adds new meals, swaps items, or suggests the next meal against remaining macros. Recomputes totals and "remaining" row in place.

Every entry includes:

- Meal-by-meal macros table (calories, protein, carbs, fat, fiber) with `Total / Plan target / Remaining` rows.
- Hydration, supplements, late-eating notes.
- Nutrition Analysis rating per category, including a **Condition adherence** row tied to the user's profile.
- Patterns across recent days, and a short coach note.

Cross-references today's `/fitness-journal` entry — pre/post-workout fuel timing, training-day carb bump, etc.

## Food library

A growing reference of the named items you eat — so you can log "protein shake" without re-describing the recipe each time, and so there's **one place to see everything you eat**. It's for *nutrient* tracking, not real recipes: each entry just needs enough description to estimate macros. Two sections:

- **Home / regular foods** — staples you make or eat normally.
- **Junk / outside food** — takeout, treats, restaurant items (kept separate so the pattern is visible).

Lives in your vault at `$VAULT_DIR/fitness/Food Library.md` (created empty on first run). When you log a meal:

- If you name an item that's in the library, the coach reuses its saved macros instead of re-asking.
- If you describe a new item that looks like a recurring staple, it offers once to save it to the right section — written only on a yes.

Edit the file directly any time; it's a normal Obsidian note.

**Default destination:** `$VAULT_DIR/fitness/diet-tracking/YYYY-MM-DD.md`

**Overrides:**

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_DIET_DIR` | Where today's entry is written |
| `PBRAIN_FITNESS_DIR` | Where the script reads today's fitness entry from (cross-ref) |
| `PBRAIN_DIET_PLAN_FILE` | Diet plan markdown path (default: `$VAULT_DIR/fitness/Diet Plan.md`) |
| `PBRAIN_DIET_PROFILE_FILE` | Profile JSON path (default: `~/.config/pbrain/diet-profile.json`) |
| `PBRAIN_FOOD_LIBRARY_FILE` | Named-food library markdown (default: `$VAULT_DIR/fitness/Food Library.md`) |

**Re-running setup:** delete the profile file to redo the interview; delete the plan file to recompute it from the existing profile.

**Note:** Macro estimates from food descriptions are coach-grade, not lab-grade. This is not medical advice — for diagnosed conditions, your doctor's restrictions override this plan.
