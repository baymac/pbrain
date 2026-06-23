#!/usr/bin/env bash
set -euo pipefail

# finance.sh
# Personal financial tracker. Acts as a financial coach on first run: gathers
# your financial preferences, style, monthly targets, spend categories, current
# balances + investments, recurring payments, and income — and writes ONE
# versioned finance profile. Then each session either shows / updates the live
# monthly report, or INGESTS a data source (a pasted statement, CSV, or list of
# transactions) — parsing, categorizing, deduping, appending, and recomputing
# the month report in real time.
#
# Base config lives in the VERSIONED PROFILE STORE (lib/profiles.sh) under the
# finance-tracking dir:
#   <finance-dir>/.profile/finance-profile.vN.md — currency, financial-month
#       start day, financial style, income sources, accounts, investments,
#       recurring expenses, spend categories, savings target, contingency
#       target, free-form notes.
#   <finance-dir>/.profile/category-library.vN.md — merchant -> category memory
#       (LIVING doc: rows append in place; version bumps only on a structural
#       rebuild) so recurring merchants classify consistently month to month.
#
# `finance.sh profile show|new|commit [finance-profile|category-library]`
# manages versions: drafts are editable, committed versions are final.
#
# Monthly reports are ONE FILE PER MONTH:
#   <finance-dir>/YYYY-MM.md
# recomputed in place as transactions are added.
#
# Session flow:
#   - finance.sh                 -> FINANCE_SESSION: open/show the month report,
#                                   update a balance, mark a recurring payment
#                                   paid, or (if the user provides a data
#                                   source in the conversation) ingest it.
#   - finance.sh ingest [path]   -> FINANCE_INGEST: parse a data source (cat the
#                                   file when a readable path is given, else the
#                                   user pastes it into the conversation) ->
#                                   dedupe -> categorize -> append -> recompute.
#
# Default destinations:
#   Monthly reports: $VAULT_DIR/life/finance-tracking/YYYY-MM.md
#   Profile store:   $VAULT_DIR/life/finance-tracking/.profile/
#
# Overrides:
#   PBRAIN_VAULT                   — vault root
#   PBRAIN_FINANCE_DIR             — monthly-reports dir (the store lives inside it)
#   PBRAIN_FINANCE_PROFILE_FILE    — explicit profile file (bypasses the store)
#   PBRAIN_CATEGORY_LIBRARY_FILE   — explicit category-library file (bypasses the store)

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

# Surface this user's standing preferences for /finance (emits nothing if none set).
pbrain_emit_prefs "finance" || true

FINANCE_DIR="${PBRAIN_FINANCE_DIR:-$VAULT_DIR/life/finance-tracking}"
STORE="$(pbrain_profile_store "$FINANCE_DIR")"

TODAY="$(date +%Y-%m-%d)"
MONTH="$(date +%Y-%m)"
OUT_FILE="$FINANCE_DIR/$MONTH.md"

mkdir -p "$FINANCE_DIR"

