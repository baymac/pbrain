#!/usr/bin/env python3
"""pbrain ↔ Plane (makeplane) integration — the hybrid backend.

Plane (self-hosted or Cloud) is the project brain: the hierarchy (Module →
Issue → Sub-issue), the UI, the source of truth. pbrain stays the daily-ritual
layer and talks to Plane through exactly TWO seams:

  • READ  ("what's ready"):  list work-items, keep the ones in an active state
                             group, emit pbrain's ready-task JSON.
  • WRITE ("set status"):    PATCH a work-item's `state` to the state id that
                             matches the target status group (+ completed_at).

Plane's status is a first-class `State` resource grouped into
backlog | unstarted | started | completed | cancelled. We map:

    Plane state group   →   pbrain status        (read)
      backlog               todo  (not "ready" unless --include-backlog)
      unstarted             todo  (ready)
      started               doing (ready)
      completed             done
      cancelled             dropped

    pbrain status       →   target Plane group    (write)
      todo                  unstarted
      doing / blocked       started
      done                  completed
      dropped               cancelled

Config (NEVER in the vault — it holds a secret token) lives at
~/.config/pbrain/plane.json, with env overrides:
    PBRAIN_PLANE_BASE_URL    e.g. https://api.plane.so  (or your self-host URL)
    PBRAIN_PLANE_API_KEY     a Personal Access Token (X-API-Key header)
    PBRAIN_PLANE_WORKSPACE   workspace slug
    PBRAIN_PLANE_PROJECT     default project id (uuid)
    PBRAIN_PLANE_DEFAULT_EST_H   fallback hours per task for block-packing (default 2)

Stdlib only (urllib). The HTTP client is isolated so the pure mapping
functions can be unit-tested without a network.
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

# State group ordering for "active / ready"
READY_GROUPS = ("unstarted", "started")
GROUP_TO_STATUS = {
    "backlog": "todo",
    "unstarted": "todo",
    "started": "doing",
    "completed": "done",
    "cancelled": "dropped",
}
STATUS_TO_GROUP = {
    "todo": "unstarted",
    "doing": "started",
    "blocked": "started",
    "done": "completed",
    "dropped": "cancelled",
}
PRIORITY_RANK = {"urgent": 0, "high": 1, "medium": 2, "low": 3, "none": 4, "": 4, None: 4}


class PlaneError(Exception):
    pass


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
def config_path():
    base = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config"))
    return os.path.join(base, "pbrain", "plane.json")


def load_config():
    """Merge the JSON config file (if any) with env overrides. Env wins."""
    cfg = {}
    p = config_path()
    if os.path.exists(p):
        try:
            with open(p) as fh:
                cfg = json.load(fh)
        except Exception as e:
            raise PlaneError("cannot read %s: %s" % (p, e))
    env = {
        "base_url": os.environ.get("PBRAIN_PLANE_BASE_URL"),
        "api_key": os.environ.get("PBRAIN_PLANE_API_KEY"),
        "workspace": os.environ.get("PBRAIN_PLANE_WORKSPACE"),
        "project": os.environ.get("PBRAIN_PLANE_PROJECT"),
        "default_est_h": os.environ.get("PBRAIN_PLANE_DEFAULT_EST_H"),
    }
    for k, v in env.items():
        if v:
            cfg[k] = v
    if cfg.get("base_url"):
        cfg["base_url"] = cfg["base_url"].rstrip("/")
    try:
        cfg["default_est_h"] = float(cfg.get("default_est_h") or 2)
    except (TypeError, ValueError):
        cfg["default_est_h"] = 2.0
    return cfg


def normalize_registry(cfg):
    """Return the project registry as a list of {id,name,shortcut}.

    Back-compatible: when `projects` is absent, synthesize a one-entry registry
    from the lone `project` uuid (and optional `project_name`), so existing
    single-project configs keep working untouched. Pure — no network, no I/O.
    """
    out = []
    projs = cfg.get("projects")
    if isinstance(projs, list):
        for p in projs:
            if isinstance(p, dict) and p.get("id"):
                out.append({"id": p["id"],
                            "name": p.get("name") or p["id"],
                            "shortcut": (p.get("shortcut") or "")})
            elif isinstance(p, str) and p:
                out.append({"id": p, "name": p, "shortcut": ""})
    if out:
        return out
    lone = cfg.get("project")
    if lone:
        return [{"id": lone, "name": cfg.get("project_name") or lone, "shortcut": ""}]
    return []


_UUID_RE = None


def _looks_like_uuid(s):
    import re
    global _UUID_RE
    if _UUID_RE is None:
        _UUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                              r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
    return bool(_UUID_RE.match((s or "").strip()))


def resolve_project_ref(cfg, ref):
    """Resolve a project reference (uuid | name | shortcut) to its uuid.

    Match precedence: exact id → shortcut (ci) → name (ci). An unknown ref that
    already looks like a uuid is accepted as-is (lets a raw id pass before the
    registry is synced); anything else returns None. Pure.
    """
    if not ref:
        return None
    r = ref.strip()
    rl = r.lower()
    reg = normalize_registry(cfg)
    for p in reg:
        if p["id"] == r:
            return p["id"]
    for p in reg:
        if (p.get("shortcut") or "").lower() == rl and rl:
            return p["id"]
    for p in reg:
        if (p.get("name") or "").lower() == rl:
            return p["id"]
    return r if _looks_like_uuid(r) else None


def project_label(cfg, pid):
    """Friendly name for a project id (falls back to the id). Pure."""
    for p in normalize_registry(cfg):
        if p["id"] == pid:
            return p.get("name") or pid
    return pid


def normalize_tie(cfg, tie):
    """Normalize the project part of a `<project>:<issue>` tie to a uuid. Pure."""
    if not tie or ":" not in tie:
        return tie
    pref, iid = tie.split(":", 1)
    pid = resolve_project_ref(cfg, pref) or pref
    return "%s:%s" % (pid, iid)


def save_config(cfg):
    p = config_path()
    os.makedirs(os.path.dirname(p), exist_ok=True)
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)  # secret → 0600
    with os.fdopen(fd, "w") as fh:
        json.dump(cfg, fh, indent=2)
    return p


def require(cfg, *keys):
    missing = [k for k in keys if not cfg.get(k)]
    if missing:
        raise PlaneError("Plane not configured: missing %s. Run: /project-manager setup"
                         % ", ".join(missing))


# ---------------------------------------------------------------------------
# HTTP client (isolated — the only part that touches the network)
# ---------------------------------------------------------------------------
class PlaneClient:
    def __init__(self, base_url, api_key, workspace, opener=None):
        self.base = base_url.rstrip("/")
        self.api_key = api_key
        self.workspace = workspace
        self._opener = opener or urllib.request.build_opener()

    def _url(self, path):
        return "%s/api/v1/workspaces/%s/%s" % (self.base, self.workspace, path.lstrip("/"))

    def _request(self, method, path, params=None, body=None):
        url = self._url(path)
        if params:
            url += "?" + urllib.parse.urlencode({k: v for k, v in params.items() if v not in (None, "")})
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("X-API-Key", self.api_key)
        req.add_header("Content-Type", "application/json")
        try:
            with self._opener.open(req, timeout=30) as resp:
                raw = resp.read().decode()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = ""
            try:
                detail = e.read().decode()[:400]
            except Exception:
                pass
            raise PlaneError("Plane API %s %s -> HTTP %s %s" % (method, path, e.code, detail))
        except urllib.error.URLError as e:
            raise PlaneError("Plane API unreachable (%s): %s" % (url, e))

    def list_all(self, path, params=None):
        """Follow cursor pagination, return all `results`."""
        params = dict(params or {})
        params.setdefault("per_page", 100)
        out, cursor, guard = [], None, 0
        while True:
            if cursor:
                params["cursor"] = cursor
            page = self._request("GET", path, params=params)
            if isinstance(page, list):          # some endpoints return a bare list
                out.extend(page)
                break
            out.extend(page.get("results", []))
            cursor = page.get("next_cursor")
            if not page.get("next_page_results") or not cursor:
                break
            guard += 1
            if guard > 200:                     # safety: never loop forever
                break
        return out

    def list_states(self, project_id):
        return self.list_all("projects/%s/states/" % project_id)

    def list_work_items(self, project_id):
        return self.list_all("projects/%s/work-items/" % project_id, params={"expand": "assignees,state"})

    def list_modules(self, project_id):
        return self.list_all("projects/%s/modules/" % project_id)

    def list_module_items(self, project_id, module_id):
        return self.list_all("projects/%s/modules/%s/module-issues/" % (project_id, module_id))

    def update_work_item(self, project_id, issue_id, body):
        return self._request("PATCH", "projects/%s/work-items/%s/" % (project_id, issue_id), body=body)

    def list_projects(self):
        return self.list_all("projects/")

    def get_work_item(self, project_id, issue_id):
        return self._request("GET", "projects/%s/work-items/%s/" % (project_id, issue_id))

    def list_sub_issues(self, project_id, issue_id):
        """Best-effort sub-issue read. Returns a list, or None when it can't tell."""
        try:
            res = self._request("GET", "projects/%s/work-items/%s/sub-issues/"
                                % (project_id, issue_id))
        except PlaneError:
            return None
        if isinstance(res, dict):
            return res.get("sub_issues") or res.get("results") or []
        if isinstance(res, list):
            return res
        return None

    def create_project(self, body):
        return self._request("POST", "projects/", body=body)

    def create_work_item(self, project_id, body):
        return self._request("POST", "projects/%s/work-items/" % project_id, body=body)

    def create_sub_issue(self, project_id, parent_id, body):
        b = dict(body)
        b["parent"] = parent_id
        return self._request("POST", "projects/%s/work-items/" % project_id, body=b)


