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
  # Deterministic entry point: default to the /bin/bash fallback so schedule tests
  # don't depend on whether swiftc is installed. The dedicated wrapper tests below
  # flip this off explicitly.
  export PBRAIN_GROOM_NO_APP=1
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

@test "pmg_staging_file is a non-iCloud config path distinct from the vault file" {
  source "$REPO_ROOT/lib/pm-groom.sh"
  run pmg_staging_file 2026-06-22
  [ "$status" -eq 0 ]
  [[ "$output" == "$PBRAIN_PMG_DIR/2026-06-22.data.md" ]]
  # and it differs from the iCloud vault path
  [[ "$output" != "$PBRAIN_VAULT"* ]]
}

@test "pmg_web_base resolves the BROWSER host (plane.localhost), not the 127.0.0.1 loopback" {
  # A real plane.json whose base_url is the loopback the API client uses.
  mkdir -p "$XDG_CONFIG_HOME/pbrain"
  cat > "$XDG_CONFIG_HOME/pbrain/plane.json" <<'JSON'
{"base_url":"http://127.0.0.1:1800","api_key":"k","workspace":"pb"}
JSON
  run env -u PBRAIN_PLANE_WEB_BASE PATH="$STUB:$PATH" bash -c \
    "source '$REPO_ROOT/lib/launchd.sh'; source '$REPO_ROOT/lib/pm-groom.sh'; pmg_web_base"
  [ "$status" -eq 0 ]
  [[ "$output" == "http://plane.localhost:1800/pb" ]]
  [[ "$output" != *127.0.0.1* ]]
}

