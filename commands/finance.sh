#!/usr/bin/env bash
set -euo pipefail

# finance.sh
# Personal financial tracker, split into two trackers that share one profile and
# one monthly file:
#
#   EXPENSE TRACKER (core, always on) — strictly what you spend. The month file's
#       ## Expenses section: a transaction ledger, spend-by-category, recurring
#       expense statuses, a forward ledger of major PLANNED one-off expenses for
#       the rest of the calendar year, and a next-month spend FORECAST.
#
#   BALANCES TRACKER (opt-in) — earnings, accounts, investments, liabilities →
#       net worth and, crucially, RUNWAY. Only written when the profile flag
#       track_balances=true. The month file's ## Balances section: accounts &
#       investments + net worth, income, savings rate, contingency/runway, and
#       planned-expense affordability.
#
# Analytics degrade by tier: expenses-only → spend/category + total + forecast +
# planned + cross-month trend. Both → all of that PLUS runway, savings rate, net
# worth Δ, and affordability. Balances-only is not a mode (no spend → no burn to
# compute runway against); onboarding makes expenses mandatory, balances opt-in.
#
# Base config lives in the VERSIONED PROFILE STORE (lib/profiles.sh) under the
# finance-tracking dir:
#   <finance-dir>/.profile/finance-profile.vN.md — currency, financial-month
#       start day, style, spend categories, recurring + planned expenses,
#       savings target, and (when opted in) income, accounts, investments,
#       contingency target. The top-level `track_balances` flag gates the
#       balances half.
#   <finance-dir>/.profile/category-library.vN.md — merchant -> category memory
#       (LIVING doc: rows append in place; version bumps only on a structural
#       rebuild) so recurring merchants classify consistently month to month.
#
# Subcommands:
#   finance.sh                      -> FINANCE_SESSION: open/show the month
#                                      report; route on intent (ingest, add a
#                                      planned expense, update a balance, mark a
#                                      bill paid, answer a status question).
#   finance.sh expense <amount ...> -> FINANCE_EXPENSE_QUICKADD: fast single-
#                                      expense add. The shell extracts the amount
#                                      deterministically; the model parses the
#                                      rest of the phrase (item / merchant /
#                                      account / date, defaulting date+time to
#                                      now), categorizes, confirms, and appends.
#   finance.sh ingest [path]        -> FINANCE_INGEST: parse a data source ->
#                                      dedupe -> categorize -> append -> recompute.
#   finance.sh balances [on|off]    -> FINANCE_BALANCES_OPT: opt in/out of the
#                                      balances tracker (routes through a profile
#                                      draft, since committed profiles are final).
#   finance.sh profile show|new|commit [finance-profile|category-library]
#
# Monthly reports are ONE FILE PER MONTH:  <finance-dir>/YYYY-MM.md
# recomputed in place as transactions / balances change.
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
NOW="$(date +%H:%M)"
MONTH="$(date +%Y-%m)"
YEAR="$(date +%Y)"
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
      echo "(currency + financial-month start + style; whether balances tracking is ON;"
      echo "spend categories; recurring + planned expenses; and — only if track_balances"
      echo "is true — accounts/investments net worth, income, savings + contingency"
      echo "targets; plus a one-line category-library count). Do not dump raw JSON."
      echo "Committed profiles are final — to change one: /finance profile new [base]."
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
year: $YEAR

INSTRUCTIONS — first-time finance setup. Do not log or analyse any
transactions yet. You are the user's financial coach for this conversation.
Money is sensitive — be matter-of-fact, never judgmental, and reassure the
user that everything stays local in their own vault.

/finance is TWO trackers sharing one profile:
  • EXPENSE tracker — the CORE, always on: what you spend, plus planned one-off
    expenses for the rest of the year and a next-month forecast.
  • BALANCES tracker — OPT-IN: accounts, investments, income → net worth and
    runway. Skippable; the user can turn it on later with /finance balances on.

