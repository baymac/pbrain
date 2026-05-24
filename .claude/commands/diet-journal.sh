#!/usr/bin/env bash
set -euo pipefail

VAULT_DIR="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault"
DIET_DIR="$VAULT_DIR/fitness/diet-tracking"
TODAY="$(date +%Y-%m-%d)"
OUT_FILE="$DIET_DIR/$TODAY.md"

mkdir -p "$DIET_DIR"

if [[ -f "$OUT_FILE" ]]; then
  echo "DIET_JOURNAL_EXISTING"
  echo "file: $OUT_FILE"
  echo ""
  cat "$OUT_FILE"
  echo ""
  echo "---"
  echo "Today's diet entry already exists. Show it to the user and ask if they want to update or add anything."
  exit 0
fi

RECENT_DIET="$(python3 <<'PYEOF'
import os, glob

d = os.path.expanduser(
    "~/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault/fitness/diet-tracking"
)
files = sorted(glob.glob(os.path.join(d, "*.md")))[-5:]
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
FITNESS_FILE="$VAULT_DIR/fitness/daily-tracking/$TODAY.md"
if [[ -f "$FITNESS_FILE" ]]; then
  FITNESS_TODAY="$(cat "$FITNESS_FILE")"
fi

cat <<PROMPT
DIET_JOURNAL_SESSION
date: $TODAY
output_file: $OUT_FILE

=== RECENT DIET HISTORY (last 5 days) ===
$RECENT_DIET

=== TODAY'S FITNESS ENTRY ===
${FITNESS_TODAY:-(no fitness entry for today yet)}

---
INSTRUCTIONS — follow these steps in order.

Step 1 — Ask:
  "Walk me through what you ate today — just tell me naturally."
  Let them describe it freely. Don't interrupt or prompt for structure.

Step 2 — Ask only what is still missing after their answer:
  - Hydration? (glasses of water / other drinks)
  - Any supplements today?
  - Anything after 9pm?
  - How was your energy and digestion through the day?

Step 3 — Analyze nutrition quality. Do NOT count calories. Focus on behavior and coverage.

  Assess each category:
  - Protein: sufficient for recovery? (target: ~1.6–2g/kg bodyweight if known, else estimate from meals)
  - Good fats: any nuts/seeds/avocado/eggs/fish/olive oil?
  - Carb quality: whole food sources vs refined (bread, pasta, sweets, rice)
  - Fiber: vegetables, fruits, legumes present?
  - Hydration: roughly adequate?
  - Junk/processed food: frequency, volume, pattern
  - Meal timing: skipped meals, large gaps, heavy eating late?

  Cross-reference with today's fitness entry if available:
  - Was there pre-workout fuel?
  - Was there post-workout protein within ~2h?
  - Does energy reported in fitness check-in correlate with what they ate?

  Scan past diet entries for recurring patterns:
  - protein consistently low?
  - junk food on specific days?
  - late eating pattern?
  - hydration issues?

Step 4 — Write the entry to: $OUT_FILE

  Use exactly this format:

  ---
  date: $TODAY
  ---

  # Diet Log — $TODAY

  ## What I Ate

  **Breakfast:** {summary or "skipped"}
  **Lunch:** {summary or "skipped"}
  **Dinner:** {summary or "skipped"}
  **Snacks:** {list or "none"}
  **Hydration:** {glasses water + other drinks}
  **Supplements:** {list or "none"}
  **Late eating (after 9pm):** {yes — what / no}

  ---

  ## Nutrition Analysis

  | Category | Rating | Note |
  |---|---|---|
  | Protein | ✅ / ⚠️ / ❌ | {brief note} |
  | Good fats | ✅ / ⚠️ / ❌ | {brief note} |
  | Carb quality | ✅ / ⚠️ / ❌ | {brief note} |
  | Fiber | ✅ / ⚠️ / ❌ | {brief note} |
  | Hydration | ✅ / ⚠️ / ❌ | {brief note} |
  | Junk food | ✅ / ⚠️ / ❌ | {brief note} |
  | Meal timing | ✅ / ⚠️ / ❌ | {brief note} |

  ---

  ## Patterns (from history)

  {2-3 bullet points on recurring patterns detected across recent entries, or "(not enough history yet)"}

  ---

  ## Suggested Improvement

  {2-3 specific, non-shaming improvements for tomorrow — e.g. "add a handful of nuts to lunch", not "eat healthier"}

Step 5 — Confirm: "Saved → $OUT_FILE"
PROMPT
