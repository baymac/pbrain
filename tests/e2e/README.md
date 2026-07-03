# tests/e2e — a reusable e2e framework for pbrain commands (PB-89)

A table-driven end-to-end **framework** that replays a **persona ↔ command chat**
against a *real* pbrain command and shows the command's **tracking artifact**
(the Plane writes or the vault file it produced) alongside the chat in one
standalone HTML report. Distinct **personas** (different `prefs.md`, plus an
`e2e_voice` bank of messy free-text utterances) drive the same scenarios, and
every run must behave correctly.

This is separate from the unit suites in `tests/*.bats` (which cover individual
`lib/` helpers): here the *real* command scripts run, so we test orchestration
behaviour, not a mocked script.

**Commands covered today:**
- `/plan-my-work` — the 5-stage execute loop (`tests/e2e-pmw.bats`, driver
  `harness.bash`). Tracking = the Plane write-journal.
- `/journal` — the daily journal loop (`tests/e2e-journal.bats`, driver
  `journal.bash`). Tracking = the real dated vault markdown file.

## Framework vs per-command driver

| Piece | Scope | File |
|---|---|---|
| transcript, assertions, persona voice + asserted-intent parser, env scaffold (temp vault/DB/config + prefs injection), result emission | **shared rig** | `lib.bash` |
| standalone HTML reporter (kind-aware Tracking pane) | **shared** | `report.py` |
| personas (prefs + `e2e_voice` bank) | **shared** | `personas/*.md` |
| the command's own state machine (its loop) + scenarios | **per-command** | `harness.bash` (pmw), `journal.bash` (journal), `scenarios/*.json` |

Adding a command = write a `<cmd>.bash` driver that `source`s `lib.bash`, calls
`e2e_env_setup`, replays the command's loop with the shared helpers, and calls
`e2e_emit_result <pass> <tracking_kind> <tracking_json> <artifact>`; then add
scenarios and a `tests/e2e-<cmd>.bats`. `tracking_kind` ∈ `plane-journal` |
`vault-file` | `db-rows`.

## Run

```bash
bats tests/e2e-pmw.bats        # one command (partial report)
bats tests/e2e-journal.bats    # the other command (partial report)
bats tests/                    # ALL e2e commands → ONE union report
```

Each `@test` is one **(scenario × persona)** run. All e2e suites write results
into a shared dir (`.e2e_report/.results`) and emit a single standalone
**`.e2e_report/e2e-<timestamp>.html`** (gitignored) — path printed at the end.
Running `bats tests/` produces a union report covering every command; a single
suite alone yields a partial one (results are cleared fresh per `bats`
invocation, keyed on the bats PID, but accumulate across suites in the same
invocation). The report embeds, per run: a pass/fail grid, the persona ↔ command
chat, the Tracking artifact, and any SEAM callouts.

## What is real vs faked (honest boundary)

| Layer | Real? | How |
|---|---|---|
| the command script under test (`project-manager.sh`, `journal.sh`) | **real** | runs unmodified |
| `PBRAIN_VAULT` / `PBRAIN_DB_FILE` / `XDG_CONFIG_HOME` | **real** | per-run tempdirs |
| persona `prefs.md` | **real** | injected via `PBRAIN_PREFS_DIR` (`_global/prefs.md`) |
| git worktree / branch / commit (pmw) | **real** | throwaway repo in a tempdir |
| vault markdown artifact (journal) | **real** | the actual dated file the command writes |
| Plane network I/O (pmw) | faked | `fake_plane.py` swapped in for `lib/plane.py`; reads serve scenario JSON, writes are journalled |
| `gh`, CI checks, `gh pr merge` (pmw) | **faked, scripted** | shown as `SEAM` lines; never fabricated into a real PR/merge |

## Layout

```
tests/e2e/
├── lib.bash              # SHARED rig: transcript, asserts, persona voice, env scaffold, result emission
├── report.py             # SHARED: aggregates *.result.json → one standalone HTML (kind-aware Tracking pane)
├── personas/*.md         # SHARED: personas (real prefs.md + an `e2e_voice` utterance bank)
├── harness.bash          # /plan-my-work driver: 5-stage loop + multi-loop dispatch (sources lib.bash)
├── fake_plane.py         # /plan-my-work only: the Plane boundary seam (drop-in for lib/plane.py)
├── journal.bash          # /journal driver: replays the journal loop, writes a real vault file (sources lib.bash)
└── scenarios/*.json      # per-command table-driven cases
```

