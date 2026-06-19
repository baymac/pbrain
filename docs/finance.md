# /finance

Personal financial tracker. Acts as a financial coach on first run (a one-time interview → **one versioned finance profile**: currency, financial-month start, style, spend categories, accounts, investments, recurring payments, income, and savings/contingency targets), then keeps a **live monthly report** you update in real time — including by pasting a bank/card statement, CSV, or a freeform list of transactions and letting the command parse, categorize, dedupe, and fold it in.

It's a **tracker and analytics** tool — it surfaces where your money goes and how your net worth, savings rate, and runway are trending. It does **not** set per-category spending caps or police your spending.

Base config lives in the **versioned profile store** under your finance-tracking dir:

```
$VAULT_DIR/life/finance-tracking/.profile/
├── finance-profile.vN.md    # currency, categories, accounts, investments, recurring, income, savings + contingency targets
└── category-library.vN.md   # merchant → category memory (living document — rows append in place)
```

Monthly reports are **one file per month**: `$VAULT_DIR/life/finance-tracking/YYYY-MM.md`.

A **committed** profile version is final — changes mint the next version (`profile new` → edit the draft → `profile commit`).

## First-run setup (one interview)

Asks, in batches, about: primary **currency** and the **day your financial month starts** (payday-based), your **financial style** and money goals, **spend categories** (seeded defaults — housing, diet, fitness, shopping, entertainment, work, grooming, utilities, transport, debt, insurance, and the mandatory `other` fallback — adjustable), current **accounts** (credit cards and loans carry a negative balance), **investments** (with a liquid flag), **income sources**, **recurring payments**, a **savings target** (rate or absolute), and a **contingency / emergency-fund target** in months of essential expenses. It reflects a net-worth + savings-room + runway summary back for your confirmation, then writes the committed v1 profile. Sections you skip can be filled in later via `/finance profile new`.

(The savings and contingency targets are health benchmarks for the analytics — there are no per-category spending caps; `/finance` tracks where money goes, it doesn't police it.)

`diet` and `fitness` categories carry a label-only cross-link to `/diet-journal` and `/fitness-journal` (a live data join is intentionally out of scope for v1).

## The monthly report

Each `YYYY-MM.md` has these sections, recomputed in place on every change:

- **Transactions** — date, description, category (exactly one), out/in, account, note.
- **Income** — expected vs received per source; ad-hoc income lands as an extra.
- **Recurring expenses (status)** — paid / due / overdue judged against today and the ledger.
- **Spend by category** — spent, % of spend, Δ vs last month, sorted high → low (analytics only — no caps, no over-budget flags).
- **Balances & net worth** — liquid net worth + investments − liabilities, with Δ vs last month.
- **Savings rate** — net income − spend vs your savings target.
- **Contingency / runway** — liquid savings ÷ essential monthly burn vs your target months.
- **Insights & notes** — net-worth trajectory, savings trend, burn direction (with ≥2 prior months), plus any `other`-bucket rows worth reclassifying.

## Adding transactions (LLM-assisted ingestion)

You don't type transactions one at a time. Paste a bank/card statement, a CSV, or a freeform list — or point the command at a file (`/finance ingest path/to/statement.csv`) — and it:

1. **Parses** each row (date, merchant, amount, direction, account).
2. **Dedupes** against what's already logged on (date + amount + normalized description) — re-pasting an overlapping statement adds **zero** duplicate rows and reports "N new / M skipped".
3. **Categorizes** each new row to exactly one category: category-library merchant memory → recurring-expense match → semantic match → `other`. Unclassifiable rows go to `other` and are surfaced for you to reclassify.
4. **Recomputes** income, recurring status, spend-by-category, balances, savings rate, and runway.

The first time a merchant is classified, the command offers once to save it to the category library so it classifies the same way next month (written only on a yes).

## Other things you can do in a session

- **Update a balance** — "HDFC is now ₹X", "paid the card down to −₹Y": rewrites the row and recomputes net worth + runway. It offers to persist the new balance to your profile (the source of truth for next month).
- **Mark a recurring bill paid** — flips its status and adds the matching transaction row.
- **Ask a status question** — where is my money going, how much runway, am I on track to my savings target — answered from the report.

## Managing the profile

```bash
/finance profile show              # human-readable summary of profile + category library
/finance profile new               # mint a new draft of the finance profile
/finance profile commit            # finalize the open draft
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