# ---------------------------------------------------------------------------
# Pure mapping helpers (no network — unit-tested directly)
# ---------------------------------------------------------------------------
def state_group(issue, states_by_id):
    """Resolve an issue's state group whether `state` is an expanded object or a bare id."""
    st = issue.get("state")
    if isinstance(st, dict):
        return st.get("group", "")
    if isinstance(st, str) and st in states_by_id:
        return states_by_id[st].get("group", "")
    return ""


def pick_state_id(states, group, want_name=None):
    """Choose the state id to write for a target group.

    Prefer an exact name match (e.g. "Blocked"), then the project's default
    state in that group, then the lowest-sequence state in that group.
    """
    in_group = [s for s in states if s.get("group") == group]
    if want_name:
        for s in states:
            if (s.get("name") or "").strip().lower() == want_name.strip().lower():
                return s["id"]
    for s in in_group:
        if s.get("default"):
            return s["id"]
    if in_group:
        in_group.sort(key=lambda s: s.get("sequence", 0))
        return in_group[0]["id"]
    return None


def issue_to_ready(issue, project_id, states_by_id, module_by_issue, default_est_h):
    grp = state_group(issue, states_by_id)
    iid = issue.get("id")
    return {
        "tie": "%s:%s" % (project_id, iid),
        "id": issue.get("sequence_id", iid),
        "issue_id": iid,
        "title": issue.get("name", ""),
        "est_h": default_est_h,
        "lane": module_by_issue.get(iid, ""),
        "due": issue.get("target_date") or "",
        "status": GROUP_TO_STATUS.get(grp, "todo"),
        "priority": issue.get("priority") or "none",
        "is_sub": bool(issue.get("parent")),
    }


