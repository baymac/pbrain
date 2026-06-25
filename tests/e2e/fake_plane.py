#!/usr/bin/env python3
"""fake_plane.py — drop-in replacement for lib/plane.py in the e2e harness.

PB-89. This is NOT a re-implementation of Plane. It is the network boundary
seam: the real commands/project-manager.sh runs unmodified on top of it and
shells out `python3 <this> <verb> ...` exactly as it would the real engine.

  - READ verbs (spec/find/subtree/blocked-by/web-base/link-base/projects) print canned
    JSON sourced from the scenario file named by $E2E_SCENARIO.
  - WRITE verbs (move/comment/update/tag/priority/...) print a minimal OK shape
    AND append a structured record to the journal at $E2E_JOURNAL, one JSON
    object per line, so the harness can assert the exact write sequence a run
    produced. Nothing leaves the machine.

Honesty: this fakes only Plane I/O. project-manager.sh's argument parsing,
marker emission (PM_SPEC/PM_MOVE/...), and dispatch all run for real.
"""
import json
import os
import sys

SCENARIO = os.environ.get("E2E_SCENARIO", "")
JOURNAL = os.environ.get("E2E_JOURNAL", "")


def _load_scenario():
    if not SCENARIO or not os.path.isfile(SCENARIO):
        return {}
    with open(SCENARIO) as fh:
        return json.load(fh)


def _resolve(sc, ref):
    """Resolve a tie/id ref to its issue dict.

    Multi-loop scenarios carry an `issues` list (each with its own tie/id/gates/
    blocked_by/subtree); single-leaf scenarios carry just `issue`. Match by exact
    tie, exact id, or id-substring-of-tie (project-manager passes the composite
    tie). Falls back to the lone `issue`.
    """
    issues = sc.get("issues") or []
    for it in issues:
        if ref and (ref == it.get("tie") or ref == it.get("id")
                    or (it.get("id") and it.get("id") in str(ref))
                    or (it.get("tie") and ref in str(it.get("tie")))):
            return it
    return sc.get("issue", {})


def _journal(record):
    if not JOURNAL:
        return
    with open(JOURNAL, "a") as fh:
        fh.write(json.dumps(record, sort_keys=True) + "\n")


def _emit(obj):
    """plane.py prints raw JSON on stdout; project-manager.sh wraps it."""
    sys.stdout.write(json.dumps(obj))
    sys.stdout.write("\n")


def _flag(argv, name):
    """Tiny --flag <value> reader matching how project-manager.sh passes args."""
    if name in argv:
        i = argv.index(name)
        if i + 1 < len(argv):
            return argv[i + 1]
    return None


def main(argv):
    if not argv:
        _emit({})
        return 0
    verb, rest = argv[0], argv[1:]
    sc = _load_scenario()
    # The first non-flag token after the verb is the issue ref (tie/id), if any.
    ref = next((a for a in rest if not a.startswith("--")), "")
    issue = _resolve(sc, ref) if ref else sc.get("issue", {})

    # ---- READ verbs: serve canned scenario state ----------------------------
    if verb == "spec":
        # The shape project-manager.sh's spec --read consumer expects: the
        # issue's plan/approval/gate state plus its comments + dependencies.
        _emit({
            "status": "ok",
            "tie": issue.get("tie", ""),
            "id": issue.get("id", ""),
            "issue_id": issue.get("issue_id", ""),
            "title": issue.get("title", ""),
            "description": issue.get("description", ""),
            "description_html": issue.get("description_html", ""),
            "has_plan": issue.get("has_plan", False),
            "comments": issue.get("comments", []),
            "comments_authoritative": issue.get("comments_authoritative", True),
            "approved": issue.get("approved", False),
            "approved_label": "plan-approved",
            "auto_gates": issue.get("auto_gates", []),
            "blocked_by": issue.get("blocked_by", []),
            "priority": issue.get("priority", "none"),
            "state": issue.get("state", "Todo"),
            "project": issue.get("project", ""),
            "project_id": issue.get("project_id", ""),
        })
        return 0
    if verb == "find":
        _emit(sc.get("find", []))
        return 0
    if verb == "subtree":
        # open sub-issue ids of the resolved (parent) issue
        _emit(issue.get("subtree", sc.get("subtree", [])))
        return 0
    if verb == "blocked-by":
        _emit(issue.get("blocked_by", []))
        return 0
    if verb == "web-base":
        _emit(sc.get("web_base", "http://plane.localhost:1800/pb"))
        return 0
    if verb == "link-base":
        # Preferred clickable base (PB-148): the scenario can pin "link_base" to a
        # plane:// deep link; default mirrors web-base (no app → http fallback).
        _emit(sc.get("link_base", sc.get("web_base", "http://plane.localhost:1800/pb")))
        return 0
    if verb == "projects":
        _emit(sc.get("projects", []))
        return 0

    # ---- WRITE verbs: record to the journal, print an OK shape ---------------
    if verb == "move":
        rec = {"verb": "move", "tie": _flag(rest, "--tie"),
               "status": _flag(rest, "--status")}
        _journal(rec)
        _emit([{"tie": rec["tie"], "status": rec["status"], "ok": True}])
        return 0
    if verb == "comment":
        rec = {"verb": "comment", "tie": _flag(rest, "--tie"),
               "body": _flag(rest, "--body")}
        _journal(rec)
        _emit([{"tie": rec["tie"], "ok": True, "field": "comment"}])
        return 0
    if verb == "update":
        edits = _flag(rest, "--edits") or "[]"
        try:
            parsed = json.loads(edits)
        except (ValueError, TypeError):
            parsed = []
        fields = [e.get("field") for e in parsed if isinstance(e, dict)]
        _journal({"verb": "update", "fields": fields})
        _emit([{"ok": True, "field": f} for f in fields] or [{"ok": True}])
        return 0
    if verb == "tag":
        rec = {"verb": "tag", "tie": _flag(rest, "--tie"),
               "add": _flag(rest, "--add"), "remove": _flag(rest, "--remove"),
               "set": _flag(rest, "--set")}
        _journal(rec)
        _emit([{"tie": rec["tie"], "ok": True}])
        return 0
    if verb == "priority":
        rec = {"verb": "priority", "tie": _flag(rest, "--tie"),
               "value": _flag(rest, "--value")}
        _journal(rec)
        _emit([{"tie": rec["tie"], "ok": True}])
        return 0

    # Any other verb: record it so the harness can flag unexpected traffic,
    # and degrade to an empty array (the real engine's safe shape).
    _journal({"verb": verb, "argv": rest})
    _emit([])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