# Seed a committed weekly-goals profile for the test ISO week (PBRAIN_PMG_DATE
# 2026-06-22 -> ISO 2026-W26) listing the given comma-separated plane_project ids.
_seed_weekly_goals() {
  local store="$PBRAIN_VAULT/life/daily-planning/.profile"
  mkdir -p "$store"
  local goals=""
  local IFS=,; local first=1
  for pid in $1; do
    [[ $first -eq 1 ]] || goals+=","
    goals+="{\"plane_project\":\"$pid\",\"project_name\":\"p\",\"allocation_percent\":100}"
    first=0
  done
  cat > "$store/weekly-goals.v1.md" <<EOF
---
version: 1
committed: true
---
\`\`\`json
{"period":"2026-W26","goals":[$goals]}
\`\`\`
EOF
}

@test "pmg_default_projects returns this week's weekly-goal plane_project ids" {
  source "$REPO_ROOT/lib/vault.sh"
  source "$REPO_ROOT/lib/pm-groom.sh"
  _seed_weekly_goals "PID-ONE,PID-TWO"
  run pmg_default_projects
  [ "$status" -eq 0 ]
  [[ "$output" == "PID-ONE,PID-TWO" ]]
}

@test "pmg_default_projects is empty when there are no weekly goals (-> all-registry fallback)" {
  source "$REPO_ROOT/lib/vault.sh"
  source "$REPO_ROOT/lib/pm-groom.sh"
  # no weekly-goals file seeded
  run pmg_default_projects
  [ "$status" -eq 0 ]
  [[ -z "$output" ]]
}

@test "pmg_run with NO --projects scans only the weekly-goal projects" {
  _seed_weekly_goals "WG-PID"
  local realpy; realpy="$(command -v python3)"
  # Shim records which --projects the groom/ready scan was invoked with.
  cat > "$STUB/python3" <<SHIM
#!/usr/bin/env bash
seen=""
for ((k=1;k<=\$#;k++)); do
  if [[ "\${!k}" == "--projects" ]]; then n=\$((k+1)); seen="\${!n}"; fi
done
for a in "\$@"; do
  if [[ "\$a" == groom ]]; then echo "PROJECTS_SEEN=\$seen" >> "$TMP/seen.log"
    echo '{"applied":true,"projects":[],"todo":[],"needs_review":[],"errors":[]}'; exit 0; fi
  if [[ "\$a" == ready ]]; then echo '[]'; exit 0; fi
done
exec "$realpy" "\$@"
SHIM
  chmod +x "$STUB/python3"
  run env PATH="$STUB:$PATH" bash -c \
    "source '$REPO_ROOT/lib/vault.sh'; source '$REPO_ROOT/lib/launchd.sh'; source '$REPO_ROOT/lib/pm-groom.sh'; pmg_run --apply"
  [ "$status" -eq 0 ]
  grep -q "PROJECTS_SEEN=WG-PID" "$TMP/seen.log"
}

@test "pmg_run with explicit --projects overrides the weekly-goal default" {
  _seed_weekly_goals "WG-PID"
  local realpy; realpy="$(command -v python3)"
  cat > "$STUB/python3" <<SHIM
#!/usr/bin/env bash
seen=""
for ((k=1;k<=\$#;k++)); do
  if [[ "\${!k}" == "--projects" ]]; then n=\$((k+1)); seen="\${!n}"; fi
done
for a in "\$@"; do
  if [[ "\$a" == groom ]]; then echo "PROJECTS_SEEN=\$seen" >> "$TMP/seen.log"
    echo '{"applied":true,"projects":[],"todo":[],"needs_review":[],"errors":[]}'; exit 0; fi
  if [[ "\$a" == ready ]]; then echo '[]'; exit 0; fi
done
exec "$realpy" "\$@"
SHIM
  chmod +x "$STUB/python3"
  run env PATH="$STUB:$PATH" bash -c \
    "source '$REPO_ROOT/lib/vault.sh'; source '$REPO_ROOT/lib/launchd.sh'; source '$REPO_ROOT/lib/pm-groom.sh'; pmg_run --projects EXPLICIT-PID --apply"
  [ "$status" -eq 0 ]
  grep -q "PROJECTS_SEEN=EXPLICIT-PID" "$TMP/seen.log"
}

@test "queue renders the Issue id as a clickable Plane browse link" {
  local realpy; realpy="$(command -v python3)"
  cat > "$STUB/python3" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == groom ]]; then
    echo '{"applied":true,"projects":[],"todo":[{"id":89,"title":"x","project":"pb"}],"needs_review":[],"errors":[]}'; exit 0; fi
  if [[ "\$a" == ready ]]; then
    echo '[{"id":89,"title":"x","priority":"urgent","project":"pb"}]'; exit 0; fi
done
exec "$realpy" "\$@"
SHIM
  chmod +x "$STUB/python3"
  export PBRAIN_PLANE_WEB_BASE="http://plane.localhost:1800/pb"
  export PBRAIN_PLANE_DEEPLINK=0   # pin the http form (no desktop-app deep link)
  run env PATH="$STUB:$PATH" bash -c \
    "source '$REPO_ROOT/lib/vault.sh'; source '$REPO_ROOT/lib/launchd.sh'; source '$REPO_ROOT/lib/pm-groom.sh'; pmg_run --projects A --apply"
  [ "$status" -eq 0 ]
  grep -q '\[PB-89\](http://plane.localhost:1800/pb/browse/PB-89)' "$PBRAIN_VAULT/agent-work/daily-grooming/2026-06-22.md"
}

@test "queue link uses the plane:// deep link when the desktop app is present" {
  local realpy; realpy="$(command -v python3)"
  cat > "$STUB/python3" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == groom ]]; then
    echo '{"applied":true,"projects":[],"todo":[{"id":89,"title":"x","project":"pb"}],"needs_review":[],"errors":[]}'; exit 0; fi
  if [[ "\$a" == ready ]]; then
    echo '[{"id":89,"title":"x","priority":"urgent","project":"pb"}]'; exit 0; fi
done
exec "$realpy" "\$@"
SHIM
  chmod +x "$STUB/python3"
  export PBRAIN_PLANE_WEB_BASE="http://plane.localhost:1800/pb"
  export PBRAIN_PLANE_DEEPLINK=1   # force the deep-link form (PB-148)
  run env PATH="$STUB:$PATH" bash -c \
    "source '$REPO_ROOT/lib/vault.sh'; source '$REPO_ROOT/lib/launchd.sh'; source '$REPO_ROOT/lib/pm-groom.sh'; pmg_run --projects A --apply"
  [ "$status" -eq 0 ]
  grep -q '\[PB-89\](plane://pb/browse/PB-89)' "$PBRAIN_VAULT/agent-work/daily-grooming/2026-06-22.md"
}

@test "queue table renders an Auto column with the granted stages" {
  local realpy; realpy="$(command -v python3)"
  cat > "$STUB/python3" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == groom ]]; then
    echo '{"applied":true,"projects":[],"todo":[{"id":7,"title":"x","project":"pb"}],"needs_review":[],"errors":[]}'; exit 0; fi
  if [[ "\$a" == ready ]]; then
    echo '[{"id":7,"title":"x","priority":"high","project":"pb","auto_gates":["plan","implement"]}]'; exit 0; fi
done
exec "$realpy" "\$@"
SHIM
  chmod +x "$STUB/python3"
  export PBRAIN_PMG_NO_WEB=1
  run env PATH="$STUB:$PATH" bash -c \
    "source '$REPO_ROOT/lib/vault.sh'; source '$REPO_ROOT/lib/launchd.sh'; source '$REPO_ROOT/lib/pm-groom.sh'; pmg_run --projects A --apply"
  [ "$status" -eq 0 ]
  F="$PBRAIN_VAULT/agent-work/daily-grooming/2026-06-22.md"
  grep -q '| # | Issue | Priority | Auto | Title |' "$F"
  grep -q 'plan,implement' "$F"
}

@test "queue link uses the project SHORTCUT, not the name (multi-word project → no spaces)" {
  local realpy; realpy="$(command -v python3)"
  cat > "$STUB/python3" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == groom ]]; then
    echo '{"applied":true,"projects":[],"todo":[],"needs_review":[],"errors":[]}'; exit 0; fi
  if [[ "\$a" == ready ]]; then
    echo '[{"id":2,"title":"x","priority":"high","project":"YouTube Summary Extension","project_short":"YT"}]'; exit 0; fi
done
exec "$realpy" "\$@"
SHIM
  chmod +x "$STUB/python3"
  export PBRAIN_PLANE_WEB_BASE="http://plane.localhost:1800/pb"
  export PBRAIN_PLANE_DEEPLINK=0   # pin the http form so the shortcut shape is what's asserted
  run env PATH="$STUB:$PATH" bash -c \
    "source '$REPO_ROOT/lib/vault.sh'; source '$REPO_ROOT/lib/launchd.sh'; source '$REPO_ROOT/lib/pm-groom.sh'; pmg_run --projects A --apply"
  [ "$status" -eq 0 ]
  F="$PBRAIN_VAULT/agent-work/daily-grooming/2026-06-22.md"
  # the link is built from YT (the shortcut), with NO spaces — clickable
  grep -q '\[YT-2\](http://plane.localhost:1800/pb/browse/YT-2)' "$F"
  # and the broken name-based form must NOT appear
  ! grep -q 'YOUTUBE SUMMARY EXTENSION-2' "$F"
}

@test "queue abridges a long title so the row stays one line" {
  local realpy; realpy="$(command -v python3)"
  local longtitle="project-manager enforce file sole intake new work plus audit demote distracting low-level primitives everywhere"
  cat > "$STUB/python3" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == groom ]]; then
    echo '{"applied":true,"projects":[],"todo":[],"needs_review":[],"errors":[]}'; exit 0; fi
  if [[ "\$a" == ready ]]; then
    echo '[{"id":5,"title":"$longtitle","priority":"high","project":"pb","project_short":"PB"}]'; exit 0; fi
done
exec "$realpy" "\$@"
SHIM
  chmod +x "$STUB/python3"
  export PBRAIN_PMG_NO_WEB=1
  run env PATH="$STUB:$PATH" bash -c \
    "source '$REPO_ROOT/lib/vault.sh'; source '$REPO_ROOT/lib/launchd.sh'; source '$REPO_ROOT/lib/pm-groom.sh'; pmg_run --projects A --apply"
  [ "$status" -eq 0 ]
  F="$PBRAIN_VAULT/agent-work/daily-grooming/2026-06-22.md"
  # the full untruncated title must NOT appear; the ellipsis must
  ! grep -q "low-level primitives everywhere" "$F"
  grep -q '…' "$F"
}

@test "grooming file has an Enriched-this-run section, preserved across re-renders" {
  local realpy; realpy="$(command -v python3)"
  cat > "$STUB/python3" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == groom ]]; then
    echo '{"applied":true,"projects":[],"todo":[],"needs_review":[],"errors":[]}'; exit 0; fi
  if [[ "\$a" == ready ]]; then echo '[]'; exit 0; fi
done
exec "$realpy" "\$@"
SHIM
  chmod +x "$STUB/python3"
  export PBRAIN_PMG_NO_WEB=1
  run env PATH="$STUB:$PATH" bash -c \
    "source '$REPO_ROOT/lib/vault.sh'; source '$REPO_ROOT/lib/launchd.sh'; source '$REPO_ROOT/lib/pm-groom.sh'; pmg_run --projects A --apply"
  [ "$status" -eq 0 ]
  F="$PBRAIN_VAULT/agent-work/daily-grooming/2026-06-22.md"
  grep -q '## Enriched this run' "$F"
  # simulate the agent appending an entry, then re-render and confirm it survives
  printf '\n- [PB-9](x) — wrote description; priority→high\n' >> "$F"
  # also append to the staging copy the re-render reads from
  S="$PBRAIN_PMG_DIR/2026-06-22.md"
  [ -f "$S" ] && printf '\n## Enriched this run\n\n- [PB-9](x) — wrote description; priority→high\n' >> "$S" || true
  run env PATH="$STUB:$PATH" bash -c \
    "source '$REPO_ROOT/lib/vault.sh'; source '$REPO_ROOT/lib/launchd.sh'; source '$REPO_ROOT/lib/pm-groom.sh'; pmg_run --projects A --apply"
  [ "$status" -eq 0 ]
  grep -q 'PB-9.*wrote description' "$F"
}

@test "queue Issue cell falls back to a bare ref when no web base is configured" {
  local realpy; realpy="$(command -v python3)"
  cat > "$STUB/python3" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == groom ]]; then
    echo '{"applied":true,"projects":[],"todo":[{"id":89,"title":"x","project":"pb"}],"needs_review":[],"errors":[]}'; exit 0; fi
  if [[ "\$a" == ready ]]; then
    echo '[{"id":89,"title":"x","priority":"urgent","project":"pb"}]'; exit 0; fi
done
exec "$realpy" "\$@"
SHIM
  chmod +x "$STUB/python3"
  export PBRAIN_PMG_NO_WEB=1
  run env PATH="$STUB:$PATH" bash -c \
    "source '$REPO_ROOT/lib/vault.sh'; source '$REPO_ROOT/lib/launchd.sh'; source '$REPO_ROOT/lib/pm-groom.sh'; pmg_run --projects A --apply"
  [ "$status" -eq 0 ]
  # bare ref present, no markdown link
  grep -q 'PB-89' "$PBRAIN_VAULT/agent-work/daily-grooming/2026-06-22.md"
  ! grep -q '](http' "$PBRAIN_VAULT/agent-work/daily-grooming/2026-06-22.md"
}

@test "pmg_run writes the STAGING grooming-data even when the vault dir is unwritable" {
  local realpy; realpy="$(command -v python3)"
  cat > "$STUB/python3" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do
  if [[ "\$a" == groom ]]; then
    echo '{"applied":true,"projects":[],"todo":[{"id":1,"title":"ready one"}],"needs_review":[],"errors":[]}'
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
  # Simulate the headless-no-FDA case: make the vault grooming-data dir unwritable.
  mkdir -p "$PBRAIN_VAULT/agent-work/daily-grooming"
  chmod 500 "$PBRAIN_VAULT/agent-work/daily-grooming"
  run env PATH="$STUB:$PATH" bash -c \
    "source '$REPO_ROOT/lib/vault.sh'; source '$REPO_ROOT/lib/launchd.sh'; source '$REPO_ROOT/lib/pm-groom.sh'; pmg_run --projects A --apply"
  chmod 755 "$PBRAIN_VAULT/agent-work/daily-grooming" 2>/dev/null || true
  # The run still succeeds (vault write is best-effort) and staging IS written.
  [ "$status" -eq 0 ]
  staging="$PBRAIN_PMG_DIR/2026-06-22.data.md"
  [ -f "$staging" ]
  grep -q "## Queue — ordered (1)" "$staging"
  grep -q "ready one" "$staging"
}

@test "pmg_run preserves ## Auto-work from the STAGING file when the vault copy is absent" {
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
  # Seed a prior staging file carrying a recorded Auto-work outcome, and NO vault file.
  mkdir -p "$PBRAIN_PMG_DIR"
  printf '# old\n\n## Auto-work\n\n- **1** parked at: test\n' > "$PBRAIN_PMG_DIR/2026-06-22.data.md"
  run env PATH="$STUB:$PATH" bash -c \
    "source '$REPO_ROOT/lib/vault.sh'; source '$REPO_ROOT/lib/launchd.sh'; source '$REPO_ROOT/lib/pm-groom.sh'; pmg_run --projects A --apply"
  [ "$status" -eq 0 ]
  # The re-render must carry the prior Auto-work content forward (read from staging).
  grep -q "parked at: test" "$PBRAIN_PMG_DIR/2026-06-22.data.md"
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

@test "groom enable writes the daily LaunchAgent plist with the run --apply entry (bash fallback)" {
  # PBRAIN_GROOM_NO_APP=1 (from setup) forces the /bin/bash entry point.
  run PM groom enable --time 06:40 --projects A,B
  [ "$status" -eq 0 ] && [[ "$output" == *PM_GROOM_ENABLE* ]]
  plist="$HOME/Library/LaunchAgents/com.pbrain.pm-groom.plist"
  [ -f "$plist" ] \
    && grep -q "com.pbrain.pm-groom" "$plist" \
    && grep -q "<integer>6</integer>" "$plist" \
    && grep -q "<integer>40</integer>" "$plist" \
    && grep -q "groom" "$plist" \
    && grep -q "apply" "$plist" \
    && grep -q "PBRAIN_PMG_HEADLESS" "$plist"
}

@test "groom enable points the LaunchAgent at pbrain-groom.app when the binary is built" {
  # Force the app path on, and stub a pre-built binary so no swiftc is needed.
  unset PBRAIN_GROOM_NO_APP
  export PBRAIN_GROOM_APP="$TMP/pbrain-groom.app"
  mkdir -p "$PBRAIN_GROOM_APP/Contents/MacOS"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$PBRAIN_GROOM_APP/Contents/MacOS/pbrain-groom"
  chmod +x "$PBRAIN_GROOM_APP/Contents/MacOS/pbrain-groom"
  # A no-op swiftc stub so any build attempt is harmless (source-hash fast path
  # returns before calling it anyway, since the binary already exists).
  printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/swiftc"; chmod +x "$STUB/swiftc"
  run PM groom enable --time 06:40 --projects A,B
  [ "$status" -eq 0 ]
  plist="$HOME/Library/LaunchAgents/com.pbrain.pm-groom.plist"
  [ -f "$plist" ] \
    && grep -q "pbrain-groom" "$plist" \
    && grep -q -- "--script" "$plist" \
    && grep -q -- "--staging-dir" "$plist" \
    && grep -q -- "--vault-dir" "$plist"
}

@test "groom disable removes the LaunchAgent plist" {
  PM groom enable --time 07:00 >/dev/null
  plist="$HOME/Library/LaunchAgents/com.pbrain.pm-groom.plist"
  [ -f "$plist" ]
  run PM groom disable
  [ "$status" -eq 0 ] && [[ "$output" == *PM_GROOM_DISABLE* ]] && [ ! -f "$plist" ]
}

@test "groom enable --autonomous writes HOME/USER/AUTONOMOUS env (and no secret)" {
  run PM groom enable --time 06:40 --autonomous
  [ "$status" -eq 0 ] && [[ "$output" == *"autonomous: on"* ]]
  plist="$HOME/Library/LaunchAgents/com.pbrain.pm-groom.plist"
  # the autonomous env keys are present...
  local envblock
  envblock="$(awk '/<key>EnvironmentVariables/,/<\/dict>/' "$plist")"
  [[ "$envblock" == *PBRAIN_GROOM_AUTONOMOUS* ]]
  [[ "$envblock" == *"<key>HOME</key>"* ]]
  [[ "$envblock" == *"<key>USER</key>"* ]]
  # ...and NO secret is ever written.
  ! grep -qiE "api.?key|sk-ant|ANTHROPIC_API_KEY|token|secret" "$plist"
}

@test "plain groom enable does NOT add the autonomous env keys" {
  run PM groom enable --time 06:40
  [ "$status" -eq 0 ]
  plist="$HOME/Library/LaunchAgents/com.pbrain.pm-groom.plist"
  local envblock
  envblock="$(awk '/<key>EnvironmentVariables/,/<\/dict>/' "$plist")"
  [[ "$envblock" != *PBRAIN_GROOM_AUTONOMOUS* ]]
  [[ "$envblock" != *"<key>HOME</key>"* ]]
}

@test "groom status reports the autonomous mode (on after --autonomous, off otherwise)" {
  PM groom enable --time 06:40 --autonomous >/dev/null
  run PM groom status
  [ "$status" -eq 0 ] && [[ "$output" == *"autonomous: on"* ]]
  PM groom enable --time 06:40 >/dev/null
  run PM groom status
  [ "$status" -eq 0 ] && [[ "$output" == *"autonomous: off"* ]]
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