def filter_ready(items, include_backlog=False):
    groups = READY_GROUPS + (("backlog",) if include_backlog else ())
    ready = [it for it in items if it["_group"] in groups]
    ready.sort(key=lambda it: (PRIORITY_RANK.get(it["priority"], 4),
                               it["due"] or "9999-99-99", str(it["id"])))
    for it in ready:
        it.pop("_group", None)
    return ready


def build_status_body(status, states, completed_at=None):
    """Return the PATCH body to move an issue to the given pbrain status."""
    group = STATUS_TO_GROUP.get(status)
    if group is None:
        raise PlaneError("unknown status: %s" % status)
    want_name = "blocked" if status == "blocked" else None
    sid = pick_state_id(states, group, want_name=want_name)
    if not sid:
        raise PlaneError("no Plane state found for group '%s' — create one in the project" % group)
    body = {"state": sid}
    if status == "done":
        body["completed_at"] = completed_at or None
    return body


def _est_of(issue):
    try:
        return float(issue.get("estimate_point") or 0)
    except (TypeError, ValueError):
        return 0.0


def issue_to_progress(issue, project_id, states_by_id):
    """Map a raw issue to a progress row (status + estimate weight). Pure."""
    grp = state_group(issue, states_by_id)
    iid = issue.get("id")
    return {
        "tie": "%s:%s" % (project_id, iid),
        "title": issue.get("name", ""),
        "status": GROUP_TO_STATUS.get(grp, "todo"),
        "group": grp,
        "est": _est_of(issue),
        "completed_at": issue.get("completed_at") or "",
    }


