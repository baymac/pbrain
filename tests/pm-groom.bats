#!/usr/bin/env bats
# Tests for headless mechanical grooming (PB-46): lib/pm-groom.sh + the
# /project-manager groom dispatch + the pure groom_run logic in lib/plane.py.
#
# No live Plane: the pure-logic tests drive groom_run() with an in-process
# FakeClient (importlib, like tests/plane.bats); the report-rendering test
# stubs `python3 ... groom` with a canned-JSON shim on PATH; the schedule verbs
# stub launchctl so no agent is installed (we assert on the plist file).
#
# NB: bats only enforces the LAST command of each @test, so must-hold checks are
# chained with && into one final line.
#
# Run with:  bats tests/

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TMP="$(mktemp -d)"
  export PBRAIN_MIGRATIONS=0 PBRAIN_UPDATE_CHECK=0 PBRAIN_SELF_IMPROVE=off PBRAIN_NO_AUTOVAULT=1
  export XDG_CONFIG_HOME="$TMP/config"; mkdir -p "$XDG_CONFIG_HOME/pbrain"
  export HOME="$TMP/home"; mkdir -p "$HOME/Library/LaunchAgents"
  export PBRAIN_VAULT="$TMP/vault"; mkdir -p "$PBRAIN_VAULT"
  export PBRAIN_PMG_DIR="$TMP/pmg"
  export PBRAIN_PMG_DATE="2026-06-22"
  PLANE="$REPO_ROOT/lib/plane.py"

  STUB="$TMP/bin"; mkdir -p "$STUB"
  # launchctl: `print` reports not-loaded (exit 1); bootstrap/bootout no-op.
  printf '#!/usr/bin/env bash\n[[ "$1" == print ]] && exit 1\nexit 0\n' > "$STUB/launchctl"; chmod +x "$STUB/launchctl"

  PM() { env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/project-manager.sh" "$@"; }
}
teardown() { rm -rf "$TMP"; }

# --- pure logic: groom_run ---------------------------------------------------

@test "groom_run reports a well-formed TODO issue as pipeline-ready (todo-only, PB-94)" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class FakeClient:
    DATA = {"A": {
      "states":[{"id":"td","group":"unstarted","default":True}],
      "items":[{"id":"a1","sequence_id":1,"name":"ready one","priority":"high",
                "description_stripped":"has body","state":"td"}],
    }}
    def list_states(self,pid): return self.DATA[pid]["states"]
    def list_work_items(self,pid): return self.DATA[pid]["items"]
    def update_work_item(self,pid,iid,body): raise AssertionError("groom must not write")
m.ensure_estimate_scale = lambda cfg,c,pid: None
cfg = {"projects":[{"id":"A","name":"Alpha","shortcut":""}]}
rep = m.groom_run(cfg, FakeClient(), ["A"], apply=False)
assert "triaged" not in rep and "auto_exec" not in rep, rep   # old keys gone
assert [r["id"] for r in rep["todo"]] == [1], rep
assert rep["needs_review"] == [], rep
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "groom_run SKIPS backlog entirely — no promotion, no thin-flagging (PB-94)" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class FakeClient:
    DATA = {"A": {
      "states":[{"id":"bk","group":"backlog","default":True},
                {"id":"td","group":"unstarted","default":True}],
      # one well-formed backlog issue + one THIN backlog issue — both must be ignored
      "items":[{"id":"b1","sequence_id":1,"name":"wf backlog","priority":"high",
                "description_stripped":"body","state":"bk"},
               {"id":"b2","sequence_id":2,"name":"thin backlog","priority":"none",
                "description_stripped":"","state":"bk"}],
    }}
    def list_states(self,pid): return self.DATA[pid]["states"]
    def list_work_items(self,pid): return self.DATA[pid]["items"]
    def update_work_item(self,pid,iid,body): raise AssertionError("never write backlog")
