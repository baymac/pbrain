#!/usr/bin/env bash
# fitness-journal.bash — the /fitness-journal driver for the pbrain e2e framework.
#
# THIRD command on the framework (after pmw + journal), and the e2e coverage for
# the sleep-capture contract (PB-110, revised): sleep is mandatory to ASK, carried
# forward from a real prior entry ONLY on confirmation, and NEVER fabricated from
# the profile's typical window. A wrong sleep value is worse than a blank one.
#
# Like journal.sh, fitness-journal.sh is a DISPATCHER: it emits a context block +
# prose Steps (FITNESS_JOURNAL_SESSION on a fresh day) that the AGENT follows to
# write the dated markdown file. This driver replays the agent's role against the
# REAL fitness-journal.sh:
#   REAL  — commands/fitness-journal.sh, real $PBRAIN_VAULT, real persona prefs
#           injection, the real seeded profile/library/activity-profile, and the
#           real dated fitness file (with its sleep_* frontmatter) it writes.
#   FAKED — nothing network; fitness-journal touches only the vault + prefs, which
#           are already real per-run temp dirs.
#
# Tracking channel = the real vault file (tracking_kind=vault-file), so the report
# shows the actual sleep_* frontmatter the agent wrote, alongside the chat.

set -uo pipefail
source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.bash"

E2E_FDIR=""        # fitness daily-tracking dir (real, under the temp vault)
E2E_STORE=""       # the .profile store under it
E2E_OUT_FILE=""    # today's dated fitness file

_fitness_sh() {  # run the REAL fitness-journal.sh with the daily dump
  PBRAIN_FITNESS_DIR="$E2E_FDIR" \
    bash "$E2E_REAL_ROOT/commands/fitness-journal.sh" "$@" 2>>"$E2E_WORK/fitness.stderr"
}