def progress_summary(rows, since=None):
    """Bucket progress rows → counts + weighted pct + completed-since list. Pure.

    pct = done-weight / total-weight, weight = estimate_point when ANY row has
    one, else a flat count. `dropped` is excluded from both. completed_since
    lists done rows whose completed_at date is >= `since` (YYYY-MM-DD).
    """
    counts = {"todo": 0, "doing": 0, "done": 0, "dropped": 0}
    any_est = any(r.get("est") for r in rows)
    done_w = total_w = 0.0
    completed_since = []
    for r in rows:
        st = r.get("status", "todo")
        counts[st] = counts.get(st, 0) + 1
        if st == "dropped":
            continue
        w = (r.get("est") or 0) if any_est else 1
        total_w += w
        if st == "done":
            done_w += w
            cs = (r.get("completed_at") or "")[:10]
            if since and cs and cs >= since:
                completed_since.append({"tie": r.get("tie"), "title": r.get("title")})
    pct = int(round(100 * done_w / total_w)) if total_w else 0
    return {"pct": pct, "counts": counts, "weighted": any_est,
            "total": len(rows), "completed_since": completed_since}


def thinness_flags(issue, sub_count=None):
    """Flags for a too-thin Plane issue. Pure.

    Treats an ABSENT field as "can't assess" (no flag) — only a field that is
    present-but-empty is thin. Avoids false enrichment proposals when a
    self-host version simply doesn't return a field. Flags:
      no_description | no_priority

    no_estimate is intentionally omitted: Plane's estimate_point requires a
    UUID-based scheme configured in the UI. Without one, the API returns 400
    on any PATCH — the flag is structurally unresolvable. Estimates live in
    the tracker's free-text Est column instead.
    """
    flags = []
    if "description_stripped" in issue or "description_html" in issue:
        stripped = (issue.get("description_stripped") or "").strip()
        html = (issue.get("description_html") or "").strip()
        if not stripped and html in ("", "<p></p>", "<p><br></p>"):
            flags.append("no_description")
    if "priority" in issue and (issue.get("priority") in (None, "", "none")):
        flags.append("no_priority")
    return flags


ENRICH_FIELD_MAP = {
    "description": "description_html",
    "description_html": "description_html",
    "priority": "priority",
    "estimate": "estimate_point",
    "estimate_point": "estimate_point",
    "target_date": "target_date",
    "due": "target_date",
    "start_date": "start_date",
    "timeline": "target_date",
    "title": "name",
    "name": "name",
    "assignees": "assignees",
    "assignee": "assignees",
}

# Relation types supported by Plane's relations API.
RELATION_TYPES = frozenset(
    ["blocking", "blocked_by", "relates_to", "duplicate",
     "start_after", "start_before", "finish_after", "finish_before"]
)


def build_enrich_body(field, value):
    """PATCH body for a single enrichment field→value. Pure.

    Sub-issue creation is NOT a PATCH — handle field 'subissue' in enrich().
    """
    key = ENRICH_FIELD_MAP.get(field)
    if not key:
        raise PlaneError("unknown enrich field: %s" % field)
    return {key: value}


def completed_on(issue, date):
    """True when the issue's completed_at falls on `date` (YYYY-MM-DD). Pure."""
    ca = (issue.get("completed_at") or "")[:10]
    return bool(ca) and ca == date


# ---------------------------------------------------------------------------
# Seam orchestration
# ---------------------------------------------------------------------------
def _module_map(client, project_id, enable):
    if not enable:
        return {}
    out = {}
    try:
        for m in client.list_modules(project_id):
            name = m.get("name", "")
            for link in client.list_module_items(project_id, m.get("id")):
                iid = link.get("issue") or link.get("id")
                if iid:
                    out[iid] = name
    except PlaneError:
        return {}          # lanes are best-effort; never fail the read seam over them
    return out


