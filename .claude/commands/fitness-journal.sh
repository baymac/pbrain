#!/usr/bin/env bash
set -euo pipefail

VAULT_DIR="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault"
TRACKING_DIR="$VAULT_DIR/fitness/daily-tracking"
TODAY="$(date +%Y-%m-%d)"
OUT_FILE="$TRACKING_DIR/$TODAY.md"

mkdir -p "$TRACKING_DIR"

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

RECENT_SESSIONS="$(python3 <<'PYEOF'
import os, glob

d = os.path.expanduser(
    "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault/fitness/daily-tracking"
)
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

GYM_PLAN="$(cat "$VAULT_DIR/fitness/Gym Plan.md" 2>/dev/null || echo "(no gym plan found)")"

cat <<PROMPT
FITNESS_JOURNAL_SESSION
date: $TODAY
output_file: $OUT_FILE

=== RECENT SESSIONS (last 7) ===
$RECENT_SESSIONS

=== GYM PLAN ===
$GYM_PLAN

---
INSTRUCTIONS — follow these steps in order.

Step 1 — Ask all state questions at once, exactly like this:
  "Quick check-in before we plan today:"
  1. Energy level? (1–10)
  2. Soreness? Which muscles? (1–10)
  3. Sleep last night? (hours + quality 1–10)
  4. Stress? (low / medium / high)
  5. Any pain or injury?
  6. Bodyweight today? (kg — skip if you don't have it)

Step 2 — After their answers, ask:
  "What do you want today?"
  Options: Gym | Football | Apple Fitness+ | Home workout | Recovery/stretching | Walk/cardio | Rest day

Step 3 — Ask: "How much time do you have? Any equipment unavailable?"

Step 4 — Apply adaptive coaching rules before confirming intent:
  - Sleep < 6h AND soreness > 7 AND stress = high → recommend downgrade (gym → recovery/lighter)
  - Leg soreness > 7 AND today is a leg day (A or C) → flag it, suggest swap to B/D or deload
  - Any body part not trained in last 5+ sessions → mention gap
  - Energy < 4 → suggest shorter session or rest
  If you recommend a change, explain why briefly and let the user confirm or override.

---

Step 5A — IF INTENT = GYM:

  Determine next session:
  - Parse frontmatter (week, block, day) from recent sessions to find the last completed day letter (A/B/C/D)
  - Cycle: A→B→C→D→A. After completing D, increment week. Week 5 starts Block 2.
  - Use Block 1 exercises for weeks 1-4, Block 2 for weeks 5-8 (from gym plan above)
  - Session number = total gym sessions completed so far + 1

  Determine weights using progressive overload:
  - For each exercise, scan recent sessions for the last logged weight and reps
  - If last session completed all reps cleanly → add 2.5kg (barbell), 1-2kg (DB/cable)
  - If reps were missed last time → repeat same weight
  - If exercise never done before → start conservatively (use RPE 6 as guide, pick a light weight)

  Generate the file in EXACTLY this format — match spacing, table structure, and section order precisely:

  ---
  date: $TODAY
  week: {N}
  block: {N}
  day: {letter}
  focus: {muscle groups matching gym plan day}
  bodyweight: {kg or leave blank if skipped}
  status: planned
  ---

  # Day {letter} — {Focus}
  **Week {N} · Block {N} · Session {N}** | ~{estimated duration} min

  > {one coaching note tailored to today's state — RPE guidance, fatigue cue, or mindset note. Keep it to 1-2 sentences.}

  ---

  ## Warmup ({X} min)

  | | |
  |---|---|
  | {exercise} | {reps/duration + cue} |
  | ... | ... |
  (4-5 warmup items relevant to today's muscle groups)

  ---

  ## Workout

  ### {Muscle Group 1}

  | Exercise | Sets × Reps | Weight | Notes |
  |---|---|---|---|
  | {exercise} | {sets × reps} | **{weight}** | {short form cue} |
  | ... | ... | ... | ... |

  Rest {X}s between sets.

  ### {Muscle Group 2}

  | Exercise | Sets × Reps | Weight | Notes |
  |---|---|---|---|
  | ... | ... | ... | ... |

  Rest {X}s between sets.

  (repeat for each muscle group in today's day plan)

  ---

  ## Cooldown ({X} min)

  - {stretch relevant to today's muscles}: {duration}
  - ...
  (3-5 items)

  ---

  ## Log your sets here

  | Exercise | Set 1 | Set 2 | Set 3 | Notes |
  |---|---|---|---|---|
  | {every exercise from the workout} | | | | |
  | ... | | | | |

  ---

  ## Notes

  - {1-3 contextual notes: progression cues, what to watch, any football/recovery interaction}
  - Next session: {next day of week from weekly schedule} → Day {next letter} ({next focus})

---

Step 5B — IF INTENT ≠ GYM:
  Generate a shorter markdown note for the chosen mode.
  Use the same frontmatter (date, focus: {type}, status: planned).
  For Recovery/Football/Home: include a brief structured plan appropriate to the mode — no full exercise tables needed.
  For Rest: simple note confirming rest with any recovery recommendations.

---

Step 6 — Write the final content to: $OUT_FILE
  Then confirm: "Saved → $OUT_FILE"
PROMPT
