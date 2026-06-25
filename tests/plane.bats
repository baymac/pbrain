#!/usr/bin/env bats
# Tests for the pbrain ↔ Plane backend (lib/plane.py + the seams in
# lib/projects.sh). Network calls are NOT exercised here — we test the pure
# mapping functions (status↔state-group, state pick, ready filter, resolve
# payload), the config surface, and that the daily-loop seams route to Plane
# when configured and degrade gracefully (to []/{}) otherwise.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0 PBRAIN_UPDATE_CHECK=0 PBRAIN_SELF_IMPROVE=off
  export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/pbrain"
  export PBRAIN_VAULT="$TMP/vault"; mkdir -p "$PBRAIN_VAULT"
  PLANE="$REPO_ROOT/lib/plane.py"
  # ensure no stray creds leak in from the dev shell
  unset PBRAIN_PLANE_API_KEY PBRAIN_PLANE_BASE_URL PBRAIN_PLANE_WORKSPACE PBRAIN_PLANE_PROJECT
}
teardown() { rm -rf "$TMP"; }

PY() { python3 "$PLANE" "$@"; }

# --- pure mapping (imported, no network) ------------------------------------
@test "status<->state-group mapping is correct both directions" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.GROUP_TO_STATUS["unstarted"] == "todo"
assert m.GROUP_TO_STATUS["started"] == "doing"
assert m.GROUP_TO_STATUS["completed"] == "done"
assert m.GROUP_TO_STATUS["cancelled"] == "dropped"
assert m.STATUS_TO_GROUP["doing"] == "started"
assert m.STATUS_TO_GROUP["blocked"] == "started"
assert m.STATUS_TO_GROUP["done"] == "completed"
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]
}

@test "web_base swaps the loopback for the vanity host, keeps real hostnames, appends workspace" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util, os
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
os.environ.pop("PBRAIN_PLANE_WEB_BASE", None)
# loopback base -> browser vanity host plane.localhost, same port, + workspace
assert m.web_base({"base_url":"http://127.0.0.1:1800","workspace":"pb"}) == "http://plane.localhost:1800/pb", m.web_base({"base_url":"http://127.0.0.1:1800","workspace":"pb"})
assert m.web_base({"base_url":"http://localhost:1800","workspace":"pb"}) == "http://plane.localhost:1800/pb"
# real hostname (VPS/domain) is kept as-is
assert m.web_base({"base_url":"https://plane.example.com","workspace":"acme"}) == "https://plane.example.com/acme"
# no workspace -> no trailing segment
assert m.web_base({"base_url":"http://127.0.0.1:1800"}) == "http://plane.localhost:1800"
# empty cfg -> empty string (callers fall back)
assert m.web_base({}) == ""
# explicit override wins outright
os.environ["PBRAIN_PLANE_WEB_BASE"] = "http://custom:9/x"
assert m.web_base({"base_url":"http://127.0.0.1:1800","workspace":"pb"}) == "http://custom:9/x"
del os.environ["PBRAIN_PLANE_WEB_BASE"]
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]
}

@test "PB-134 browse_url builds the canonical short, terminal-clickable issue link" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util, os
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
os.environ.pop("PBRAIN_PLANE_WEB_BASE", None)
cfg = {"base_url":"http://127.0.0.1:1800","workspace":"pb",
       "projects":[{"id":"P1","shortcut":"pb","name":"pbrain"}]}
# canonical short browse form, loopback swapped to the vanity host, trailing slash
assert m.browse_url(cfg, "P1", 134) == "http://plane.localhost:1800/pb/browse/PB-134/", m.browse_url(cfg, "P1", 134)
# uses the UPPERCASED project short, not the display name (no spaces -> never breaks)
cfg2 = {"base_url":"http://127.0.0.1:1800","workspace":"ws",
        "projects":[{"id":"P2","name":"YouTube Summary Extension","shortcut":"yt"}]}
assert m.browse_url(cfg2, "P2", 7) == "http://plane.localhost:1800/ws/browse/YT-7/", m.browse_url(cfg2, "P2", 7)
# no sequence / no web base -> empty (callers fall back to the bare ref)
assert m.browse_url(cfg, "P1", None) == ""
assert m.browse_url({}, "P1", 5) == ""
# override host is honored
os.environ["PBRAIN_PLANE_WEB_BASE"] = "https://plane.example.com/pb"
assert m.browse_url(cfg, "P1", 134) == "https://plane.example.com/pb/browse/PB-134/"
del os.environ["PBRAIN_PLANE_WEB_BASE"]
# _issue_card carries the same canonical url so `find` relays it (no guessing)
card = m._issue_card(cfg, "P1", {"id":"u1","sequence_id":134,"name":"x"}, "PB")
assert card["url"] == "http://plane.localhost:1800/pb/browse/PB-134/", card["url"]
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]
}

@test "suggest_auto_stages: easy approved issue gets plan..ship, hard/blocked gets plan only, NEVER land" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util, os
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
os.environ.pop("PBRAIN_GROOM_AUTO_MAX_HOURS", None)
i = {}
# approved + small + unblocked + no children -> full run up to ship
assert m.suggest_auto_stages(i, approved=True, est_hours=2.0) == ["plan","implement","test","ship"]
# docs/chore skips test
assert m.suggest_auto_stages(i, approved=True, est_hours=2.0, is_docs_or_chore=True) == ["plan","implement","ship"]
# big estimate -> plan only
assert m.suggest_auto_stages(i, approved=True, est_hours=8.0) == ["plan"]
# blocked -> plan only
assert m.suggest_auto_stages(i, approved=True, est_hours=2.0, has_open_blockers=True) == ["plan"]
# has open children -> plan only
assert m.suggest_auto_stages(i, approved=True, est_hours=2.0, has_open_children=True) == ["plan"]
# not approved -> plan only
assert m.suggest_auto_stages(i, approved=False, est_hours=1.0) == ["plan"]
# unknown estimate -> plan only (not treated as small)
assert m.suggest_auto_stages(i, approved=True, est_hours=None) == ["plan"]
# land is NEVER suggested, in any case
for c in [m.suggest_auto_stages(i, approved=True, est_hours=0.5),
          m.suggest_auto_stages(i, approved=True, est_hours=2.0, is_docs_or_chore=True)]:
    assert "land" not in c, c
# returns stages in GATE_NAMES order
assert m.suggest_auto_stages(i, approved=True, est_hours=1.0) == [g for g in m.GATE_NAMES if g in ("plan","implement","test","ship")]
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]
}

@test "groom_run --apply assigns the suggested auto:* labels (and PBRAIN_GROOM_NO_AUTO suppresses)" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util, os
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

# A fake client: one well-formed, approved, small, unblocked, childless todo issue.
APPROVED="lap"; GP={ "plan":"lp","implement":"li","test":"lt","ship":"ls","land":"lL" }
class FC:
    def __init__(self): self.patched={}
    def list_states(self,pid): return [{"id":"s1","name":"Todo","group":"unstarted","default":True}]
    def list_work_items(self,pid):
        return [{"id":"i1","sequence_id":7,"name":"easy one","state":"s1",
                 "labels":[APPROVED],"estimate_point":"ep1","parent":None}]
    def list_labels(self,pid):
        return ([{"id":APPROVED,"name":"plan-approved"}] +
                [{"id":v,"name":"auto:%s"%k} for k,v in GP.items()])
    def list_sub_issues(self,pid,iid): return []
    def update_work_item(self,pid,iid,body): self.patched[iid]=body.get("labels"); return {}

# Make estimate resolve to a small hours value + approved-label + gate-map work by
# monkeypatching the project-level helpers to deterministic values.
m.ensure_estimate_scale = lambda cfg,c,pid: {"x":1}
m.est_uuid_to_hours = lambda cfg,pid: {"ep1": 2.0}
m.thinness_flags = lambda issue, has_estimate_scale=False: []
m.approved_label_ids = lambda c,pid: [APPROVED]
# gate_label_map returns {stage -> SET of label ids} (matches production contract)
m.gate_label_map = lambda c,pid: {k:{v} for k,v in GP.items()}
m.state_group = lambda issue, by_id: "unstarted"
m.blocked_by_ids = lambda cfg,c,ref: []

fc=FC()
os.environ.pop("PBRAIN_GROOM_NO_AUTO", None)
rep=m.groom_run({}, fc, ["p"], apply=True)
todo=rep["todo"][0]
assert todo["auto_suggested"]==["plan","implement","test","ship"], todo
# the issue got the four stage labels (+ kept plan-approved), but NOT auto:land
patched=set(fc.patched.get("i1") or [])
assert {GP["plan"],GP["implement"],GP["test"],GP["ship"]} <= patched, patched
assert GP["land"] not in patched, patched
assert APPROVED in patched, patched

# NO_AUTO suppresses assignment entirely.
fc2=FC(); os.environ["PBRAIN_GROOM_NO_AUTO"]="1"
rep2=m.groom_run({}, fc2, ["p"], apply=True)
assert "auto_suggested" not in rep2["todo"][0], rep2["todo"][0]
assert not fc2.patched, fc2.patched
del os.environ["PBRAIN_GROOM_NO_AUTO"]
print("ok")
PYEOF
  [ "$status" -eq 0 ]
  [[ "$output" == *ok* ]]
}