def ready(cfg, client, project_id, include_backlog=False, with_lanes=False):
    states = client.list_states(project_id)
    states_by_id = {s["id"]: s for s in states}
    module_by_issue = _module_map(client, project_id, with_lanes)
    items = []
    for issue in client.list_work_items(project_id):
        r = issue_to_ready(issue, project_id, states_by_id, module_by_issue, cfg["default_est_h"])
        r["_group"] = state_group(issue, states_by_id)
        items.append(r)
    return filter_ready(items, include_backlog=include_backlog)


def resolve(cfg, client, ties):
    """ties: [{"tie":"<project_id>:<issue_id>","status":"done|doing|todo|dropped|blocked","completed_at"?}]"""
    by_project = {}
    for t in ties:
        tie = t.get("tie", "")
        if ":" not in tie:
            continue
        pid, iid = tie.split(":", 1)
        by_project.setdefault(pid, []).append((iid, t))
    summary = []
    for pid, rows in by_project.items():
        states = client.list_states(pid)
        for iid, t in rows:
            try:
                body = build_status_body(t["status"], states, completed_at=t.get("completed_at"))
                client.update_work_item(pid, iid, body)
                summary.append({"tie": "%s:%s" % (pid, iid), "ok": True, "status": t["status"]})
            except PlaneError as e:
                summary.append({"tie": "%s:%s" % (pid, iid), "ok": False, "error": str(e)})
    return summary


def _ready_sort(rows):
    rows.sort(key=lambda it: (PRIORITY_RANK.get(it.get("priority"), 4),
                              it.get("due") or "9999-99-99", str(it.get("id"))))
    return rows


def ready_multi(cfg, client, project_ids, include_backlog=False, with_lanes=False):
    """Ready tasks across several projects, each tagged with its project, then
    sorted cross-project by priority → due → id. Reuses ready() per project; a
    project that errors is skipped (best-effort) so one bad project can't fail
    the batch."""
    rows = []
    for pid in project_ids:
        try:
            rs = ready(cfg, client, pid, include_backlog=include_backlog, with_lanes=with_lanes)
        except PlaneError:
            continue
        label = project_label(cfg, pid)
        for r in rs:
            r["project_id"] = pid
            r["project"] = label
            rows.append(r)
    return _ready_sort(rows)


def progress(cfg, client, project_ids, since=None):
    """Per-project progress: status counts, weighted pct, items completed since
    `since`. Keyed by project id. Best-effort — a project that errors yields an
    `error` row instead of failing the batch."""
    out = {}
    for pid in project_ids:
        try:
            states = client.list_states(pid)
            sbi = {s["id"]: s for s in states}
            items = client.list_work_items(pid)
        except PlaneError as e:
            out[pid] = {"project_id": pid, "project": project_label(cfg, pid),
                        "error": str(e), "pct": 0,
                        "counts": {"todo": 0, "doing": 0, "done": 0, "dropped": 0},
                        "total": 0, "completed_since": []}
            continue
        rows = [issue_to_progress(it, pid, sbi) for it in items]
        summ = progress_summary(rows, since=since)
        summ["project_id"] = pid
        summ["project"] = project_label(cfg, pid)
        out[pid] = summ
    return out


def review_scan(cfg, client, project_ids, include_backlog=False):
    """Read-only: for each top-level ready issue, fetch its full record and flag
    thin ones. Sub-tasks (parent != None) are excluded — they're enriched via
    their parent. Never writes."""
    out = []
    for pid in project_ids:
        try:
            rs = ready(cfg, client, pid, include_backlog=include_backlog)
        except PlaneError:
            continue
        label = project_label(cfg, pid)
        for r in rs:
            iid = r["issue_id"]
            try:
                issue = client.get_work_item(pid, iid)
            except PlaneError:
                continue
            if issue.get("parent"):
                continue
            flags = thinness_flags(issue)
            if flags:
                out.append({"tie": r["tie"], "project_id": pid, "project": label,
                            "id": r.get("id"), "title": r["title"], "flags": flags})
    return out