m.ensure_estimate_scale = lambda cfg,c,pid: None
cfg = {"projects":[{"id":"A","name":"Alpha","shortcut":""}]}
rep = m.groom_run(cfg, FakeClient(), ["A"], apply=True)
assert rep["todo"] == [], rep            # backlog never enters the pipeline
assert rep["needs_review"] == [], rep    # backlog is NOT thin-flagged
assert rep["projects"][0]["counts"]["skipped"] == 2, rep
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "groom_run flags a THIN todo issue into needs_review (enrich before running)" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class FakeClient:
    DATA = {"A": {
      "states":[{"id":"td","group":"unstarted","default":True}],
      # thin: no description, no priority
      "items":[{"id":"a1","sequence_id":1,"name":"thin todo","priority":"none",
                "description_stripped":"","description_html":"<p></p>","state":"td"}],
    }}
    def list_states(self,pid): return self.DATA[pid]["states"]
    def list_work_items(self,pid): return self.DATA[pid]["items"]
    def update_work_item(self,pid,iid,body): raise AssertionError("groom must not write")
m.ensure_estimate_scale = lambda cfg,c,pid: None
cfg = {"projects":[{"id":"A","name":"Alpha","shortcut":""}]}
rep = m.groom_run(cfg, FakeClient(), ["A"], apply=False)
assert rep["todo"] == [], rep
assert len(rep["needs_review"]) == 1 and rep["needs_review"][0]["id"] == 1, rep
assert "flags" in rep["needs_review"][0], rep
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "groom_run skips sub-issues, and records a per-project error and keeps going" {
  run python3 - "$PLANE" <<'PYEOF'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("plane", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class FakeClient:
    DATA = {"A": {
      "states":[{"id":"td","group":"unstarted","default":True}],
      "items":[{"id":"a1","sequence_id":1,"name":"child","priority":"high",
                "description_stripped":"body","state":"td","parent":"P1"}],  # sub-issue
    }}
    def list_states(self,pid):
        if pid == "B": raise m.PlaneError("boom")
        return self.DATA[pid]["states"]
    def list_work_items(self,pid): return self.DATA[pid]["items"]
m.ensure_estimate_scale = lambda cfg,c,pid: None
cfg = {"projects":[{"id":"A","name":"Alpha","shortcut":""},
                   {"id":"B","name":"Beta","shortcut":""}]}
rep = m.groom_run(cfg, FakeClient(), ["A","B"], apply=False)
assert rep["todo"] == [] and rep["needs_review"] == [], rep   # the only A item is a sub-issue
assert rep["projects"][0]["counts"]["skipped"] == 1, rep
assert len(rep["errors"]) == 1 and rep["errors"][0]["project_id"] == "B", rep
print("ok")
PYEOF
  [ "$status" -eq 0 ]; [[ "$output" == *ok* ]]
}

@test "pmg_run renders a dated markdown report from the scan JSON" {
  # Stub python3 so `groom` returns canned JSON, but the rendering heredoc still
  # runs under the real interpreter. The shim dispatches on the args; for the
  # render call it execs the REAL python3 by absolute path (resolved before the
  # stub shadows it) — execing `python3` by name would re-find the stub and loop.
  local REAL_PY3; REAL_PY3="$(command -v python3)"
  cat > "$STUB/python3" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == groom ]]; then
    echo '{"applied":true,"projects":[{"project_id":"A","project":"Alpha","counts":{"todo":1,"needs_review":1,"skipped":0}}],"todo":[{"id":1,"title":"ready one"}],"needs_review":[{"id":2,"title":"too thin","flags":["no_description"]}],"errors":[]}'
    exit 0
  fi
done
exec "$REAL_PY3" "\$@"
SHIM
  chmod +x "$STUB/python3"
  run env PATH="$STUB:$PATH" bash -c "source '$REPO_ROOT/lib/launchd.sh'; source '$REPO_ROOT/lib/pm-groom.sh'; pmg_run --projects A --apply"
  [ "$status" -eq 0 ]
  report="$TMP/pmg/2026-06-22.md"
  [ -f "$report" ] \
    && grep -q "PM groom report — 2026-06-22 (applied)" "$report" \
    && grep -q "ready one" "$report" \
    && grep -q "too thin" "$report" \
    && grep -q "no_description" "$report"
}

