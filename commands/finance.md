---
description: Personal financial tracker — live monthly report (transactions, income, recurring payments, spend by category, balances & net worth, savings rate, contingency runway). First run builds a versioned finance profile (currency, categories, accounts, investments, recurring bills, income, savings + contingency targets) via interview. Paste a statement / CSV / list and it parses, dedupes, categorizes, and folds it into the month report in real time. A tracker and analytics tool — it surfaces where money goes, it does not cap or police spending.
---
Run this with the Bash tool first, then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/finance.sh"
```

**Run bash immediately. Do not say anything to the user until you have the INSTRUCTIONS block.** If the user passed arguments, append them: `profile show|new|commit [finance-profile|category-library]`, or `ingest [path]` to fold a data source (a file path, else the user pastes it into the conversation) into the month report.

The script emits one of several tokens — follow the INSTRUCTIONS for whichever fires. Key hard rules:

- **First-time setup** (`FINANCE_SETUP_PROFILE`): interview in 3–4 batches (not one at a time, not all at once). Money is sensitive — be matter-of-fact and reassuring, everything stays local. Reflect a net-worth + savings-room + runway summary for confirmation before writing the committed v1 profile. Don't log transactions until the profile is committed.
- **Returning session** (`FINANCE_SESSION`): open with the one-line status, then infer intent — ingest a pasted data source, update a balance, mark a recurring bill paid, or answer a status question. Don't force an upfront menu.
- **Ingest** (`FINANCE_INGEST`, or the ingest branch of a session): parse → **DEDUPE** on (date + abs(amount) + normalized-description) → categorize → append → recompute. Re-pasting overlapping data must add **zero** duplicate rows; always report "N new / M skipped".
- **Exactly one category per transaction** — never multi-tag, never drop. Resolution order: category-library merchant memory → recurring-expense match → semantic match to a profile category → `other` (the mandatory fallback). Surface every `other` row for the user to reclassify.
- **Recompute everything** after any change: income reconciliation, recurring-payment statuses (a match flips due→paid), spend by category, balances/net worth, savings rate, runway, status line. Never invent figures the user didn't give.
- **Balances are user-maintained.** A transaction doesn't silently move an account balance — only update a balance when the user states it. Persisting a new balance is a **profile edit**: route it through `/finance profile new finance-profile`, never silently edit a committed profile.
- Committed profiles are final — changes go through `profile new` → edit draft → `profile commit`. The **category library** is a living document (merchant→category rows append in place, no version bump); offer once to save a newly-classified merchant, write only on a yes.
- **Never auto-commit a draft.** After editing a draft, show what changed and ask "Want to lock this in?" Commit only on an explicit yes. Keep editing the same open draft for further changes — don't mint a new version mid-conversation.
- This is **not financial advice** — figures are the user's own estimates; surface patterns and gaps, don't prescribe.

## Morning sequence check (do this first)

Before the finance session, check the morning anchors. Use today's date in `YYYY-MM-DD` format.

1. If `$VAULT_DIR/life/daily-tracking/<TODAY>.md` does NOT exist → say "Heads up: today's `/journal` is empty. Want to fill it in first? Clears the head before anything else." Pause.
2. Else if `$VAULT_DIR/life/gratitude-journal/<TODAY>.md` does NOT exist → say "Heads up: today's gratitude entry is missing. Want to run `/gratitude-journal` first?" Pause.

Suggest once. If user says continue / skip / no, proceed. **If the injected USER PREFERENCES block (global or per-command) says to skip the journal/gratitude nudge, skip steps 1–2 entirely** — a standing preference always overrides a built-in nudge. Resolve `$VAULT_DIR` the same way `lib/vault.sh` does: `$PBRAIN_VAULT` → `~/.config/pbrain/vault` → default iCloud Obsidian path.
