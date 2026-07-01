#!/usr/bin/env bash
# harness.bash — the /plan-my-work driver for the pbrain e2e framework (PB-89).
#
# Command-agnostic rig (transcript, asserts, persona voice, env scaffold, result
# emission) lives in lib.bash; this file is ONLY the /plan-my-work-specific state
# machine: the 5-stage pipeline from commands/templates/plan-my-work/execute.txt
# (plan → implement → test → ship → land), walked stop-at-first-gap off each
# issue's own `auto:<stage>` labels, with blocked_by / parent-sub-issue
# multi-loop dispatch, and the park-and-resume path.
#
# REAL vs FAKED:
#   REAL   — commands/project-manager.sh (the thing under test) runs unmodified;
#            real git worktree/branch/commit; real PBRAIN_VAULT/DB; persona prefs.
#   FAKED  — the Plane network boundary (fake_plane.py, swapped for lib/plane.py),
#            and the irreversible gh / CI / merge seams (scripted, shown as SEAM
#            lines, never fabricated into a real PR/merge).
# Tracking channel = the Plane write-journal (tracking_kind=plane-journal).

set -uo pipefail
source "$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib.bash"

# --- pmw-specific run state -------------------------------------------------
E2E_FAKEROOT=""      # fake pbrain root (real project-manager.sh, fake plane.py)
E2E_JOURNAL=""       # Plane write journal (one JSON record per line) = tracking
E2E_REPO=""          # throwaway target git repo the loop "works in"
E2E_PM=""            # path to the fake-rooted project-manager.sh
E2E_TERMINALS=()     # per-driven-issue terminal: "<id>:done" | "<id>:park:<stage>"
E2E_CUR_ID=""        # the issue the stage code is currently driving
PM_TIE=""            # the CURRENT issue's composite tie (write verbs require it)

# --- Plane write-journal predicates -----------------------------------------
_journal_has() {  # _journal_has <verb> [key=value ...]
  local verb="$1"; shift
  python3 - "$E2E_JOURNAL" "$verb" "$@" <<'PY'
import json, sys
path, verb = sys.argv[1], sys.argv[2]
want = dict(kv.split("=", 1) for kv in sys.argv[3:])
try:
    rows = [json.loads(l) for l in open(path) if l.strip()]
except FileNotFoundError:
    rows = []
for r in rows:
    if r.get("verb") != verb:
        continue
    if all(str(r.get(k, "")) == v or v in str(r.get(k, "")) for k, v in want.items()):
        sys.exit(0)
sys.exit(1)
PY
}
_journal_no() { ! _journal_has "$@"; }
_journal_move_to() { _journal_has move status="$1"; }

# Ordering: the blocker's first move→doing precedes the primary's.
_journal_order_blocker_first() {  # <blocker_tie> <primary_tie>
  python3 - "$E2E_JOURNAL" "$1" "$2" <<'PY'
import json, sys
path, btie, ptie = sys.argv[1], sys.argv[2], sys.argv[3]
rows = [json.loads(l) for l in open(path) if l.strip()]
def first_doing(tie):
    for i, r in enumerate(rows):
        if r.get("verb") == "move" and r.get("tie") == tie and r.get("status") == "doing":
            return i
    return None
b, p = first_doing(btie), first_doing(ptie)
sys.exit(0 if (b is not None and (p is None or b < p)) else 1)
PY
}
# Ordering: the parent's move→done is the LAST done in the journal.
_journal_parent_done_last() {  # <parent_tie>
  python3 - "$E2E_JOURNAL" "$1" <<'PY'
import json, sys
path, ptie = sys.argv[1], sys.argv[2]
rows = [json.loads(l) for l in open(path) if l.strip()]
dones = [i for i, r in enumerate(rows)
         if r.get("verb") == "move" and r.get("status") == "done"]
sys.exit(0 if dones and rows[dones[-1]].get("tie") == ptie else 1)
PY
}

