#!/usr/bin/env bash
# queue.bash — live-logic e2e for the PB-141/PB-146 queue model, with an HTML report.
#
# WHAT THIS IS
# -----------
# A real end-to-end of the QUEUE feature: it drives the REAL engine in lib/plane.py
# (enqueue_ordered, queued_multi, rank_done_by_completion, ready/issue_to_ready, the
# Queued state + sort_order) through a full lifecycle. The ONLY fake is the network
# boundary — a tiny in-memory PlaneClient stand-in (FakePlaneHTTP) implements the
# handful of HTTP methods the engine calls (list_states / list_work_items /
# update_work_item / list_labels / list_modules). Everything above that — state
# resolution, group mapping, ranking, the Queued filter — is the production code.
#
# This is the same boundary-honesty as tests/e2e/fake_plane.py (fake Plane I/O, real
# command logic), but at the engine level so we exercise the actual queue functions
# rather than re-implementing them.
#
# WHAT IT ASSERTS (one scenario per lifecycle step)
#   1. intake lands in Todo (NOT Backlog, NOT Queued)
#   2. groom enqueue moves ranked todo -> Queued with ascending sort_order
#   3. an in-progress (Building) issue is NEVER pulled back into the queue
#   4. Backlog is never touched by enqueue
#   5. queued_multi returns the Queued issues in sort_order (what pmw walks)
#   6. completing an issue advances it out of the queue (queue shrinks)
#   7. PB-146: the Done column is ranked newest-completed-first (smallest sort_order)
#
# OUTPUT
#   An HTML report at tests/e2e/.e2e_report/e2e-<stamp>.html, produced by the same
#   tests/e2e/report.py the rest of the e2e suite uses. Each step is one row; the
#   Plane write-journal (the PATCHes the engine issued) is shown per step.
#
# RUN
#   bash tests/e2e/queue.bash            # run + build the HTML report, print its path
#   PBRAIN_E2E_OPEN=1 bash tests/e2e/queue.bash   # also `open` the report (macOS)

set -uo pipefail

E2E_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P -- "$E2E_DIR/../.." && pwd -P)"
PLANE="$REPO_ROOT/lib/plane.py"

RESULTS_DIR="$E2E_DIR/.e2e_results"
REPORT_DIR="$E2E_DIR/.e2e_report"
# Guard: only wipe RESULTS_DIR when E2E_DIR resolved and the path is the expected
# .e2e_results dir under it — never an empty/unexpected target.
[[ -n "$E2E_DIR" && "$RESULTS_DIR" == "$E2E_DIR/.e2e_results" ]] \
  || { echo "queue.bash: refusing to clear unexpected RESULTS_DIR: $RESULTS_DIR" >&2; exit 1; }
rm -rf "$RESULTS_DIR"; mkdir -p "$RESULTS_DIR" "$REPORT_DIR"

# The real engine + the fake HTTP boundary drive the whole lifecycle in one Python
# process; it writes one <step>.result.json per assertion in report.py's schema.
PLANE="$PLANE" RESULTS_DIR="$RESULTS_DIR" python3 - <<'PY'
import importlib.util, json, os

spec = importlib.util.spec_from_file_location("plane", os.environ["PLANE"])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
RES = os.environ["RESULTS_DIR"]

PID = "proj-pb"
# The seeded pipeline states (post-PB-141: Queued sits in the unstarted group).
STATES = [
    {"id": "s-backlog",  "name": "Backlog",  "group": "backlog"},
    {"id": "s-todo",     "name": "Todo",     "group": "unstarted", "default": True},
    {"id": "s-queued",   "name": "Queued",   "group": "unstarted"},
    {"id": "s-planning", "name": "Planning", "group": "started"},
    {"id": "s-building", "name": "Building", "group": "started"},
    {"id": "s-done",     "name": "Done",     "group": "completed"},
    {"id": "s-cancel",   "name": "Cancelled","group": "cancelled"},
]
SID = {s["name"]: s["id"] for s in STATES}


class FakePlaneHTTP:
    """In-memory stand-in for PlaneClient — the network boundary only. Holds an
    issue table; PATCHes mutate it, exactly like the real API round-trip."""
    def __init__(self, issues):
        self.issues = {it["id"]: dict(it) for it in issues}
        self.journal = []                      # the PATCHes the engine issued
    # --- the methods the queue engine calls ---
    def list_states(self, pid):       return list(STATES)
    def list_work_items(self, pid):   return [dict(v) for v in self.issues.values()]
    def list_labels(self, pid):       return []      # no approval/gate labels in this fixture
    def list_modules(self, pid):      return []      # no lanes
    def get_work_item(self, pid, iid): return dict(self.issues[iid])   # claim+verify re-read
    def update_work_item(self, pid, iid, body):
        self.issues[iid].update(body)
        self.journal.append({"PATCH": iid, "body": body})
        return self.issues[iid]


