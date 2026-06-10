# /diet-journal

Daily diet journal + nutrition coach. Acts as a coach on first run (state + condition interview → personalised diet plan with macro targets), then every day either logs what you ate or suggests meals against your remaining macros. Always shows a macros table comparing actual to plan.

## First-run setup (two-step bootstrap)

**Step 1 — Profile.** Asks about body state (weight/height/age/activity), goals, **medical conditions** (diabetes, hypertension, kidney issues, IBS, PCOS, cancer/oncology diet, pregnancy, etc.), medications, allergies, intolerances, dietary preferences (veg/non-veg/vegan/halal/kosher), cuisine context, cooking capacity, budget, eating window, alcohol/caffeine habits, and any supplements you take regularly. Writes machine-readable JSON to:

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

Just describe what you ate. No upfront mode selection — the command opens with "What have you eaten today so far?" and infers what to do next.

**Logging meals:** describe naturally. Named items in your food library resolve to saved macros without re-describing. The command logs each item, estimates macros, and recomputes totals.

**Plan the rest of today:** after logging (or on a blank day), the command offers to plan remaining meal slots. It filters your food library by `Meal type`, avoids repeats from the past 2 days, respects standing preferences and conditions, cross-references today's fitness session, and builds a timed slot-by-slot plan with projected end-of-day totals. Iterate up to 2 swaps before locking it in. Confirmed slots are written as "planned" rows so you can mark them eaten when the time comes.

**Blank day:** say "nothing yet" and it plans the full day from scratch.

**Existing entry:** add new meals, swap items, or plan remaining slots. Recomputes totals and the "remaining" row in place.

Every entry includes:

- Meal-by-meal macros table (calories, protein, carbs, fat, fiber) with `Total / Plan target / Remaining` rows.
- A dedicated **Supplements** section (table: supplement · dose · timing · status · note) that doubles as a daily checklist — your regular regimen is pre-listed as `planned`, and items you take are marked `taken`. Supplements marked `active: false` in the Food Library are excluded from the checklist; they only appear when you explicitly mention taking one.
- Hydration and late-eating notes.
- Nutrition Analysis rating per category, including a **Condition adherence** row tied to the user's profile.
- Patterns across recent days, and a short coach note.

Supplements that carry real calories (protein powder, mass gainer) also get a row in the meals table so their macros count; pure micronutrients (vitamins, creatine, omega-3) sit in the Supplements section only and don't affect macro totals.

Cross-references today's `/fitness-journal` entry — pre/post-workout fuel timing, training-day carb bump, etc.

## Food library

A growing reference of the named items you eat — so you can log "protein shake" without re-describing the recipe each time, and so there's **one place to see everything you eat**. It's for *nutrient* tracking, not real recipes: each entry just needs enough description to estimate macros. Two sections:

- **Home / regular foods** — staples you make or eat normally.
- **Junk / outside food** — takeout, treats, restaurant items (kept separate so the pattern is visible).
- **Supplements** — vitamins, minerals, and ergogenic aids you take regularly, each with its **Dose**, **Timing**, and **Key nutrients** (the active dose, e.g. "2000 IU D3", "5g creatine"). Macro columns are filled only for calorie-bearing supplements like protein powder. The daily Supplements checklist is pulled from here; on first run it's seeded from any supplements captured in your profile.

Each entry carries a **Meal type** column (`breakfast`, `lunch`, `dinner`, `snack`, `post-workout`, `any`, or comma-separated combinations like `"breakfast, snack"`). The day-planner uses this to filter appropriate items for each slot. Entries without a Meal type column (older entries) are treated as `any` for full backward compatibility.

Lives in your vault at `$VAULT_DIR/fitness/Food Library.md` (created empty on first run). When you log a meal:

- If you name an item that's in the library, the coach reuses its saved macros instead of re-asking.
- If you describe a new item that looks like a recurring staple, it offers once to save it to the right section (with a Meal type) — written only on a yes. The library save check scans **all items in today's meal table** (not just what you described in the current message), so you'll get at most one save-offer per new staple per session — no repeat prompts mid-day.

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
