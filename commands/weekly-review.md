---
description: Weekly synthesis — tight 3–5 bullet read of the last 7 days, 3 reflection questions, writes to life/weekly-tracking/YYYY-Www.md. Commits the closing week's goals, mints next week's weekly-goals draft (deriving from monthly goals or profile, assigning priority+difficulty). Builds a per-command improvement list and walks it one item at a time; approved improvements mint a new committed profile version. Step 6 — if Clippings/ has .md files, ends with a guided filing walk (each clipping shown with preview, moved to a chosen vault dir, optionally renamed).
---
Run this with the Bash tool first, then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/weekly-review.sh"
```

**Run bash immediately. Do not say anything to the user until you have the INSTRUCTIONS block.**

The script emits `WEEKLY_REVIEW_SESSION` with all 7 days of context inlined plus the CORE PROFILES (goals/work/goals-library, diet, fitness, habits — versioned). Follow the INSTRUCTIONS exactly. Key hard rules:

- **Synthesis first, then questions.** Present the 3–5 bullet read before asking anything.
- Quote the user back to themselves — their language, not yours.
- If a day has zero entries, note it once ("you were dark Thursday") and move on. Don't moralize.
- **Improvements one by one.** Build the per-command improvement list from the week's evidence, then walk it item by item — approve or reject each, no batch approvals. Propose nothing without a clear signal.
- **Weekly goals lifecycle (every run):** commit closing week's weekly-goals draft → mint next week's draft → derive from monthly goals or profile → walk goals one by one with priority + difficulty. If weekly goals aren't set up yet, offer to start them.
- **Approved improvements update profiles via versions:** run the owning command's `profile new`, apply only the approved edits to the draft (keep fenced JSON valid), then ask "Want to lock this in?" before running `profile commit` — only commit on explicit yes / "lock" / "commit". If more edits are requested, keep modifying the same open draft, do NOT mint a new version. Libraries (work/goals/food/fitness) are living documents — apply approved edits in place, no version mint.
- Record every proposal + decision (+ new version path when committed) in the review's `## Improvements` section.
- Do NOT generate a generic "great week!" summary. Specifics or silence.
- Do NOT prescribe productivity systems or self-improvement frameworks.