## Personas speak in free text (with an asserted intent)

Each persona file carries an `e2e_voice:` bank — one row per stage:

```
e2e_voice:
  plan       go      | ye plan's fine just run it
  implement  go      | kk go ahead build it
  ship       hold    | no dont open a pr yet
  land       confirm | yep merge it. land pb-900
```

The **utterance** (right of `|`) is the messy human line shown in the transcript;
the **intent** column (`go` | `hold` | `confirm`) is *ground truth*. At each
manual gate the harness shows the utterance, runs its keyword intent-parser
(`_parse_intent`) on it, and **asserts the parse equals the ground-truth intent**.
So a free-text line the parser would misread is a caught hard failure — the
parser is itself under test — while gate routing always uses the ground-truth
intent, keeping the suite deterministic. A stage with no row defaults to `hold`
(parks). To prove the guard: edit a row so its utterance contradicts its intent
column and that run will FAIL on `intent parse MISMATCH`.

## Single-leaf vs multi-loop scenarios

A scenario is either **single-leaf** (one issue) or **multi-loop** (a dependency
chain or a parent with sub-issues):

- **Single-leaf:** one `issue` block. `test_result`/`ci_result`/`gh_present` sit
  at the top level.
- **Multi-loop:** a `primary_id` plus an `issues` array (each entry has its own
  `tie`/`id`/`id_slug`/`auto_gates`/`blocked_by`/`subtree`, and may override
  `test_result`/`ci_result`/`gh_present`; top-level values are the fallback). The
  dispatcher mirrors `execute.txt` pre-flight:
  - `blocked_by` non-empty → drive the **blocker(s) to done first**, then the
    primary. If a blocker parks, the primary never starts. (Asserts the blocker's
    `move→doing` precedes the primary's.)
  - `subtree` non-empty (parent, PB-81) → drive **each child** as its own
    branch/PR/merge, then close the **parent last**. (Asserts each child gets a
    distinct branch and the parent's `move→done` is the last done in the journal.)

## `expect` vocabulary

- `done` — every driven issue reached done.
- `park:<stage>` — single-leaf park at `<stage>`, nothing reached done.
- `park:<id>:<stage>` — multi-loop: that issue parked at `<stage>` (e.g. a
  blocker that couldn't finish).

## Adding a scenario

Copy an existing fixture (the `_doc` field explains each key) and add a `@test`
in `tests/e2e-pmw.bats` pairing it with the persona(s) you want. An optional
`display` field gives the report grid a friendly label.

## Invariants asserted

- **stop-at-first-gap** gating: a stage advances only if its own `auto:<stage>`
  label is present (or the persona manually passes the gate).
- **park is durable + resumable**: WIP-commit + push intent + a `pbrain park:`
  breadcrumb comment; status stays `doing` (never `done`).
- **CI-red hard-stops land** even when `auto:land` is present.
- **no release** is cut at land.
- the loop **writes nothing to the vault**.
- **blocked_by** drives the blocker first; the primary doesn't start until the
  blocker reaches done (and not at all if the blocker parks).
- **parent/sub-issues (PB-81):** each child is its own branch/PR/merge and the
  parent is closed last.
- **intent parser** is asserted against each persona utterance's ground-truth
  intent (a misparse is a caught failure).

## Queue e2e (PB-141 / PB-146) — `queue.bash`

A standalone engine-level e2e for the Queued-state queue model. Unlike the
persona scenarios above, it drives the REAL queue engine in `lib/plane.py`
(`enqueue_ordered`, `queued_multi`, `rank_done_by_completion`, the Queued state +
`sort_order`) through a full lifecycle, faking only the network boundary with an
in-memory `PlaneClient` stand-in. Eight steps, one per lifecycle transition:
intake→Todo, enqueue ranks Todo→Queued, in-progress never re-queued, Backlog
untouched, pmw reads the queue in order, completing advances out, two parallel sessions claim different issues, Done ranked
newest-first. Emits an HTML report via the same `report.py` (showing the Plane
write-journal per step).

```
bash tests/e2e/queue.bash                  # run + write the HTML report, print its path
PBRAIN_E2E_OPEN=1 bash tests/e2e/queue.bash # also open it (macOS)
```

## plan-my-day live e2e (PB-186) — `plan-my-day-live.sh`

A standalone, real-vault, agent-to-agent e2e for `/plan-my-day`. Because
`/plan-my-day` AUTO-PLANS (it derives the day from the user's real profile,
fitness journal, diet meal times, habits and calendar — the user only does a
light morning check-in), a faithful test runs the REAL command against a
faithful copy of the user's data.

Pipeline: SNAPSHOT the real `$VAULT_DIR` + `~/.config/pbrain` into a throwaway
dir (real vault untouched; Plane/reminders/DB neutralized) → apply migration
`0015` on the copy (so `block_layout_policy` + `break_minutes` exist) → delete
ONLY today's `daily-planning/<date>.md` in the copy → REPLAY: run the real
`plan-my-day.sh plan` and converse two real models (a SKILL model following the
emitted instructions + a PERSONA model answering the morning check-in from a
scenario) until the plan is written → ASSERT the generated `## Today at a glance`
table against the policy (work blocks fixed at `session_length_min`, trimmed only
at end-of-day or a hard anchor; breaks within `break_minutes` min..max, never
padded) → REPORT a clean standalone HTML (conversation bubbles + day timeline +
rules-check) and open it.

The football time, meal slots and buffers are NOT supplied by the scenario —
they come from the copied fitness journal / diet profile, exactly as a real
morning run does. Skips cleanly (not a pass) if the `claude` CLI is absent.

```
bash tests/e2e/plan-my-day-live.sh run                 # full pipeline + open report
bash tests/e2e/plan-my-day-live.sh run --no-open       # don't auto-open
bash tests/e2e/plan-my-day-live.sh run --scenario tests/e2e/scenarios/plan-my-day/today-replay.json
PBRAIN_E2E_MODEL=claude-haiku-4-5-20251001 bash tests/e2e/plan-my-day-live.sh run  # cheaper smoke run
```

### Chain mode (`--chain`, PB-165) — the CONNECTED pipeline on real today-data

The default run replays a single fixed scenario against plan-my-day. **Chain mode**
instead regenerates the user's *own real today-data* live, in dependency order —
**journal → fitness-journal → diet-journal → plan-my-day** — so it exercises the
actual linkage (fitness records a `**When**` time → plan-my-day anchors the day
from it; journal sleep → fitness prefill). Each leg's persona is *inspired by facts
extracted from that day's real files* (facts only, rephrased naturally), the outputs
are reset so each regenerates, and plan-my-day is asserted against the regenerated
data — no invented scenario.

```
# Run the chain on a specific day (e.g. a day whose data straddled midnight):
bash tests/e2e/plan-my-day-live.sh run --chain --date 2026-07-01 --no-open
PBRAIN_E2E_CHAIN=1 PBRAIN_TODAY_OVERRIDE=2026-07-01 bash tests/e2e/plan-my-day-live.sh run
```

`--date` / `PBRAIN_TODAY_OVERRIDE` pins the day; the commands honor the same
override so the whole chain is internally consistent (weekday derived from the
pinned date, wall-clock time unchanged). Pieces added for chain mode:
`plan-my-day-chain.bash` (the leg orchestrator) and `plan-my-day-facts.py` (the
read-only fact extractor). The snapshot/fake-reminders/plane-disable safety is
unchanged — the real vault is never touched, and all temp cleanup goes through a
guarded `_safe_rmrf` (refuses empty/non-temp paths).

It applies migrations 0015 (break band + fixed-block policy) and 0016 (diet
meal durations + post-meal nap) on the copy, so the assert enforces: fixed
work blocks, breaks within break_minutes min..max, meals capped at their
diet-profile duration (default 30, never longer — not even "lunch out"), a
post-meal nap treated as a break (unless a fixed nap is configured), no
pre-activity padding (only commute reserved), no future-✓ fabrication, no
mega-rest. (Per-day block priority + conflict-raising is tracked separately as
PB-194, not covered here.)

Pieces: `plan-my-day-live.sh` (orchestrator), `plan-my-day-assert.py` (the
policy check), `plan-my-day-report.py` (the HTML renderer), and the scenario at
`scenarios/plan-my-day/today-replay.json`.