@test "pmg_run drives a REAL plane.py groom end-to-end (catches argv-splitting)" {
  # No scan stub: pmg_run invokes a real plane.py whose make_client/load_config
  # are monkeypatched to a FakeClient. The --projects flag must reach groom_run
  # as a separate arg from its value — a quoted ${var:+...} that word-splits
  # "--projects A" into one token would make argparse reject it and fail here.
  cat > "$TMP/fakeplane.py" <<PYFAKE
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location("realplane", "$PLANE")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class FakeClient:
    def list_states(self, pid):
        return [{"id":"bk","group":"backlog","default":True},
                {"id":"td","group":"unstarted","default":True}]
    def list_work_items(self, pid):
        return [{"id":"x1","sequence_id":42,"name":"groom me","priority":"high",
                 "description_stripped":"body","state":"td"}]
    def update_work_item(self, pid, iid, body): pass
m.load_config = lambda: {"projects":[{"id":"A","name":"Alpha","shortcut":""}]}
m.make_client = lambda cfg: FakeClient()
m.ensure_estimate_scale = lambda cfg,c,pid: None
sys.exit(m.main())
PYFAKE
  run env PBRAIN_PLANE_PY="$TMP/fakeplane.py" bash -c \
    "source '$REPO_ROOT/lib/launchd.sh'; source '$REPO_ROOT/lib/pm-groom.sh'; pmg_run --projects A --apply"
  [ "$status" -eq 0 ]
  report="$TMP/pmg/2026-06-22.md"
  [ -f "$report" ] \
    && grep -q "(applied)" "$report" \
    && grep -q "groom me" "$report" \
    && grep -q "Todo — pipeline-ready" "$report"
}

# --- PB-94: vault grooming-data artifact + agent-drive block -----------------

@test "pmg_run writes the vault grooming-data file with the ordered queue (PB-94)" {
  local realpy; realpy="$(command -v python3)"
  cat > "$STUB/python3" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == groom ]]; then
    echo '{"applied":true,"projects":[],"todo":[{"id":1,"title":"ready one"}],"needs_review":[{"id":2,"title":"too thin","flags":["no_estimate"]}],"errors":[]}'
    exit 0
  fi
  if [[ "\$a" == ready ]]; then
    echo '[{"id":1,"title":"ready one","priority":"high"}]'
    exit 0
  fi
done
exec "$realpy" "\$@"
SHIM
  chmod +x "$STUB/python3"
  run env PATH="$STUB:$PATH" bash -c \
    "source '$REPO_ROOT/lib/vault.sh'; source '$REPO_ROOT/lib/launchd.sh'; source '$REPO_ROOT/lib/pm-groom.sh'; pmg_run --projects A --apply"
  [ "$status" -eq 0 ]
  data="$PBRAIN_VAULT/agent-work/daily-grooming/2026-06-22.md"
  [ -f "$data" ]
  grep -q "type: daily-grooming" "$data"
  grep -q "## Queue — ordered (1)" "$data"
  grep -q "ready one" "$data"
  grep -q "## Auto-work" "$data"
  grep -q "## Needs review" "$data"
}

@test "groom run emits the agent-drive block interactively, suppresses it headless" {
  local realpy; realpy="$(command -v python3)"
  cat > "$STUB/python3" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == groom ]]; then
    echo '{"applied":true,"projects":[],"todo":[{"id":1,"title":"x"}],"needs_review":[],"errors":[]}'
    exit 0
  fi
  if [[ "\$a" == ready ]]; then
    echo '[{"id":1,"title":"x","priority":"high"}]'
    exit 0
  fi
done
exec "$realpy" "\$@"
SHIM
  chmod +x "$STUB/python3"
  # Interactive (no headless marker): the drive block IS emitted.
  run env PATH="$STUB:$PATH" bash "$REPO_ROOT/commands/project-manager.sh" groom run --projects A --apply
  [ "$status" -eq 0 ]
  [[ "$output" == *"groom: drive the ordered queue"* ]]
  # Headless (LaunchAgent path): the block is suppressed.
  run env PATH="$STUB:$PATH" PBRAIN_PMG_HEADLESS=1 \
    bash "$REPO_ROOT/commands/project-manager.sh" groom run --projects A --apply
  [ "$status" -eq 0 ]
  [[ "$output" != *"groom: drive the ordered queue"* ]]
}

