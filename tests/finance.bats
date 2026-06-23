#!/usr/bin/env bats
# Tests for commands/finance.sh — the mechanical (non-LLM) paths: setup vs
# draft phases, the profile subcommand round-trip, the category-library stub,
# session vs ingest routing, env overrides, and the config-error guard.
#
# NOTE: the pbrain bats harness only enforces each test's LAST command, so the
# must-hold checks are combined with `&&` onto the final line.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0   # keep the vault migration runner out of unit tests
  export PBRAIN_VAULT="$TMP/vault"
  export XDG_CONFIG_HOME="$TMP/config"
  mkdir -p "$PBRAIN_VAULT" "$XDG_CONFIG_HOME/pbrain"
  export PBRAIN_SELF_IMPROVE=off
  export PBRAIN_UPDATE_CHECK=0
  FIN="$PBRAIN_VAULT/life/finance-tracking"
  STORE="$FIN/.profile"
  TODAY="$(date +%Y-%m-%d)"
  MONTH="$(date +%Y-%m)"
  YEAR="$(date +%Y)"
}

teardown() {
  rm -rf "$TMP"
}

FIN() { bash "$REPO_ROOT/commands/finance.sh" "$@"; }

write_profile() {
  mkdir -p "$STORE"
  cat > "$STORE/finance-profile.v1.md" <<EOF
---
type: finance-profile
date: $TODAY
version: 1
committed: true
---

# Finance profile

\`\`\`json
{"created": "$TODAY", "currency": "INR", "currency_symbol": "₹",
 "financial_month_start_day": 1, "financial_style": "balanced",
 "categories": [{"name": "diet", "essential": true},
                {"name": "other", "essential": false}],
 "accounts": [{"name": "HDFC", "type": "savings", "liquid": true,
               "balance": 200000, "as_of": "$TODAY"}],
 "savings_target": {"type": "rate", "value": 30},
 "contingency": {"target_months": 6}}
\`\`\`
EOF
}

# A profile with the balances tracker opted IN (track_balances: true).
write_profile_balances() {
  mkdir -p "$STORE"
  cat > "$STORE/finance-profile.v1.md" <<EOF
---
type: finance-profile
date: $TODAY
version: 1
committed: true
---

# Finance profile

\`\`\`json
{"created": "$TODAY", "currency": "INR", "currency_symbol": "₹",
 "financial_month_start_day": 1, "financial_style": "balanced",
 "track_balances": true,
 "categories": [{"name": "diet", "essential": true},
                {"name": "other", "essential": false}],
 "recurring_expenses": [],
 "planned_expenses": [{"name": "Car insurance", "category": "insurance",
                       "amount": 40000, "month": "$YEAR-09", "essential": true}],
 "income_sources": [{"name": "Salary", "amount": 180000, "cadence": "monthly",
                     "expected_day": 1, "type": "salary", "essential": true}],
 "accounts": [{"name": "HDFC", "type": "savings", "liquid": true,
               "balance": 200000, "as_of": "$TODAY"}],
 "savings_target": {"type": "rate", "value": 30},
 "contingency": {"target_months": 6}}
\`\`\`
EOF
}

# ── setup / draft phases ─────────────────────────────────────────────────────

@test "fresh user gets the single setup block" {
  run FIN
  [ "$status" -eq 0 ]
  [[ "$output" == *"diet"* ]] && [[ "$output" == *"FINANCE_SETUP_PROFILE"* ]]
}

@test "setup block points at the v1 profile path" {
  run FIN
  [[ "$output" == *"finance-profile.v1.md"* ]]
}

@test "open draft short-circuits to the draft-continuation block" {
  mkdir -p "$STORE"
  cat > "$STORE/finance-profile.v1.md" <<EOF
---
type: finance-profile
version: 1
committed: false
---
# Finance profile
\`\`\`json
{"created": "$TODAY"}
\`\`\`
EOF
  run FIN
  [[ "$output" == *"profile commit finance-profile"* ]] && [[ "$output" == *"FINANCE_PROFILE_DRAFT_OPEN"* ]]
}

# ── session / ingest routing ─────────────────────────────────────────────────

@test "committed profile routes to the session block" {
  write_profile
  run FIN
  [ "$status" -eq 0 ]
  [[ "$output" == *"month: $MONTH"* ]] && [[ "$output" == *"FINANCE_SESSION"* ]]
}

@test "session block carries the report-format + categorization specs" {
  write_profile
  run FIN
  [[ "$output" == *"exactly ONE category"* ]] && [[ "$output" == *"Spend by category"* ]]
}

@test "ingest subcommand routes to the ingest block" {
  write_profile
  run FIN ingest
  [ "$status" -eq 0 ]
  [[ "$output" == *"DEDUPE"* ]] && [[ "$output" == *"FINANCE_INGEST"* ]]
}

@test "ingest with a file path embeds the data source" {
  write_profile
  printf '2026-06-03,Zomato,420\n' > "$TMP/stmt.csv"
  run FIN ingest "$TMP/stmt.csv"
  [[ "$output" == *"Zomato"* ]] && [[ "$output" == *"FINANCE_INGEST"* ]]
}

@test "existing month report is fed back into the session context" {
  write_profile
  mkdir -p "$FIN"
  echo "EXISTING-MONTH-MARKER" > "$FIN/$MONTH.md"
  run FIN
  [[ "$output" == *"EXISTING-MONTH-MARKER"* ]]
}

@test "prior month reports surface as recent context" {
  write_profile
  mkdir -p "$FIN"
  echo "OLD-MONTH-MARKER" > "$FIN/2026-05.md"
  run FIN
  [[ "$output" == *"OLD-MONTH-MARKER"* ]]
}

# ── category library stub ────────────────────────────────────────────────────

@test "category-library stub is auto-created committed in the store" {
  write_profile
  run FIN
  [ -f "$STORE/category-library.v1.md" ]
  grep -q '^committed: true$' "$STORE/category-library.v1.md" && grep -q 'Merchant (normalized)' "$STORE/category-library.v1.md"
}

# ── config error guard ───────────────────────────────────────────────────────

@test "profile with no JSON block raises a config error" {
  mkdir -p "$STORE"
  cat > "$STORE/finance-profile.v1.md" <<EOF
---
type: finance-profile
version: 1
committed: true
---
# Finance profile (no json block)
EOF
  run FIN
  [ "$status" -eq 1 ]
  [[ "$output" == *"FINANCE_CONFIG_ERROR"* ]]
}

# ── env overrides ────────────────────────────────────────────────────────────

@test "PBRAIN_FINANCE_DIR relocates the reports + store" {
  ALT="$TMP/alt-finance"
  mkdir -p "$ALT/.profile"
  cat > "$ALT/.profile/finance-profile.v1.md" <<EOF
---
type: finance-profile
version: 1
committed: true
---
# Finance profile
\`\`\`json
{"created": "$TODAY", "currency": "USD"}
\`\`\`
EOF
  PBRAIN_FINANCE_DIR="$ALT" run FIN
  [ "$status" -eq 0 ]
  [[ "$output" == *"output_file: $ALT/$MONTH.md"* ]] && [[ "$output" == *"FINANCE_SESSION"* ]]
}

@test "PBRAIN_FINANCE_PROFILE_FILE override is honored" {
  cat > "$TMP/custom-profile.md" <<EOF
---
type: finance-profile
version: 1
committed: true
---
# Finance profile
\`\`\`json
{"created": "$TODAY", "currency": "EUR", "financial_style": "frugal"}
\`\`\`
EOF
  PBRAIN_FINANCE_PROFILE_FILE="$TMP/custom-profile.md" run FIN
  [ "$status" -eq 0 ]
  [[ "$output" == *"frugal"* ]] && [[ "$output" == *"FINANCE_SESSION"* ]]
}

# ── profile subcommand ───────────────────────────────────────────────────────

@test "profile new mints a draft and commit freezes it" {
  write_profile
  run FIN profile new
  [ "$status" -eq 0 ]
  [ -f "$STORE/finance-profile.v2.md" ]
  grep -q '^committed: false$' "$STORE/finance-profile.v2.md"
  run FIN profile commit
  [[ "$output" == *"FINANCE_PROFILE_COMMITTED"* ]]
  grep -q '^committed: true$' "$STORE/finance-profile.v2.md"
}

@test "profile show cats the committed profile" {
  write_profile
  run FIN profile show
  [[ "$output" == *'"currency": "INR"'* ]] && [[ "$output" == *"FINANCE_PROFILE_SHOW"* ]]
}

# ── setup offers the balances opt-in; expenses mandatory ─────────────────────

@test "setup block offers the balances opt-in and a planned-expenses ask" {
  run FIN
  [ "$status" -eq 0 ]
  [[ "$output" == *"balances on"* ]] && [[ "$output" == *"PLANNED one-off expenses"* ]]
}

@test "setup block names both trackers (expense core + balances opt-in)" {
  run FIN
  [[ "$output" == *"track_balances"* ]] && [[ "$output" == *"OPT-IN"* ]]
}

# ── expense quick-add ────────────────────────────────────────────────────────

@test "expense subcommand routes to the quick-add block and extracts the amount" {
  write_profile
  run FIN expense 100 coffee at xyz
  [ "$status" -eq 0 ]
  [[ "$output" == *"FINANCE_EXPENSE_QUICKADD"* ]] && [[ "$output" == *"parsed_amount: 100"* ]]
}

@test "expense quick-add carries the raw_input verbatim" {
  write_profile
  run FIN expense 250 lunch at Punjabi Dhaba
  [[ "$output" == *"raw_input: 250 lunch at Punjabi Dhaba"* ]] && [[ "$output" == *"FINANCE_EXPENSE_QUICKADD"* ]]
}

@test "expense amount extraction tolerates a currency symbol prefix" {
  write_profile
  run FIN expense '₹100' chai
  [[ "$output" == *"parsed_amount: 100"* ]] && [[ "$output" == *"FINANCE_EXPENSE_QUICKADD"* ]]
}

@test "expense amount extraction tolerates thousands separators + decimals" {
  write_profile
  run FIN expense '1,200.50 flight' on MMT
  [[ "$output" == *"parsed_amount: 1200.50"* ]] && [[ "$output" == *"FINANCE_EXPENSE_QUICKADD"* ]]
}

@test "expense amount extraction keeps a bare 4-digit number whole (not truncated)" {
  write_profile
  run FIN expense 3499 sneakers on 12 jun
  [[ "$output" == *"parsed_amount: 3499"* ]] && [[ "$output" == *"FINANCE_EXPENSE_QUICKADD"* ]]
}

@test "expense amount extraction handles Indian lakh grouping" {
  write_profile
  run FIN expense '1,50,000 down payment'
  [[ "$output" == *"parsed_amount: 150000"* ]] && [[ "$output" == *"FINANCE_EXPENSE_QUICKADD"* ]]
}

@test "expense quick-add does not touch the balances section when off" {
  write_profile
  run FIN expense 100 coffee
  [[ "$output" == *"Do NOT touch the"* ]] && [[ "$output" == *"track_balances: false"* ]]
}

# ── two-section report: expenses always, balances only when opted in ─────────

@test "expenses-only session writes ONLY the Expenses section (no Balances)" {
  write_profile
  run FIN
  [[ "$output" == *"## Expenses"* ]] && [[ "$output" == *"Balances tracking is OFF"* ]]
}

@test "expenses-only session carries forecast + planned specs" {
  write_profile
  run FIN
  [[ "$output" == *"Next-month forecast"* ]] && [[ "$output" == *"Planned (rest of year)"* ]]
}

@test "balances-on session writes the Balances section + runway" {
  write_profile_balances
  run FIN
  [[ "$output" == *"## Balances"* ]] && [[ "$output" == *"Contingency / runway"* ]]
}

@test "balances-on session reports track_balances true in the header" {
  write_profile_balances
  run FIN
  [[ "$output" == *"track_balances: true"* ]] && [[ "$output" == *"FINANCE_SESSION"* ]]
}

@test "ingest still carries the dedupe invariant + two-section routing" {
  write_profile
  run FIN ingest
  [[ "$output" == *"DEDUPE"* ]] && [[ "$output" == *"### Transactions"* ]]
}

# ── balances opt-in toggle ───────────────────────────────────────────────────

@test "balances with no arg reports the current tier" {
  write_profile
  run FIN balances
  [ "$status" -eq 0 ]
  [[ "$output" == *"track_balances=false"* ]] && [[ "$output" == *"FINANCE_BALANCES_OPT"* ]]
}

@test "balances on mints a profile draft and routes through opt-in" {
  write_profile
  run FIN balances on
  [ "$status" -eq 0 ]
  [ -f "$STORE/finance-profile.v2.md" ]
  grep -q '^committed: false$' "$STORE/finance-profile.v2.md"
  [[ "$output" == *"want: on"* ]] && [[ "$output" == *"FINANCE_BALANCES_OPT"* ]]
}

@test "balances off routes through opt-in keeping data lossless" {
  write_profile_balances
  run FIN balances off
  [[ "$output" == *"want: off"* ]] && [[ "$output" == *"lossless"* ]]
}

@test "balances with a bad arg errors" {
  write_profile
  run FIN balances maybe
  [ "$status" -eq 2 ]
}