# ---------------------------------------------------------------------------
# `profile` subcommand — manage the versioned finance profiles.
#   profile show | profile new [finance-profile|category-library] | profile commit [base]
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "profile" ]]; then
  ACTION="${2:-show}"
  BASE="${3:-finance-profile}"
  case "$ACTION" in
    show)
      echo "FINANCE_PROFILE_SHOW"
      for b in finance-profile category-library; do
        f="$(pbrain_profile_latest "$STORE" "$b")"
        d="$(pbrain_profile_draft "$STORE" "$b")"
        echo ""
        echo "=== $b (committed: ${f:-none}; draft: ${d:-none}) ==="
        [[ -n "$f" ]] && cat "$f"
      done
      echo ""
      echo "---"
      echo "INSTRUCTIONS: Present the profile above as a short human-readable summary"
      echo "(currency + financial-month start + style line, then accounts/investments"
      echo "net worth, recurring + income totals, categories, savings +"
      echo "contingency targets, and a one-line category-library count). Do not dump raw"
      echo "JSON. Committed profiles are final — to change one: /finance profile new [base]."
      exit 0
      ;;
    new)
      DRAFT="$(pbrain_profile_draft "$STORE" "$BASE")"
      if [[ -n "$DRAFT" ]]; then
        echo "FINANCE_PROFILE_DRAFT_OPEN"
        echo "draft: $DRAFT"
        echo "A draft of $BASE is already open. Iterate on it with the user and, when they"
        echo "confirm, finalize with: bash \"$_SCRIPT_DIR/finance.sh\" profile commit $BASE"
        exit 0
      fi
      NEW_PATH="$(pbrain_profile_new "$STORE" "$BASE")" || exit 1
      echo "FINANCE_PROFILE_NEW"
      echo "draft: $NEW_PATH"
      echo ""
      echo "INSTRUCTIONS: A new DRAFT version of $BASE was minted (copied from the"
      echo "previous version when one existed). Walk the user through what they want to"
      echo "change, edit the draft file directly (keep the fenced JSON block valid and"
      echo "the frontmatter version/committed lines intact), iterate until they are"
      echo "happy, then finalize with:"
      echo "  bash \"$_SCRIPT_DIR/finance.sh\" profile commit $BASE"
      echo "Once committed the version is FINAL — further changes mint the next version."
      exit 0
      ;;
    commit)
      OUT="$(pbrain_profile_commit "$STORE" "$BASE")" || exit 1
      echo "FINANCE_PROFILE_COMMITTED"
      echo "file: $OUT"
      echo "This version is now final. Future changes: /finance profile new $BASE"
      exit 0
      ;;
    *)
      echo "usage: finance.sh profile show|new|commit [finance-profile|category-library]" >&2
      exit 2
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Resolution — explicit override file, else latest committed in the store.
# ---------------------------------------------------------------------------
PROFILE_FILE="${PBRAIN_FINANCE_PROFILE_FILE:-}"
if [[ -n "$PROFILE_FILE" && ! -f "$PROFILE_FILE" ]]; then PROFILE_FILE=""; fi
[[ -n "$PROFILE_FILE" ]] || PROFILE_FILE="$(pbrain_profile_latest "$STORE" finance-profile)"

# ---------------------------------------------------------------------------
# PHASE 0 — first-run setup (no committed finance profile anywhere).
# ---------------------------------------------------------------------------
if [[ -z "$PROFILE_FILE" ]]; then
  DRAFT="$(pbrain_profile_draft "$STORE" finance-profile)"
  if [[ -n "$DRAFT" ]]; then
    echo "FINANCE_PROFILE_DRAFT_OPEN"
    echo "draft: $DRAFT"
    echo ""
    cat "$DRAFT"
    echo ""
    echo "---"
    echo "A finance-profile draft is already open (shown above). Review it with the user,"
    echo "apply any edits they want (keep the fenced JSON valid), then finalize with:"
    echo "  bash \"$_SCRIPT_DIR/finance.sh\" profile commit finance-profile"
    echo "Monthly tracking starts once the profile is committed."
    exit 0
  fi
  cat <<SETUP
FINANCE_SETUP_PROFILE
store: $STORE
profile_v1: $STORE/finance-profile.v1.md
month_file: $OUT_FILE

INSTRUCTIONS — first-time finance setup. Do not log or analyse any
transactions yet. You are the user's financial coach for this conversation.
Money is sensitive — be matter-of-fact, never judgmental, and reassure the
user that everything stays local in their own vault.

Step 1 — Tell the user this is a one-time setup, then interview them. Ask the
questions in 3–4 batches (not all at once, not one at a time). Cover
everything below — skip a sub-question only if it clearly does not apply. It
is fine to leave a section sparse and fill it in later via /finance profile new.

  Basics + style
  - Primary currency (code + symbol, e.g. INR ₹, USD \$)?
  - What day does your financial month start on (payday-based, e.g. the 1st,
    or the 25th)? Defaults to 1.
  - How would you describe your financial style — frugal saver, balanced,
    spender working on it, FIRE-focused, debt-payoff mode, etc.?
  - Top money goals right now (build emergency fund, pay off a loan, save for
    X, invest more, just get visibility)?

  Categories of spend
  - We seed sensible defaults: housing, diet, fitness, shopping,
    entertainment, work, grooming, utilities, transport, debt, insurance,
    other. Confirm/adjust — add any they care about (travel, kids, gifts,
    subscriptions, health). NOTE: "other" is mandatory and always present as
    the catch-all. For diet + fitness, mention these soft-link to
    /diet-journal and /fitness-journal by name (label only in v1).

  Balances + investments
  - Current accounts: name, type (checking/savings/credit/wallet/cash),
    whether it is liquid, current balance. Credit cards + loans carry the
    OUTSTANDING balance as a NEGATIVE number (a liability).
  - Investments: name, type (stocks/mutual-funds/crypto/retirement/property/
    gold/FD), current value, whether it is liquid (can be tapped in an
    emergency).

  Income
  - Income sources: name, amount, cadence (monthly/biweekly/weekly/yearly/
    irregular), the day it usually arrives, type (salary/freelance/business/
    rental/interest/other), and whether it is your essential/primary income.

  Recurring payments
  - Recurring expenses: name, which category, amount, cadence, due day,
    whether it is essential (rent, utilities, EMI) vs discretionary
    (subscriptions), any end date, and whether the amount is variable.

  Targets
  - Savings target — a rate (e.g. save 30% of income) OR an absolute monthly
    number.
  - Contingency / emergency-fund target — how many months of essential
    expenses they want liquid (e.g. 6 months).

  (These are health benchmarks for the analytics, not spend limits — /finance
  tracks and surfaces patterns, it does not police category-level spending.)

