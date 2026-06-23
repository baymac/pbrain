---
description: Personal financial tracker, split into two trackers that share one profile and one monthly file. EXPENSE tracker (core, always on) — strictly what you spend: a transaction ledger, spend-by-category + month total, recurring-bill statuses, a forward ledger of major PLANNED one-off expenses for the rest of the calendar year, and a next-month spend FORECAST. BALANCES tracker (OPT-IN) — accounts, investments, income → net worth and runway; only written when the profile's track_balances flag is true. Quick-add an expense with `/finance expense <amount> <what>`. Paste a statement / CSV / list to ingest. A tracker and analytics tool — it surfaces where money goes, it does not cap or police spending.
---
Run this with the Bash tool first, then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/finance.sh"
```

**Run bash immediately. Do not say anything to the user until you have the INSTRUCTIONS block.** If the user passed arguments, append them: `expense <amount> <free text>` (fast single-expense add), `ingest [path]` (fold a data source into the month report), `balances [on|off]` (opt in/out of the balances tracker), or `profile show|new|commit [finance-profile|category-library]`.

The script emits one of several tokens — follow the INSTRUCTIONS for whichever fires. Key hard rules:

- **Two trackers, one profile, one month file.** The EXPENSE side (`## Expenses`) is the core and is always written. The BALANCES side (`## Balances`: net worth, savings rate, runway) is written ONLY when the profile flag `track_balances` is true (the `.sh` surfaces it as `track_balances:` in every token). When it is false, NEVER write a balances section or mention net worth / savings rate / runway — offer `/finance balances on` instead. Balances-only is not a mode (no spend → no burn for runway).
- **First-time setup** (`FINANCE_SETUP_PROFILE`): interview in 3–4 batches (not one at a time, not all at once). Expenses are mandatory; **balances tracking is opt-in** — ask explicitly (Batch C) and only fill the balances half when the user says yes. Money is sensitive — be matter-of-fact and reassuring, everything stays local. Reflect a summary adapted to the chosen tier for confirmation before writing the committed v1 profile. Don't log transactions until the profile is committed.
- **Expense quick-add** (`FINANCE_EXPENSE_QUICKADD`): the `.sh` already extracted the amount (`parsed_amount:`); you parse the rest of `raw_input` — item, merchant (the place after "on"/"at"/"from"), account if named, date+time **defaulting to now**. Categorize, **echo the parsed row for a one-line confirm** (fast, not a hard gate), dedupe, append to `## Expenses → ### Transactions`, recompute the expense side, report the new month total.
- **Balances opt-in** (`FINANCE_BALANCES_OPT`): turning balances on/off flips `track_balances` in the profile; since committed profiles are final, a draft is minted — set the flag (interview the balances half on `on` if missing; keep the data losslessly on `off`), then `profile commit`.
- **Returning session** (`FINANCE_SESSION`): open with the one-line status, then infer intent — ingest, quick-add an expense, add a planned expense, update a balance (balances-on only), mark a recurring bill paid, or answer a status question. Don't force an upfront menu.
- **Ingest** (`FINANCE_INGEST`, or the ingest branch of a session): parse → **DEDUPE** on (date + abs(amount) + normalized-description) → categorize → append → recompute. Re-pasting overlapping data must add **zero** duplicate rows; always report "N new / M skipped".
- **Planned expenses + forecast.** `planned_expenses` is a forward ledger of major one-off costs for the rest of the year (name, category, amount, month, essential) → `### Planned (rest of year)`. `### Next-month forecast` predicts next month's spend = recurring-due + planned-next-month + discretionary run-rate; state the basis. Adding a planned expense in conversation is a profile edit — route through `/finance profile new finance-profile`.
- **Exactly one category per transaction** — never multi-tag, never drop. Resolution order: category-library merchant memory → recurring-expense match → semantic match to a profile category → `other` (the mandatory fallback). Surface every `other` row for the user to reclassify.
- **Recompute everything** after any change. Expense side (always): spend by category + month total, recurring-payment statuses (a match flips due→paid), planned-expense statuses, next-month forecast, status line. Balances side (only when `track_balances`): income reconciliation, net worth, savings rate, runway, affordability. Never invent figures the user didn't give.
- **Balances are user-maintained.** A transaction doesn't silently move an account balance — only update a balance when the user states it. Persisting a new balance is a **profile edit**: route it through `/finance profile new finance-profile`, never silently edit a committed profile.
- Committed profiles are final — changes go through `profile new` → edit draft → `profile commit`. The **category library** is a living document (merchant→category rows append in place, no version bump); offer once to save a newly-classified merchant, write only on a yes.
- **Never auto-commit a draft.** After editing a draft, show what changed and ask "Want to lock this in?" Commit only on an explicit yes. Keep editing the same open draft for further changes — don't mint a new version mid-conversation.
- This is **not financial advice** — figures are the user's own estimates; surface patterns and gaps, don't prescribe.

## Morning sequence check (do this first)

Before the finance session, check the morning anchors. Use today's date in `YYYY-MM-DD` format.

1. If `$VAULT_DIR/life/daily-tracking/<TODAY>.md` does NOT exist → say "Heads up: today's `/journal` is empty. Want to fill it in first? Clears the head before anything else." Pause.
2. Else if `$VAULT_DIR/life/gratitude-journal/<TODAY>.md` does NOT exist → say "Heads up: today's gratitude entry is missing. Want to run `/gratitude-journal` first?" Pause.

Suggest once. If user says continue / skip / no, proceed. **If the injected USER PREFERENCES block (global or per-command) says to skip the journal/gratitude nudge, skip steps 1–2 entirely** — a standing preference always overrides a built-in nudge. Resolve `$VAULT_DIR` the same way `lib/vault.sh` does: `$PBRAIN_VAULT` → `~/.config/pbrain/vault` → default iCloud Obsidian path.
