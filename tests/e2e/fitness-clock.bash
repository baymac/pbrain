#!/usr/bin/env bash
# fitness-clock.bash — /fitness-journal PB-117 clock-contract driver for the
# pbrain e2e framework.
#
# Sibling of fitness-journal.bash (which owns the sleep contract). This driver
# exercises the OTHER thing the daily LOG flow must get right: deciding PLANNED
# vs COMPLETED by the clock, not by phrasing.
#
#   REAL  — commands/fitness-journal.sh, real $PBRAIN_VAULT, real persona prefs
#           injection, real seeded profile/library/activity-profile. The script
#           emits an authoritative time_now (HH:MM) in the FITNESS_JOURNAL_SESSION
#           block + the clock-based planned-vs-completed instructions.
#   AGENT  — replayed deterministically here: given the emitted block + the
#           scenario's session time (an OFFSET from the real time_now, so the
#           test is clock-stable), write today's dated file with the status and
#           sections the clock dictates.
#
# What it proves end-to-end (PB-117):
#   future time  → status: planned, ## Planned only, NO ## Logged actuals (a
#                  present-tense "I am doing X at <future>" must not be logged as
#                  done with invented numbers).
#   past/now + done → status: completed, BOTH ## Planned and ## Logged.
# The artifact (the real dated markdown) is the tracking channel, shown in the
# union HTML report alongside the chat. tracking_kind=vault-file.
#
# Shares lib.bash with the other e2e drivers. Sourced directly here (like every
# other driver) so it works both when loaded by tests/e2e-fitness.bats AND when
# dispatched by run.sh via the scenario's engine override (PB-190); re-sourcing
# lib.bash is idempotent.

set -uo pipefail
source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.bash"

E2E_FDIR=""        # fitness daily-tracking dir (real, under the temp vault)
E2E_STORE=""       # the .profile store under it
E2E_OUT_FILE=""    # today's dated fitness file

_fitnessclock_sh() {  # run the REAL fitness-journal.sh with the daily dump
  PBRAIN_FITNESS_DIR="$E2E_FDIR" \
    bash "$E2E_REAL_ROOT/commands/fitness-journal.sh" "$@" 2>>"$E2E_WORK/fitness.stderr"
}

