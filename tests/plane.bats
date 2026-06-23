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
# parse_issue_ref: url | id | bare seq | name
assert m.parse_issue_ref("http://x/pb/browse/PB-26/")==("PB",26)
assert m.parse_issue_ref("PB-26")==("PB",26)
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

@test "bug_context resolves project, returns triage context + dedupe, branches on need_project (PB-67); never writes" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

assert m.SEVERITY_TO_PRIORITY["crash"]=="urgent" and m.SEVERITY_TO_PRIORITY["polish"]=="low"

class C:
    def __init__(self): self.writes=[]
    def list_labels(self,pid): return [{"id":"b","name":"bug"},{"id":"f","name":"feature"}]
    def list_states(self,pid): return [{"id":"s1","name":"Todo","group":"unstarted"},
                                       {"id":"sd","name":"Done","group":"completed"}]
    def list_projects(self): return [{"id":"P","identifier":"PB"}]
    def list_work_items(self,pid):
        return [{"sequence_id":98,"name":"old bug","labels":[{"id":"b"}],"state":"s1"},
                {"sequence_id":50,"name":"closed bug","labels":[{"id":"b"}],"state":"sd"},
                {"sequence_id":51,"name":"not a bug","labels":[{"id":"f"}],"state":"s1"}]
    def create_work_item(self,*a,**k): self.writes.append("create"); raise AssertionError("wrote!")
    def update_work_item(self,*a,**k): self.writes.append("update"); raise AssertionError("wrote!")
    def create_label(self,*a,**k): self.writes.append("label"); raise AssertionError("wrote!")

cfg={"project":"P","projects":[{"id":"P","name":"pb","shortcut":"pb"}]}
c=C()
r=m.bug_context(cfg,c,"reminder fires late")
assert r["status"]=="ok", r
assert r["project_id"]=="P" and r["has_bug_label"] is True, r
assert r["convention_labels"]==["bug","feature","chore","docs"], r
ids=[b["id"] for b in r["recent_open_bugs"]]      # only the OPEN bug, PB-98
assert ids==["PB-98"], r["recent_open_bugs"]
assert c.writes==[], "bug_context must not write"

cfg2={"projects":[{"id":"P","name":"pb","shortcut":"pb"},{"id":"Q","name":"yt","shortcut":"yt"}]}
r2=m.bug_context(cfg2,C(),"x")
assert r2["status"]=="need_project" and len(r2["projects"])==2, r2

r3=m.bug_context(cfg2,C(),"x",project_ref="nope")
assert r3["status"]=="unknown_project", r3
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "seed_convention_labels creates only missing convention labels, idempotent, fuzzy-skips existing (PB-70)" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)

names = {l["name"] for l in m.CONVENTION_LABELS}
assert names == {"bug","feature","chore","docs"}, names   # canon = type set

class FC:
    def __init__(self, existing): self.labels=list(existing); self.created=[]
    def list_labels(self, pid): return list(self.labels)
    def create_label(self, pid, name, color=None):
        rec={"id":"n%d"%len(self.created),"name":name,"color":color}
        self.created.append(name); self.labels.append(rec); return rec

# Start with one already present, fuzzily ('Bug' vs 'bug') -> only 3 created.
fc=FC([{"id":"l1","name":"Bug"}])
r1=m.seed_convention_labels(fc,"p")
assert sorted(r1["created"])==["chore","docs","feature"], r1
assert r1["existing"]==["bug"], r1
assert "error" not in r1, r1
# colors are applied on create
assert any(l.get("color") for l in fc.labels if l["name"]=="feature"), fc.labels

# Idempotent: a second pass creates nothing.
r2=m.seed_convention_labels(fc,"p")
assert r2["created"]==[], r2
assert sorted(r2["existing"])==["bug","chore","docs","feature"], r2

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

@test "subtree_context: parent target -> open children as ready rows (sorted, done excluded); leaf -> none; branches" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class FC:
    # parent p1 (seq 7) has three children: two OPEN (different priority), one DONE.
    # a separate leaf l1 (seq 9) has no children at all.
    items={
      "p1":{"id":"p1","sequence_id":7,"name":"build payment flow",
            "state":{"name":"In Progress","group":"started"},"priority":"high","parent":None},
      "cA":{"id":"cA","sequence_id":11,"name":"add webhook","parent":"p1",
            "state":{"name":"Todo","group":"unstarted"},"priority":"medium"},
      "cB":{"id":"cB","sequence_id":12,"name":"wire stripe","parent":"p1",
            "state":{"name":"In Progress","group":"started"},"priority":"high"},
      "cDone":{"id":"cDone","sequence_id":13,"name":"already shipped","parent":"p1",
               "state":{"name":"Done","group":"completed"},"priority":"high"},
      "l1":{"id":"l1","sequence_id":9,"name":"standalone leaf task",
            "state":{"name":"Todo","group":"unstarted"},"priority":"low","parent":None},
    }
    def list_projects(self): return [{"id":"P","identifier":"PB","name":"pb"}]
    def list_work_items(self,pid): return list(self.items.values()) if pid=="P" else []
    def list_states(self,pid): return [{"id":"s1","name":"Todo","group":"unstarted"},
                                       {"id":"s2","name":"In Progress","group":"started"},
                                       {"id":"s3","name":"Done","group":"completed"}]
    def list_modules(self,pid): return []
    def list_module_issues(self,pid,mid): return []
cfg={"projects":[{"id":"P","name":"pb","shortcut":"pb"}],"default_est_h":2}
fc=FC()

# PARENT target: open children only, sorted priority -> due -> id (high cB before medium cA)
ctx=m.subtree_context(cfg,fc,"PB-7")
assert ctx["status"]=="ok", ctx
assert ctx["has_open_children"] is True, ctx
ids=[c["id"] for c in ctx["children"]]
assert ids==[12,11], ids                               # cB(high) before cA(medium); cDone excluded
assert all(c["is_sub"] for c in ctx["children"]), ctx  # every child flagged is_sub
assert ctx["children"][0]["tie"]=="P:cB"               # full tie carried for execute
assert ctx["children"][0]["project"]=="pb"

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