@test "pmg_prune keeps the newest N dated reports and deletes the rest" {
  source "$REPO_ROOT/lib/pm-groom.sh"
  mkdir -p "$TMP/pmg"
  for d in 2026-06-18 2026-06-19 2026-06-20 2026-06-21 2026-06-22; do
    printf '# report\n' > "$TMP/pmg/$d.md"
  done
  pmg_prune "$TMP/pmg" 3
  # newest 3 kept, oldest 2 gone
  [ ! -f "$TMP/pmg/2026-06-18.md" ] \
    && [ ! -f "$TMP/pmg/2026-06-19.md" ] \
    && [ -f "$TMP/pmg/2026-06-20.md" ] \
    && [ -f "$TMP/pmg/2026-06-21.md" ] \
    && [ -f "$TMP/pmg/2026-06-22.md" ]
}

@test "pmg_prune with keep<=0 or non-numeric disables pruning" {
  source "$REPO_ROOT/lib/pm-groom.sh"
  mkdir -p "$TMP/pmg"; printf 'x\n' > "$TMP/pmg/2026-06-22.md"
  pmg_prune "$TMP/pmg" 0
  pmg_prune "$TMP/pmg" abc
  [ -f "$TMP/pmg/2026-06-22.md" ]
}

@test "pmg_run prunes old reports after writing today's (keep override)" {
  # Pre-seed 3 old reports, keep=2, then a real run writes today's → keep 2 total.
  mkdir -p "$TMP/pmg"
  for d in 2026-06-19 2026-06-20 2026-06-21; do printf '# old\n' > "$TMP/pmg/$d.md"; done
  cat > "$TMP/fakeplane.py" <<PYFAKE
import importlib.util, sys
spec = importlib.util.spec_from_file_location("realplane", "$PLANE")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
class FakeClient:
    def list_states(self, pid): return [{"id":"bk","group":"backlog","default":True}]
    def list_work_items(self, pid): return []
    def update_work_item(self, pid, iid, body): pass
m.load_config = lambda: {"projects":[{"id":"A","name":"Alpha","shortcut":""}]}
m.make_client = lambda cfg: FakeClient()
m.ensure_estimate_scale = lambda cfg,c,pid: None
sys.exit(m.main())
PYFAKE
  run env PBRAIN_PLANE_PY="$TMP/fakeplane.py" PBRAIN_PMG_KEEP=2 bash -c \
    "source '$REPO_ROOT/lib/launchd.sh'; source '$REPO_ROOT/lib/pm-groom.sh'; pmg_run --projects A"
  [ "$status" -eq 0 ]
  # today + the single newest old one survive; the rest pruned → exactly 2 files
  n="$(ls -1 "$TMP/pmg"/*.md 2>/dev/null | wc -l | tr -d ' ')"
  [ -f "$TMP/pmg/2026-06-22.md" ] && [ "$n" -eq 2 ]
}

@test "pmg_report_fresh is true only when a non-empty report exists for the date" {
  source "$REPO_ROOT/lib/pm-groom.sh"
  run pmg_report_fresh 2026-06-22
  [ "$status" -ne 0 ]                       # none yet
  mkdir -p "$TMP/pmg"; printf '# report\n' > "$TMP/pmg/2026-06-22.md"
  run pmg_report_fresh 2026-06-22
  [ "$status" -eq 0 ]
}

# --- schedule verbs ----------------------------------------------------------

@test "groom status reports no schedule and no report on a clean machine" {
  run PM groom status
  [ "$status" -eq 0 ] \
    && [[ "$output" == *PMG_STATUS* ]] \
    && [[ "$output" == *"scheduled: no"* ]] \
    && [[ "$output" == *"today_report: (none)"* ]]
}