@test "pick_state_id prefers name match, then default, then lowest sequence" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
states = [
  {"id":"todo","group":"unstarted","default":True,"sequence":2},
  {"id":"prog","group":"started","sequence":3},
  {"id":"block","name":"Blocked","group":"started","sequence":4},
  {"id":"done","group":"completed","default":True,"sequence":5},
]
assert m.pick_state_id(states,"unstarted")=="todo"               # default
assert m.pick_state_id(states,"started")=="prog"                 # lowest seq
assert m.pick_state_id(states,"started",want_name="blocked")=="block"  # name match
assert m.pick_state_id(states,"backlog") is None                 # absent group
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "build_status_body sets state id and completed_at for done" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
states=[{"id":"prog","group":"started"},{"id":"done","group":"completed","default":True}]
assert m.build_status_body("doing",states)=={"state":"prog"}
b=m.build_status_body("done",states,completed_at="2026-06-13T00:00:00Z")
assert b["state"]=="done" and b["completed_at"]=="2026-06-13T00:00:00Z"
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "PB-130/PB-141 PIPELINE_STATES: 9 states incl. Queued, correct names+groups, Todo default, no dup names" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
ps = m.PIPELINE_STATES
names = [s["name"] for s in ps]
# Todo is KEPT (not renamed to "Triage" — Plane reserves that name for its intake).
# PB-141: Queued sits between Todo and Planning (groom's ranked run queue).
assert names == ["Backlog","Todo","Queued","Planning","Building","Testing","Shipped","Landed","Cancelled"], names
by = {s["name"]: s for s in ps}
assert by["Backlog"]["group"]=="backlog"
assert by["Todo"]["group"]=="unstarted"
# PB-141: Queued shares the unstarted group with Todo (ready-eligible), is NOT default.
assert by["Queued"]["group"]=="unstarted" and not by["Queued"].get("default")
assert m.QUEUED_STATE == "Queued"
for n in ("Planning","Building","Testing","Shipped"):
    assert by[n]["group"]=="started", n
assert by["Landed"]["group"]=="completed"
assert by["Cancelled"]["group"]=="cancelled"
# exactly one default, and it is Todo (newly-filed lands ready)
defaults=[s["name"] for s in ps if s.get("default")]
assert defaults==["Todo"], defaults
# only In Progress is removed; Todo is kept (not in the removal map)
assert "in progress" in m.DEFAULT_STATES_TO_REMOVE and "todo" not in m.DEFAULT_STATES_TO_REMOVE
# orders are unique and ascending → distinct sequences when seeded
orders=[s["order"] for s in ps]
assert orders==sorted(orders) and len(set(orders))==len(orders)
# every group used is one pbrain knows about (ready contract intact)
groups=set(s["group"] for s in ps)
assert groups <= set(("backlog","unstarted","started","completed","cancelled")), groups
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "PB-141 queued_multi keeps only the Queued state sorted by sort_order; enqueue skips in-progress" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

# state_name resolves both expanded-object and bare-id forms.
sbi = {"q": {"name": "Queued", "group": "unstarted"},
       "t": {"name": "Todo",   "group": "unstarted"}}
assert m.state_name({"state": {"name": "Queued"}}, sbi) == "Queued"
assert m.state_name({"state": "q"}, sbi) == "Queued"

# queued_multi filters to Queued and orders by sort_order (lower first).
rows = [
  {"tie":"p:1","id":1,"state_name":"Todo","sort_order":None,"priority":"high","due":""},
  {"tie":"p:2","id":2,"state_name":"Queued","sort_order":2000.0,"priority":"low","due":""},
  {"tie":"p:3","id":3,"state_name":"Queued","sort_order":1000.0,"priority":"low","due":""},
]
m.ready_multi = lambda *a, **k: rows           # stub the source
got = [r["id"] for r in m.queued_multi({}, None, ["p"])]
assert got == [3, 2], got                       # only Queued, sort_order asc

# enqueue_ordered: todo rows get Queued + ascending sort_order; in-progress skipped.
class FakeClient:
    def __init__(self): self.patches=[]
    def list_states(self, pid): return [
        {"id":"q","name":"Queued","group":"unstarted"},
        {"id":"t","name":"Todo","group":"unstarted","default":True}]
    def update_work_item(self, pid, iid, body): self.patches.append((iid, body))
fc = FakeClient()
ordered = [
  {"tie":"p:10","status":"todo","priority":"high","due":""},
  {"tie":"p:11","status":"doing","priority":"high","due":""},   # already in progress
  {"tie":"p:12","status":"todo","priority":"low","due":""},
]
out = m.enqueue_ordered({}, fc, ordered)
moved = [(iid, body["sort_order"]) for iid, body in fc.patches]
assert [iid for iid,_ in moved] == ["10","12"], moved   # only todo rows moved
assert moved[0][1] < moved[1][1], moved                  # ascending rank
assert all(body["state"]=="q" for _,body in fc.patches)  # → Queued state id
assert any(r.get("skipped") for r in out)                # doing row reported skipped
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "PB-152 parked label: seeded, and skipped by queued_multi + enqueue (ready keeps it)" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

# 1) parked is in the seed set (so labels --seed / project-create create it).
names = {l["name"] for l in m._seed_label_specs()}
assert "parked" in names, names

# 2) queued_multi DROPS a parked row but keeps an unparked one.
rows = [
  {"tie":"p:2","id":2,"state_name":"Queued","sort_order":1000.0,"priority":"low","due":"","is_parked":False},
  {"tie":"p:3","id":3,"state_name":"Queued","sort_order":2000.0,"priority":"low","due":"","is_parked":True},
]
m.ready_multi = lambda *a, **k: rows
got = [r["id"] for r in m.queued_multi({}, None, ["p"])]
assert got == [2], got                              # parked id 3 excluded

# 3) enqueue_ordered skips a parked todo row (reported skipped:"parked", never moved).
class FakeClient:
    def __init__(self): self.patches=[]
    def list_states(self, pid): return [
        {"id":"q","name":"Queued","group":"unstarted"},
        {"id":"t","name":"Todo","group":"unstarted","default":True}]
    def update_work_item(self, pid, iid, body): self.patches.append((iid, body))
fc = FakeClient()
ordered = [
  {"tie":"p:10","status":"todo","priority":"high","due":"","is_parked":False},
  {"tie":"p:11","status":"todo","priority":"high","due":"","is_parked":True},   # parked hold
]
out = m.enqueue_ordered({}, fc, ordered)
assert [iid for iid,_ in fc.patches] == ["10"], fc.patches          # parked not queued
assert any(r.get("skipped")=="parked" for r in out), out

# 4) issue_to_ready sets is_parked from the parked label ids.
issue = {"id":"i9","labels":["LP"],"state":{"group":"unstarted"}}
r = m.issue_to_ready(issue, "p", {}, {}, 1.0, parked_label_ids={"LP"})
assert r["is_parked"] is True, r
r2 = m.issue_to_ready(issue, "p", {}, {}, 1.0, parked_label_ids={"OTHER"})
assert r2["is_parked"] is False, r2
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "PB-141 claim_next_queued: two sessions claim DIFFERENT issues sequentially (no collision)" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

SID = {"Todo":"t","Queued":"q","Planning":"pl"}
STATES = [{"id":"t","name":"Todo","group":"unstarted","default":True},
          {"id":"q","name":"Queued","group":"unstarted"},
          {"id":"pl","name":"Planning","group":"started"}]

class Shared:
    """One in-memory store shared by both 'sessions' (like the live Plane)."""
    def __init__(self):
        self.issues = {
            "A": {"id":"A","name":"A","state":"q","sort_order":1000.0,"priority":"high","parent":None},
            "B": {"id":"B","name":"B","state":"q","sort_order":2000.0,"priority":"low","parent":None},
        }
    def list_states(self, pid): return list(STATES)
    def list_work_items(self, pid): return [dict(v) for v in self.issues.values()]
    def list_labels(self, pid): return []
    def list_modules(self, pid): return []
    def update_work_item(self, pid, iid, body): self.issues[iid].update(body)
    def get_work_item(self, pid, iid): return dict(self.issues[iid])

cfg = {"default_est_h": 2.0}
sh = Shared()
# Two sessions claim in turn (sequential calls model the common case + the verify
# guarantees safety even if interleaved). Distinct session tokens → distinct sentinels.
c1 = m.claim_next_queued(cfg, sh, ["p"], "1001")
c2 = m.claim_next_queued(cfg, sh, ["p"], "2002")
got = sorted([c1["tie"].split(":")[-1], c2["tie"].split(":")[-1]])
assert got == ["A","B"], got                       # they took DIFFERENT issues
# both claimed issues are now OUT of the queue (in Planning)
assert sh.issues["A"]["state"]=="pl" and sh.issues["B"]["state"]=="pl"
# queue is now empty → a third claim returns None (nothing left)
assert m.claim_next_queued(cfg, sh, ["p"], "3003") is None

# Same-instant race: both sessions see A as top and both PATCH it; last write wins.
# Re-run with a store where only A is queued; the LOSER must fall through to None
# (not double-own A).
sh2 = Shared(); del sh2.issues["B"]                 # only A in the queue
winner = m.claim_next_queued(cfg, sh2, ["p"], "5005")
assert winner is not None and winner["tie"].endswith("A")
# A is claimed; a second claimer now finds the queue empty → None (no double-claim)
assert m.claim_next_queued(cfg, sh2, ["p"], "6006") is None
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "PB-146 rank_done_by_completion: Done column ranked newest-completed-first (smallest sort_order)" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class FakeClient:
    def __init__(self): self.patches=[]
    def list_states(self, pid): return [
        {"id":"d","name":"Landed","group":"completed"},
        {"id":"t","name":"Todo","group":"unstarted"}]
    def list_work_items(self, pid): return [
        {"id":"a","state":"d","completed_at":"2026-06-20T10:00:00Z"},
        {"id":"b","state":"d","completed_at":"2026-06-25T10:00:00Z"},  # newest
        {"id":"c","state":"d","completed_at":""},                       # no date → last
        {"id":"z","state":"t","completed_at":""},                       # not completed → ignored
    ]
    def update_work_item(self, pid, iid, body): self.patches.append((iid, body))