Step 1 — Tell the user this is a one-time setup and that balances tracking is
optional. Interview in 3–4 batches (not all at once, not one at a time).

  Batch A — Basics + style (always)
  - Primary currency (code + symbol, e.g. INR ₹, USD \$)?
  - What day does your financial month start on (payday-based, e.g. the 1st or
    the 25th)? Defaults to 1.
  - Financial style — frugal saver, balanced, spender working on it, FIRE,
    debt-payoff, etc.? Top money goals right now?

  Batch B — Spending (always — this is the core)
  - Spend categories: we seed sensible defaults — housing, diet, fitness,
    shopping, entertainment, work, grooming, utilities, transport, debt,
    insurance, other. Confirm/adjust. "other" is mandatory (catch-all). diet +
    fitness soft-link to /diet-journal and /fitness-journal (label only in v1).
  - Recurring expenses: name, category, amount, cadence, due day, essential?
    (rent/utilities/EMI) vs discretionary (subscriptions), variable amount?
  - PLANNED one-off expenses for the rest of $YEAR: any big known costs ahead
    (insurance renewal, a trip, taxes, a purchase) — name, category, amount,
    which MONTH (YYYY-MM), essential? Leave empty if none come to mind.

  Batch C — Balances (OPT-IN — ask explicitly)
  - "Do you also want to track balances — accounts, investments, income — so I
    can show net worth and runway? You can turn this on anytime later with
    /finance balances on." If NO → set track_balances=false and SKIP the rest of
    this batch and the savings target. If YES → set track_balances=true and ask:
    - Accounts: name, type (checking/savings/credit/wallet/cash), liquid?,
      current balance. Credit cards + loans carry the OUTSTANDING balance as a
      NEGATIVE number (a liability).
    - Investments: name, type (stocks/mutual-funds/crypto/retirement/property/
      gold/FD), current value, liquid (tappable in an emergency)?
    - Income sources: name, amount, cadence, expected day, type, essential/primary?
    - Savings target — a rate (e.g. 30% of income) OR an absolute monthly number.
    - Contingency / emergency-fund target — how many months of essential
      expenses they want liquid (e.g. 6 months).

  (Targets are health benchmarks for the analytics, not spend limits — /finance
  tracks and surfaces patterns, it does not police category-level spending.)

