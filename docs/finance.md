# /finance

Personal financial tracker, split into **two trackers** that share one profile and one monthly file:

- **Expense tracker — the core, always on.** Strictly what you spend: a transaction ledger, spend-by-category + a month total, recurring-bill statuses, a forward ledger of major **planned one-off expenses for the rest of the calendar year**, and a **next-month spend forecast**.
- **Balances tracker — opt-in.** Earnings, accounts, investments, liabilities → **net worth** and, crucially, **runway**. Only shown when you turn it on (`/finance balances on`).

It's a **tracker and analytics** tool — it surfaces where your money goes and how things are trending. It does **not** set per-category spending caps or police your spending.

Base config lives in the **versioned profile store** under your finance-tracking dir:

```
$VAULT_DIR/life/finance-tracking/.profile/
├── finance-profile.vN.md    # currency, categories, recurring + planned expenses, savings target,
│                            #   and (when opted in) accounts, investments, income, contingency.
│                            #   The track_balances flag gates the balances half.
└── category-library.vN.md   # merchant → category memory (living document — rows append in place)
```

Monthly reports are **one file per month**: `$VAULT_DIR/life/finance-tracking/YYYY-MM.md`.

A **committed** profile version is final — changes mint the next version (`profile new` → edit the draft → `profile commit`).

## First-run setup (one interview)

A one-time interview in 3–4 batches. **Expenses are mandatory; balances tracking is opt-in.**

- **Basics** — primary currency, the day your financial month starts (payday-based), your financial style and goals.
- **Spending (the core)** — spend categories (seeded defaults — housing, diet, fitness, shopping, entertainment, work, grooming, utilities, transport, debt, insurance, and the mandatory `other` fallback — adjustable), recurring payments, and any **planned one-off expenses for the rest of the year** (insurance renewal, a trip, taxes — name, category, amount, which month).
- **Balances (opt-in)** — you're asked explicitly: *"Do you also want to track balances — accounts, investments, income — for net worth and runway?"* Say **no** and it tracks expenses only; say **yes** and it interviews accounts (credit cards/loans negative), investments (with a liquid flag), income sources, a savings target, and a contingency target in months of essential expenses. You can turn this on later anytime with `/finance balances on`.

It reflects a summary back — adapted to your tier — for your confirmation, then writes the committed v1 profile. Sections you skip can be filled in later via `/finance profile new`.

`diet` and `fitness` categories carry a label-only cross-link to `/diet-journal` and `/fitness-journal` (a live data join is intentionally out of scope for v1).

## The monthly report

Each `YYYY-MM.md` has a top-level **`## Expenses`** section (always) and, when balances tracking is on, a **`## Balances`** section. Everything is recomputed in place on every change.

**`## Expenses`** (always):
- **Transactions** — date, description, merchant, category (exactly one), amount, account, note.
- **Spend by category** — spent, % of spend, Δ vs last month, sorted high → low, with a month total (analytics only — no caps, no over-budget flags).
- **Recurring expenses (status)** — paid / due / overdue judged against today and the ledger.
- **Planned (rest of year)** — your forward ledger of major one-off expenses, by month, with status (this-month / upcoming / paid).
- **Next-month forecast** — predicted spend = recurring due next month + planned expenses next month + a run-rate of your discretionary spend.

**`## Balances`** (only when `track_balances` is on):
- **Accounts & investments** — liquid net worth + investments − liabilities, with Δ vs last month.
- **Income** — expected vs received per source.
- **Savings rate** — net income − spend vs your savings target.
- **Contingency / runway** — liquid savings ÷ essential monthly burn vs your target months.
- **Planned-expense affordability** — flags any upcoming planned expense that would dip your projected liquid below the contingency target.

**Insights & notes** closes the report; it degrades by tier — never mentioning net worth / savings / runway when balances tracking is off.

## Quick-add an expense

The fastest way to log a single spend:

```bash
/finance expense 250 lunch at Punjabi Dhaba
/finance expense ₹100 chai
/finance expense 1200 flight on MakeMyTrip on 12 jun
```

The amount is extracted for you; the rest of the phrase is parsed into item, merchant (the place after "on"/"at"/"from"), account (if you name one), and date — **defaulting to now** when you don't give one. It categorizes the expense, echoes the parsed row back for a quick confirm, dedupes, appends to `### Transactions`, and reports the new month total.

## Ingesting a statement (LLM-assisted)

For many transactions at once, paste a bank/card statement, a CSV, or a freeform list — or point the command at a file (`/finance ingest path/to/statement.csv`) — and it:

1. **Parses** each row (date, merchant, amount, direction, account).
2. **Dedupes** against what's already logged on (date + amount + normalized description) — re-pasting an overlapping statement adds **zero** duplicate rows and reports "N new / M skipped".
3. **Categorizes** each new row to exactly one category: category-library merchant memory → recurring-expense match → semantic match → `other`. Unclassifiable rows go to `other` and are surfaced for you to reclassify.
4. **Recomputes** the expense side (spend-by-category, recurring status, planned status, forecast) — plus the balances side when it's on.

The first time a merchant is classified, the command offers once to save it to the category library so it classifies the same way next month (written only on a yes).

## Other things you can do in a session

- **Add a planned expense** — "insurance ₹40k due in September": folded into your planned-expenses ledger (a profile edit) and the forecast.
- **Mark a recurring bill paid** — flips its status and adds the matching transaction row.
- **Update a balance** *(balances-on only)* — "HDFC is now ₹X": rewrites the row and recomputes net worth + runway, and offers to persist it to your profile.
- **Ask a status question** — where is my money going, what does next month look like, how much runway do I have — answered from the report.

## Turning balances tracking on or off

```bash
/finance balances           # report whether balances tracking is on or off
/finance balances on        # opt in — interviews accounts/investments/income if needed, then commits
/finance balances off       # opt out — keeps your balances data (lossless), just stops showing it
```

## Managing the profile

```bash
/finance profile show                   # human-readable summary of profile + category library
/finance profile new                    # mint a new draft of the finance profile
/finance profile commit                 # finalize the open draft
/finance profile new category-library   # structural rebuild of the library (rare)
```

**Default destination:** `$VAULT_DIR/life/finance-tracking/YYYY-MM.md`

**Overrides:**

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_FINANCE_DIR` | Monthly-reports dir; the `.profile` store lives inside it |
| `PBRAIN_FINANCE_PROFILE_FILE` | Explicit profile file, bypassing the versioned store |
| `PBRAIN_CATEGORY_LIBRARY_FILE` | Explicit category-library file, bypassing the store |

**Note:** Balances and values are **user-maintained estimates**, not a synced bank feed — revisit them monthly. This is not financial advice; the command surfaces patterns and gaps, it doesn't prescribe.