fc = FakeClient()
out = m.rank_done_by_completion({}, fc, ["p"])
ranked = [(iid, body["sort_order"]) for iid, body in fc.patches]
# Only Done issues touched; the Todo issue z is never patched.
assert [iid for iid,_ in ranked] == ["b","a","c"], ranked   # newest→oldest→undated
# newest (b) gets the smallest sort_order so it floats to the top of the column
assert ranked[0][1] < ranked[1][1] < ranked[2][1], ranked
assert all(set(body.keys())=={"sort_order"} for _,body in fc.patches)  # state untouched
assert all(r.get("ok") for r in out)
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "PB-130 STAGE_TO_STATE maps the auto-exec stages to pipeline states" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.STAGE_TO_STATE=={"plan":"Planning","implement":"Building","test":"Testing","ship":"Shipped","land":"Shipped"}, m.STAGE_TO_STATE
# every mapped state name is a real pipeline state in the started group
by={s["name"]:s for s in m.PIPELINE_STATES}
for stage,name in m.STAGE_TO_STATE.items():
    assert name in by, name
    assert by[name]["group"]=="started", (stage,name)
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "PB-130 build_status_body to_state targets the named state, falls back to group default" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# A pipeline project: distinct started-group states by name.
pipeline=[
  {"id":"plan","name":"Planning","group":"started","sequence":3},
  {"id":"build","name":"Building","group":"started","sequence":4},
  {"id":"test","name":"Testing","group":"started","sequence":5},
  {"id":"rev","name":"Shipped","group":"started","sequence":6},
  {"id":"done","name":"Landed","group":"completed","default":True},
]
assert m.build_status_body("doing",pipeline,to_state="Building")=={"state":"build"}
assert m.build_status_body("doing",pipeline,to_state="Shipped")=={"state":"rev"}
# case-insensitive name match (pick_state_id lowercases)
assert m.build_status_body("doing",pipeline,to_state="testing")=={"state":"test"}
# Non-pipeline project (no named states): to_state degrades to the started default.
legacy=[{"id":"prog","group":"started","default":True},{"id":"done","group":"completed","default":True}]
assert m.build_status_body("doing",legacy,to_state="Building")=={"state":"prog"}
# to_state=None keeps the old behaviour exactly.
assert m.build_status_body("doing",legacy)=={"state":"prog"}
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "PB-130 state_group_id reads expanded-dict or bare-uuid state" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.state_group_id({"state":{"id":"abc","name":"Building"}})=="abc"
assert m.state_group_id({"state":"xyz"})=="xyz"
assert m.state_group_id({})  is None
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "PB-130 resolve_state_id: matches by name (ci), by status word, None on miss" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
states=[
  {"id":"bk","name":"Backlog","group":"backlog"},
  {"id":"td","name":"Todo","group":"unstarted","default":True},
  {"id":"bd","name":"Building","group":"started"},
]
# by exact name (case-insensitive)
assert m.resolve_state_id(states,"Backlog")=="bk"
assert m.resolve_state_id(states,"backlog")=="bk"
# by pbrain status word → that group's default/lowest
assert m.resolve_state_id(states,"todo")=="td"      # unstarted default
assert m.resolve_state_id(states,"doing")=="bd"     # started
# name takes precedence over status word when both could match
# (none here), and a miss / empty returns None
assert m.resolve_state_id(states,"Nonexistent") is None
assert m.resolve_state_id(states,"") is None
assert m.resolve_state_id(states,None) is None
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "PB-143 issue_description_text: falls back to stripped HTML when description_stripped is null" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# Plane's PATCH quirk: description_html set, description_stripped null/missing.
html = "<h2>Implementation Plan</h2><p>Do the <strong>thing</strong>.</p>"
issue = {"description_html": html, "description_stripped": None}
txt = m.issue_description_text(issue)
assert "Implementation Plan" in txt, txt          # marker survives → has_plan works
assert "Do the thing" in txt, txt                 # body text recovered
assert m.PLAN_MARKER.lower() in txt.lower()        # the exact has_plan predicate
# Prefer the server-stripped form when present (no double work).
assert m.issue_description_text(
    {"description_html": html, "description_stripped": "PRE"}) == "PRE"
# Genuinely empty stays empty.
assert m.issue_description_text({"description_html": "", "description_stripped": ""}) == ""
assert m.issue_description_text({}) == ""
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "PB-130 seed_pipeline_states: creates work states, keeps Todo, removes In Progress after re-point (fake client)" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class Fake:
    """In-memory Plane: default 5 states + 2 issues (one on In Progress)."""
    def __init__(self):
        self.states=[
          {"id":"bk","name":"Backlog","group":"backlog","default":False},
          {"id":"td","name":"Todo","group":"unstarted","default":True},
          {"id":"ip","name":"In Progress","group":"started","default":False},
          {"id":"dn","name":"Done","group":"completed","default":False},
          {"id":"cx","name":"Cancelled","group":"cancelled","default":False},
        ]
        self.items=[{"id":"i1","state":"td"},{"id":"i2","state":"ip"}]
        self._n=0
    def _has_internal_auth(self): return True
    def list_states(self,pid): return [dict(s) for s in self.states]
    def list_work_items(self,pid): return [dict(it) for it in self.items]
    def create_state(self,pid,name,group,color=None,default=False,sequence=None):
        self._n+=1; sid="new%d"%self._n
        self.states.append({"id":sid,"name":name,"group":group,"default":default})
        return {"id":sid}
    def update_state(self,pid,sid,**kw):
        for s in self.states:
            if s["id"]==sid: s.update({k:v for k,v in kw.items() if v is not None})
        return {}
    def delete_state(self,pid,sid):
        self.states=[s for s in self.states if s["id"]!=sid]; return {}
    def update_work_item(self,pid,iid,body):
        for it in self.items:
            if it["id"]==iid: it["state"]=body.get("state",it["state"])
        return {}

c=Fake()
out=m.seed_pipeline_states(c, "P")
names=[s["name"] for s in c.states]
# the 4 work states were created
assert set(["Planning","Building","Testing","Shipped"]).issubset(set(names)), names
# Todo kept, In Progress removed
assert "Todo" in names and "In Progress" not in names, names
assert "In Progress" in out["removed"], out
# the issue that was on In Progress got re-pointed to Building
building_id=next(s["id"] for s in c.states if s["name"]=="Building")
assert any(it["id"]=="i2" and it["state"]==building_id for it in c.items), c.items
# idempotent: a second seed makes no further removals/creates
out2=m.seed_pipeline_states(c, "P")
assert out2["created"]==[] and out2["removed"]==[], out2
# no internal auth → manual steps, no writes
class NoAuth(Fake):
    def _has_internal_auth(self): return False
na=NoAuth(); o=m.seed_pipeline_states(na,"P")
assert o.get("manual_steps") and "In Progress" in [s["name"] for s in na.states]
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "PB-XXX rename_pipeline_states: Review→Shipped, Done→Landed in place (id kept), idempotent" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

# Sanity: the rename map is the two states we expect.
assert m.STATE_RENAMES == {"Review":"Shipped","Done":"Landed"}, m.STATE_RENAMES

class Fake:
    """A project still on the OLD names (Review/Done)."""
    def __init__(self):
        self.states=[
          {"id":"td","name":"Todo","group":"unstarted"},
          {"id":"rev","name":"Review","group":"started"},
          {"id":"dn","name":"Done","group":"completed"},
        ]
        self.patches=[]
    def list_states(self,pid): return [dict(s) for s in self.states]
    def update_state(self,pid,sid,name=None,**kw):
        self.patches.append((sid,name))
        for s in self.states:
            if s["id"]==sid and name is not None: s["name"]=name
        return {}

fc=Fake()
out=m.rename_pipeline_states(fc,"P")
# Renamed both, in place — the SAME ids were patched (no create/delete).
assert sorted(out["renamed"])==["Done→Landed","Review→Shipped"], out
assert set(fc.patches)=={("rev","Shipped"),("dn","Landed")}, fc.patches
names={s["name"] for s in fc.states}
assert names=={"Todo","Shipped","Landed"}, names
# groups are untouched by the rename
g={s["name"]:s["group"] for s in fc.states}
assert g["Shipped"]=="started" and g["Landed"]=="completed", g

# Idempotent: a second run renames nothing (already on the new names) and records
# them as already-done; no further PATCHes.
fc.patches=[]
out2=m.rename_pipeline_states(fc,"P")
assert out2["renamed"]==[], out2
assert sorted(out2["already"])==["Landed","Shipped"], out2
assert fc.patches==[], fc.patches

# A project that never had Review/Done is a clean no-op (no renamed, no already).
class Bare:
    def list_states(self,pid): return [{"id":"x","name":"Todo","group":"unstarted"}]
    def update_state(self,pid,sid,**kw): raise AssertionError("should not write")
out3=m.rename_pipeline_states(Bare(),"P")
assert out3["renamed"]==[] and out3["already"]==[] and not out3["error"], out3
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "filter_ready drops backlog by default and orders by priority then due" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
items=[
  {"_group":"backlog","priority":"urgent","due":"","id":1},
  {"_group":"started","priority":"low","due":"","id":2},
  {"_group":"unstarted","priority":"high","due":"","id":3},
]
assert [x["id"] for x in m.filter_ready([dict(i) for i in items])]==[3,2]
assert [x["id"] for x in m.filter_ready([dict(i) for i in items], include_backlog=True)]==[1,3,2]
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

# --- spec/approval gate (PB-45) ---------------------------------------------
@test "issue_to_ready carries approved flag from plan-approved label ids" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
states={"s":{"id":"s","group":"unstarted","name":"Todo","sequence":1}}
approved={"id":"i1","name":"A","state":"s","labels":["L1","Lx"],"parent":None}
plain   ={"id":"i2","name":"B","state":"s","labels":[{"id":"L2"}],"parent":"p"}
ra=m.issue_to_ready(approved,"P",states,{},2,None,approved_label_ids={"L1"})
rb=m.issue_to_ready(plain,  "P",states,{},2,None,approved_label_ids={"L1"})
assert ra["approved"] is True
assert rb["approved"] is False and rb["is_sub"] is True
# no approved ids known -> never approved
assert m.issue_to_ready(approved,"P",states,{},2,None)["approved"] is False
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "filter_ready approved_only keeps only approved rows" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
items=[
  {"_group":"unstarted","priority":"high","due":"","id":1,"approved":True},
  {"_group":"started","priority":"urgent","due":"","id":2,"approved":False},
]
assert [x["id"] for x in m.filter_ready([dict(i) for i in items])]==[2,1]
appr=m.filter_ready([dict(i) for i in items], approved_only=True)
assert [x["id"] for x in appr]==[1] and all(x["approved"] for x in appr)
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "approved_label_ids matches plan-approved fuzzily and degrades on error" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class Ok:
    def list_labels(self,p): return [{"id":"L1","name":"Plan-Approved"},{"id":"L2","name":"bug"}]