def enrich(cfg, client, edits):
    """Apply confirmed enrichments. edits: [{tie, field, value}]. Special fields:
    'subissue'/'subtask' — POSTs a sub-issue (value = title string).
    'relation:<type>' — POSTs a relation (value = target tie or issue uuid).
    Everything else PATCHes the issue via ENRICH_FIELD_MAP. Only ever called
    after an explicit per-item confirm in the command layer."""
    summary = []
    for e in edits:
        tie = normalize_tie(cfg, e.get("tie", ""))
        field = e.get("field", "")
        value = e.get("value")
        if ":" not in tie:
            summary.append({"tie": tie, "ok": False, "error": "bad tie"})
            continue
        pid, iid = tie.split(":", 1)
        try:
            if field in ("subissue", "sub_issue", "subtask"):
                client.create_sub_issue(pid, iid, {"name": value})
            elif field.startswith("relation:"):
                rel_type = field.split(":", 1)[1]
                if rel_type not in RELATION_TYPES:
                    raise PlaneError("unknown relation type: %s (valid: %s)"
                                     % (rel_type, ", ".join(sorted(RELATION_TYPES))))
                # value may be a full tie (pid:iid) or a bare uuid
                target_iid = value.split(":", 1)[-1] if ":" in str(value) else value
                path = "projects/%s/work-items/%s/relations/" % (pid, iid)
                client._request("POST", path,
                                body={"relation_type": rel_type, "issues": [target_iid]})
            else:
                client.update_work_item(pid, iid, build_enrich_body(field, value))
            summary.append({"tie": tie, "ok": True, "field": field})
        except PlaneError as ex:
            summary.append({"tie": tie, "ok": False, "field": field, "error": str(ex)})
    return summary


def completed_today(cfg, client, project_ids, date):
    """Issues completed in Plane on `date` (for end-of-day unplanned detection)."""
    out = []
    for pid in project_ids:
        try:
            items = client.list_work_items(pid)
        except PlaneError:
            continue
        label = project_label(cfg, pid)
        for it in items:
            if completed_on(it, date):
                out.append({"tie": "%s:%s" % (pid, it.get("id")),
                            "title": it.get("name", ""), "project": label,
                            "project_id": pid})
    return out


def create_issue(cfg, client, project_ref, title, priority=None, target_date=None):
    """Create a work item in the given project. Returns the created issue dict."""
    pid = resolve_project_ref(cfg, project_ref)
    if not pid:
        raise PlaneError("unknown project: %s" % project_ref)
    body = {"name": title}
    if priority and priority != "none":
        body["priority"] = priority
    if target_date:
        body["target_date"] = target_date
    result = client.create_work_item(pid, body)
    return {"project_id": pid, "project": project_label(cfg, pid), "issue": result}


def create_project(cfg, client, name, shortcut=None):
    """Create a new Plane project in the workspace and add it to the registry."""
    body = {"name": name, "network": 0, "identifier": (shortcut or name[:3]).upper()}
    result = client.create_project(body)
    pid = result.get("id")
    if not pid:
        raise PlaneError("Plane returned no id for new project")
    reg = normalize_registry(cfg)
    reg.append({"id": pid, "name": name, "shortcut": shortcut or ""})
    cfg["projects"] = reg
    save_config(cfg)
    return {"id": pid, "name": name, "shortcut": shortcut or ""}


def move_status(cfg, client, tie, status, completed_at=None):
    """Single-tie status write (thin wrapper over resolve)."""
    return resolve(cfg, client, [{"tie": normalize_tie(cfg, tie),
                                  "status": status, "completed_at": completed_at}])


def set_priority(cfg, client, tie, value):
    tie = normalize_tie(cfg, tie)
    pid, iid = tie.split(":", 1)
    try:
        client.update_work_item(pid, iid, {"priority": value})
        return {"tie": tie, "ok": True, "priority": value}
    except PlaneError as e:
        return {"tie": tie, "ok": False, "error": str(e)}


def set_timeline(cfg, client, tie, target_date):
    tie = normalize_tie(cfg, tie)
    pid, iid = tie.split(":", 1)
    try:
        client.update_work_item(pid, iid, {"target_date": target_date})
        return {"tie": tie, "ok": True, "target_date": target_date}
    except PlaneError as e:
        return {"tie": tie, "ok": False, "error": str(e)}


def make_client(cfg):
    require(cfg, "base_url", "api_key", "workspace")
    return PlaneClient(cfg["base_url"], cfg["api_key"], cfg["workspace"])