def issue(iid, state, *, priority="medium", completed_at=None, sort_order=None):
    o = {"id": iid, "name": "Issue %s" % iid, "state": SID[state],
         "priority": priority, "parent": None}
    if completed_at is not None:
        o["completed_at"] = completed_at
    if sort_order is not None:
        o["sort_order"] = sort_order
    return o


CFG = {"default_est_h": 2.0}
RESULTS = []

def record(name, expect, passed, lines, journal):
    """Emit one report.py-schema result.json for this lifecycle step."""
    transcript = "\n".join(lines)
    out = {
        "scenario": name, "persona": "queue-engine",
        "passed": bool(passed), "skipped": False,
        "expect": expect, "display": name,
        "transcript": transcript,
        "tracking_kind": "plane-journal",
        "tracking": journal,
        "artifact": "",
        "failures": [] if passed else ["assertion failed — see transcript"],
        "seams": [],
    }
    safe = name.lower().replace(" ", "-").replace("/", "-")
    json.dump(out, open(os.path.join(RES, "%s.result.json" % safe), "w"), indent=2)
    RESULTS.append((name, passed))


def _ready_rows(client):
    # ready_multi reuses ready(); patch project resolution to our single fake project.
    return m.ready_multi(CFG, client, [PID])

# ── STEP 1: intake lands in Todo ───────────────────────────────────────────────
# A freshly-filed issue is in Todo (the seeded default). We assert the row the
# engine produces reports state_name Todo and a ready status — not Backlog/Queued.
fc = FakePlaneHTTP([issue("T1", "Todo")])
rows = _ready_rows(fc)
r = next((x for x in rows if x["tie"].endswith("T1")), None)
ok = bool(r) and r["state_name"] == "Todo" and r["status"] == "todo"
record("01 intake lands in Todo",
       "a filed issue is in Todo (ready), not Backlog or Queued",
       ok,
       ["filed T1 with the default state",
        "ready row: %s" % json.dumps(r)],
       fc.journal)

# ── STEP 2/3/4: enqueue ranks Todo -> Queued; skips in-progress; ignores Backlog ─
fc = FakePlaneHTTP([
    issue("Q1", "Todo",     priority="high"),
    issue("Q2", "Todo",     priority="low"),
    issue("B1", "Building"),                       # in progress — must NOT be queued
    issue("K1", "Backlog"),                        # the user's staging area — untouched
])
ordered = m.ready_multi(CFG, fc, [PID], ordered=True)
out = m.enqueue_ordered(CFG, fc, ordered)
moved = {j["PATCH"]: j["body"] for j in fc.journal}
# 2: both Todo issues moved to Queued with ascending sort_order (high before low)
q1, q2 = fc.issues["Q1"], fc.issues["Q2"]
ok2 = (q1["state"] == SID["Queued"] and q2["state"] == SID["Queued"]
       and q1.get("sort_order") < q2.get("sort_order"))
record("02 enqueue ranks Todo into Queued",
       "todo issues move to Queued with ascending sort_order (priority order)",
       ok2,
       ["enqueue summary: %s" % json.dumps(out),
        "Q1(high) sort_order=%s  Q2(low) sort_order=%s"
        % (q1.get("sort_order"), q2.get("sort_order"))],
       [j for j in fc.journal if j["PATCH"] in ("Q1", "Q2")])
# 3: the Building issue was never patched
ok3 = "B1" not in moved and fc.issues["B1"]["state"] == SID["Building"]
record("03 in-progress issue not re-queued",
       "a Building issue is never pulled back into the queue",
       ok3,
       ["B1 still in state: %s (Building=%s)" % (fc.issues["B1"]["state"], SID["Building"]),
        "B1 patched? %s" % ("yes" if "B1" in moved else "no")],
       [])
# 4: the Backlog issue was never patched
ok4 = "K1" not in moved and fc.issues["K1"]["state"] == SID["Backlog"]
record("04 Backlog is never touched",
       "enqueue leaves the user's Backlog untouched",
       ok4,
       ["K1 still in state: %s (Backlog=%s)" % (fc.issues["K1"]["state"], SID["Backlog"]),
        "K1 patched? %s" % ("yes" if "K1" in moved else "no")],
       [])