class Boom:
    def list_labels(self,p): raise m.PlaneError("x")
assert m.approved_label_ids(Ok(),"P")=={"L1"}
assert m.approved_label_ids(Boom(),"P")==set()
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "spec subcommand is registered in the CLI parser" {
  run python3 "$PLANE" spec --help
  [ "$status" -eq 0 ]; [[ "$output" == *"name fragment"* ]]
}

@test "spec_context surfaces user comments as authoritative, newest last (PB-61)" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class FC:
    def get_work_item(self,pid,iid):
        return {"id":"i1","name":"do the thing","description_stripped":"old desc",
                "description_html":"<p>old desc</p>","labels":[],"priority":"high"}
    def list_comments(self,pid,iid):
        # returned out of order on purpose; spec_context must sort oldest->newest
        return [
          {"id":"c2","created_at":"2026-06-02T00:00:00Z","comment_stripped":"actually use X"},
          {"id":"c1","created_at":"2026-06-01T00:00:00Z","comment_html":"<p>first note</p>"},
          {"id":"c3","created_at":"2026-06-03T00:00:00Z","comment_stripped":"   "},  # blank -> dropped
        ]
# isolate from find_issues / label lookups; we only test the comments wiring
m.find_issues = lambda cfg,client,ref,project_ref=None: [
    {"tie":"P:i1","id":"PB-1","issue_id":"i1","project":"pb","project_id":"P","state":"Todo"}]
m.approved_label_ids = lambda client,pid: set()
res = m.spec_context({"projects":[{"id":"P","name":"pb","shortcut":"pb"}]}, FC(), "PB-1")
assert res["status"]=="ok", res
assert res["comments_authoritative"] is True
bodies=[c["body"] for c in res["comments"]]
assert bodies==["first note","actually use X"], bodies   # sorted + html-stripped + blank dropped
assert res["comments"][-1]["body"]=="actually use X"      # newest is last
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "spec_context tolerates a comments-read failure (best-effort) (PB-61)" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class FC:
    def get_work_item(self,pid,iid):
        return {"id":"i1","name":"t","description_stripped":"d","description_html":"<p>d</p>",
                "labels":[],"priority":"none"}
    def list_comments(self,pid,iid): raise m.PlaneError("boom")
m.find_issues = lambda cfg,client,ref,project_ref=None: [
    {"tie":"P:i1","id":"PB-1","issue_id":"i1","project":"pb","project_id":"P","state":"Todo"}]
m.approved_label_ids = lambda client,pid: set()
res = m.spec_context({"projects":[{"id":"P","name":"pb","shortcut":"pb"}]}, FC(), "PB-1")
assert res["status"]=="ok"
assert res["comments"]==[]            # failure degrades to empty, gate not blocked
assert res["comments_authoritative"] is True
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "strip_html drops tags, breaks on block ends, unescapes (PB-61)" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.strip_html("")==""
assert m.strip_html("<p>use &amp; keep</p>")=="use & keep"
assert m.strip_html("a<br>b").splitlines()==["a","b"]
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

# --- config + backend switch ------------------------------------------------
@test "setup writes a 0600 config with backend=plane" {
  run PY setup --base-url https://api.plane.so --api-key SECRET --workspace ws --project pid
  [ "$status" -eq 0 ]
  [[ "$output" == *PLANE_CONFIGURED*backend=plane* ]]
  [ -f "$XDG_CONFIG_HOME/pbrain/plane.json" ]
  grep -q '"api_key": "SECRET"' "$XDG_CONFIG_HOME/pbrain/plane.json"
  perm="$(stat -f '%Lp' "$XDG_CONFIG_HOME/pbrain/plane.json" 2>/dev/null || stat -c '%a' "$XDG_CONFIG_HOME/pbrain/plane.json")"
  [ "$perm" = "600" ]
}

@test "use switches the backend in config" {
  PY setup --base-url https://api.plane.so --api-key SECRET --workspace ws --project pid >/dev/null
  run PY use markdown
  [ "$status" -eq 0 ]; [[ "$output" == *"PLANE_BACKEND markdown"* ]]
  grep -q '"backend": "markdown"' "$XDG_CONFIG_HOME/pbrain/plane.json"
}

@test "ping fails cleanly with a clear error when unreachable" {
  PY setup --base-url http://127.0.0.1:9 --api-key SECRET --workspace ws --project pid >/dev/null
  run PY ping
  [[ "$output" == *PLANE_ERROR* ]]
}

# --- secret redaction shield (PB-16) ----------------------------------------
@test "redact() masks registered secrets; short values are left alone" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.register_secret("plane_api_0123456789abcdef")
m.register_secret("short")          # < 8 chars -> not a secret, never masked
out = m.redact("tok=plane_api_0123456789abcdef end=short")
print("ok" if ("plane_api_0123456789abcdef" not in out
               and m._REDACTION in out and "end=short" in out) else "BAD:%s" % out)
PYEOF
  [ "$status" -eq 0 ] && [[ "$output" == *ok* ]]
}

@test "load_config registers the api_key as a redaction secret" {
  PY setup --base-url https://api.plane.so --api-key plane_api_supersecrettoken --workspace ws --project pid >/dev/null
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.load_config()
print("ok" if m.redact("key plane_api_supersecrettoken x")
      == "key %s x" % m._REDACTION else "BAD")
PYEOF
  [ "$status" -eq 0 ] && [[ "$output" == *ok* ]]
}

@test "install_redaction_shield scrubs a registered secret from real stdout" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.register_secret("plane_api_TOPSECRETvalue123")
m.install_redaction_shield()
print("leaking plane_api_TOPSECRETvalue123 here")   # even a direct print is masked
PYEOF
  [ "$status" -eq 0 ] && [[ "$output" != *plane_api_TOPSECRETvalue123* ]] && [[ "$output" == *REDACTED* ]]
}

# --- projects.sh seams ------------------------------------------------------
@test "ready_json routes to Plane and degrades to [] when unreachable" {
  export PBRAIN_PLANE_BASE_URL=http://127.0.0.1:9 PBRAIN_PLANE_API_KEY=SECRET
  export PBRAIN_PLANE_WORKSPACE=ws PBRAIN_PLANE_PROJECT=pid
  source "$REPO_ROOT/lib/vault.sh"
  run pbrain_projects_ready_json
  [ "$status" -eq 0 ]
  [ "$output" = "[]" ]   # never fatal, never partial garbage
}

@test "seams degrade to []/{} when Plane is not configured" {
  source "$REPO_ROOT/lib/vault.sh"
  run pbrain_plane_configured
  [ "$status" -ne 0 ]                       # not configured
  run pbrain_projects_ready_json;    [ "$output" = "[]" ]
  run pbrain_projects_registry_json; [ "$output" = "[]" ]
  run pbrain_projects_progress_json; [ "$output" = "{}" ]
}

@test "pbrain_plane_configured is true once a config with an api_key exists" {
  PY setup --base-url https://api.plane.so --api-key SECRET --workspace ws --project pid >/dev/null
  source "$REPO_ROOT/lib/vault.sh"
  run pbrain_plane_configured
  [ "$status" -eq 0 ]
}

# --- multi-project pure fns (no network) ------------------------------------
@test "normalize_registry synthesizes a one-entry registry from a lone project" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# back-compat: lone project → single synthesized entry
r = m.normalize_registry({"project":"uuid-1"})
assert r == [{"id":"uuid-1","name":"uuid-1","shortcut":""}], r
# explicit registry wins, fields filled in
r = m.normalize_registry({"projects":[{"id":"a","name":"Lettuce","shortcut":"lt"},{"id":"b"}]})
assert r[0]["shortcut"]=="lt" and r[1]["name"]=="b", r
# none → empty
assert m.normalize_registry({}) == []
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "resolve_project_ref matches id, shortcut, name (ci) and uuid passthrough" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
cfg = {"projects":[{"id":"11111111-1111-1111-1111-111111111111","name":"Lettuce","shortcut":"lt"}]}
assert m.resolve_project_ref(cfg,"lt")==cfg["projects"][0]["id"]
assert m.resolve_project_ref(cfg,"LETTUCE")==cfg["projects"][0]["id"]
assert m.resolve_project_ref(cfg,cfg["projects"][0]["id"])==cfg["projects"][0]["id"]
# unknown but uuid-shaped → passthrough; unknown junk → None
assert m.resolve_project_ref(cfg,"22222222-2222-2222-2222-222222222222")=="22222222-2222-2222-2222-222222222222"
assert m.resolve_project_ref(cfg,"nope") is None
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "thinness_flags treats absent fields as can't-assess, empty as thin" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# present-but-empty description + priority → those two flags. no_estimate is
# intentionally NOT flagged (estimate_point needs a UUID scheme; see the fn docstring).
full = {"description_html":"<p></p>","estimate_point":0,"priority":"none"}
assert sorted(m.thinness_flags(full,0))==["no_description","no_priority"]
# absent fields → no flags
assert m.thinness_flags({}, None)==[]
# populated → no flags
ok = {"description_html":"<p>real</p>","estimate_point":3,"priority":"high"}
assert m.thinness_flags(ok,2)==[]
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "build_enrich_body maps fields and rejects unknowns" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.build_enrich_body("description","x")=={"description_html":"x"}
assert m.build_enrich_body("priority","high")=={"priority":"high"}
assert m.build_enrich_body("estimate",3)=={"estimate_point":3}
assert m.build_enrich_body("due","2026-07-01")=={"target_date":"2026-07-01"}
try:
    m.build_enrich_body("bogus","x"); raise SystemExit("should have raised")
