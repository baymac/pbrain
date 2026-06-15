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
# all present-but-empty + 0 subs → every flag
full = {"description_html":"<p></p>","estimate_point":0,"priority":"none"}
assert sorted(m.thinness_flags(full,0))==["no_description","no_estimate","no_priority","no_subissues"]
# absent fields → no flags; sub_count None → no subissue flag
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