Step 2 — Reflect a compact summary back, ADAPTED to the chosen tier:
  - Expenses-only: total monthly recurring, the planned-expense calendar for the
    rest of the year, and what the next-month forecast will be based on.
  - Both: ALSO net worth (liquid + investments − liabilities), expected monthly
    income, the implied savings room, and the contingency gap (current liquid ÷
    essential monthly burn vs target months).
  Iterate until they confirm. THEN write the profile:

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
   "track_balances": false,
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
   "recurring_expenses": [
     {"name": "Rent", "category": "housing", "amount": 0,
      "cadence": "monthly", "due_day": 1, "essential": true,
      "end_date": null, "variable": false}],
   "planned_expenses": [
     {"name": "Car insurance", "category": "insurance", "amount": 0,
      "month": "$YEAR-09", "essential": true, "note": ""}],
   "savings_target": {"type": "rate", "value": 30},
   "income_sources": [
     {"name": "Salary", "amount": 0, "cadence": "monthly",
      "expected_day": 1, "type": "salary", "essential": true}],
   "accounts": [
     {"name": "HDFC Savings", "type": "savings", "liquid": true,
      "balance": 0, "as_of": "$TODAY"}],
   "investments": [
     {"name": "Index funds", "type": "mutual_funds", "value": 0,
      "liquid": false, "as_of": "$TODAY"}],
   "contingency": {"target_months": 6, "essential_burn_basis": "recurring+essential_categories"},
   "notes": "free-form summary of anything important"}
  \`\`\`

  IMPORTANT — when track_balances is FALSE, OMIT the balances-half keys entirely
  (income_sources, accounts, investments, contingency) and drop savings_target;
  keep currency/style/categories/recurring_expenses/planned_expenses. When TRUE,
  fill every key from the interview.

  Then a short guidance body, in EXACTLY these sections (skip the balances ones
  when track_balances is false):

  > {one-paragraph summary of their financial picture and what success looks
  > like over the next few months.}

  ## Categories
  {bullet per category: name — essential?; note diet/fitness cross-links and the
  "other" fallback.}

  ## Recurring payments
  {table: Name | Category | Amount | Cadence | Due day | Essential | Variable.}

  ## Planned expenses (rest of $YEAR)
  {table: Month | Name | Category | Amount | Essential — sorted by month.}

  ## Income            (only when track_balances)
  {table: Source | Amount | Cadence | Day | Type | Essential.}

  ## Accounts & investments   (only when track_balances)
  {table: Name | Type | Liquid | Balance/Value | as_of; liabilities negative;
  end with the net-worth line.}

  ## Targets           (only when track_balances)
  {savings target + contingency target months + current runway vs that target.}

  ## Notes
  {caveats: figures are user-maintained estimates; revisit balances monthly;
  this is not financial advice.}

Step 3 — After writing, confirm (adapt to tier):
  "Finance profile saved (v1, committed) → $STORE/finance-profile.v1.md.
   Re-run /finance to open this month's report. Quick-add an expense any time
   with /finance expense <amount> <what> — e.g. /finance expense 250 lunch at
   Punjabi Dhaba. Paste a statement with /finance ingest.
   {if balances off:} Turn on net-worth + runway tracking later with
   /finance balances on."
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

# Is the balances tracker opted in? (track_balances:true in the profile JSON.)
TRACK_BALANCES="$(printf '%s' "$PROFILE_JSON" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print("true" if d.get("track_balances") is True else "false")
except Exception:
    print("false")
')"

# Category library — explicit override, else latest in the store, else the store
# v1 path. A missing file gets the stub created in place (committed; LIVING doc).
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

# Recent month reports (cross-month spend trend + forecast baseline + net-worth
# trends when balances are tracked).
RECENT_MONTHS="$(python3 - "$FINANCE_DIR" "$MONTH" <<'PYEOF'
import os, glob, sys
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

# ---------------------------------------------------------------------------
# Shared spec fragments. The report is composed by tier: the EXPENSE spec is
# always written; the BALANCES spec is appended only when track_balances=true.
# ---------------------------------------------------------------------------
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

PLANNED_SPEC="PLANNED EXPENSES — the profile's planned_expenses is a forward ledger of major
one-off costs for the rest of the calendar year (each: name, category, amount,
month YYYY-MM, essential). In ### Planned (rest of year) list every planned
expense whose month is >= this month, sorted by month, with a Status:
'this-month' (due in $MONTH), 'upcoming' (a later month), or 'paid' (a matching
transaction has landed this period). When the user adds a planned expense in
conversation, append it to the profile via /finance profile new finance-profile
(committed profiles are final) — do not silently edit a committed profile."

FORECAST_SPEC="NEXT-MONTH FORECAST — in ### Next-month forecast, predict next month's spend as:
recurring expenses due next month + any planned_expenses dated next month + a
run-rate of DISCRETIONARY spend (this month's non-recurring, non-one-off spend,
pro-rated to a full month; average with prior months when >=2 reports exist).
State the basis in one line (e.g. 'recurring ₹X + planned ₹Y + run-rate ₹Z').
This is an estimate to plan around, not a budget cap."

EXPENSE_REPORT_SPEC="EXPENSE SECTION — the month file $OUT_FILE always has a top-level ## Expenses
section with EXACTLY these subsections (create from this skeleton on first write
this month; otherwise rewrite in place preserving the shape):

  ## Expenses

  ### Transactions
  | Date | Description | Merchant | Category | Amount | Account | Note |
  |---|---|---|---|---|---|---|
  {one row per spend transaction, newest at the bottom; exactly ONE category
  each — unclassifiable rows use \`other\`. Account may be blank.}

  ### Spend by category
  | Category | Spent | % of spend | Δ vs last month |
  |---|---|---|---|
  {one row per category with any spend this month, sorted high → low; Δ only when
  a prior report exists. MONTH TOTAL at the bottom. Analytics — where the money
  went — never a budget check; never flag a category as 'over'.}

  ### Recurring expenses (status)
  | Name | Category | Amount | Due day | Status |
  {paid / due / overdue judged against today ($TODAY) and the ledger; a matching
  transaction flips due→paid.}

  ### Planned (rest of year)
  | Month | Name | Category | Amount | Status |
  {planned_expenses with month >= $MONTH, sorted by month; Status this-month /
  upcoming / paid.}

  ### Next-month forecast
  {the single forecast line + its basis.}

$PLANNED_SPEC

$FORECAST_SPEC"

BALANCES_REPORT_SPEC="BALANCES SECTION — only when track_balances is true. Append a top-level
## Balances section with EXACTLY these subsections:

  ## Balances

  ### Accounts & investments
  | Name | Type | Liquid | Balance | as_of |
  {accounts then investments; liabilities negative. Then Liquid net worth,
  Investments, Liabilities, and Net worth (Δ vs last month when a prior report
  exists). Balances are user-maintained — a transaction does NOT move an account
  balance unless the user says so.}

  ### Income
  | Source | Expected | Received | Status |
  {expected vs received per source; ad-hoc income lands as an 'extra' row; total
  at the bottom.}

  ### Savings rate
  {net income − total spend this month vs the profile savings_target (rate or
  absolute). ✅/⚠️ against target.}

  ### Contingency / runway
  {liquid savings ÷ essential monthly burn = N months of runway, vs
  contingency.target_months. ✅/⚠️. Essential burn = essential recurring +
  essential-category spend.}

  ### Planned-expense affordability
  {for each upcoming planned expense, check projected liquid at its month
  (current liquid − expected net saving until then) against the contingency
  target; flag any planned expense that would dip liquid below the target.}"

INSIGHTS_SPEC="## Insights & notes — 2–4 bullets at the very end, AFTER the section(s) above.
Degrade by tier: expenses-only → top/fastest-growing category, any overdue bill,
any big planned expense coming up, any \`other\`-bucket rows to reclassify. With
≥2 prior reports, comment on the spend trend. When track_balances is true, ALSO
comment on net-worth trajectory, savings-rate trend, and runway direction. NEVER
reference balances, net worth, savings rate, or runway when track_balances is
false. Always recompute every total / Δ / flag after a change; two decimals;
never invent figures the user did not give."

# Compose the active report spec by tier.
if [[ "$TRACK_BALANCES" == "true" ]]; then
  REPORT_SPEC="$EXPENSE_REPORT_SPEC

$BALANCES_REPORT_SPEC

$INSIGHTS_SPEC

The month file frontmatter carries 'track_balances: true'."
else
  REPORT_SPEC="$EXPENSE_REPORT_SPEC

$INSIGHTS_SPEC

Balances tracking is OFF — write ONLY the ## Expenses section (no ## Balances,
no net worth / savings rate / runway anywhere). The month file frontmatter
carries 'track_balances: false'. The user can opt in with /finance balances on."
fi

# ---------------------------------------------------------------------------
# `expense` quick-add — `finance.sh expense <amount> <free text>`. The shell
# deterministically extracts the amount + currency; the model parses the rest.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "expense" ]]; then
  shift || true
  RAW="$*"
  PARSED_AMOUNT="$(printf '%s' "$RAW" | python3 -c '
import sys, re
s = sys.stdin.read()
# First number that looks like a money amount, allowing thousands separators,
# decimals, and a leading/trailing currency symbol (handled by the regex around).
m = re.search(r"(\d{1,3}(?:,\d{2,3})*(?:\.\d{1,2})?|\d+(?:\.\d{1,2})?)", s)
print(m.group(1).replace(",", "") if m else "")
')"
  cat <<QUICKADD
FINANCE_EXPENSE_QUICKADD
date: $TODAY
time: $NOW
month: $MONTH
output_file: $OUT_FILE
profile_file: $PROFILE_FILE
category_library: $CATEGORY_LIBRARY_FILE
track_balances: $TRACK_BALANCES
parsed_amount: ${PARSED_AMOUNT:-(could not extract — read it from raw_input)}
raw_input: $RAW

=== FINANCE PROFILE ===
$PROFILE_CONTENT

=== CATEGORY LIBRARY ($CATEGORY_LIBRARY_FILE) ===
$CATEGORY_LIBRARY_CONTENT

=== CURRENT MONTH REPORT ($OUT_FILE) ===
${EXISTING_MONTH:-(no report for $MONTH yet — create it from the skeleton)}

---
INSTRUCTIONS — quick-add ONE expense from raw_input.

Step 1 — Parse raw_input into a single expense:
  - amount: use parsed_amount above (the shell already extracted it); only re-read
    raw_input if it is empty or clearly wrong.
  - item/description: WHAT was bought (e.g. "buy xyz" → "xyz").
  - merchant/payee: the place/person, typically after "on"/"at"/"from"
    (e.g. "on abc" → merchant "abc"). May be absent.
  - account: only if the user named one (e.g. "on HDFC", "ICICI card"); else blank.
  - date + time: DEFAULT to today ($TODAY) and now ($NOW) when not stated. Parse
    relative/explicit dates if given ("on 12 jun", "yesterday").
  If the amount truly cannot be determined, ask the user once; otherwise proceed.

Step 2 — Categorize the expense to exactly ONE category.
$CATEGORIZE_SPEC

Step 3 — Echo the parsed row back for a quick one-line confirm (date · item ·
merchant · amount · inferred category · account?). This is a fast confirm, not a
hard gate — if the user objects, fix the field they name.

Step 4 — DEDUPE then append to ## Expenses → ### Transactions (check date +
abs(amount) + normalized-description against existing rows; skip an exact dupe).
Recompute the EXPENSE side only: ### Spend by category (+ month total), recurring
status if it matched a bill, and ### Next-month forecast. Do NOT touch the
## Balances section.

$REPORT_SPEC

Step 5 — Write $OUT_FILE and report: "Logged {amount} {item} → {category}; $MONTH
total now {X}." Mention if it flipped a recurring bill to paid or fell to \`other\`.
QUICKADD
  pbrain_emit_habits_extract "finance" || true
  exit 0
fi

# ---------------------------------------------------------------------------
# `balances` subcommand — opt in/out of the balances tracker. Because committed
# profiles are final, flipping the flag routes through a profile draft.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "balances" ]]; then
  WANT="${2:-}"
  if [[ -z "$WANT" ]]; then
    echo "FINANCE_BALANCES_OPT"
    echo "current: track_balances=$TRACK_BALANCES"
    echo "profile_file: $PROFILE_FILE"
    echo ""
    echo "INSTRUCTIONS: Tell the user whether balances tracking is currently ON or OFF"
    echo "(track_balances above). If ON, the month report includes ## Balances (net"
    echo "worth, savings rate, runway). If OFF, only ## Expenses is tracked. To change"
    echo "it: /finance balances on  or  /finance balances off."
    exit 0
  fi
  case "$WANT" in on|off) ;; *) echo "usage: finance.sh balances [on|off]" >&2; exit 2;; esac
  DRAFT="$(pbrain_profile_draft "$STORE" finance-profile)"
  if [[ -z "$DRAFT" ]]; then
    DRAFT="$(pbrain_profile_new "$STORE" finance-profile)" || exit 1
  fi
  cat <<BALOPT
FINANCE_BALANCES_OPT
want: $WANT
current: track_balances=$TRACK_BALANCES
draft: $DRAFT
year: $YEAR

=== FINANCE PROFILE (latest committed) ===
$PROFILE_CONTENT

---
INSTRUCTIONS — the user wants balances tracking turned $WANT. A profile DRAFT is
open at $DRAFT (committed profiles are final, so this is a new version).

If turning ON:
  - Set "track_balances": true in the draft JSON.
  - If the balances-half keys are missing or zero (income_sources, accounts,
    investments, contingency, savings_target), interview the user for them now —
    accounts (liquid?, balance; liabilities negative), investments (liquid?,
    value), income sources, savings target (rate or absolute), contingency target
    months — exactly as in first-run setup Batch C. Reflect net worth + runway
    back before committing.

If turning OFF:
  - Set "track_balances": false in the draft JSON. Keep the balances-half data in
    the profile (so turning it back on later is lossless) — just stop writing the
    ## Balances section. Confirm that net worth / runway will no longer be shown.

Then keep the JSON valid + frontmatter intact and finalize:
  bash "$_SCRIPT_DIR/finance.sh" profile commit finance-profile
After commit, re-run /finance — the month report will $([ "$WANT" = on ] && echo "now include ## Balances" || echo "drop the ## Balances section").
BALOPT
  exit 0
fi

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
  if [[ "$TRACK_BALANCES" == "true" ]]; then
    BALANCES_INGEST_NOTE="Because balances tracking is ON, also recompute ## Balances: income reconciliation (a credit that matches an income source lands as received), savings rate, net worth (only move a balance if the user says so — balances are user-maintained), and runway."
  else
    BALANCES_INGEST_NOTE="Balances tracking is OFF — do NOT write a ## Balances section; income/refund credits still appear in ### Transactions as 'in' but with no net-worth/runway math."
  fi
  cat <<INGEST
FINANCE_INGEST
date: $TODAY
month: $MONTH
output_file: $OUT_FILE
profile_file: $PROFILE_FILE
category_library: $CATEGORY_LIBRARY_FILE
track_balances: $TRACK_BALANCES
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
transactions ALREADY in ## Expenses → ### Transactions on (date + abs(amount) +
normalized-description). Skip exact duplicates. Re-pasting an overlapping
statement must add ZERO duplicate rows.

Step 3 — CATEGORIZE each NEW spend row.
$CATEGORIZE_SPEC

Step 4 — Append new spend rows to ## Expenses → ### Transactions and recompute
the EXPENSE side: spend-by-category (+ month total), recurring-payment statuses
(a match flips due→paid), planned-expense statuses, and the next-month forecast.
$BALANCES_INGEST_NOTE

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
# SESSION mode (default) — open/show the month report; route on intent.
# ---------------------------------------------------------------------------
cat <<SESSION
FINANCE_SESSION
date: $TODAY
month: $MONTH
output_file: $OUT_FILE
profile_file: $PROFILE_FILE
category_library: $CATEGORY_LIBRARY_FILE
track_balances: $TRACK_BALANCES

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
profile (track_balances=$TRACK_BALANCES). Figure out intent from what they say;
do not force an upfront menu.

Step 1 — If no report exists for $MONTH yet, create it from the profile: seed
## Expenses with ### Recurring expenses (status) (all 'due'/'overdue' by date),
### Planned (rest of year) (from planned_expenses), an empty ### Transactions +
### Spend by category, and ### Next-month forecast. When track_balances is true,
ALSO seed ## Balances (### Accounts & investments + net worth from the profile,
### Income expected per source, savings rate, runway, affordability). Carry the
Δ baseline from last month's report when one exists. Then open with a one-line
status (top spend so far / overdue bill; net worth + runway too when on).

If a report DOES exist, open with its status line and ask what they want to do.

Step 2 — Route on intent:

  A) INGEST A DATA SOURCE — if the user pastes or points at a statement / CSV /
     list, run the full ingest sub-flow (parse → DEDUPE on date+abs(amount)+
     normalized-description → categorize → append to ### Transactions →
     recompute). $CATEGORIZE_SPEC

  B) QUICK-ADD ONE EXPENSE — a single "spent X on Y" — add it to ### Transactions
     (categorize, dedupe), recompute the expense side. (Same as /finance expense.)

  C) ADD A PLANNED EXPENSE — "I have insurance ₹40k due in September": append it
     to planned_expenses. That is a profile edit, so route through
     /finance profile new finance-profile (never silently edit a committed
     profile), then reflect it in ### Planned (rest of year) + the forecast.

  D) UPDATE A BALANCE (only when track_balances) — "HDFC is now ₹X": rewrite that
     account/investment row, refresh as_of, recompute net worth + runway. Offer to
     persist to the profile via /finance profile new finance-profile.

  E) MARK A RECURRING PAYMENT PAID — flip its ### Recurring expenses row to paid
     and add the matching ### Transactions row, then recompute.

  F) STATUS / QUESTION — answer from the report (where is my money going, what is
     next month looking like, am I on track / how much runway) without rewriting
     unless asked. Only answer runway/net-worth questions when track_balances is
     true; if off and the user asks, offer /finance balances on.

Step 3 — Whenever you change the report, recompute every total / Δ / flag and
rewrite $OUT_FILE in place.

$REPORT_SPEC

Step 4 — End with: "Saved → $OUT_FILE. Quick-add with /finance expense <amount>
<what>, or paste a statement to categorize."
SESSION

# Habit extraction: log any tracked habits the user evidenced (silent if no
# habits profile). Self-improvement: capture standing preferences / quality
# fixes the user raised this session (silent unless there was genuine feedback).
pbrain_emit_habits_extract "finance" || true
pbrain_emit_self_improve "finance" "$PROFILE_FILE" "finance profile" || true