except m.PlaneError:
    pass
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "issue-ref + fuzzy helpers resolve names/ids purely" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# parse_issue_ref: url | id | hyphenless id | bare seq | name
assert m.parse_issue_ref("http://x/pb/browse/PB-26/")==("PB",26)
assert m.parse_issue_ref("PB-26")==("PB",26)
assert m.parse_issue_ref("pb8")==("PB",8)       # hyphenless, lowercased (PB-97)
assert m.parse_issue_ref("PB8")==("PB",8)       # hyphenless, uppercase
assert m.parse_issue_ref("26")==(None,26)
assert m.parse_issue_ref("fix the bug")==(None,None)
# match_label (normalised)
labs=[{"id":"l1","name":"Backend"},{"id":"l2","name":"bug fix"}]
assert m.match_label(labs,"backend")["id"]=="l1"
assert m.match_label(labs,"BUG-FIX")["id"]=="l2"
assert m.match_label(labs,"frontend") is None
# match_member: unique vs ambiguous
mem=[{"id":"u1","display_name":"Sam Lee","email":"sam@x.com"},
     {"id":"u2","display_name":"Sammy","email":"sammy@x.com"}]
assert m.match_member(mem,"u1")[0]["id"]=="u1"
assert m.match_member(mem,"Sammy")[0]["id"]=="u2"
assert m.match_member(mem,"sam")[0] is None and len(m.match_member(mem,"sam")[1])==2
# merge_labels
assert m.merge_labels(["a","b"],add=["b","c"])==["a","b","c"]
assert m.merge_labels(["a","b"],remove=["a"])==["b"]
assert m.merge_labels(["a"],replace=["x","x","y"])==["x","y"]
# CreationGuard cap
g=m.CreationGuard(max_creates=1); assert g.allow(); g.record(); assert not g.allow()
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "resolve_label_refs reuses existing, creates within guard, skips over cap" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class FC:
    def __init__(self): self.created=[]
    def list_labels(self,pid): return [{"id":"l1","name":"backend"}]
    def create_label(self,pid,name,color=None):
        nid="n%d"%len(self.created); self.created.append(name); return {"id":nid,"name":name}
fc=FC(); g=m.CreationGuard(max_creates=1)
res=m.resolve_label_refs(fc,"p",["Backend","urgent","frontend"],guard=g)
assert res["ids"][0]=="l1"                         # reused (fuzzy 'Backend'->'backend')
assert [c["name"] for c in res["created"]]==["urgent"]
assert res["skipped"]==["frontend"]                # guard cap hit
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "enrich routes label/state/comment fields and find_issues resolves by id+name" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class FC:
    def __init__(self):
        self.patches=[]; self.comments=[]; self.labels=[{"id":"l1","name":"backend"}]
        self.item={"id":"i1","sequence_id":7,"name":"fix login bug",
                   "state":{"name":"Todo","group":"unstarted"},"priority":"high",
                   "labels":[],"parent":None}
    def list_projects(self): return [{"id":"P","identifier":"PB","name":"pb"}]
    def list_work_items(self,pid): return [self.item] if pid=="P" else []
    def get_work_item(self,pid,iid): return self.item
    def update_work_item(self,pid,iid,body):
        self.patches.append(body)
        if "labels" in body: self.item["labels"]=body["labels"]
        return {}
    def list_labels(self,pid): return self.labels
    def create_label(self,pid,name,color=None):
        nid="l%d"%(len(self.labels)+1); o={"id":nid,"name":name}; self.labels.append(o); return o
    def list_members(self,pid): return [{"id":"u1","display_name":"kylo","email":"k@x.com"}]
    def list_states(self,pid): return [{"id":"s1","name":"Todo","group":"unstarted","default":True},
                                       {"id":"s2","name":"In Progress","group":"started"}]
    def create_comment(self,pid,iid,html): self.comments.append(html); return {}
cfg={"projects":[{"id":"P","name":"pb","shortcut":"pb"}]}
fc=FC()
out=m.enrich(cfg,fc,[
  {"tie":"P:i1","field":"tag","value":"urgent"},
  {"tie":"P:i1","field":"state","value":"In Progress"},
  {"tie":"P:i1","field":"comment","value":"looks good"},
])
assert all(r["ok"] for r in out), out
assert {"labels":["l2"]} in fc.patches              # created 'urgent' + patched
assert {"state":"s2"} in fc.patches                 # state-by-name -> id
assert fc.comments==["<p>looks good</p>"]           # comment wrapped
assert [c["id"] for c in m.find_issues(cfg,fc,"PB-7")]==["PB-7"]
assert [c["id"] for c in m.find_issues(cfg,fc,"login")]==["PB-7"]
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "explode_context resolves one issue with subissues; branches on ambiguous/none" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class FC:
    items={"i1":{"id":"i1","sequence_id":7,"name":"build payment flow",
                 "state":{"name":"Todo","group":"unstarted"},"priority":"high","parent":None},
           "i2":{"id":"i2","sequence_id":8,"name":"build payment refunds",
                 "state":{"name":"In Progress","group":"started"},"priority":"medium","parent":None}}
    def list_projects(self): return [{"id":"P","identifier":"PB","name":"pb"}]
    def list_work_items(self,pid): return list(self.items.values()) if pid=="P" else []
    def get_work_item(self,pid,iid):
        # full record returns state as a BARE id (unlike list_work_items)
        return {"id":"i1","name":"build payment flow","description_stripped":"Take payments end to end",
                "priority":"high","state":"s1","estimate_point":None}
    def list_states(self,pid): return [{"id":"s1","name":"Todo","group":"unstarted"},
                                       {"id":"s2","name":"In Progress","group":"started"}]
    def list_sub_issues(self,pid,iid): return [{"id":"c1","name":"wire stripe","state":"s1"},
                                               {"id":"c2","name":"add webhook","state":"s2"}]
cfg={"projects":[{"id":"P","name":"pb","shortcut":"pb"}]}
fc=FC()
ctx=m.explode_context(cfg,fc,"PB-7")
assert ctx["status"]=="ok", ctx
assert ctx["state"]=="Todo"                                   # from the find card, not the bare id
assert ctx["description"]=="Take payments end to end"
assert ctx["has_estimate_scale"] is False and ctx["estimate_points"]==[]
assert [s["title"] for s in ctx["existing_subissues"]]==["wire stripe","add webhook"]
assert ctx["existing_subissues"][1]["state"]=="In Progress"   # bare id -> resolved name
amb=m.explode_context(cfg,fc,"build payment")
assert amb["status"]=="ambiguous" and len(amb["candidates"])==2, amb
non=m.explode_context(cfg,fc,"zzz no such issue")
assert non["status"]=="none" and non["candidates"]==[], non
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "file_context: generic intake context (types/labels/estimate/dedupe), branches, never writes (PB-67)" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

# consts: types cover all asked-for kinds; refactor/improvement fold into chore/feature
assert set(m.WORK_TYPES)=={"bug","feature","docs","chore","refactor","improvement"}, m.WORK_TYPES
assert m.WORK_TYPES["refactor"]["label"]=="chore" and m.WORK_TYPES["improvement"]["label"]=="feature"
assert m.SEVERITY_TO_PRIORITY["crash"]=="urgent" and m.SEVERITY_TO_PRIORITY["polish"]=="low"

class C:
    def __init__(self): self.writes=[]
    def list_labels(self,pid): return [{"id":"b","name":"bug"},{"id":"f","name":"feature"}]
    def list_states(self,pid): return [{"id":"s1","name":"Todo","group":"unstarted"},
                                       {"id":"sd","name":"Landed","group":"completed"}]
    def list_projects(self): return [{"id":"P","identifier":"PB"}]
    def list_work_items(self,pid):
        return [{"sequence_id":98,"name":"open item","labels":[],"state":"s1"},
                {"sequence_id":50,"name":"done item","labels":[],"state":"sd"}]
    def create_work_item(self,*a,**k): self.writes.append("c"); raise AssertionError("wrote!")
    def update_work_item(self,*a,**k): self.writes.append("u"); raise AssertionError("wrote!")

# estimates: stub ensure_estimate_scale so the test is offline + deterministic
m.ensure_estimate_scale = lambda cfg, client, pid: {"points": {"1": "u1", "2": "u2", "3": "u3"}}

cfg={"project":"P","projects":[{"id":"P","name":"pb","shortcut":"pb"}]}
c=C()
r=m.file_context(cfg,c,"add a dark mode toggle")
assert r["status"]=="ok" and r["project_id"]=="P", r
assert r["work_types"]["bug"]=="bug" and r["work_types"]["refactor"]=="chore", r["work_types"]
assert r["has_estimate_scale"] is True and r["estimate_points"]==["1","2","3"], r
# dedupe lists OPEN items only (PB-98), not the done one
assert [i["id"] for i in r["recent_open_items"]]==["PB-98"], r["recent_open_items"]
assert c.writes==[], "file_context must not write"

# several projects, none named -> need_project; bad ref -> unknown_project
cfg2={"projects":[{"id":"P","name":"pb"},{"id":"Q","name":"yt"}]}
assert m.file_context(cfg2,C(),"x")["status"]=="need_project"
assert m.file_context(cfg2,C(),"x",project_ref="nope")["status"]=="unknown_project"
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "seed_convention_labels creates missing labels, recolors colorless/mismatched existing, idempotent (PB-70)" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

names = {l["name"] for l in m.CONVENTION_LABELS}
assert names == {"bug","feature","chore","docs"}, names   # canon = type set
# The seeder seeds the convention types + plan-approved + the per-gate auto:* labels (PB-94)
# + the auto:groomed quality-vet marker (which is NOT a pipeline gate).
seed_names = {s["name"] for s in m._seed_label_specs()}
assert {"bug","feature","chore","docs", m.APPROVED_LABEL} <= seed_names, seed_names
assert {"auto:%s" % g for g in m.GATE_NAMES} <= seed_names, seed_names
assert "auto:groomed" in seed_names, seed_names
assert "groomed" not in m.GATE_NAMES, "auto:groomed must NOT be a pipeline gate"
# the marker never appears in auto-stage suggestions (gate machinery ignores it)
assert "groomed" not in m.suggest_auto_stages({}, approved=True, est_hours=1.0)