# Seed the committed profile + library + gym activity profile so the real command
# reaches the daily LOG flow (not first-run setup). Values mirror the unit suite
# helpers; the profile sleep window is deliberately 23:00/07:00 — the value the
# cold-start scenario proves is NOT fabricated into the artifact.
_seed_profiles() {  # <today>
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
{"created": "$today",
 "sleep": {"bed_time": "23:00", "wake_time": "07:00", "hours": 8.0},
 "steps_per_day": 8000,
 "health_metrics": {"source": "none", "notes": ""},
 "notes": ""}
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
{"created": "$today", "activities": [
  {"id": "gym", "name": "Gym", "occurrence": {"per": "week", "times": 4},
   "days": ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"], "equipment": "full gym",
   "typical_time": "17:00", "duration_min": 75, "notes": "",
   "kpis": [{"id": "sets", "label": "Sets", "type": "sets", "unit": null}]}]}
\`\`\`
EOF
  cat >"$E2E_STORE/activities/gym.v1.md" <<EOF
---
activity: Gym
created: $today
days: [Mon, Tue, Wed, Thu, Fri, Sat, Sun]
occurrence: "4/week"
equipment: full gym
version: 1
committed: true
---

# Gym — Profile

## Block 1 (Weeks 1–4)

### Day A — Push
| Exercise | Sets × Reps | Notes |
|---|---|---|
| Bench press | 4 × 8 | |
EOF
}

# Write a prior dated session carrying real sleep_* — the confirm-and-carry source.
_seed_prior_session() {  # <date> <bed> <wake> <quality> <hours>
  cat >"$E2E_FDIR/$1.md" <<EOF
---
type: fitness
date: $1
activity: gym
focus: gym
status: completed
sleep_bed: $2
sleep_wake: $3
sleep_quality: $4
sleep_hours: $5
tags: []
---

# Gym
EOF
}

# Write today's fitness entry the way Step 4–6 instruct, with sleep_* set per the
# scenario's sleep_mode. This is the agent's role: it NEVER invents sleep.
#   captured → write the volunteered bed/wake/quality/hours, no provenance note.
#   carry    → copy the prior session's values + a ## Notes provenance line.
#   cold     → leave all four sleep_* BLANK (no profile-window fabrication).
_write_entry() {  # <today> <sleep_mode> <bed> <wake> <quality> <hours> <carry_from>
  python3 - "$E2E_OUT_FILE" "$@" <<'PY'
import sys
(path, today, mode, bed, wake, quality, hours, carry_from) = sys.argv[1:9]
notes = "—"
if mode == "carry":
    notes = ("Sleep carried forward from %s (confirmed), not measured today."
             % carry_from)
elif mode == "cold":
    bed = wake = quality = hours = ""   # honest blank; never the profile window
doc = (
    "---\n"
    "type: fitness\n"
    "date: %s\n"
    "activity: gym\n"
    "focus: gym\n"
    "duration_min: 75\n"
    "status: completed\n"
    "sleep_bed: %s\n"
    "sleep_wake: %s\n"
    "sleep_quality: %s\n"
    "sleep_hours: %s\n"
    "tags: []\n"
    "---\n\n"
    "## Planned\n\nDay A — Push\n\n"
    "## Logged\n\nBench press 4×8\n\n"
    "## Notes\n\n%s\n"
    % (today, bed, wake, quality, hours, notes)
)
open(path, "w").write(doc)
PY
}

# e2e_run_fitness <real_root> <scenario> <persona> <out_dir>
e2e_run_fitness() {
  e2e_env_setup "$1" "$2" "$3" "$4"
  : >"$E2E_WORK/fitness.stderr"
  E2E_FDIR="$PBRAIN_VAULT/fitness/daily-tracking"
  E2E_STORE="$E2E_FDIR/.profile"
  mkdir -p "$E2E_FDIR"
  local today; today="$(date +%Y-%m-%d)"
  E2E_OUT_FILE="$E2E_FDIR/$today.md"

  local sleep_mode bed wake quality hours dump
  sleep_mode="$(_sc sleep_mode)"
  bed="$(_sc sleep_bed)"; wake="$(_sc sleep_wake)"
  quality="$(_sc sleep_quality)"; hours="$(_sc sleep_hours)"
  dump="$(_sc dump)"

  # Seed THIS persona's saved fitness-journal vault (profile/library/prior sessions)
  # if it has fixtures; else fall back to the inline stub seeder.
  if ! e2e_seed_persona_fixtures fitness-journal "$E2E_FDIR"; then
    _seed_profiles "$today"
    e2e_note "no persona fixtures — used the inline stub profile/library"
  fi

  # 1) The human's session dump.
  e2e_user "$dump"

  # 2) Run the REAL fitness-journal.sh; capture the emitted block.
  local block
  block="$(_fitness_sh "$dump")"
  e2e_cmd "fitness-journal \"$dump\""
  e2e_assert "fitness-journal.sh emitted FITNESS_JOURNAL_SESSION (daily LOG flow)" \
    grep -q "FITNESS_JOURNAL_SESSION" <<<"$block"

  # --- assertions on the EMITTED sleep contract (given-or-blank) -----------
  e2e_assert "Step 1 makes sleep mandatory to surface" \
    grep -q "ALWAYS surface" <<<"$block"
  e2e_assert "Step 4 is given-or-confirmed-or-blank (write only what's given this session)" \
    grep -q "SLEEP GIVEN OR CONFIRMED THIS SESSION" <<<"$block"
  e2e_assert "contract forbids assumed sleep (false data)" \
    grep -q "false data" <<<"$block"
  e2e_assert "no carry-forward mechanism in the instructions" \
    bash -c '! grep -qi "carry forward\|carried forward\|MOST RECENT SLEEP" <<<"$0"' "$block"
  e2e_assert "persona prefs surfaced to the command" \
    grep -qiE "preference|hygiene|prefs" <<<"$block"

  case "$sleep_mode" in
    cold)
      e2e_say fitness "Sleep last night — time to bed, time up, quality 1–10?"
      e2e_user "skip that, just log the workout"
      e2e_note "sleep withheld → leave sleep_* BLANK (no carry from the persona's prior session, no profile window)"
      ;;
    captured)
      e2e_say fitness "got it — bed $bed, up $wake, that's ${hours}h."
      e2e_note "sleep given THIS session → fresh reading, no provenance note"
      ;;
  esac

  # 3) Write the artifact the way the instructions say (agent never invents sleep).
  _write_entry "$today" "$sleep_mode" "$bed" "$wake" "$quality" "$hours" ""
  e2e_say fitness "wrote today's fitness entry with sleep_* per the precedence (mode: $sleep_mode)"

  # --- assertions on the REAL artifact -------------------------------------
  e2e_assert "dated fitness file exists" test -f "$E2E_OUT_FILE"
  e2e_assert "entry has the four sleep_* frontmatter keys" \
    bash -c 'for k in sleep_bed sleep_wake sleep_quality sleep_hours; do grep -q "^$k:" "$0" || exit 1; done' "$E2E_OUT_FILE"

  case "$sleep_mode" in
    captured)
      e2e_assert "captured: real bed time written ($bed)" grep -q "^sleep_bed: $bed\$" "$E2E_OUT_FILE"
      e2e_assert "captured: real hours written ($hours)" grep -q "^sleep_hours: $hours\$" "$E2E_OUT_FILE"
      e2e_assert "captured: NOT marked carried-forward (it was measured today)" \
        bash -c '! grep -qi "carried forward" "$0"' "$E2E_OUT_FILE"
      ;;
    cold)
      e2e_assert "withheld: sleep_bed left BLANK (not invented)" grep -qE "^sleep_bed: *\$" "$E2E_OUT_FILE"
      e2e_assert "withheld: sleep_hours left BLANK (not invented)" grep -qE "^sleep_hours: *\$" "$E2E_OUT_FILE"
      # The persona's prior session (23:40) and profile window (23:00) must NOT leak in.
      e2e_assert "withheld: prior session 23:40 NOT carried into the entry" \
        bash -c '! grep -q "^sleep_bed: 23:40" "$0"' "$E2E_OUT_FILE"
      e2e_assert "withheld: profile window 23:00 NOT fabricated into the entry" \
        bash -c '! grep -q "^sleep_bed: 23:00" "$0"' "$E2E_OUT_FILE"
      ;;
  esac

  e2e_assert "no unexpected stderr from fitness-journal.sh" test ! -s "$E2E_WORK/fitness.stderr"
  e2e_assert "reached expected terminal ($(_sc expect))" _judge_fitness

  e2e_fold_parse_fails
  local pass="true"; [[ ${#E2E_FAILURES[@]} -eq 0 ]] || pass="false"

  local artifact; artifact="$E2E_OUT_FILE"$'\n---\n'"$(cat "$E2E_OUT_FILE")"
  e2e_emit_result "$pass" "vault-file" "" "$artifact"
  e2e_safe_rmrf "$E2E_WORK"
  [[ "$pass" == "true" ]]
}

# fitness terminal: "logged" iff the dated file exists with the sleep_* contract.
_judge_fitness() {
  local expect; expect="$(_sc expect)"
  case "$expect" in
    logged) test -f "$E2E_OUT_FILE" && grep -q "^sleep_bed:" "$E2E_OUT_FILE" ;;
    *) return 1 ;;
  esac
}