def project_ids_from_arg(cfg, projects_arg):
    """Resolve a comma-separated --projects arg → list of uuids. Empty arg →
    the whole registry (or the lone project)."""
    if projects_arg:
        ids = []
        for ref in projects_arg.split(","):
            ref = ref.strip()
            if not ref:
                continue
            pid = resolve_project_ref(cfg, ref)
            if pid:
                ids.append(pid)
        return ids
    return [p["id"] for p in normalize_registry(cfg)]


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def cmd_setup(args):
    cfg = load_config()
    for k in ("base_url", "api_key", "workspace", "project"):
        v = getattr(args, k.replace("-", "_"))
        if v:
            cfg[k] = v.rstrip("/") if k == "base_url" else v
    require(cfg, "base_url", "api_key", "workspace")
    # strip default_est_h back to a plain value for storage
    cfg["default_est_h"] = cfg.get("default_est_h", 2.0)
    # Setting up Plane means you want pbrain's daily loop to use it.
    cfg.setdefault("backend", "plane")
    p = save_config(cfg)
    print("PLANE_CONFIGURED %s backend=%s" % (p, cfg["backend"]))
    return 0


def cmd_use(args):
    cfg = load_config()
    if args.backend not in ("plane", "markdown"):
        raise PlaneError("backend must be 'plane' or 'markdown'")
    cfg["backend"] = args.backend
    p = save_config(cfg)
    print("PLANE_BACKEND %s (%s)" % (args.backend, p))
    return 0


def cmd_ping(args):
    cfg = load_config()
    client = make_client(cfg)
    pid = args.project or cfg.get("project")
    if not pid:
        raise PlaneError("no project id — pass --project or set it in setup")
    states = client.list_states(pid)
    print("PLANE_OK workspace=%s project=%s states=%d" % (cfg["workspace"], pid, len(states)))
    print(json.dumps([{"name": s.get("name"), "group": s.get("group")} for s in states], ensure_ascii=False))
    return 0


def cmd_states(args):
    cfg = load_config()
    client = make_client(cfg)
    pid = args.project or cfg.get("project")
    print(json.dumps(client.list_states(pid), ensure_ascii=False))
    return 0


def cmd_ready(args):
    cfg = load_config()
    client = make_client(cfg)
    if getattr(args, "projects", None):
        ids = project_ids_from_arg(cfg, args.projects)
        print(json.dumps(ready_multi(cfg, client, ids, include_backlog=args.include_backlog,
                                      with_lanes=args.with_lanes), ensure_ascii=False))
        return 0
    pid = args.project or cfg.get("project")
    if not pid:
        raise PlaneError("no project id — pass --project/--projects or set it in setup")
    print(json.dumps(ready(cfg, client, pid, include_backlog=args.include_backlog,
                           with_lanes=args.with_lanes), ensure_ascii=False))
    return 0


def cmd_resolve(args):
    cfg = load_config()
    client = make_client(cfg)
    ties = json.loads(args.ties)
    print(json.dumps(resolve(cfg, client, ties), ensure_ascii=False))
    return 0


def cmd_projects(args):
    cfg = load_config()
    if args.sync:
        client = make_client(cfg)
        remote = client.list_projects()
        existing = {x["id"]: x for x in normalize_registry(cfg)}
        reg = []
        for p in remote:
            pid = p.get("id")
            if not pid:
                continue
            reg.append({"id": pid, "name": p.get("name") or pid,
                        "shortcut": (existing.get(pid, {}).get("shortcut") or "")})
        cfg["projects"] = reg
        save_config(cfg)
    print(json.dumps(normalize_registry(cfg), ensure_ascii=False))
    return 0


def cmd_progress(args):
    cfg = load_config()
    client = make_client(cfg)
    ids = project_ids_from_arg(cfg, args.projects)
    print(json.dumps(progress(cfg, client, ids, since=args.since), ensure_ascii=False))
    return 0


def cmd_review(args):
    cfg = load_config()
    client = make_client(cfg)
    ids = project_ids_from_arg(cfg, args.projects)
    print(json.dumps(review_scan(cfg, client, ids, include_backlog=args.include_backlog),
                     ensure_ascii=False))
    return 0


def cmd_enrich(args):
    cfg = load_config()
    client = make_client(cfg)
    edits = json.loads(args.edits)
    print(json.dumps(enrich(cfg, client, edits), ensure_ascii=False))
    return 0


def cmd_completed(args):
    cfg = load_config()
    client = make_client(cfg)
    ids = project_ids_from_arg(cfg, args.projects)
    print(json.dumps(completed_today(cfg, client, ids, args.date), ensure_ascii=False))
    return 0