class FC:
    def __init__(self, existing): self.labels=list(existing); self.created=[]; self.recolored=[]
    def list_labels(self, pid): return list(self.labels)
    def create_label(self, pid, name, color=None):
        rec={"id":"n%d"%len(self.created),"name":name,"color":color}
        self.created.append(name); self.labels.append(rec); return rec
    def update_label(self, pid, label_id, color=None, name=None):
        for l in self.labels:
            if l.get("id")==label_id:
                if color: l["color"]=color
                if name: l["name"]=name
        self.recolored.append(label_id); return {"id":label_id,"color":color}

# Start with one already present, fuzzily ('Bug' vs 'bug') but COLORLESS -> it is
# RECOLORED to the canonical color (not recreated); the rest of the seed set
# (convention types minus bug + plan-approved + auto:* gates) is created.
fc=FC([{"id":"l1","name":"Bug","color":None}])
r1=m.seed_convention_labels(fc,"p")
expected_created = sorted((seed_names - {"bug"}))
assert sorted(r1["created"])==expected_created, (r1, expected_created)
assert r1["recolored"]==["bug"], r1                 # colorless existing -> repaired
assert "bug" not in r1["existing"], r1
assert "error" not in r1, r1
# colors are applied on create
assert any(l.get("color") for l in fc.labels if l["name"]=="feature"), fc.labels
# and the recolor actually patched the existing 'Bug' label to the spec color
bugspec=next(s for s in m._seed_label_specs() if s["name"]=="bug")
assert any(l.get("color")==bugspec["color"] for l in fc.labels if l["name"]=="Bug"), fc.labels

# Idempotent: a second pass creates nothing and recolors nothing (colors now match).
r2=m.seed_convention_labels(fc,"p")
assert r2["created"]==[], r2
assert r2["recolored"]==[], r2
assert sorted(r2["existing"])==sorted(seed_names), r2

# list_labels failure degrades to a reported error, never raises.
class Boom:
    def list_labels(self,pid): raise m.PlaneError("nope")
rb=m.seed_convention_labels(Boom(),"p")
assert rb["created"]==[] and "error" in rb, rb
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "list_sub_issues: uses /sub-issues/ payload when present; parent-scan fallback when endpoint 404s (PB-67)" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

# A child whose parent points UP at the parent, plus an unrelated issue.
KIDS=[{"id":"c1","name":"wire stripe","parent":"PARENT","state":{"name":"Backlog","group":"backlog"}},
      {"id":"x9","name":"unrelated","parent":None,"state":{"name":"Todo","group":"unstarted"}}]

# Build a real Client without running __init__ (no network/creds needed); we only
# override the two methods list_sub_issues touches.
def client(endpoint):
    c = m.PlaneClient.__new__(m.PlaneClient)
    def list_work_items(pid): return list(KIDS)
    c.list_work_items = list_work_items
    if endpoint == "ok":
        c._request = lambda method, path, **kw: {"sub_issues":[{"id":"c1","name":"wire stripe","state":"s1"}]}
    elif endpoint == "404":
        def boom(method, path, **kw): raise m.PlaneError("HTTP 404 Page not found")
        c._request = boom
    return c

# fast path: endpoint returns a payload -> use it verbatim (no parent-scan)
subs = client("ok").list_sub_issues("PARENT","PARENT")
assert [s["id"] for s in subs]==["c1"], subs

# fallback: endpoint 404s -> scan work items for parent==issue_id
subs = client("404").list_sub_issues("PARENT","PARENT")
assert [s["id"] for s in subs]==["c1"], subs          # only the real child, not x9
assert all(s["parent"]=="PARENT" for s in subs), subs
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "subtree_context: parent target -> not-done children as ready rows (sorted, incl backlog, done/cancelled excluded); leaf -> none; branches" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class FC:
    # parent p1 (seq 7) has five children: two OPEN (different priority), one BACKLOG,
    # one DONE, one CANCELLED. a separate leaf l1 (seq 9) has no children at all.
    # PB-81: a parent execute target drives EVERY not-done child, backlog included.
    items={
      "p1":{"id":"p1","sequence_id":7,"name":"build payment flow",
            "state":{"name":"In Progress","group":"started"},"priority":"high","parent":None},
      "cA":{"id":"cA","sequence_id":11,"name":"add webhook","parent":"p1",
            "state":{"name":"Todo","group":"unstarted"},"priority":"medium"},
      "cB":{"id":"cB","sequence_id":12,"name":"wire stripe","parent":"p1",
            "state":{"name":"In Progress","group":"started"},"priority":"high"},
      "cBack":{"id":"cBack","sequence_id":14,"name":"sample data gen","parent":"p1",
               "state":{"name":"Backlog","group":"backlog"},"priority":"medium"},
      "cDone":{"id":"cDone","sequence_id":13,"name":"already shipped","parent":"p1",
               "state":{"name":"Done","group":"completed"},"priority":"high"},
      "cCancel":{"id":"cCancel","sequence_id":15,"name":"scrapped idea","parent":"p1",
                 "state":{"name":"Cancelled","group":"cancelled"},"priority":"high"},
      "l1":{"id":"l1","sequence_id":9,"name":"standalone leaf task",
            "state":{"name":"Todo","group":"unstarted"},"priority":"low","parent":None},
    }
    def list_projects(self): return [{"id":"P","identifier":"PB","name":"pb"}]
    def list_work_items(self,pid): return list(self.items.values()) if pid=="P" else []
    def list_states(self,pid): return [{"id":"s1","name":"Todo","group":"unstarted"},
                                       {"id":"s2","name":"In Progress","group":"started"},
                                       {"id":"s0","name":"Backlog","group":"backlog"},
                                       {"id":"s3","name":"Done","group":"completed"},
                                       {"id":"s4","name":"Cancelled","group":"cancelled"}]
    def list_modules(self,pid): return []
    def list_module_issues(self,pid,mid): return []
cfg={"projects":[{"id":"P","name":"pb","shortcut":"pb"}],"default_est_h":2}
fc=FC()

# PARENT target: not-done children, sorted priority -> due -> id.
# high cB, then medium cA / cBack by id; done + cancelled excluded.
ctx=m.subtree_context(cfg,fc,"PB-7")
assert ctx["status"]=="ok", ctx
assert ctx["has_open_children"] is True, ctx
ids=[c["id"] for c in ctx["children"]]
assert ids==[12,11,14], ids                            # cB(high) > cA(med id11) > cBack(med id14); done+cancelled out
assert all(c["is_sub"] for c in ctx["children"]), ctx  # every child flagged is_sub
assert ctx["children"][0]["tie"]=="P:cB"               # full tie carried for execute
assert ctx["children"][0]["project"]=="pb"
# the backlog child carries a sane status so execute treats it as a real unit of work
back=[c for c in ctx["children"] if c["id"]==14][0]
assert back["tie"]=="P:cBack" and back["status"]=="todo", back

# LEAF target: no children -> treat the issue itself as the unit of work
leaf=m.subtree_context(cfg,fc,"PB-9")
assert leaf["status"]=="ok" and leaf["has_open_children"] is False and leaf["children"]==[], leaf

# none branch like explode/spec (no card matches the fragment)
non=m.subtree_context(cfg,fc,"zzz no such issue")
assert non["status"]=="none" and non["candidates"]==[], non
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "estimate scale: parse payload, resolve value<->uuid, points->hours" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
payload = [{"id":"e1","type":"points","last_used":True,"name":"Points",
            "points":[{"id":"u1","value":"1"},{"id":"u2","value":"2"},
                      {"id":"u5","value":"5"}]}]
scale = m.parse_estimate_payload(payload)
assert scale["type"]=="points" and scale["points"]=={"1":"u1","2":"u2","5":"u5"}, scale
cfg={"estimates":{"P":dict(scale, hours_per_point=1.5)}}
assert m.est_value_to_uuid(cfg,"P")=={"1":"u1","2":"u2","5":"u5"}
assert m.est_uuid_to_points(cfg,"P")=={"u1":1.0,"u2":2.0,"u5":5.0}
assert m.est_uuid_to_hours(cfg,"P")=={"u1":1.5,"u2":3.0,"u5":7.5}   # value * hpp
# unconfigured project -> empty maps (no crash)
assert m.est_value_to_uuid(cfg,"Q")=={} and m.est_uuid_to_hours(cfg,"Q")=={}
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "issue_to_ready uses estimate hours when set, else default; no_estimate flag gated on scale" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
uuid_hours={"u5":7.5}
r=m.issue_to_ready({"id":"i","sequence_id":9,"estimate_point":"u5"},"P",{},{},2.0,uuid_hours)
assert r["est_h"]==7.5, r                                    # mapped estimate wins
r2=m.issue_to_ready({"id":"j","sequence_id":10,"estimate_point":None},"P",{},{},2.0,uuid_hours)
assert r2["est_h"]==2.0, r2                                  # fallback to default
r3=m.issue_to_ready({"id":"k","sequence_id":11},"P",{},{},2.0,None)
assert r3["est_h"]==2.0, r3                                  # no map at all -> default
# progress weight resolves uuid->points
assert m._est_of({"estimate_point":"u5"},{"u5":5.0})==5.0
assert m._est_of({"estimate_point":None},{"u5":5.0})==0.0
# no_estimate only when a scale exists
base={"estimate_point":None,"priority":"high","description_html":"<p>x</p>"}
assert m.thinness_flags(base, has_estimate_scale=True)==["no_estimate"]
assert m.thinness_flags(base, has_estimate_scale=False)==[]
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "enrich estimate resolves a point value to its estimate_point uuid (and clears)" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class FC:
    def __init__(self): self.patches=[]
    def get_work_item(self,pid,iid): return {"id":iid}
    def update_work_item(self,pid,iid,body): self.patches.append(body); return {}
cfg={"projects":[{"id":"P","name":"pb","shortcut":"pb"}],
     "estimates":{"P":{"type":"points","hours_per_point":1.0,
                       "points":{"1":"u1","2":"u2","3":"u3","5":"u5"}}}}