# ── STEP 5: queued_multi returns the queue in sort_order (what pmw walks) ───────
q = m.queued_multi(CFG, fc, [PID])
order = [x["tie"].split(":")[-1] for x in q]
ok5 = order == ["Q1", "Q2"]                       # high-priority first, by sort_order
record("05 pmw reads the queue in order",
       "queued_multi returns Queued issues in sort_order (Q1 then Q2)",
       ok5,
       ["queue order: %s" % order,
        "sort_orders: %s" % [x.get("sort_order") for x in q]],
       [])

# ── STEP 6: completing an issue advances it out of the queue ───────────────────
fc.update_work_item(PID, "Q1", {"state": SID["Done"], "completed_at": "2026-06-26T09:00:00Z"})
q_after = m.queued_multi(CFG, fc, [PID])
order_after = [x["tie"].split(":")[-1] for x in q_after]
ok6 = order_after == ["Q2"]                        # Q1 left the queue, Q2 remains
record("06 completing advances out of the queue",
       "a completed issue leaves Queued; the queue shrinks to the rest",
       ok6,
       ["queue before: ['Q1','Q2']", "queue after completing Q1: %s" % order_after],
       [j for j in fc.journal if j["PATCH"] == "Q1"][-1:])

# ── STEP 6b: two parallel sessions claim DIFFERENT issues (no collision) ───────
fc = FakePlaneHTTP([
    issue("P1", "Queued", priority="high", sort_order=1000.0),
    issue("P2", "Queued", priority="low",  sort_order=2000.0),
])
s1 = m.claim_next_queued(CFG, fc, [PID], "1001")     # session 1
s2 = m.claim_next_queued(CFG, fc, [PID], "2002")     # session 2
picked = sorted([s1["tie"].split(":")[-1], s2["tie"].split(":")[-1]])
both_planning = fc.issues["P1"]["state"] == SID["Planning"] and fc.issues["P2"]["state"] == SID["Planning"]
ok6b = picked == ["P1", "P2"] and both_planning
record("06b two sessions claim different issues",
       "parallel /plan-my-work sessions claim DIFFERENT queued issues (atomic claim)",
       ok6b,
       ["session1 claimed: %s" % (s1["tie"].split(":")[-1]),
        "session2 claimed: %s" % (s2["tie"].split(":")[-1]),
        "both moved out of Queued → Planning: %s" % both_planning],
       fc.journal)

# ── STEP 7 (PB-146): Done column ranked newest-completed-first ─────────────────
fc = FakePlaneHTTP([
    issue("D_old", "Done", completed_at="2026-06-20T10:00:00Z"),
    issue("D_new", "Done", completed_at="2026-06-25T10:00:00Z"),   # newest
    issue("D_mid", "Done", completed_at="2026-06-22T10:00:00Z"),
    issue("D_nil", "Done", completed_at=""),                       # undated -> last
    issue("T_x",   "Todo"),                                        # not Done -> ignored
])
m.rank_done_by_completion(CFG, fc, [PID])
ranked = sorted(
    [(iid, fc.issues[iid].get("sort_order")) for iid in
     ("D_old", "D_new", "D_mid", "D_nil")],
    key=lambda t: (t[1] if t[1] is not None else 1e18))
ok7 = ([iid for iid, _ in ranked] == ["D_new", "D_mid", "D_old", "D_nil"]
       and "T_x" not in {j["PATCH"] for j in fc.journal})       # Todo untouched
record("07 Done column ranked newest-first (PB-146)",
       "Done issues get sort_order by completed_at desc; Todo untouched",
       ok7,
       ["rank (state_name=Done) by sort_order asc: %s" % ranked,
        "Todo issue T_x patched? %s"
        % ("yes" if "T_x" in {j['PATCH'] for j in fc.journal} else "no")],
       fc.journal)

# Summary line for the runner.
total = len(RESULTS); passed = sum(1 for _, p in RESULTS if p)
print("STEPS %d PASS %d FAIL %d" % (total, passed, total - passed))
PY
rc=$?

# Build the HTML report with the SAME reporter the rest of the e2e suite uses.
python3 "$E2E_DIR/report.py" "$RESULTS_DIR" "$REPORT_DIR"
report="$(ls -t "$REPORT_DIR"/e2e-*.html 2>/dev/null | head -1)"

echo
echo "Queue e2e report: $report"
[[ "${PBRAIN_E2E_OPEN:-0}" == "1" && -n "$report" ]] && open "$report" 2>/dev/null || true

# Non-zero exit if any step failed (the Python summary drives it via grep).
exit "$rc"