# --- fake pbrain root (real PM, faked plane.py) -----------------------------
_build_fakeroot() {
  mkdir -p "$E2E_FAKEROOT/lib" "$E2E_FAKEROOT/commands/templates/plan-my-work" \
           "$E2E_FAKEROOT/commands/templates/project-manager"
  cp "$E2E_REAL_ROOT"/lib/*.sh "$E2E_FAKEROOT/lib/" 2>/dev/null || true
  cp "$E2E_REAL_ROOT"/lib/*.py "$E2E_FAKEROOT/lib/" 2>/dev/null || true
  cp "$E2E_REAL_ROOT/commands/project-manager.sh" "$E2E_FAKEROOT/commands/"
  cp "$E2E_REAL_ROOT/commands/plan-my-work.sh" "$E2E_FAKEROOT/commands/"
  cp -R "$E2E_REAL_ROOT/commands/templates/." \
        "$E2E_FAKEROOT/commands/templates/" 2>/dev/null || true
  cp "$E2E_REAL_ROOT/tests/e2e/fake_plane.py" "$E2E_FAKEROOT/lib/plane.py"
  chmod +x "$E2E_FAKEROOT/commands/"*.sh "$E2E_FAKEROOT/lib/plane.py" 2>/dev/null || true
  E2E_PM="$E2E_FAKEROOT/commands/project-manager.sh"
}

_pm() {  # run the REAL project-manager.sh against the fake plane.py
  E2E_SCENARIO="$E2E_SCENARIO_FILE" E2E_JOURNAL="$E2E_JOURNAL" \
    bash "$E2E_PM" "$@" 2>>"$E2E_WORK/pm.stderr"
}

# --- per-issue scenario accessors -------------------------------------------
# _iss <id> <key> → field from the issue resolved by id (multi-loop) or, when the
# scenario has no `issues` map, from the lone `issue`. List fields space-joined.
_iss() {
  python3 - "$E2E_SCENARIO_FILE" "$1" "$2" <<'PY'
import json, sys
sc = json.load(open(sys.argv[1])); ref, key = sys.argv[2], sys.argv[3]
def resolve(sc, ref):
    for it in (sc.get("issues") or []):
        if ref and (ref == it.get("tie") or ref == it.get("id")
                    or (it.get("id") and it.get("id") in str(ref))):
            return it
    return sc.get("issue", {})
it = resolve(sc, ref)
v = it.get(key, "")
print(" ".join(str(x) for x in v) if isinstance(v, list) else v)
PY
}
_iss_gates() { _iss "$1" auto_gates; }
_iss_has_gate() { [[ " $(_iss_gates "$1") " == *" $2 "* ]]; }
_iss_field() { local v; v="$(_iss "$1" "$2")"; [[ -n "$v" ]] && { printf '%s\n' "$v"; return; }; _sc "$2"; }

# Back-compat shims keyed on the CURRENT issue.
_sc_issue() { _iss "$E2E_CUR_ID" "$1"; }
_sc_gates() { _iss_gates "$E2E_CUR_ID"; }
_has_gate() { _iss_has_gate "$E2E_CUR_ID" "$1"; }

# --- driving ONE leaf issue through the 5 stages (mirrors execute.txt) -------
_drive_leaf() {
  local id="$1" slug base_branch wt
  E2E_CUR_ID="$id"
  PM_TIE="$(_iss "$id" tie)"
  slug="$(_iss "$id" id_slug)"; [[ -n "$slug" ]] || slug="$(tr '[:upper:]' '[:lower:]' <<<"$id")"
  [[ -n "$slug" ]] || slug="pb-e2e"
  base_branch="$(_sc base_branch)"; [[ -n "$base_branch" ]] || base_branch="main"
  wt="$E2E_WORK/wt-$slug"

  e2e_say pmw "marking $id in progress"
  e2e_cmd "project-manager move $id --to doing"; _pm move "$PM_TIE" --to doing >/dev/null
  e2e_assert "$id moved to doing" _journal_has move tie="$PM_TIE" status=doing

  # STAGE 1 — PLAN
  if _has_gate plan; then
    e2e_say pmw "$id: plan's auto-approved (auto:plan) — picking it up"
  else
    if ! _say_advances plan; then e2e_say pmw "ok, holding on plan then"; _park plan "$slug" "$wt"; _term "$id" "park:plan"; return 1; fi
    e2e_say pmw "got it, starting on plan"
  fi
  git -C "$E2E_REPO" worktree add "$wt" -b "pbrain/$slug" "origin/$base_branch" >/dev/null 2>&1 \
    || git -C "$E2E_REPO" worktree add "$wt" -b "pbrain/$slug" "$base_branch" >/dev/null 2>&1
  e2e_cmd "git worktree add wt-$slug -b pbrain/$slug origin/$base_branch"
  e2e_assert "$id: worktree created on isolated branch" test -d "$wt"
  e2e_assert "$id: branch is pbrain/$slug" test "$(git -C "$wt" branch --show-current)" = "pbrain/$slug"
  if [[ "$(_iss "$id" approved)" == "True" ]]; then
    e2e_say pmw "$id: plan already approved — using the saved one, not re-drafting"
  else
    e2e_say pmw "$id: no approved plan yet — drafting one and saving it to the issue"
    _pm update --edits '[{"tie":"'"$PM_TIE"'","field":"description","value":"<plan>"}]' >/dev/null
    e2e_cmd "project-manager update --edits (append ## Implementation Plan)"
    e2e_assert "$id: plan saved to issue description" _journal_has update fields=description
  fi
  _pm comment "$PM_TIE" --body "pbrain auto-exec: STAGE plan complete; branch pbrain/$slug" >/dev/null
  e2e_assert "$id: stage-1 log comment appended" _journal_has comment tie="$PM_TIE"

  # STAGE 2 — IMPLEMENT
  if ! _stage_gate implement "$slug" "$wt"; then _term "$id" "park:implement"; return 1; fi
  printf 'e2e change for %s\n' "$id" >>"$wt/E2E_CHANGE.txt"
  git -C "$wt" add -A >/dev/null 2>&1
  git -C "$wt" -c user.email=e2e@x -c user.name=e2e commit -m "PB e2e: implement $id" >/dev/null 2>&1
  e2e_cmd "git commit -m 'implement $id'"
  e2e_assert "$id: implement produced a local commit" git -C "$wt" rev-parse HEAD~0
  _pm comment "$PM_TIE" --body "pbrain auto-exec: STAGE implement complete; files changed: E2E_CHANGE.txt" >/dev/null

  # STAGE 3 — TEST
  if ! _stage_gate test "$slug" "$wt"; then _term "$id" "park:test"; return 1; fi
  e2e_say pmw "$id: running the tests…"
  if [[ "$(_iss_field "$id" test_result)" == "red" ]]; then
    e2e_say pmw "$id: tests are red — stopping before ship"
    e2e_assert "$id: test red → no done" _journal_no move tie="$PM_TIE" status=done
    _park test "$slug" "$wt"; _term "$id" "park:test"; return 1
  fi
  e2e_say pmw "$id: tests green"
  _pm comment "$PM_TIE" --body "pbrain auto-exec: STAGE test complete; tests green" >/dev/null

  # STAGE 4 — SHIP
  if ! _stage_gate ship "$slug" "$wt"; then _term "$id" "park:ship"; return 1; fi
  if [[ "$(_iss_field "$id" gh_present)" == "no" ]]; then
    e2e_say pmw "$id: no gh here — pushing the branch and handing back a compare link, not faking a PR"
    e2e_seam "git push origin pbrain/$slug (no network in harness)"
    e2e_note "manual PR: $(_sc web_base)/pulls/new pbrain/$slug"
    e2e_assert "$id: no PR url fabricated into Plane" _journal_no comment tie="$PM_TIE" body=PR:
    _park ship "$slug" "$wt"; _term "$id" "park:ship"; return 1
  fi
  e2e_seam "gh pr create --fill --base $base_branch (real-run only)"
  _pm comment "$PM_TIE" --body "PR: $(_sc web_base)/pr/$slug (SEAM: not a real PR in harness)" >/dev/null
  e2e_assert "$id: PR link recorded to issue" _journal_has comment tie="$PM_TIE" body=PR:

  # STAGE 5 — LAND (irreversible, double-gated)
  if ! _has_gate land; then
    if ! _say_advances land; then e2e_say pmw "ok, not landing it then — parking"; _park land "$slug" "$wt"; _term "$id" "park:land"; return 1; fi
  fi
  e2e_say pmw "$id: checking CI before merge (red hard-stops, even with auto:land)"
  if [[ "$(_iss_field "$id" ci_result)" == "red" ]]; then
    e2e_seam "gh pr checks --watch → RED (scripted)"
    e2e_say pmw "$id: CI's red — not merging, parking instead"
    e2e_assert "$id: CI red HARD-STOPS merge regardless of auto:land" _journal_no move tie="$PM_TIE" status=done
    _park land "$slug" "$wt"; _term "$id" "park:land"; return 1
  fi
  e2e_seam "gh pr checks --watch → GREEN (scripted)"
  if _has_gate land; then
    e2e_say pmw "$id: auto:land set + CI green — typed confirm waived, merging"
  else
    e2e_say pmw "$id: got your land confirm + CI green — merging"
  fi
  e2e_seam "gh pr merge --squash --delete-branch (real-run only — NOT executed)"
  e2e_assert "$id: no release cut at land (invariant)" _journal_no tag add=release
  _pm move "$PM_TIE" --to done >/dev/null
  e2e_cmd "project-manager move $id --to done"
  e2e_assert "$id: moved to done only after (waived/typed)+green" _journal_has move tie="$PM_TIE" status=done
  e2e_say pmw "$id: landed 🎉"
  _term "$id" "done"
  return 0
}

_term() { E2E_TERMINALS+=("$1:$2"); }

# --- dispatcher (pre-flight: blocked_by → subtree → leaf) -------------------
_run_loop() {
  local primary; primary="$(_iss "" id)"
  [[ -n "$primary" ]] || primary="$(_sc primary_id)"
  E2E_CUR_ID="$primary"; PM_TIE="$(_iss "$primary" tie)"

  e2e_user "$primary — can you take a look n start on this"
  e2e_say pmw "sure, pulling up $primary — reading its state from Plane"
  e2e_cmd "project-manager spec <id> --read"
  local spec; spec="$(_pm spec "$PM_TIE" --read)"
  e2e_assert "spec --read returns PM_SPEC marker" grep -q PM_SPEC <<<"$spec"

  local blocked subtree
  blocked="$(_iss "$primary" blocked_by)"
  subtree="$(_iss "$primary" subtree)"

  if [[ -n "$blocked" && "$blocked" != "[]" ]]; then
    e2e_say pmw "$primary is blocked by [$blocked] — doing the blocker(s) first"
    local b
    for b in $blocked; do
      e2e_user "ye do the blocker $b first then"
      if ! _drive_leaf "$b"; then
        e2e_say pmw "blocker $b parked — can't proceed to $primary yet"
        return 0
      fi
    done
    e2e_assert "primary $primary not started before its blocker reached doing" \
      _journal_order_blocker_first "$(_iss "$b" tie)" "$(_iss "$primary" tie)"
    _drive_leaf "$primary"; return 0
  fi

  if [[ -n "$subtree" && "$subtree" != "[]" ]]; then
    e2e_say pmw "$primary has open sub-issues [$subtree] — driving each (one branch/PR each), parent closed last"
    local c
    for c in $subtree; do
      e2e_user "ok work thru the sub-issues"
      if ! _drive_leaf "$c"; then
        e2e_say pmw "child $c parked — parent $primary stays open"
        return 0
      fi
    done
    E2E_CUR_ID="$primary"; PM_TIE="$(_iss "$primary" tie)"
    e2e_say pmw "all sub-issues landed — closing the parent $primary last"
    _pm move "$PM_TIE" --to done >/dev/null
    e2e_cmd "project-manager move $primary --to done"
    e2e_assert "parent $primary closed (move→done)" _journal_has move tie="$PM_TIE" status=done
    e2e_assert "parent closed AFTER all children (last done in journal)" \
      _journal_parent_done_last "$PM_TIE"
    _term "$primary" "done"
    return 0
  fi

  _drive_leaf "$primary"
  return 0
}

_stage_gate() {  # <stage> <slug> <wt>
  local stage="$1" slug="$2" wt="$3"
  if _has_gate "$stage"; then e2e_say pmw "$E2E_CUR_ID: $stage's auto-approved (auto:$stage) — going"; return 0; fi
  if _say_advances "$stage"; then e2e_say pmw "alright, on it — $stage"; return 0; fi
  e2e_say pmw "ok holding at $stage"; _park "$stage" "$slug" "$wt"; return 1
}

_park() {  # <stage> <slug> <wt>
  local stage="$1" slug="$2" wt="$3"
  e2e_say pmw "no worries — saving where i got to so we can pick it back up. parking at $stage"
  if [[ -d "$wt" ]]; then
    git -C "$wt" add -A >/dev/null 2>&1 || true
    git -C "$wt" -c user.email=e2e@x -c user.name=e2e \
      commit -m "WIP: parked at $stage (pbrain auto-exec)" >/dev/null 2>&1 || true
    e2e_cmd "git commit -m 'WIP: parked at $stage'  (then push -u origin pbrain/$slug)"
    e2e_seam "git push -u origin pbrain/$slug (no network in harness)"
    e2e_assert "park made a WIP commit on the branch" git -C "$wt" rev-parse HEAD~0
  fi
  _pm comment "$PM_TIE" --body "pbrain park: branch pbrain/$slug, parked at $stage; resume /plan-my-work" >/dev/null
  e2e_cmd "project-manager comment <id> --body 'pbrain park: ... parked at $stage'"
  e2e_assert "park breadcrumb comment recorded" _journal_has comment tie="$PM_TIE" body="pbrain park:"
  e2e_assert "this issue stays out of done on park" _journal_no move tie="$PM_TIE" status=done
  return 0
}

# Judge per-issue terminals against `expect`.
_judge_expect() {
  local expect; expect="$(_sc expect)"
  local terms="${E2E_TERMINALS[*]:-}"
  e2e_note "terminals: [$terms] | expect: $expect"
  case "$expect" in
    done)
      [[ -n "$terms" ]] || return 1
      local t; for t in "${E2E_TERMINALS[@]}"; do [[ "$t" == *":done" ]] || return 1; done
      return 0 ;;
    park:*:*)
      local rest="${expect#park:}"; local pid="${rest%%:*}" pstage="${rest#*:}"
      [[ " $terms " == *" $pid:park:$pstage "* ]] ;;
    park:*)
      local stage="${expect#park:}" t
      for t in "${E2E_TERMINALS[@]:-}"; do [[ "$t" == *":done" ]] && return 1; done
      for t in "${E2E_TERMINALS[@]:-}"; do [[ "$t" == *":park:$stage" ]] && return 0; done
      return 1 ;;
    *) return 1 ;;
  esac
}

# --- public entry: run one (scenario × persona) -----------------------------
# e2e_run <real_root> <scenario_file> <persona_file> <out_dir>
e2e_run() {
  e2e_env_setup "$1" "$2" "$3" "$4"
  E2E_TERMINALS=()
  E2E_FAKEROOT="$E2E_WORK/fakeroot"
  E2E_JOURNAL="$E2E_WORK/plane-journal.jsonl"
  E2E_REPO="$E2E_WORK/target-repo"
  : >"$E2E_JOURNAL"; : >"$E2E_WORK/pm.stderr"

  # Configure Plane (unreachable is fine — fake_plane.py is the engine).
  cat >"$XDG_CONFIG_HOME/pbrain/plane.json" <<'JSON'
{"base_url":"http://127.0.0.1:9","api_key":"E2E","workspace":"ws","project":"pid"}
JSON

  _build_fakeroot
  mkdir -p "$E2E_REPO"
  git -C "$E2E_REPO" init -q
  git -C "$E2E_REPO" -c user.email=e2e@x -c user.name=e2e commit -q --allow-empty -m init
  printf 'pbrain e2e target\n' >"$E2E_REPO/README.md"
  git -C "$E2E_REPO" add -A; git -C "$E2E_REPO" -c user.email=e2e@x -c user.name=e2e commit -q -m seed

  _run_loop

  e2e_assert "reached expected terminal ($(_sc expect))" _judge_expect
  local vault_files; vault_files="$(find "$PBRAIN_VAULT" -type f 2>/dev/null)"
  e2e_assert "PB-94: loop wrote nothing to the vault" test -z "$vault_files"
  e2e_assert "no unexpected stderr from project-manager.sh" test ! -s "$E2E_WORK/pm.stderr"

  e2e_fold_parse_fails
  local pass="true"; [[ ${#E2E_FAILURES[@]} -eq 0 ]] || pass="false"

  # Tracking channel = the Plane write-journal.
  e2e_emit_result "$pass" "plane-journal" "$E2E_JOURNAL" ""
  e2e_safe_rmrf "$E2E_WORK"
  [[ "$pass" == "true" ]]
}