# Inline stub profile/library/activity profile so the real command reaches the
# daily LOG flow (used only when the persona has no fitness-journal fixtures).
# Mirrors fitness-journal.bash's _seed_profiles.
_clock_seed_profiles() {  # <today>
  local today="$1"
  mkdir -p "$E2E_STORE/activities"
  cat >"$E2E_STORE/fitness-profile.v1.md" <<EOF
---
type: fitness-profile
date: $today
version: 1
committed: true
---

# Fitness profile

\`\`\`json
{"created":"$today","sleep":{"bed_time":"23:00","wake_time":"07:00","hours":8.0},"steps_per_day":8000,"health_metrics":{"source":"none","notes":""},"notes":""}
\`\`\`
EOF
  cat >"$E2E_STORE/fitness-library.v1.md" <<EOF
---
type: fitness-library
date: $today
version: 1
committed: true
---

# Fitness library

\`\`\`json
{"created":"$today","activities":[{"id":"apple-fitness","name":"Apple Fitness","occurrence":{"per":"week","times":3},"days":["Mon","Tue","Wed","Thu","Fri","Sat","Sun"],"equipment":"none","typical_time":"18:00","duration_min":35,"notes":"","kpis":[{"id":"duration","label":"Duration","type":"duration","unit":"min"}]}]}
\`\`\`
EOF
  cat >"$E2E_STORE/activities/apple-fitness.v1.md" <<EOF
---
activity: Apple Fitness
created: $today
days: [Mon, Tue, Wed, Thu, Fri, Sat, Sun]
occurrence: "3/week"
equipment: none
version: 1
committed: true
---

# Apple Fitness — Profile

Home Apple Fitness+ sessions (kickboxing / strength / cooldown).
EOF
}

# A clock-stable session time: $1 = signed minute offset from the real time_now.
# Future scenarios pass a positive offset, past scenarios a negative one, so the
# test never flakes around a wall-clock boundary.
_session_time_at_offset() {  # <offset_min> -> HH:MM (24h)
  python3 - "$1" <<'PY'
import sys, datetime
off = int(sys.argv[1])
t = datetime.datetime.now() + datetime.timedelta(minutes=off)
print(t.strftime("%H:%M"))
PY
}

# Replay the agent's documented role for the clock contract: write today's file
# with the status + sections the clock dictates. NEVER fabricates ## Logged for a
# future session. status="planned" => ## Planned only; status="completed" =>
# both sections with the dump's actuals.
_clock_write_entry() {  # <today> <status> <session_time> <dump>
  python3 - "$E2E_OUT_FILE" "$@" <<'PY'
import sys
(path, today, status, stime, dump) = sys.argv[1:6]
lines = [
    "---",
    "type: fitness",
    "date: %s" % today,
    "activity: apple-fitness",
    "focus: Apple Fitness",
    "session_time: %s" % stime,
    "status: %s" % status,
    "sleep_bed: ",
    "sleep_wake: ",
    "sleep_quality: ",
    "sleep_hours: ",
    "tags: []",
    "---",
    "",
    "# Apple Fitness — %s" % today,
    "",
    "## Planned",
    "| KPI | Target |",
    "|---|---|",
    "| Duration | 35 min |",
    "",
]
if status == "completed":
    # session is at/past now and reported as done → record the real actuals.
    lines += [
        "## Logged",
        "| KPI | Logged |",
        "|---|---|",
        "| Duration | 35 min (20 kickboxing / 10 strength / 5 cooldown) |",
        "",
    ]
# status == planned → NO ## Logged section at all (no fabricated actuals).
open(path, "w").write("\n".join(lines))
PY
}

# Terminal judge: the dated file exists and its status matches the clock outcome;
# a planned entry must NOT carry a ## Logged section, a completed one must.
_judge_clock() {
  local want; want="$(_sc expect_status)"
  [ -f "$E2E_OUT_FILE" ] || return 1
  grep -qE "^status: $want\$" "$E2E_OUT_FILE" || return 1
  if [ "$want" = "planned" ]; then
    ! grep -q "^## Logged" "$E2E_OUT_FILE" || return 1
  else
    grep -q "^## Logged" "$E2E_OUT_FILE" || return 1
  fi
  return 0
}

# e2e_run_fitness_clock <repo_root> <scenario.json> <persona.md> <results_dir>
e2e_run_fitness_clock() {
  e2e_env_setup "$1" "$2" "$3" "$4"
  : >"$E2E_WORK/fitness.stderr"

  E2E_FDIR="$PBRAIN_VAULT/fitness/daily-tracking"
  E2E_STORE="$E2E_FDIR/.profile"
  mkdir -p "$E2E_FDIR"
  local today; today="$(date +%Y-%m-%d)"
  E2E_OUT_FILE="$E2E_FDIR/$today.md"

  local dump status offset stime
  dump="$(_sc dump)"
  status="$(_sc expect_status)"
  offset="$(_sc session_time_offset_min)"
  stime="$(_session_time_at_offset "$offset")"

  # Seed THIS persona's saved fitness vault if it has fixtures; else inline stub.
  if ! e2e_seed_persona_fixtures fitness-journal "$E2E_FDIR"; then
    _clock_seed_profiles "$today"
    e2e_note "no persona fixtures — used inline stub profile/library"
  fi

  # 1) The human's session dump, with the concrete clock-stable session time.
  e2e_user "$dump (at $stime)"

  # 2) Run the REAL fitness-journal.sh; capture the emitted block.
  local block
  block="$(_fitnessclock_sh "$dump (at $stime)")"
  e2e_cmd "fitness-journal \"$dump (at $stime)\""
  e2e_assert "fitness-journal.sh emitted FITNESS_JOURNAL_SESSION (daily LOG flow)" \
    grep -q "FITNESS_JOURNAL_SESSION" <<<"$block"

  # --- assertions on the EMITTED clock contract (PB-117) ----------------
  e2e_assert "session block emits an authoritative time_now (HH:MM)" \
    grep -qE "^time_now: [0-2][0-9]:[0-5][0-9]\$" <<<"$block"
  e2e_assert "instructions tell the agent to compare against time_now" \
    grep -q "compare it against time_now" <<<"$block"
  e2e_assert "future session => planned, no fabricated actuals" \
    grep -q "NOT write a ## Logged section or invent any actuals" <<<"$block"
  e2e_assert "persona prefs surfaced on the command" \
    grep -qiE "preference|hygiene|prefs" <<<"$block"

  # The script's emitted time_now is the ground-truth now; assert our offset
  # actually lands on the intended side of it (future for planned, past for done).
  local now_emitted
  now_emitted="$(grep -m1 -E "^time_now: " <<<"$block" | awk '{print $2}')"
  if [ "$status" = "planned" ]; then
    e2e_assert "session time $stime is in the future relative to time_now $now_emitted" \
      python3 -c 'import sys;a,b=sys.argv[1:3];print("ok") if a>b else sys.exit(1)' "$stime" "$now_emitted"
    e2e_say fitness "That's at $stime — still ahead of now ($now_emitted), so I'll log it as planned, no actuals yet."
  else
    e2e_assert "session time $stime is at/past time_now $now_emitted" \
      python3 -c 'import sys;a,b=sys.argv[1:3];print("ok") if a<=b else sys.exit(1)' "$stime" "$now_emitted"
    e2e_say fitness "Got it — $stime is past now ($now_emitted) and you're describing it as done, so I'll log the actuals."
  fi

  # 3) Agent writes today's entry per the clock outcome.
  _clock_write_entry "$today" "$status" "$stime" "$dump"
  e2e_note "agent wrote $today.md → status: $status"

  # --- assertions on the WRITTEN artifact -------------------------------
  e2e_assert "artifact status is $status" \
    grep -qE "^status: $status\$" "$E2E_OUT_FILE"
  if [ "$status" = "planned" ]; then
    e2e_assert "planned: ## Planned section present" grep -q "^## Planned" "$E2E_OUT_FILE"
    e2e_assert "planned: NO ## Logged actuals fabricated" \
      bash -c '! grep -q "^## Logged" "$0"' "$E2E_OUT_FILE"
  else
    e2e_assert "completed: ## Planned section present" grep -q "^## Planned" "$E2E_OUT_FILE"
    e2e_assert "completed: ## Logged actuals present" grep -q "^## Logged" "$E2E_OUT_FILE"
  fi

  e2e_assert "no unexpected stderr from fitness-journal.sh" test ! -s "$E2E_WORK/fitness.stderr"
  e2e_assert "reached expected terminal ($(_sc expect))" _judge_clock

  e2e_fold_parse_fails
  local pass="true"; [[ ${#E2E_FAILURES[@]} -eq 0 ]] || pass="false"
  local artifact; artifact="$E2E_OUT_FILE"$'\n---\n'"$(cat "$E2E_OUT_FILE")"
  e2e_emit_result "$pass" "vault-file" "" "$artifact"
  rm -rf "$E2E_WORK"
  [[ "$pass" == "true" ]]
}