fc=FC()
out=m.enrich(cfg,fc,[
  {"tie":"P:i1","field":"estimate","value":"3"},      # plain value
  {"tie":"P:i2","field":"estimate","value":"5 pts"},  # numeric extracted from text
  {"tie":"P:i3","field":"estimate","value":"none"},   # clear
])
assert all(r["ok"] for r in out), out
assert {"estimate_point":"u3"} in fc.patches, fc.patches
assert {"estimate_point":"u5"} in fc.patches, fc.patches
assert {"estimate_point":None} in fc.patches, fc.patches
# an off-scale value errors clearly
bad=m.enrich(cfg,fc,[{"tie":"P:i4","field":"estimate","value":"4"}])
assert not bad[0]["ok"] and "no estimate bucket" in bad[0]["error"], bad
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "ensure_estimate_scale: skips without auth, fetches+caches with auth, degrades on error" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class FC:
    def __init__(self, auth=True, payload=None, err=False):
        self._auth=auth; self._payload=payload; self._err=err
        self._est_attempted=set(); self.calls=0
    def _has_internal_auth(self): return self._auth
    def list_estimates(self, pid):
        self.calls+=1
        if self._err: raise m.PlaneError("boom")
        return self._payload
# no internal auth -> None, never calls the API (silent skip, no network)
fc=FC(auth=False)
assert m.ensure_estimate_scale({}, fc, "P") is None and fc.calls==0
# auth + payload -> fetch once, cache the scale; second call hits cache (no refetch)
payload=[{"type":"points","last_used":True,"name":"Points","points":[{"id":"u2","value":"2"}]}]
cfg={}; fc2=FC(auth=True, payload=payload)
sc=m.ensure_estimate_scale(cfg, fc2, "P")
assert sc and sc["points"]=={"2":"u2"} and fc2.calls==1, sc
assert m.ensure_estimate_scale(cfg, fc2, "P")["points"]=={"2":"u2"} and fc2.calls==1
# error -> None, and the project is marked attempted so we don't hammer the API
cfg2={}; fc3=FC(auth=True, err=True)
assert m.ensure_estimate_scale(cfg2, fc3, "Q") is None and fc3.calls==1
assert m.ensure_estimate_scale(cfg2, fc3, "Q") is None and fc3.calls==1
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "browser cookie: _vhost_from_base candidates + _decrypt_v10 round-trips, skips v20" {
  command -v openssl >/dev/null || skip "openssl not available"
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util, hashlib, subprocess
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# host candidates always include plane.localhost/localhost + the base host
h = m._vhost_from_base("http://127.0.0.1:1800")
assert "plane.localhost" in h and "localhost" in h and "127.0.0.1" in h, h
assert m._vhost_from_base("http://plane.example:80")[0]=="plane.example"
# v10 decrypt round-trip: SHA256(host) prefix + value, PKCS7-padded, AES-128-CBC
key=hashlib.pbkdf2_hmac("sha1", b"pw", b"saltysalt", 1003, 16)
host="plane.localhost"; value="sess-xyz-123"
plain=hashlib.sha256(host.encode()).digest()+value.encode()
pad=16-(len(plain)%16); plain+=bytes([pad])*pad
ct=subprocess.run(["openssl","enc","-aes-128-cbc","-nopad","-K",key.hex(),"-iv","20"*16],
                  input=plain, capture_output=True).stdout
assert m._decrypt_v10(b"v10"+ct, key, host)==value
assert m._decrypt_v10(b"v20"+ct, key, host) is None   # app-bound encryption -> skip
assert m._decrypt_v10(b"", key, host) is None
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "client refreshes the internal-session cookie via the refresher (and persists it)" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
calls={"n":0,"saved":[]}
def refresher(): calls["n"]+=1; return "csrftoken=a; session-id=b"
def persist(ck): calls["saved"].append(ck)
c=m.PlaneClient("http://x","k","ws",cookie_refresher=refresher,on_cookie_refreshed=persist)
assert c._has_internal_auth()                       # refresher counts as auth
c._ensure_internal_session()                        # no stored cookie -> pull one
assert c._session_cookie=="csrftoken=a; session-id=b"
assert calls["n"]==1 and calls["saved"]==["csrftoken=a; session-id=b"]
# no auth at all -> raises (callers catch and degrade)
c2=m.PlaneClient("http://x","k","ws")
try:
    c2._ensure_internal_session(); raise SystemExit("should have raised")
except m.PlaneError:
    pass
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "setup_project_estimate reuses-or-creates a scale, activates it, caches it" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class FC:
    def __init__(self, scale=None):
        self.created=False; self.activated=None; self._est_attempted=set()
        self.deleted=[]; self.ctype=None; self.scale=scale or []
    def _has_internal_auth(self): return True
    def list_estimates(self, pid): return self.scale
    def create_estimate(self, pid, values, name="Points", type_="points"):
        self.created=True; self.ctype=type_
        self.scale=[{"id":"E1","type":type_,"last_used":True,"name":name,
                     "points":[{"id":"u%s"%v,"value":str(v)} for v in values]}]
    def delete_estimate(self, pid, eid): self.deleted.append(eid)
    def update_project(self, pid, body): self.activated=body.get("estimate")
# empty project -> create (Fibonacci default) + activate + cache
fc=FC(); sc=m.setup_project_estimate({}, fc, "P", values=[1,2,3])
assert fc.created and fc.activated=="E1", (fc.created, fc.activated)
assert sc["points"]=={"1":"u1","2":"u2","3":"u3"}, sc
# pre-existing scale -> NO re-create (idempotent), still (re)activates + caches
fc2=FC(scale=[{"id":"E9","type":"points","points":[{"id":"x2","value":"2"}]}])
sc2=m.setup_project_estimate({}, fc2, "Q")
assert not fc2.created and fc2.activated=="E9" and sc2["points"]=={"2":"x2"}, (fc2.created, sc2)
# t-shirt (categories) type
fc3=FC(); sc3=m.setup_project_estimate({}, fc3, "R", values=["S","M","L"], type_="categories")
assert fc3.ctype=="categories" and sc3["points"]=={"S":"uS","M":"uM","L":"uL"}, (fc3.ctype, sc3)
# replace -> delete existing first, then create the new type
fc4=FC(scale=[{"id":"OLD","type":"points","points":[{"id":"p1","value":"1"}]}])
m.setup_project_estimate({}, fc4, "S", values=["XS","S"], type_="categories", replace=True)
assert fc4.deleted==["OLD"] and fc4.created and fc4.ctype=="categories", (fc4.deleted, fc4.ctype)
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "enrich module auto-creates a missing module, then files the issue; cycle does not" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class FC:
    def __init__(self):
        self.modules=[]; self.filed=[]; self.cycles=[]
    def list_modules(self,pid): return list(self.modules)   # fresh list, like the real client
    def list_cycles(self,pid): return list(self.cycles)
    def create_module(self,pid,name):
        o={"id":"m%d"%len(self.modules),"name":name}; self.modules.append(o); return o
    def add_to_module(self,pid,mid,iid): self.filed.append((mid,iid))
    def add_to_cycle(self,pid,cid,iid): self.filed.append((cid,iid))
cfg={"projects":[{"id":"P","name":"pb","shortcut":"pb"}]}
fc=FC()
out=m.enrich(cfg,fc,[{"tie":"P:i1","field":"module","value":"Plane backend"}])
assert out[0]["ok"] and out[0].get("created_module")=="Plane backend", out
assert fc.modules[0]["name"]=="Plane backend" and fc.filed==[("m0","i1")], (fc.modules, fc.filed)
# a second issue into the SAME module reuses it (no duplicate create)
out2=m.enrich(cfg,fc,[{"tie":"P:i2","field":"module","value":"plane backend"}])  # fuzzy
assert out2[0]["ok"] and "created_module" not in out2[0], out2
assert len(fc.modules)==1 and ("m0","i2") in fc.filed
# cycle does NOT auto-create (we don't use cycles)
bad=m.enrich(cfg,fc,[{"tie":"P:i3","field":"cycle","value":"Sprint 1"}])
assert not bad[0]["ok"] and "no cycle" in bad[0]["error"], bad
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "batch tagging the same new label across issues creates it once (cache stays fresh)" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class FC:
    def __init__(self): self.labels=[]; self.creates=0
    def list_labels(self,pid): return list(self.labels)         # fresh list, like real client
    def create_label(self,pid,name,color=None):
        self.creates+=1; o={"id":"L%d"%self.creates,"name":name}; self.labels.append(o); return o
    def get_work_item(self,pid,iid): return {"id":iid,"labels":[]}
    def update_work_item(self,pid,iid,body): pass
cfg={"projects":[{"id":"P","name":"pb","shortcut":"pb"}]}
fc=FC()
# 6 issues all tagged 'bug' -> created ONCE and reused (would otherwise burn the guard)
out=m.enrich(cfg,fc,[{"tie":"P:i%d"%i,"field":"tag","value":"bug"} for i in range(6)])
assert all(r["ok"] for r in out), out
assert fc.creates==1, ("label created %d times, expected 1"%fc.creates)
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "completed_on matches on the date only" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
assert m.completed_on({"completed_at":"2026-06-15T09:00:00Z"},"2026-06-15")
assert not m.completed_on({"completed_at":"2026-06-14T23:00:00Z"},"2026-06-15")
assert not m.completed_on({"completed_at":None},"2026-06-15")
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "progress_summary weights by estimate when present, else counts; lists completed-since" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
rows = [
  {"status":"done","est":3,"completed_at":"2026-06-15T00:00:00Z","tie":"p:1","title":"a"},
  {"status":"todo","est":1,"completed_at":"","tie":"p:2","title":"b"},
  {"status":"dropped","est":9,"completed_at":"","tie":"p:3","title":"c"},
]
s = m.progress_summary(rows, since="2026-06-15")
assert s["pct"]==75, s              # 3 done / (3+1) total, dropped excluded
assert s["counts"]["done"]==1 and s["counts"]["dropped"]==1
assert [x["tie"] for x in s["completed_since"]]==["p:1"]
# no estimates → flat count weighting
flat = m.progress_summary([{"status":"done","est":0},{"status":"todo","est":0}])
assert flat["pct"]==50
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "ready_multi tags rows with project and sorts cross-project by priority" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

class FakeClient:
    DATA = {
      "A": {"states":[{"id":"u","group":"unstarted","default":True}],
            "items":[{"id":"a1","name":"A-low","priority":"low","state":"u"}]},
      "B": {"states":[{"id":"u","group":"unstarted","default":True}],
            "items":[{"id":"b1","name":"B-urgent","priority":"urgent","state":"u"}]},
    }
    def list_states(self,pid): return self.DATA[pid]["states"]
    def list_work_items(self,pid): return self.DATA[pid]["items"]
    def list_modules(self,pid): return []
    def list_module_items(self,pid,mid): return []

cfg = {"default_est_h":2.0,
       "projects":[{"id":"A","name":"Alpha","shortcut":""},{"id":"B","name":"Bravo","shortcut":""}]}
rows = m.ready_multi(cfg, FakeClient(), ["A","B"])
# urgent (B) sorts before low (A); each tagged with its project name
assert [r["project"] for r in rows]==["Bravo","Alpha"], rows
assert rows[0]["project_id"]=="B" and rows[0]["tie"]=="B:b1"
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "projects --sync degrades to PLANE_ERROR when unreachable; bare prints registry" {
  PY setup --base-url http://127.0.0.1:9 --api-key SECRET --workspace ws --project pid >/dev/null
  run PY projects
  [ "$status" -eq 0 ]
  [[ "$output" == *'"id": "pid"'* ]]   # synthesized one-entry registry from lone project
  run PY projects --sync
  [[ "$output" == *PLANE_ERROR* ]]
}

# --- PB-40 per-project working location (workdir / workdirs) ----------------
@test "workdir records a working location, surfaced by workdirs (pure config, no network)" {
  PY setup --base-url http://127.0.0.1:9 --api-key SECRET --workspace ws --project pid >/dev/null
  PY workdir pid --path "$TMP" --kind repo --base-branch main >/dev/null
  run PY workdirs
  [ "$status" -eq 0 ] && [[ "$output" == *'"pid"'* ]] && [[ "$output" == *"$TMP"* ]] \
    && grep -q '"work"' "$XDG_CONFIG_HOME/pbrain/plane.json"
}

@test "workdir --clear removes the working location" {
  PY setup --base-url http://127.0.0.1:9 --api-key SECRET --workspace ws --project pid >/dev/null
  PY workdir pid --path "$TMP" >/dev/null
  PY workdir pid --clear >/dev/null
  run PY workdirs
  [ "$status" -eq 0 ] && [[ "$output" == "{}" ]]
}

@test "workdir rejects a path that does not exist (no write)" {
  PY setup --base-url http://127.0.0.1:9 --api-key SECRET --workspace ws --project pid >/dev/null
  run PY workdir pid --path "$TMP/does-not-exist"
  [[ "$output" == *PLANE_ERROR* ]] && ! grep -q '"work"' "$XDG_CONFIG_HOME/pbrain/plane.json"
}

@test "projects --sync preserves projects[].work (a sync must not wipe working locations)" {
  run python3 - "$PLANE" "$TMP" <<'PYEOF'
import importlib.util, sys, json, argparse
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
workpath = sys.argv[2]
cfg = {"base_url": "http://127.0.0.1:9", "api_key": "SECRET", "workspace": "ws",
       "projects": [{"id": "A", "name": "Alpha", "shortcut": "a",
                     "work": {"path": workpath, "kind": "repo",
                              "base_branch": "main", "isolation": "worktree"}}]}
m.save_config(cfg)
class FakeClient:
    def list_projects(self):
        return [{"id": "A", "name": "Alpha Renamed"}]   # remote dropped `work`
m.make_client = lambda c: FakeClient()
m.cmd_projects(argparse.Namespace(sync=True))
saved = json.load(open(m.config_path()))
work = {p["id"]: p.get("work") for p in saved["projects"]}
assert work.get("A") and work["A"]["path"] == workpath, work
print("ok")
PYEOF
  [ "$status" -eq 0 ] && [[ "$output" == *ok* ]]
}

# ===== PB-94: per-gate auto-execution labels =====================================

@test "PB-94 seed set includes auto:* gate labels + plan-approved" {
  run python3 - "$PLANE" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
names = [s["name"] for s in m._seed_label_specs()]
for g in m.GATE_NAMES:
    assert ("auto:%s" % g) in names, (g, names)
assert m.APPROVED_LABEL in names, names
# convention labels still present (not displaced)
for c in ("bug", "feature", "chore", "docs"):
    assert c in names, names
print("ok")
PYEOF
  [ "$status" -eq 0 ] && [[ "$output" == *ok* ]]
}

@test "PB-94 issue_gate_clearances maps auto:* labels → gate names; empty when absent" {
  run python3 - "$PLANE" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# gate_map: stage name -> set of label ids
gate_map = {"plan": {"L1"}, "test": {"L2"}, "land": {"L3"}}
# an issue carrying L1 + L2 is cleared for plan + test, in GATE_NAMES (pipeline) order
issue = {"labels": ["L1", "L2", "Lother"]}
assert m.issue_gate_clearances(issue, gate_map) == ["plan", "test"], \
    m.issue_gate_clearances(issue, gate_map)
# no auto label → empty (every stage manual / parks)
assert m.issue_gate_clearances({"labels": ["Lz"]}, gate_map) == []
# empty gate_map (labels unlistable) → degrade to all-manual
assert m.issue_gate_clearances(issue, {}) == []
print("ok")
PYEOF
  [ "$status" -eq 0 ] && [[ "$output" == *ok* ]]
}

@test "PB-94 gate_label_map degrades to empty when labels can't be listed" {
  run python3 - "$PLANE" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class Boom:
    def list_labels(self, pid): raise RuntimeError("network down")
assert m.gate_label_map(Boom(), "A") == {}, "must not raise; returns {}"
# and a matching client surfaces the auto:* ids by stage
class Good:
    def list_labels(self, pid):
        return [{"id":"i1","name":"auto:land"}, {"id":"i2","name":"bug"},
                {"id":"i3","name":"auto:plan"}]
gm = m.gate_label_map(Good(), "A")
assert gm["land"] == {"i1"} and gm["plan"] == {"i3"} and gm["test"] == set(), gm
print("ok")
PYEOF
  [ "$status" -eq 0 ] && [[ "$output" == *ok* ]]
}

# ===== PB-94 Stage B: blocked_by read path =======================================

@test "PB-94 _blocker_uuids extracts blocked_by issue ids from the observed payload" {
  run python3 - "$PLANE" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# the real shape: normalised list with relation_type + issue_id (the blocker)
rels = [{"project_id":"P","issue_id":"BLOCKER","relation_type":"blocked_by"},
        {"project_id":"P","issue_id":"OTHER","relation_type":"blocking"}]
assert m._blocker_uuids(rels) == ["BLOCKER"], m._blocker_uuids(rels)
# tolerate alternate field names, and NEVER fall back to `id` (relation row id)
assert m._blocker_uuids([{"relation":"blocked_by","related_issue":"B2"}]) == ["B2"]
assert m._blocker_uuids([{"relation_type":"blocked_by","id":"RELROW"}]) == []
assert m._blocker_uuids([]) == [] and m._blocker_uuids(None) == []
print("ok")
PYEOF
  [ "$status" -eq 0 ] && [[ "$output" == *ok* ]]
}

@test "PB-94 Client.list_relations normalises dict-keyed-by-type to a flat list" {
  run python3 - "$PLANE" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# Bind the unbound method onto a lightweight stub so we exercise the real
# normalisation logic without constructing a full Client.
class Stub:
    def __init__(self, payload, boom=False): self._payload, self._boom = payload, boom
    def _request(self, method, path, params=None, body=None):
        if self._boom: raise m.PlaneError("down")
        return self._payload
    list_relations = m.PlaneClient.list_relations
# dict-keyed-by-type (the observed shape) → flat, relation_type stamped
out = Stub({"blocking": [], "blocked_by": [{"issue_id":"B"}]}).list_relations("P","I")
assert out == [{"issue_id":"B","relation_type":"blocked_by"}], out
# flat list passes through
assert Stub([{"issue_id":"B","relation_type":"blocked_by"}]).list_relations("P","I") \
    == [{"issue_id":"B","relation_type":"blocked_by"}]
# {results:[...]} wrapper
assert Stub({"results":[{"issue_id":"B"}]}).list_relations("P","I") == [{"issue_id":"B"}]
# unreadable → None (best-effort, never raises)
assert Stub(None, boom=True).list_relations("P","I") is None
print("ok")
PYEOF
  [ "$status" -eq 0 ] && [[ "$output" == *ok* ]]
}

@test "PB-94 blocked_by_ids returns OPEN blockers as ready rows, drops terminal ones" {
  run python3 - "$PLANE" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
PID = "P"
class FC:
    def list_states(self, pid):
        return [{"id":"open","group":"unstarted","default":True},
                {"id":"done","group":"completed","default":True}]
    def list_work_items(self, pid):
        return [{"id":"BO","sequence_id":7,"name":"open blocker","state":"open","priority":"high","labels":[]},
                {"id":"BD","sequence_id":8,"name":"done blocker","state":"done","priority":"low","labels":[]}]
    def list_relations(self, pid, iid):
        return [{"issue_id":"BO","relation_type":"blocked_by"},
                {"issue_id":"BD","relation_type":"blocked_by"}]
    def list_labels(self, pid): return []
# stub the resolution helpers blocked_by_ids leans on
m.find_issues = lambda cfg, c, ref, project_ref=None: [{"tie":"P:SUBJ","id":1,"project_id":"P","issue_id":"SUBJ","title":"subj"}]
m._module_map = lambda c, pid, x: {}
m.ensure_estimate_scale = lambda cfg, c, pid: None
m.est_uuid_to_hours = lambda cfg, pid: {}
m.approved_label_ids = lambda c, pid: set()
m.project_label = lambda cfg, pid: "pb"
cfg = {"default_est_h": 2.0}
res = m.blocked_by_ids(cfg, FC(), "PB-1")
assert res["status"] == "ok", res
ids = [b["id"] for b in res["blockers"]]
assert ids == [7], ids            # only the OPEN blocker; done one dropped
print("ok")
PYEOF
  [ "$status" -eq 0 ] && [[ "$output" == *ok* ]]
}
