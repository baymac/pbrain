#!/usr/bin/env bats
# Tests for lib/habit_schedule.py — the is_due engine + frequency→days spacing +
# non-destructive schedule derivation. Pure unit tests (no vault, no DB).
#
# Run with:  bats tests/schedule.bats

setup() {
  LIBDIR="$(cd "$BATS_TEST_DIRNAME/../lib" && pwd)"
}

# PYEVAL <expr> — eval a python expression with habit_schedule imported.
PYEVAL() {
  python3 - "$LIBDIR" "$1" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from habit_schedule import is_due, derive_schedule, spaced_weekdays, spaced_dom, norm_days, schedule_label
print(eval(sys.argv[2]))
PYEOF
}

# ── is_due: daily ───────────────────────────────────────────────────────────
@test "is_due daily is always true" {
  run PYEVAL "is_due({'type':'daily'}, '2026-06-02')"
  [ "$output" = "True" ]
}

# ── is_due: weekdays ────────────────────────────────────────────────────────
@test "is_due weekdays true on a listed day (2026-06-03 = Wed)" {
  run PYEVAL "is_due({'type':'weekdays','days':['mon','wed','fri']}, '2026-06-03')"
  [ "$output" = "True" ]
}

@test "is_due weekdays false on an unlisted day (2026-06-02 = Tue)" {
  run PYEVAL "is_due({'type':'weekdays','days':['mon','wed','fri']}, '2026-06-02')"
  [ "$output" = "False" ]
}

# ── is_due: interval (every N days from a start) ────────────────────────────
@test "is_due interval true exactly N days after start" {
  run PYEVAL "is_due({'type':'interval','start_date':'2026-06-01','every_days':15}, '2026-06-16')"
  [ "$output" = "True" ]   # 15 days later
}

@test "is_due interval false off the cadence" {
  run PYEVAL "is_due({'type':'interval','start_date':'2026-06-01','every_days':15}, '2026-06-10')"
  [ "$output" = "False" ]
}

@test "is_due interval false before the start date" {
  run PYEVAL "is_due({'type':'interval','start_date':'2026-06-01','every_days':15}, '2026-05-17')"
  [ "$output" = "False" ]
}

@test "is_due interval true on the start date itself" {
  run PYEVAL "is_due({'type':'interval','start_date':'2026-06-01','every_days':20}, '2026-06-01')"
  [ "$output" = "True" ]
}

# ── is_due: monthly (calendar day-of-month) ─────────────────────────────────
@test "is_due monthly true on a listed day-of-month" {
  run PYEVAL "is_due({'type':'monthly','days_of_month':[1,16]}, '2026-06-16')"
  [ "$output" = "True" ]
}

@test "is_due monthly false on an unlisted day-of-month" {
  run PYEVAL "is_due({'type':'monthly','days_of_month':[1,16]}, '2026-06-17')"
  [ "$output" = "False" ]
}

@test "is_due monthly clamps a too-large day to the month's last day (31 → June 30)" {
  run PYEVAL "is_due({'type':'monthly','days_of_month':[31]}, '2026-06-30')"
  [ "$output" = "True" ]
}

# ── spacing: frequency → concrete days ──────────────────────────────────────
@test "spaced_weekdays 2/week from Monday → mon,thu" {
  run PYEVAL "spaced_weekdays(0,2)"
  [ "$output" = "['mon', 'thu']" ]
}

@test "spaced_weekdays 3/week from Monday → mon,wed,fri" {
  run PYEVAL "spaced_weekdays(0,3)"
  [ "$output" = "['mon', 'wed', 'fri']" ]
}

@test "spaced_weekdays 1/week from Monday → mon" {
  run PYEVAL "spaced_weekdays(0,1)"
  [ "$output" = "['mon']" ]
}

@test "spaced_dom 2/month from the 1st → 1,16" {
  run PYEVAL "spaced_dom(1,2)"
  [ "$output" = "[1, 16]" ]
}

# ── derive_schedule: explicit wins, else synthesized ────────────────────────
@test "derive_schedule uses an explicit weekdays schedule" {
  run PYEVAL "derive_schedule({'schedule':{'type':'weekdays','days':['Mon','FRI']}})['days']"
  [ "$output" = "['mon', 'fri']" ]
}

@test "derive_schedule synthesizes daily from a legacy daily habit" {
  run PYEVAL "derive_schedule({'schedule_type':'daily'})['type']"
  [ "$output" = "daily" ]
}

@test "derive_schedule synthesizes spaced weekdays from a legacy weekly Nx habit" {
  run PYEVAL "derive_schedule({'schedule_type':'weekly','target_count':3})['days']"
  [ "$output" = "['mon', 'wed', 'fri']" ]   # default start Monday
}

@test "derive_schedule reads leftover reminder.days as a weekdays schedule" {
  run PYEVAL "derive_schedule({'schedule_type':'weekly','reminder':{'state':'linked','days':['tue','sat']}})['days']"
  [ "$output" = "['tue', 'sat']" ]
}

@test "derive_schedule synthesizes monthly from a legacy monthly habit" {
  run PYEVAL "derive_schedule({'schedule_type':'monthly','target_count':1})['type']"
  [ "$output" = "monthly" ]
}