Step 2 — Reflect a compact summary back: net worth (liquid + investments −
liabilities), total monthly recurring, expected monthly income, the implied
savings room, and the contingency gap (current liquid ÷ essential monthly burn
vs target months). Iterate until they confirm. THEN write the profile:

  $STORE/finance-profile.v1.md   (mkdir -p "$STORE" first)
  ---
  type: finance-profile
  date: $TODAY
  tags: []
  version: 1
  committed: true
  ---

  # Finance profile

  \`\`\`json
  {"created": "$TODAY",
   "currency": "INR", "currency_symbol": "₹",
   "financial_month_start_day": 1,
   "financial_style": "...",
   "goals": ["..."],
   "income_sources": [
     {"name": "Salary", "amount": 0, "cadence": "monthly",
      "expected_day": 1, "type": "salary", "essential": true}],
   "accounts": [
     {"name": "HDFC Savings", "type": "savings", "liquid": true,
      "balance": 0, "as_of": "$TODAY"}],
   "investments": [
     {"name": "Index funds", "type": "mutual_funds", "value": 0,
      "liquid": false, "as_of": "$TODAY"}],
   "recurring_expenses": [
     {"name": "Rent", "category": "housing", "amount": 0,
      "cadence": "monthly", "due_day": 1, "essential": true,
      "end_date": null, "variable": false}],
   "categories": [
     {"name": "housing", "essential": true},
     {"name": "diet", "essential": true, "links": ["/diet-journal"]},
     {"name": "fitness", "essential": false, "links": ["/fitness-journal"]},
     {"name": "shopping", "essential": false},
     {"name": "entertainment", "essential": false},
     {"name": "work", "essential": false},
     {"name": "grooming", "essential": false},
     {"name": "utilities", "essential": true},
     {"name": "transport", "essential": false},
     {"name": "debt", "essential": true},
     {"name": "insurance", "essential": true},
     {"name": "other", "essential": false}],
   "savings_target": {"type": "rate", "value": 30},
   "contingency": {"target_months": 6, "essential_burn_basis": "recurring+essential_categories"},
   "notes": "free-form summary of anything important"}
  \`\`\`

  Then a short guidance body, in EXACTLY these sections:

  > {one-paragraph summary of their financial picture and what success looks
  > like over the next few months — net worth direction, the headline goal,
  > the one habit that moves the needle most.}

  ## Categories
  {bullet per category: name — essential?; note the diet/fitness cross-links
  and that "other" is the fallback.}

  ## Accounts & investments
  {table: Name | Type | Liquid | Balance/Value | as_of — accounts then
  investments; liabilities shown negative. End with the net-worth line.}

  ## Income
  {table: Source | Amount | Cadence | Day | Type | Essential.}

  ## Recurring payments
  {table: Name | Category | Amount | Cadence | Due day | Essential | Variable.}

  ## Targets
  {savings target (rate or absolute) + contingency target months + the current
  runway vs that target.}

  ## Notes
  {caveats: figures are user-maintained estimates; revisit balances monthly;
  this is not financial advice.}

Step 3 — After writing, confirm:
  "Finance profile saved (v1, committed) → $STORE/finance-profile.v1.md.
   Re-run /finance to open this month's report, update a balance, or paste a
   statement / list of transactions and I will categorize and log them.
   Change the profile later with /finance profile new."
SETUP
  exit 0
fi

# Extract + validate the profile JSON (fenced block; legacy raw JSON also parses).
PROFILE_JSON="$(pbrain_profile_json "$PROFILE_FILE")"
if [[ -z "$PROFILE_JSON" ]]; then
  cat <<ERR
FINANCE_CONFIG_ERROR
profile_file: $PROFILE_FILE

The finance profile has no readable JSON block (or it is malformed). Fix the
fenced JSON in that file, or mint a fresh version with
/finance profile new finance-profile.
ERR
  exit 1
fi

PROFILE_CONTENT="$(cat "$PROFILE_FILE")"

# Category library — explicit override, else latest in the store, else the
# store v1 path. A missing file gets the stub created in place (committed; it
# is a LIVING document that grows in place), mirroring the food-library.
CATEGORY_LIBRARY_FILE="${PBRAIN_CATEGORY_LIBRARY_FILE:-}"
if [[ -z "$CATEGORY_LIBRARY_FILE" ]]; then
  CATEGORY_LIBRARY_FILE="$(pbrain_profile_latest_any "$STORE" category-library)"
fi
[[ -n "$CATEGORY_LIBRARY_FILE" ]] || CATEGORY_LIBRARY_FILE="$STORE/category-library.v1.md"
if [[ ! -f "$CATEGORY_LIBRARY_FILE" ]]; then
  mkdir -p "$(dirname "$CATEGORY_LIBRARY_FILE")"
  cat > "$CATEGORY_LIBRARY_FILE" <<LIBEOF
---
type: category-library
created: $TODAY
tags: []
version: 1
committed: true
---

# Category Library

Merchant → category memory, so a merchant that appears on your statements
classifies the same way every month. The first time a merchant is categorized
during ingestion it is appended here; later ingests look it up before guessing.
A living document — new rows are appended in place; the version only bumps on a
structural rebuild.

Match on a normalized merchant string (lowercased, statement noise like trailing
ref numbers / city codes stripped). **Alias** holds the cleaned display name.

| Merchant (normalized) | Alias | Category | Notes |
|---|---|---|---|
LIBEOF
fi
CATEGORY_LIBRARY_CONTENT="$(cat "$CATEGORY_LIBRARY_FILE" 2>/dev/null || echo "(no category library yet)")"

# Recent month reports (cross-month insights + net-worth/savings trends).
RECENT_MONTHS="$(python3 - "$FINANCE_DIR" "$MONTH" <<'PYEOF'
import os, glob, re, sys
d, current = sys.argv[1], sys.argv[2]
files = sorted(glob.glob(os.path.join(d, "[0-9][0-9][0-9][0-9]-[0-9][0-9].md")))
files = [f for f in files if os.path.basename(f) != current + ".md"][-4:]
parts = []
for f in files:
    try:
        with open(f) as fh:
            parts.append("=== " + os.path.basename(f) + " ===\n" + fh.read())
    except Exception:
        pass
print("\n\n".join(parts) if parts else "(no prior month reports yet)")
PYEOF
)"

EXISTING_MONTH=""
if [[ -f "$OUT_FILE" ]]; then
  EXISTING_MONTH="$(cat "$OUT_FILE")"
fi

# The report-format spec shared by both session and ingest instructions.
REPORT_SPEC="REPORT FORMAT — the month file $OUT_FILE has EXACTLY these sections (create
it with this skeleton on first write this month; otherwise rewrite in place
preserving the shape):

  ---
  type: finance
  month: $MONTH
  currency: {currency code from profile}
  updated: $TODAY
  tags: []
  ---

  # Finance — $MONTH

  {one-line status: net worth + Δ vs last month, savings rate so far, and the
  single most useful callout (top spend category / overdue bill / low runway).}

  ## Transactions
  | Date | Description | Category | Out | In | Account | Note |
  |---|---|---|---|---|---|---|
  {one row per transaction, newest at the bottom; Out for spend, In for income/
  refunds; exactly ONE category each — unclassifiable rows use \`other\`.}

  ## Income
  {Source | Expected | Received | Status — expected vs received per source;
  ad-hoc income lands as an 'extra' row. Total at the bottom.}

  ## Recurring expenses (status)
  {Name | Category | Amount | Due day | Status — paid / due / overdue judged
  against today ($TODAY) and the ledger. A matching transaction flips due→paid.}

  ## Spend by category
  {Category | Spent | % of spend | Δ vs last month — one row per category with
  any spend this month, sorted high → low. Δ only when a prior report exists.
  Total at the bottom. This is analytics — where the money went — not a budget
  check; never flag a category as "over".}

  ## Balances & net worth
  {Account/Investment | Type | Liquid | Balance — liabilities negative; then
  Liquid net worth, Investments, Liabilities, and Net worth (Δ vs last month
  when a prior report exists).}

  ## Savings rate
  {net income − total spend this month, vs the profile savings_target (rate or
  absolute). ✅/⚠️ against target.}

  ## Contingency / runway
  {liquid savings ÷ essential monthly burn = N months of runway, vs
  contingency.target_months. ✅/⚠️. Essential burn = essential recurring +
  essential-category spend.}

  ## Insights & notes
  {2–4 bullets. With ≥2 prior month reports, comment on net-worth trajectory,
  savings-rate trend, and burn-rate direction. Degrade gracefully with <2
  months. Surface any \`other\`-bucket rows that should become a real category.}

Always recompute every total / Δ / flag after a change. Money math: keep two
decimals, never invent figures the user did not give."

CATEGORIZE_SPEC="CATEGORIZATION — every transaction maps to exactly ONE category; never
multi-tag, never drop. Resolution order:
  1. Category-library merchant memory (normalized-merchant lookup) — reuse it.
  2. A recurring-expense match in the profile (name/amount/merchant) — use that
     expense's category and mark the recurring bill paid.
  3. Semantic match to a profile category (diet=food/groceries/restaurants,
     fitness=gym/supplements/sports, transport=fuel/cabs/transit, etc.).
  4. \`other\` — the mandatory fallback. Surface every 'other' row in
     ## Insights & notes for the user to reclassify.
When you classify a merchant for the FIRST time (steps 3–4 produced a new
mapping the user confirms), offer ONCE to append it to the category library
($CATEGORY_LIBRARY_FILE) — Merchant (normalized) | Alias | Category | Notes —
so it classifies automatically next month. Append IN PLACE; never mint a new
library version for new rows. Write only on a yes."

# ---------------------------------------------------------------------------
# INGEST mode — `finance.sh ingest [path]` — a data source to fold into the
# month report. When $2 is a readable file, cat it as the DATA SOURCE; else the
# user pastes/points at it in the conversation.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "ingest" ]]; then
  DATA_SOURCE_PATH="${2:-}"
  DATA_SOURCE_CONTENT=""
  if [[ -n "$DATA_SOURCE_PATH" && -f "$DATA_SOURCE_PATH" ]]; then
    DATA_SOURCE_CONTENT="$(cat "$DATA_SOURCE_PATH" 2>/dev/null || true)"
  fi
  cat <<INGEST
FINANCE_INGEST
date: $TODAY
month: $MONTH
output_file: $OUT_FILE
profile_file: $PROFILE_FILE
category_library: $CATEGORY_LIBRARY_FILE
data_source_path: ${DATA_SOURCE_PATH:-(none — user pastes into the conversation)}

=== FINANCE PROFILE ===
$PROFILE_CONTENT

=== CATEGORY LIBRARY ($CATEGORY_LIBRARY_FILE) ===
$CATEGORY_LIBRARY_CONTENT

=== CURRENT MONTH REPORT ($OUT_FILE) ===
${EXISTING_MONTH:-(no report for $MONTH yet — create it from the skeleton)}

=== RECENT MONTH REPORTS ===
$RECENT_MONTHS

=== DATA SOURCE ===
${DATA_SOURCE_CONTENT:-(no file given — use the statement/CSV/list the user pasted into the conversation; if none is present yet, ask them to paste it)}

---
INSTRUCTIONS — ingest a data source into this month's report.

Step 1 — Parse the data source into transactions: date, description/merchant,
amount, direction (out/in), and account when present. Handle pasted bank/card
statements, CSV, or a freeform list. Ask only for the minimum missing essential
(e.g. which account, or the year if dates are bare).

Step 2 — DEDUPE (the critical invariant). For each parsed row, check it against
transactions ALREADY in ## Transactions on (date + abs(amount) +
normalized-description). Skip exact duplicates. Re-pasting an overlapping
statement must add ZERO duplicate rows.

Step 3 — CATEGORIZE each NEW row.
$CATEGORIZE_SPEC

Step 4 — Append the new rows to ## Transactions and recompute EVERYTHING:
income reconciliation, recurring-payment statuses (a match flips due→paid),
spend-by-category, balances/net worth (a transaction against a known
account adjusts its balance only if the user asks — otherwise balances are
user-maintained), savings rate, runway, and the status line.

$REPORT_SPEC

Step 5 — Report what changed: "N new transactions logged, M duplicates skipped"
plus the notable spend movement (top / fastest-growing category), any bill that
flipped to paid, and any rows that fell to \`other\` for the user to reclassify.

Step 6 — Write the report to $OUT_FILE and confirm: "Updated → $OUT_FILE".
INGEST
  pbrain_emit_habits_extract "finance" || true
  exit 0
fi

# ---------------------------------------------------------------------------
# SESSION mode (default) — open/show the month report, update a balance, mark a
# recurring payment paid, or ingest a data source if the user provides one.
# ---------------------------------------------------------------------------
cat <<SESSION
FINANCE_SESSION
date: $TODAY
month: $MONTH
output_file: $OUT_FILE
profile_file: $PROFILE_FILE
category_library: $CATEGORY_LIBRARY_FILE

=== FINANCE PROFILE ===
$PROFILE_CONTENT

=== CATEGORY LIBRARY ($CATEGORY_LIBRARY_FILE) ===
$CATEGORY_LIBRARY_CONTENT

=== CURRENT MONTH REPORT ($OUT_FILE) ===
${EXISTING_MONTH:-(no report for $MONTH yet — create it from the skeleton below)}

=== RECENT MONTH REPORTS ===
$RECENT_MONTHS

---
INSTRUCTIONS — finance session for $MONTH. The user has a committed finance
profile. Figure out intent from what they say; do not force an upfront menu.

Step 1 — If no report exists for $MONTH yet, create it from the profile: seed
## Income (expected per source), ## Recurring expenses (status) (all 'due' or
'overdue' by date), ## Balances & net worth (from the profile accounts/
investments), and empty ## Transactions / ## Spend by category. Carry the Δ
baseline from last month's report when one exists. Then open with a one-line
status (net worth, savings rate so far, the most useful callout).

If a report DOES exist, open with its status line and ask what they want to do.

Step 2 — Route on intent:

  A) INGEST A DATA SOURCE — if the user pastes or points at a statement / CSV /
     list of transactions, run the full ingest sub-flow:
       - Parse → DEDUPE on (date + abs(amount) + normalized-description), skip
         exact dupes → categorize → append to ## Transactions → recompute.
     $CATEGORIZE_SPEC
     Report "N new / M skipped" plus spend-movement / bill / other callouts.

  B) UPDATE A BALANCE — "HDFC is now ₹X", "paid down the card to −₹Y": rewrite
     that account/investment row, refresh as_of, recompute net worth + runway.
     Offer to persist the new balance to the profile (it is the source of truth
     for next month) — that is a profile edit, so route it through
     /finance profile new finance-profile on a yes; never silently edit a
     committed profile.

  C) MARK A RECURRING PAYMENT PAID — flip its row in ## Recurring expenses to
     paid and add the matching ## Transactions row (categorized to the bill's
     category), then recompute spend-by-category + savings rate.

  D) STATUS / QUESTION — answer from the report (where is my money going, how
     much runway, am I on track to my savings target) without rewriting unless
     asked.

Step 3 — Whenever you change the report, recompute every total / Δ / flag and
rewrite $OUT_FILE in place.

$REPORT_SPEC

Step 4 — End with: "Saved → $OUT_FILE. Re-run /finance to log more, update a
balance, or paste a statement to categorize."
SESSION

# Habit extraction: log any tracked habits the user evidenced (silent if no
# habits profile). Self-improvement: capture standing preferences / quality
# fixes the user raised this session (silent unless there was genuine feedback).
pbrain_emit_habits_extract "finance" || true
pbrain_emit_self_improve "finance" "$PROFILE_FILE" "finance profile" || true