@test "groom enable writes the daily LaunchAgent plist with the run --apply entry" {
  run PM groom enable --time 06:40 --projects A,B
  [ "$status" -eq 0 ] && [[ "$output" == *PM_GROOM_ENABLE* ]]
  plist="$HOME/Library/LaunchAgents/com.pbrain.pm-groom.plist"
  [ -f "$plist" ] \
    && grep -q "com.pbrain.pm-groom" "$plist" \
    && grep -q "<integer>6</integer>" "$plist" \
    && grep -q "<integer>40</integer>" "$plist" \
    && grep -q "groom" "$plist" \
    && grep -q "apply" "$plist"
}

@test "groom disable removes the LaunchAgent plist" {
  PM groom enable --time 07:00 >/dev/null
  plist="$HOME/Library/LaunchAgents/com.pbrain.pm-groom.plist"
  [ -f "$plist" ]
  run PM groom disable
  [ "$status" -eq 0 ] && [[ "$output" == *PM_GROOM_DISABLE* ]] && [ ! -f "$plist" ]
}

# --- PB-79: groom doctor (macOS power-settings diagnostic) -------------------

@test "groom doctor FAILs when the agent isn't scheduled (clean machine)" {
  run PM groom doctor
  [ "$status" -eq 0 ] \
    && [[ "$output" == *PMG_DOCTOR* ]] \
    && [[ "$output" == *"scheduled: no"* ]] \
    && [[ "$output" == *"verdict: FAIL"* ]] \
    && [[ "$output" == *"groom enable"* ]]
}

@test "groom doctor reports UNKNOWN when pmset is unavailable" {
  # Schedule installed + loaded so we get past the FAIL gate.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/launchctl"; chmod +x "$STUB/launchctl"
  PM groom enable --time 06:40 >/dev/null
  # Build a PATH that has the core tools the command needs (bash, awk, python3…)
  # but NO pmset, so `command -v pmset` fails → the UNKNOWN power-policy path.
  NOPM="$TMP/nopmset"; mkdir -p "$NOPM"
  for t in bash sh env awk sed grep cat head python3 mktemp dirname basename rm mkdir chmod date printf; do
    src="$(command -v "$t" 2>/dev/null || true)"; [[ -n "$src" ]] && ln -sf "$src" "$NOPM/$t"
  done
  run env PATH="$STUB:$NOPM" bash "$REPO_ROOT/commands/project-manager.sh" groom doctor
  [ "$status" -eq 0 ] \
    && [[ "$output" == *PMG_DOCTOR* ]] \
    && [[ "$output" == *"powernap_ac: unknown"* ]] \
    && [[ "$output" == *"verdict: UNKNOWN"* ]]
}

@test "groom doctor WARNs when Power Nap is off on AC, and --apply runs pmset" {
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/launchctl"; chmod +x "$STUB/launchctl"
  PM groom enable --time 06:40 >/dev/null
  # Stub pmset: -g custom reports powernap 0 on AC; -c powernap 1 records a call.
  cat > "$STUB/pmset" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "-g custom")
    printf 'AC Power:\n powernap 0\n sleep 10\nBattery Power:\n powernap 0\n sleep 5\n' ;;
  "-g batt")  printf "Now drawing from 'AC Power'\n" ;;
  "-c powernap 1") echo applied > "$TMP/pmset-applied" ;;
esac
exit 0
EOF
  chmod +x "$STUB/pmset"
  run PM groom doctor
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"powernap_ac: 0"* ]] \
    && [[ "$output" == *"verdict: WARN"* ]]
  # --apply opts into the fix: the stubbed `pmset -c powernap 1` must be called.
  # PBRAIN_PMG_SUDO=env makes the privilege wrapper a no-op passthrough so the
  # stubbed pmset (on PATH) runs without a real sudo prompt.
  run env PATH="$STUB:$PATH" PBRAIN_PMG_SUDO=env \
    bash "$REPO_ROOT/commands/project-manager.sh" groom doctor --apply
  [ "$status" -eq 0 ] \
    && [[ "$output" == *"applying: env pmset -c powernap 1"* ]] \
    && [ -f "$TMP/pmset-applied" ]
}

@test "groom rejects an unknown action" {
  run PM groom frobnicate
  [ "$status" -ne 0 ] && [[ "$output" == *Usage* ]]
}