def cmd_priority(args):
    cfg = load_config()
    client = make_client(cfg)
    print(json.dumps(set_priority(cfg, client, args.tie, args.value), ensure_ascii=False))
    return 0


def cmd_timeline(args):
    cfg = load_config()
    client = make_client(cfg)
    print(json.dumps(set_timeline(cfg, client, args.tie, args.target_date), ensure_ascii=False))
    return 0


def cmd_move(args):
    cfg = load_config()
    client = make_client(cfg)
    print(json.dumps(move_status(cfg, client, args.tie, args.status,
                                 completed_at=args.completed_at), ensure_ascii=False))
    return 0


def cmd_issue(args):
    cfg = load_config()
    client = make_client(cfg)
    result = create_issue(cfg, client, args.project, args.title,
                          priority=args.priority, target_date=args.target_date)
    print(json.dumps(result, ensure_ascii=False))
    return 0


def cmd_project_create(args):
    cfg = load_config()
    client = make_client(cfg)
    result = create_project(cfg, client, args.name, shortcut=args.shortcut)
    print(json.dumps(result, ensure_ascii=False))
    return 0


def build_parser():
    p = argparse.ArgumentParser(prog="plane.py")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("setup")
    sp.add_argument("--base-url"); sp.add_argument("--api-key")
    sp.add_argument("--workspace"); sp.add_argument("--project")
    sp.set_defaults(func=cmd_setup)

    sp = sub.add_parser("use"); sp.add_argument("backend"); sp.set_defaults(func=cmd_use)
    sp = sub.add_parser("ping"); sp.add_argument("--project"); sp.set_defaults(func=cmd_ping)
    sp = sub.add_parser("states"); sp.add_argument("--project"); sp.set_defaults(func=cmd_states)

    sp = sub.add_parser("ready")
    sp.add_argument("--project")
    sp.add_argument("--projects", help="comma-separated project refs (uuid|name|shortcut)")
    sp.add_argument("--include-backlog", action="store_true")
    sp.add_argument("--with-lanes", action="store_true")
    sp.set_defaults(func=cmd_ready)

    sp = sub.add_parser("resolve"); sp.add_argument("--ties", required=True); sp.set_defaults(func=cmd_resolve)

    sp = sub.add_parser("projects"); sp.add_argument("--sync", action="store_true")
    sp.set_defaults(func=cmd_projects)

    sp = sub.add_parser("progress")
    sp.add_argument("--projects"); sp.add_argument("--since")
    sp.set_defaults(func=cmd_progress)

    sp = sub.add_parser("review")
    sp.add_argument("--projects"); sp.add_argument("--include-backlog", action="store_true")
    sp.set_defaults(func=cmd_review)

    sp = sub.add_parser("enrich"); sp.add_argument("--edits", required=True)
    sp.set_defaults(func=cmd_enrich)

    sp = sub.add_parser("completed")
    sp.add_argument("--projects"); sp.add_argument("--date", required=True)
    sp.set_defaults(func=cmd_completed)

    sp = sub.add_parser("priority")
    sp.add_argument("--tie", required=True); sp.add_argument("--value", required=True)
    sp.set_defaults(func=cmd_priority)

    sp = sub.add_parser("timeline")
    sp.add_argument("--tie", required=True); sp.add_argument("--target-date", required=True)
    sp.set_defaults(func=cmd_timeline)

    sp = sub.add_parser("move")
    sp.add_argument("--tie", required=True); sp.add_argument("--status", required=True)
    sp.add_argument("--completed-at")
    sp.set_defaults(func=cmd_move)

    sp = sub.add_parser("issue")
    sp.add_argument("--project", required=True, help="project uuid|name|shortcut")
    sp.add_argument("--title", required=True)
    sp.add_argument("--priority", default=None, choices=["urgent", "high", "medium", "low", "none"])
    sp.add_argument("--target-date", default=None)
    sp.set_defaults(func=cmd_issue)

    sp = sub.add_parser("project-create")
    sp.add_argument("--name", required=True)
    sp.add_argument("--shortcut", default=None, help="short alias, e.g. 'dj'")
    sp.set_defaults(func=cmd_project_create)

    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except PlaneError as e:
        sys.stderr.write("plane: %s\n" % e)
        print("PLANE_ERROR %s" % e)
        return 4


if __name__ == "__main__":
    sys.exit(main())
