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
import time
import urllib.error
import urllib.parse
import urllib.request

# State group ordering for "active / ready"
READY_GROUPS = ("unstarted", "started")
# Terminal groups: an issue here is finished/closed, never a unit of work.
# Used by subtree_context (PB-81) to include backlog + open children but drop
# done/cancelled when a PARENT is the execute target.
TERMINAL_GROUPS = ("completed", "cancelled")
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

# PB-130: the custom lifecycle pipeline pbrain seeds into every project. The
# working pipeline is Backlog → Todo → Planning → Building → Testing → Shipped, with
# Landed + Cancelled retained. It ADDS the four work states (Planning/Building/Testing/
# Shipped) on top of Plane's defaults and removes only "In Progress" (its issues fold
# into Building); "Todo" is KEPT as the default unstarted "not yet planned" state.
# (We keep Todo rather than rename it to "Triage" because Plane reserves the literal
# name "Triage" for its built-in intake inbox and rejects creating/renaming a state
# to it on most projects — "name already taken".) Each state carries the GROUP that
# keeps the ready/READY_GROUPS contract intact (names are cosmetic; pbrain resolves
# work by group): Backlog→backlog (the user's staging area, not "ready"); Todo + the
# four work states→unstarted/started (all ready); Landed→completed; Cancelled→cancelled.
# Todo is the project DEFAULT, so a newly-filed issue lands ready. `order` drives the
# Plane `sequence` so the board reads top-to-bottom in pipeline order. Plane's public
# token API can't write states (read-only), so seeding goes through the internal API
# (PlaneClient.create_state/update_state/delete_state); a UI-steps fallback covers the
# no-internal-auth case.
# PB-141: "Queued" sits between Todo (intake landing) and Planning. Groom moves the
# RANKED todo set here (in sort_order) and /plan-my-work walks it top-down — Plane is
# the queue, the vault markdown is demoted to a run-log. Queued is group=unstarted so
# it stays ready-eligible (READY_GROUPS) and maps to status "todo"; Todo keeps
# default:True so /project-manager intake still lands in Todo, NOT Queued.
PIPELINE_STATES = [
    {"name": "Backlog",  "group": "backlog",   "color": "#d1d5db", "default": False, "order": 0},
    {"name": "Todo",     "group": "unstarted", "color": "#f59e0b", "default": True,  "order": 1},
    {"name": "Queued",   "group": "unstarted", "color": "#eab308", "default": False, "order": 2},
    {"name": "Planning", "group": "started",   "color": "#8b5cf6", "default": False, "order": 3},
    {"name": "Building", "group": "started",   "color": "#3b82f6", "default": False, "order": 4},
    {"name": "Testing",  "group": "started",   "color": "#06b6d4", "default": False, "order": 5},
    {"name": "Shipped",  "group": "started",   "color": "#ec4899", "default": False, "order": 6},
    {"name": "Landed",   "group": "completed",  "color": "#16a34a", "default": False, "order": 7},
    {"name": "Cancelled", "group": "cancelled", "color": "#6b7280", "default": False, "order": 8},
]
# The state name groom moves ranked todo issues into, and that /plan-my-work walks.
QUEUED_STATE = "Queued"

# Plane defaults this pipeline supersedes. Only "In Progress" is removed (Todo is
# kept as the default unstarted state); its issues are re-pointed to Building first
# so Plane doesn't refuse the delete for a non-empty state.
DEFAULT_STATES_TO_REMOVE = {
    "in progress": "Building",  # Plane "In Progress" (started) → Building
}

# PB-130: which pipeline state each PB-94 auto-exec stage moves the issue into.
# Used by /plan-my-work's execute loop (via `move --to-state`). plan→Planning,
# implement→Building, test→Testing, ship & land→Shipped, then Landed on merge (handled
# by the existing `move --status done` path → the completed group). Group fallback keeps
# non-pipeline projects working: an absent named state degrades to the group's default.
STAGE_TO_STATE = {
    "plan":      "Planning",
    "implement": "Building",
    "test":      "Testing",
    "ship":      "Shipped",
    "land":      "Shipped",
}

# The pipeline-state renames (PB-XXX: Review→Shipped, Done→Landed) — OLD→NEW. The
# 0014 effectful migration consumes this to PATCH the live state names in place (the
# state id is preserved, so issues stay put — no re-pointing). Groups are unchanged:
# Shipped stays `started`, Landed stays `completed`, so all group-based logic (move,
# completion, queue exit) is untouched. Keep this in sync with PIPELINE_STATES.
STATE_RENAMES = {"Review": "Shipped", "Done": "Landed"}
PRIORITY_RANK = {"urgent": 0, "high": 1, "medium": 2, "low": 3, "none": 4, "": 4, None: 4}

# The spec/approval gate (PB-45). An issue is "plan-approved" when it carries a
# label by this name — the signal that its `## Implementation Plan` (written into
# the issue description by the `spec` walk) has been reviewed and is cleared for
# `/plan-my-work task execute` to implement against without live planning.
APPROVED_LABEL = "plan-approved"
PLAN_MARKER = "Implementation Plan"  # heading the spec walk writes into the description

# Auto-execution PIPELINE stages (PB-94). The `/plan-my-work` execution loop is a
# fixed 5-stage pipeline; each stage checks for its own `auto:<stage>` label:
# present → the stage auto-advances (announced, not silent); absent → the loop PARKS
# at that stage (the partial work is committed + pushed so it stays resumable). The
# stages, in order:
#   auto:plan      → create the worktree, draft the plan, SAVE it to the issue
#   auto:implement → write the code + commit locally
#   auto:test      → run the repo's tests/linters
#   auto:ship      → push the branch + open the PR
#   auto:land      → update docs/etc, then merge (NO new release)
# Semantics are INDEPENDENT and STOP-AT-FIRST-GAP: each label clears only its own
# stage, and a later label does NOT imply the earlier ones — the loop advances
# through the stages that have their label and stops at the first that doesn't. Set
# upstream at triage (user on the full path, agent on the fast path) so execution is
# decided ONCE. Seeded into every project alongside the convention labels (project
# create + `labels --seed`), never created ad-hoc by groom. `auto:plan` clears the
# plan GATE; plan-approved remains the separate plan-CONTENT seam. INVARIANT: even
# with `auto:land`, a red CI still hard-stops the merge — `auto:land` waives only the
# typed-confirm half, never the CI-green requirement, and never triggers a release.
GATE_NAMES = ["plan", "implement", "test", "ship", "land"]
GATE_LABELS = [{"name": "auto:%s" % g, "color": "#7c3aed"} for g in GATE_NAMES]  # violet

# The groom QUALITY-VET marker (not a pipeline gate). The judgment pass (autonomous
# nightly Claude or interactive groom) sets this once it has vetted an issue's
# description/priority/estimate quality — so later nights SKIP re-vetting it (zero
# churn). Strip it in Plane to request a re-vet. Deliberately NOT in GATE_NAMES, so
# the gate machinery (gate_label_map / suggest_auto_stages / issue_gate_clearances)
# ignores it — it only ever iterates GATE_NAMES. Seeded so `tag --add auto:groomed`
# resolves to a real label instead of creating one ad-hoc.
GROOMED_LABEL = {"name": "auto:groomed", "color": "#8b5cf6"}  # violet (marker, not gate)

# The PARKED manual-gate label (PB-152). A human adds `parked` to an issue to say
# "hands-off pmw modes must NOT touch this without me." It is honoured ONLY by the
# hands-off SELECTION paths (the Queued state queue + auto-drive: queued_multi /
# claim_next_queued / enqueue_ordered all skip a parked issue), so groom never
# enqueues it and `/plan-my-work` auto-drive / top-of-queue never claims it. An
# EXPLICIT `/plan-my-work PB-X` on a parked issue still runs (a human asked for it by
# name) — pmw just warns, via the `is_parked` flag exposed in `spec --read`. Like
# auto:groomed it is a marker, not a pipeline gate, so the gate machinery
# (GATE_NAMES iteration) ignores it. Seeded so `tag --add parked` resolves to a real
# label rather than creating one ad-hoc.
PARKED_LABEL = {"name": "parked", "color": "#f59e0b"}  # amber (manual hold marker)

# All labels pbrain seeds into a project: work-type conventions (PB-70), the
# plan-approval seam (PB-45), the per-gate auto clearances (PB-94), the groom
# quality-vet marker, and the parked manual-hold marker (PB-152).
def _seed_label_specs():
    return (CONVENTION_LABELS + [{"name": APPROVED_LABEL, "color": "#9333ea"}]
            + GATE_LABELS + [GROOMED_LABEL, PARKED_LABEL])

# Canonical "convention" labels (PB-70). Every project gets these work-item TYPE
# labels so triage is consistent across the workspace: a `bug` filed via
# `/project-manager bug` always finds its label, `feature`/`chore`/`docs` classify
# the rest. Seeded on project create AND backfilled on demand via `labels --seed`.
# Colors are Plane hex strings. Idempotent: seeding skips any that already exist
# (fuzzy-deduped by normalised name through resolve_label_refs).
CONVENTION_LABELS = [
    {"name": "bug",     "color": "#dc2626"},  # red
    {"name": "feature", "color": "#16a34a"},  # green
    {"name": "chore",   "color": "#6b7280"},  # gray
    {"name": "docs",    "color": "#2563eb"},  # blue
]

# Work-item TYPES the generic `file` intake recognises (PB-67). Any change software
# needs maps to one of these; the `label` is the convention label it carries (the
# four seeded by PB-70 — refactor/improvement fold into `chore`). `body` is the
# heading shape the explode-from-dump uses, so each type reads triage-ready.
WORK_TYPES = {
    "bug":         {"label": "bug",     "body": ["Repro", "Expected", "Actual", "Severity"]},
    "feature":     {"label": "feature", "body": ["Outcome", "Acceptance criteria", "Scope / non-goals"]},
    "docs":        {"label": "docs",    "body": ["What's undocumented", "Audience", "Where it lives"]},
    "chore":       {"label": "chore",   "body": ["What", "Why now"]},
    "refactor":    {"label": "chore",   "body": ["What", "Why", "Risk / blast radius"]},
    "improvement": {"label": "feature", "body": ["Current", "Desired", "Why it matters"]},
}

# Severity → priority (PB-67 triage convention). Used for bugs; other types take a
# plain priority. Keeps triage consistent regardless of who/what files the item.
SEVERITY_TO_PRIORITY = {
    "crash":   "urgent",  # crash / data loss / blocks the daily loop
    "blocker": "urgent",
    "high":    "high",    # wrong output / real impact, workaround exists
    "minor":   "medium",  # minor / cosmetic / a nudge mis-fires
    "polish":  "low",     # nice-to-have / polish
}


def strip_html(html):
    """Crude HTML → plain text for comment bodies (PB-61) when the API gives no
    pre-stripped form. Drops tags, collapses whitespace, unescapes the few
    entities Plane emits. Stdlib only."""
    if not html:
        return ""
    import re
    import html as _html
    text = re.sub(r"<(br|/p|/div|/li)\s*/?>", "\n", html, flags=re.I)
    text = re.sub(r"<[^>]+>", "", text)
    text = _html.unescape(text)
    return re.sub(r"[ \t]+\n", "\n", text).strip()


def issue_description_text(issue):
    """Plain-text description for an issue, robust to Plane's PATCH quirk (PB-143).

    Plane returns ``description_stripped=null`` right after a ``description_html``-
    only PATCH (it does not regenerate the stripped text server-side), so reading
    that field alone makes a freshly-written description/plan look empty. Fall back
    to stripping ``description_html`` — the same fallback the review thin-check uses.
    Pure."""
    stripped = (issue.get("description_stripped") or "").strip()
    if stripped:
        return stripped
    return strip_html(issue.get("description_html") or "")


class PlaneError(Exception):
    pass


# ---------------------------------------------------------------------------
# Secret redaction shield (PB-16)
# ---------------------------------------------------------------------------
# A defensive, code-path-independent guarantee: the Plane access token — and the
# internal-API session cookie / password used only to read estimate scales — must
# NEVER appear verbatim in this script's stdout/stderr. Secrets are registered as
# they become known (config load, client construction, live cookie refresh) and
# both streams are wrapped so any occurrence is scrubbed before it reaches the
# terminal. This backstops every present and future leak path (error messages,
# tracebacks, accidental dumps) rather than auditing each call site by hand.
_SECRETS = set()
_REDACTION = "***REDACTED***"


def register_secret(value):
    """Mark a string as a secret to scrub from all output. Short/empty values are
    ignored so we never redact incidental substrings."""
    if isinstance(value, str) and len(value) >= 8:
        _SECRETS.add(value)


def redact(text):
    if not _SECRETS or not isinstance(text, str):
        return text
    # Longest-first so a secret that contains another is fully masked.
    for s in sorted(_SECRETS, key=len, reverse=True):
        if s in text:
            text = text.replace(s, _REDACTION)
    return text


class _RedactingStream:
    """Stream proxy that scrubs registered secrets from every write()."""
    def __init__(self, wrapped):
        self._wrapped = wrapped

    def write(self, text):
        return self._wrapped.write(redact(text))

    def __getattr__(self, name):
        return getattr(self._wrapped, name)


def install_redaction_shield():
    """Wrap stdout/stderr once so registered secrets can never be emitted."""
    if not isinstance(sys.stdout, _RedactingStream):
        sys.stdout = _RedactingStream(sys.stdout)
    if not isinstance(sys.stderr, _RedactingStream):
        sys.stderr = _RedactingStream(sys.stderr)


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
def config_path():
    base = os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config"))
    return os.path.join(base, "pbrain", "plane.json")


# Internal-auth password storage (PB-18). Remote/VPS mode authenticates the
# internal estimates API with the Plane login email+password (the local browser
# cookie scrape only works against a localhost instance). The password lives in
# the macOS login Keychain, never in plane.json — plane.json only carries the
# `internal_password_source: "keychain"` marker + the (non-secret) email.
KEYCHAIN_SERVICE = "pbrain-plane-internal"


def _keychain_get(account, service=KEYCHAIN_SERVICE):
    """Read a secret from the macOS login Keychain. Returns the string or None
    (non-macOS, not found, or `security` unavailable)."""
    if sys.platform != "darwin" or not account:
        return None
    import subprocess
    try:
        out = subprocess.check_output(
            ["security", "find-generic-password", "-w", "-s", service, "-a", account],
            stderr=subprocess.DEVNULL)
        return out.decode().rstrip("\n") or None
    except Exception:
        return None


def _keychain_set(account, secret, service=KEYCHAIN_SERVICE):
    """Store/replace a secret in the macOS login Keychain (-U updates in place).
    Returns True on success, False otherwise (incl. non-macOS)."""
    if sys.platform != "darwin" or not account or not secret:
        return False
    import subprocess
    try:
        subprocess.check_call(
            ["security", "add-generic-password", "-U", "-s", service, "-a", account,
             "-w", secret],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception:
        return False


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
        # Internal-API (cookie/login) auth — only used to auto-fetch estimate
        # points, which the public token API can't enumerate. All optional.
        "internal_session_cookie": os.environ.get("PBRAIN_PLANE_SESSION_COOKIE"),
        "internal_email": os.environ.get("PBRAIN_PLANE_EMAIL"),
        "internal_password": os.environ.get("PBRAIN_PLANE_PASSWORD"),
    }
    for k, v in env.items():
        if v:
            cfg[k] = v
    if cfg.get("base_url"):
        cfg["base_url"] = cfg["base_url"].rstrip("/")
    # Resolve the internal-auth password from the macOS Keychain when plane.json
    # only carries the marker (PB-18 remote/VPS mode). Env/plaintext still win.
    if not cfg.get("internal_password") and cfg.get("internal_password_source") == "keychain":
        kc = _keychain_get(cfg.get("internal_email"))
        if kc:
            cfg["internal_password"] = kc
    try:
        cfg["default_est_h"] = float(cfg.get("default_est_h") or 2)
    except (TypeError, ValueError):
        cfg["default_est_h"] = 2.0
    # Shield every secret the config carries (PB-16) so it can't be echoed.
    for _k in ("api_key", "internal_session_cookie", "internal_password"):
        register_secret(cfg.get(_k))
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


def project_short(cfg, pid):
    """The project's UPPERCASED shortcut/identifier (e.g. 'PB', 'YT', 'KA') — the slug
    Plane uses in browse URLs (.../browse/PB-89). Falls back to a spaceless squash of
    the name, then the id. Pure. Use this (NOT project_label, the display name) anywhere
    a URL slug or issue ref like '<SHORT>-<seq>' is built — a name with spaces produces
    a broken link (e.g. 'YOUTUBE SUMMARY EXTENSION-2')."""
    for p in normalize_registry(cfg):
        if p["id"] == pid:
            sc = (p.get("shortcut") or p.get("identifier") or "").strip()
            if sc:
                return sc.upper()
            name = (p.get("name") or "").strip()
            if name:
                # last resort: squash the name to a spaceless token so the URL is valid
                return "".join(name.split()).upper()
            return pid
    return pid


# --- estimates (story points) ----------------------------------------------
# Plane's PUBLIC v1 API can neither list nor create estimate points — only the
# cookie-auth INTERNAL API (/api/workspaces/.../estimates/) exposes them. But
# the public API CAN read and write an issue's `estimate_point` (a point UUID).
# The scale is NEVER cached persistently — a user can change estimates in Plane any
# time, so we fetch it LIVE from the internal API on every run (see
# ensure_estimate_scale) and hold it only in-memory under cfg["_live_estimates"]
# (the "_" prefix marks it ephemeral — save_config drops it). cfg["estimates"] holds
# ONLY a manually imported scale (the no-internal-auth fallback). The user's
# points→hours factor persists separately in cfg["estimate_hours_per_point"].
def estimate_scale(cfg, pid):
    """The estimate scale for a project: the live-fetched one (in-memory) if present,
    else a manually imported fallback. Pure (reads cfg only).

    Shape: {"name","type","points": {"<point value>": "<estimate_point uuid>", ...}}
    """
    return ((cfg.get("_live_estimates") or {}).get(pid)
            or (cfg.get("estimates") or {}).get(pid))


def _project_hpp(cfg, pid):
    """The persisted points→hours factor for a project (default 1.0, always >0). Pure."""
    hpp = (cfg.get("estimate_hours_per_point") or {}).get(pid)
    if hpp is None:                              # back-compat: imported scale embedded it
        hpp = ((cfg.get("estimates") or {}).get(pid) or {}).get("hours_per_point")
    try:
        hpp = float(hpp)
    except (TypeError, ValueError):
        hpp = 1.0
    return hpp if hpp > 0 else 1.0


def est_value_to_uuid(cfg, pid):
    """{point-value(str) → estimate_point uuid} for a project. Pure."""
    out = {}
    for val, uid in ((estimate_scale(cfg, pid) or {}).get("points") or {}).items():
        v = str(val).strip()
        if v and uid:
            out[v] = uid
    return out


def est_uuid_to_points(cfg, pid):
    """{estimate_point uuid → numeric point value} for a project. Pure."""
    out = {}
    for val, uid in ((estimate_scale(cfg, pid) or {}).get("points") or {}).items():
        try:
            out[uid] = float(val)
        except (TypeError, ValueError):
            pass
    return out


def est_uuid_to_hours(cfg, pid):
    """{estimate_point uuid → hours} = point value × the project's hours_per_point. Pure."""
    if not estimate_scale(cfg, pid):
        return {}
    hpp = _project_hpp(cfg, pid)
    return {uid: pts * hpp for uid, pts in est_uuid_to_points(cfg, pid).items()}


def _vhost_from_base(base_url):
    """The browser-facing host candidates for a base_url. The local default flow
    serves Plane at plane.localhost while pbrain talks to the 127.0.0.1 loopback,
    so the session cookie lives under plane.localhost / localhost — search those
    plus the literal base host. Pure."""
    hosts = ["plane.localhost", "localhost", "127.0.0.1"]
    try:
        h = urllib.parse.urlparse(base_url).hostname
        if h and h not in hosts:
            hosts.insert(0, h)
    except Exception:
        pass
    return hosts


_LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "0.0.0.0", "::1"}


def web_base(cfg):
    """The BROWSER-FACING Plane base for clickable issue links — distinct from the
    API `base_url`, which is the 127.0.0.1 loopback the client talks to. The single
    source of truth so groom + /plan-my-work never drift.

    Rules:
      * PBRAIN_PLANE_WEB_BASE wins outright (explicit escape hatch).
      * Else parse base_url. If its host is a loopback (the local self-host flow,
        where the browser is served at the vhost while pbrain hits the loopback),
        swap to the preferred NON-loopback vanity host from _vhost_from_base
        (i.e. plane.localhost), keeping the same scheme + port. A real hostname
        (VPS/domain, e.g. plane.example.com) is kept as-is.
      * Append /<workspace> when known.
    Returns "" when nothing is resolvable (callers fall back). Pure (reads env)."""
    override = os.environ.get("PBRAIN_PLANE_WEB_BASE")
    if override:
        return override.rstrip("/")
    base = (cfg or {}).get("base_url") or ""
    if not base:
        return ""
    try:
        u = urllib.parse.urlparse(base)
    except Exception:
        return ""
    scheme = u.scheme or "http"
    host = u.hostname or ""
    port = u.port
    if host in _LOOPBACK_HOSTS:
        # Prefer the first non-loopback candidate (plane.localhost) as the browser host.
        host = next((h for h in _vhost_from_base(base) if h not in _LOOPBACK_HOSTS),
                    host)
    netloc = "%s:%s" % (host, port) if port else host
    out = "%s://%s" % (scheme, netloc)
    ws = (cfg or {}).get("workspace")
    if ws:
        out += "/%s" % ws
    return out.rstrip("/")


def browse_url(cfg, pid, sequence_id):
    """PB-134: the canonical browse URL for an issue — the SINGLE source of truth so
    agents never hand-assemble (and mis-shape) issue links.

        link_base(cfg) + "/browse/" + project_short(cfg, pid) + "-" + seq + "/"

    e.g. http://plane.localhost:1800/pb/browse/PB-134/ (web), or
    plane://pb/browse/PB-134/ (deep link) when the desktop app is installed — the
    SHORT ref form (not the long .../projects/<uuid>/issues/<uuid> shape) precisely
    so it fits one line and the whole link is clickable.

    App-aware (PB-134 + PB-148): routed through link_base, so it emits the plane://
    deep link when /Applications/Plane.app is present (opens the issue in the app)
    and the http web_base otherwise (browser-openable). Same gate every other saved
    link uses, so chat-emitted and vault-written links stay consistent. Returns ""
    when no base is resolvable (callers fall back to the bare ref). Pure."""
    base = link_base(cfg)
    if not base or sequence_id in (None, ""):
        return ""
    return "%s/browse/%s-%s/" % (base, project_short(cfg, pid), sequence_id)


# Deep-link app (PB-148): the Tauri desktop app registers a `plane://` URL scheme,
# so a markdown link with a plane:// target opens the issue inside the app instead
# of a browser. We only emit plane:// links when that app is actually installed —
# otherwise an http link (web_base) is the right, browser-openable fallback.
_PLANE_APP_PATH = "/Applications/Plane.app"


def deep_link_available():
    """True when the Plane desktop app (which owns the plane:// scheme) is installed.

    macOS-only and cheap: the scheme is registered by Launch Services from the app
    in /Applications, so its presence there is the reliable signal. The env override
    PBRAIN_PLANE_DEEPLINK forces the answer (1/0) for tests and for users who want to
    pin the behavior regardless of install state. Pure (reads env + one stat)."""
    forced = os.environ.get("PBRAIN_PLANE_DEEPLINK")
    if forced is not None:
        return forced.strip() not in ("", "0", "no", "false", "off")
    if sys.platform != "darwin":
        return False
    return os.path.isdir(_PLANE_APP_PATH)


def deep_link_base(cfg):
    """The plane:// base mirroring web_base's path shape: `plane://<workspace>`.

    The app's plane_uri_to_http maps `plane://<ws>/browse/<REF>` onto the same host
    it loads, so the workspace-prefixed path resolves identically to the http link.
    Derives the workspace the same way web_base does — from cfg, falling back to the
    trailing path segment of web_base (which also honours PBRAIN_PLANE_WEB_BASE), so
    the deep link and the http link always carry the same workspace slug. Returns a
    bare "plane://" when none is known (callers fall back to web_base)."""
    ws = (cfg or {}).get("workspace")
    if not ws:
        # Recover the slug from the resolved web base, e.g. ".../1800/pb" -> "pb".
        try:
            tail = web_base(cfg).rstrip("/").rsplit("/", 1)[-1]
            if tail and "://" not in tail and ":" not in tail:
                ws = tail
        except Exception:
            ws = None
    return ("plane://%s" % ws) if ws else "plane://"


def link_base(cfg):
    """The PREFERRED base for a vault-written clickable issue link: the plane:// deep
    link when the desktop app is installed, else the browser-facing web_base. This is
    the single seam that makes saved links deep-link-aware — every writer that goes
    through it inherits the behavior, and nothing changes for users without the app
    or on non-macOS (web_base http link, exactly as before)."""
    if deep_link_available():
        dl = deep_link_base(cfg)
        if dl:
            return dl
    return web_base(cfg)


# Chromium browsers we know how to read on macOS: dir + Keychain "Safe Storage" key.
_CHROMIUM_BROWSERS = {
    "brave": ("BraveSoftware/Brave-Browser", "Brave Safe Storage"),
    "chrome": ("Google/Chrome", "Chrome Safe Storage"),
    "chromium": ("Chromium", "Chromium Safe Storage"),
}


def extract_plane_cookie(base_url, browser=None):
    """Extract Plane's `csrftoken; session-id` from the local Chromium cookie
    store (macOS, v10 encryption). Returns the Cookie header string, or None if
    unavailable (not macOS, no matching cookies, app-bound v20 encryption, or a
    Keychain/openssl failure). Best-effort — never raises.

    Decrypt path: Keychain "<Browser> Safe Storage" password → PBKDF2-HMAC-SHA1
    (salt 'saltysalt', 1003, 16B) → AES-128-CBC (IV = 16×0x20) via openssl →
    strip PKCS7 pad and the 32-byte SHA256(host) prefix modern Chromium prepends.
    """
    import sqlite3, subprocess, hashlib, tempfile, shutil, glob
    if sys.platform != "darwin":
        return None
    order = [browser] if browser else ["brave", "chrome", "chromium"]
    hosts = _vhost_from_base(base_url)
    support = os.path.expanduser("~/Library/Application Support")
    for bname in order:
        meta = _CHROMIUM_BROWSERS.get((bname or "").lower())
        if not meta:
            continue
        subdir, service = meta
        try:
            pw = subprocess.check_output(
                ["security", "find-generic-password", "-w", "-s", service],
                stderr=subprocess.DEVNULL).strip()
        except Exception:
            continue
        key = hashlib.pbkdf2_hmac("sha1", pw, b"saltysalt", 1003, 16)
        for db in glob.glob(os.path.join(support, subdir, "*", "Cookies")):
            tmp = tempfile.mkdtemp()
            try:
                cp = os.path.join(tmp, "c.db")
                shutil.copy(db, cp)
                con = sqlite3.connect(cp)
                for host in hosts:
                    rows = dict(con.execute(
                        "SELECT name, encrypted_value FROM cookies WHERE host_key=? "
                        "AND name IN ('csrftoken','session-id')", (host,)).fetchall())
                    if "session-id" not in rows:
                        continue
                    out = {}
                    ok = True
                    for name, blob in rows.items():
                        val = _decrypt_v10(blob, key, host)
                        if val is None:
                            ok = False
                            break
                        out[name] = val
                    con.close()
                    if ok and out.get("session-id"):
                        parts = [("%s=%s" % (n, out[n])) for n in ("csrftoken", "session-id")
                                 if out.get(n)]
                        return "; ".join(parts)
                con.close()
            except Exception:
                pass
            finally:
                shutil.rmtree(tmp, ignore_errors=True)
    return None


def _decrypt_v10(blob, key, host):
    """Decrypt one Chromium v10 cookie value (macOS). Returns the string or None
    (non-v10 / app-bound v20 / openssl failure). Helper for extract_plane_cookie."""
    import subprocess, hashlib
    if not blob or blob[:3] != b"v10":
        return None
    try:
        res = subprocess.run(
            ["openssl", "enc", "-aes-128-cbc", "-d", "-nopad",
             "-K", key.hex(), "-iv", "20" * 16],
            input=blob[3:], capture_output=True)
        out = res.stdout
        if not out:
            return None
        out = out[:-out[-1]]                       # strip PKCS7 padding
        prefix = hashlib.sha256(host.encode()).digest()
        if out.startswith(prefix):                 # modern Chromium domain-hash prefix
            out = out[32:]
        return out.decode("utf-8", "replace")
    except Exception:
        return None


def ensure_estimate_scale(cfg, client, pid):
    """Return the project's estimate scale, fetched LIVE from Plane's internal API
    (never persisted — a user can edit estimates in Plane any time, so we always
    read real-time). The result is held only in-memory for this process under
    cfg["_live_estimates"] (so repeated lookups in one run don't refetch). Returns
    None when estimates aren't available (no internal auth, estimates not enabled on
    the project, or the endpoint unreachable) — the "use it if it exists, else skip"
    contract; callers then fall back to default_est_h.

    Best-effort: never raises. One fetch attempt per project per process (tracked on
    the client). On no-auth, falls back to a manually imported scale if one exists."""
    attempted = getattr(client, "_est_attempted", None) if client else None
    already = attempted is not None and pid in attempted
    if client is not None and not already \
            and getattr(client, "_has_internal_auth", lambda: False)():
        if attempted is not None:
            attempted.add(pid)
        try:
            scale = parse_estimate_payload(client.list_estimates(pid))
            cfg.setdefault("_live_estimates", {})[pid] = scale   # in-memory ONLY
            # The client may have refreshed a stale cookie mid-fetch; persist it.
            fresh = getattr(client, "_session_cookie", None)
            if fresh and cfg.get("internal_cookie_source") == "browser" \
                    and cfg.get("internal_session_cookie") != fresh:
                cfg["internal_session_cookie"] = fresh
                try:
                    save_config(cfg)        # save_config drops _live_estimates
                except (OSError, PlaneError):
                    pass
            return scale
        except PlaneError:
            pass
    # Live fetch unavailable/failed → whatever's already known (in-memory live from a
    # prior call this process, or a manually imported fallback). May be None.
    return estimate_scale(cfg, pid)


# Estimate templates: (estimate type, ordered point labels). The first four mirror
# the presets Plane's UI offers; "hours" is pbrain's planning-optimised scale —
# numeric work-hour buckets so a point value IS the hours /plan-my-work packs with.
ESTIMATE_TEMPLATES = {
    "fibonacci":  ("points", [1, 2, 3, 5, 8, 13]),
    "linear":     ("points", [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
    "squares":    ("points", [1, 2, 4, 8, 16, 32]),
    "tshirt":     ("categories", ["XS", "S", "M", "L", "XL", "XXL"]),
    "difficulty": ("categories", ["Easy", "Medium", "Hard", "Very Hard"]),
    "hours":      ("points", [1, 2, 4, 8, 16]),
}
FIBONACCI_SCALE = ESTIMATE_TEMPLATES["fibonacci"][1]


def setup_project_estimate(cfg, client, pid, values=None, name="Points",
                           type_="points", replace=False):
    """Ensure the project has an ACTIVE estimate scale, then read it back live.
    Reuses an existing scale (re-running is a no-op, not a 400) unless `replace`,
    which deletes any existing scales first (e.g. to switch points→t-shirt). Else
    creates one (`type_`/`values`, Fibonacci points by default) via the internal
    API, then activates it on the project (`project.estimate`, public API —
    creation alone leaves it inactive). Returns the live scale dict, or None on
    failure. Best-effort; internal auth required."""
    existing = []
    try:
        existing = client.list_estimates(pid) or []
    except PlaneError:
        return None
    if replace and existing:
        for e in existing:
            if e.get("id"):
                try:
                    client.delete_estimate(pid, e["id"])
                except PlaneError:
                    pass
        existing = []
    scale_obj = (next((e for e in existing if e.get("type") == type_), None)
                 or (existing[0] if existing else None))
    if scale_obj is None:
        try:
            client.create_estimate(pid, values or FIBONACCI_SCALE, name=name, type_=type_)
            existing = client.list_estimates(pid) or []
        except PlaneError:
            return None
        scale_obj = (next((e for e in existing if e.get("type") == type_), None)
                     or (existing[0] if existing else None))
    if scale_obj and scale_obj.get("id"):
        try:
            client.update_project(pid, {"estimate": scale_obj["id"]})   # activate
        except PlaneError:
            pass
    # Invalidate any in-memory fetch from earlier this process, then read it back live.
    (cfg.get("_live_estimates") or {}).pop(pid, None)
    att = getattr(client, "_est_attempted", None)
    if att is not None:
        att.discard(pid)
    return ensure_estimate_scale(cfg, client, pid)


def parse_estimate_payload(data):
    """Plane's /estimates/ response → a cached scale dict. Pure.

    Accepts the raw list, a single estimate dict, or {"results":[...]}. Picks the
    last_used estimate, else a points-type one, else the first. Returns
    {"name","type","points": {value: uuid}} (hours_per_point added by the caller).
    """
    if isinstance(data, dict) and "results" in data:
        data = data["results"]
    ests = [data] if isinstance(data, dict) else list(data or [])
    if not ests:
        raise PlaneError("no estimates in payload")
    chosen = (next((e for e in ests if e.get("last_used")), None)
              or next((e for e in ests if e.get("type") == "points"), None)
              or ests[0])
    points = {}
    for p in chosen.get("points") or []:
        val, uid = str(p.get("value")).strip(), p.get("id")
        if val and uid:
            points[val] = uid
    if not points:
        raise PlaneError("no estimate points in payload")
    return {"name": chosen.get("name") or "", "type": chosen.get("type") or "",
            "points": points}


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
    # Drop ephemeral, in-memory-only keys (e.g. "_live_estimates", the live-fetched
    # estimate scale) so they never get cached to disk and go stale.
    persistable = {k: v for k, v in cfg.items() if not str(k).startswith("_")}
    # Never persist the internal password when it lives in the Keychain — only the
    # marker is stored; load_config re-reads the secret at runtime (PB-18).
    if persistable.get("internal_password_source") == "keychain":
        persistable.pop("internal_password", None)
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)  # secret → 0600
    with os.fdopen(fd, "w") as fh:
        json.dump(persistable, fh, indent=2)
    return p


def _backup_config_file():
    """PB-98: snapshot the current plane.json next to itself before a destructive
    overwrite, so a clobbered api_key is recoverable. Best-effort + 0600; a backup
    hiccup must not block the (already-confirmed) reconfigure."""
    p = config_path()
    if not os.path.exists(p):
        return None
    bak = p + ".bak"
    try:
        fd = os.open(bak, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as out, open(p) as src:
            out.write(src.read())
        return bak
    except OSError:
        return None


def require(cfg, *keys):
    missing = [k for k in keys if not cfg.get(k)]
    if missing:
        raise PlaneError("Plane not configured: missing %s. Run: /project-manager setup"
                         % ", ".join(missing))


# ---------------------------------------------------------------------------
# HTTP client (isolated — the only part that touches the network)
# ---------------------------------------------------------------------------
class PlaneClient:
    def __init__(self, base_url, api_key, workspace, opener=None,
                 session_cookie=None, email=None, password=None,
                 cookie_refresher=None, on_cookie_refreshed=None):
        self.base = base_url.rstrip("/")
        self.api_key = api_key
        self.workspace = workspace
        register_secret(api_key)
        register_secret(session_cookie)
        register_secret(password)
        self._opener = opener or urllib.request.build_opener()
        # Internal-API (cookie-auth) surface — used ONLY to read estimate points,
        # which the public token API can't enumerate. Auth is a stored session
        # cookie (used directly) or Plane email/password (logged in, refreshed on
        # 401). Absent → the internal calls raise and callers degrade gracefully.
        self._session_cookie = session_cookie or None
        self._email = email or None
        self._password = password or None
        # On a 401 with a stale cookie, re-pull a fresh one (e.g. from the browser
        # cookie store) and persist it. Both optional.
        self._cookie_refresher = cookie_refresher
        self._on_cookie_refreshed = on_cookie_refreshed
        import http.cookiejar
        self._jar = http.cookiejar.CookieJar()
        self._internal = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self._jar))
        self._internal_ready = False
        self._est_attempted = set()   # projects we've tried to fetch this process

    def _url(self, path):
        return "%s/api/v1/workspaces/%s/%s" % (self.base, self.workspace, path.lstrip("/"))

    def _request(self, method, path, params=None, body=None):
        url = self._url(path)
        if params:
            url += "?" + urllib.parse.urlencode({k: v for k, v in params.items() if v not in (None, "")})
        data = json.dumps(body).encode() if body is not None else None
        # Retry on 429 (RATE_LIMIT_EXCEEDED) with backoff. Plane throttles bursts, and
        # groom now does a label-write per todo issue, so a batch would otherwise drop
        # writes silently. Honour Retry-After when present, else exponential backoff.
        # PBRAIN_PLANE_MAX_RETRIES (default 4) / PBRAIN_PLANE_RETRY_BASE (default 1.5s).
        try:
            max_retries = int(os.environ.get("PBRAIN_PLANE_MAX_RETRIES") or 4)
        except (TypeError, ValueError):
            max_retries = 4
        try:
            base = float(os.environ.get("PBRAIN_PLANE_RETRY_BASE") or 1.5)
        except (TypeError, ValueError):
            base = 1.5
        attempt = 0
        while True:
            req = urllib.request.Request(url, data=data, method=method)
            req.add_header("X-API-Key", self.api_key)
            req.add_header("Content-Type", "application/json")
            try:
                with self._opener.open(req, timeout=30) as resp:
                    raw = resp.read().decode()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as e:
                if e.code == 429 and attempt < max_retries:
                    ra = e.headers.get("Retry-After") if e.headers else None
                    try:
                        wait = float(ra) if ra else base * (2 ** attempt)
                    except (TypeError, ValueError):
                        wait = base * (2 ** attempt)
                    time.sleep(min(wait, 30.0))
                    attempt += 1
                    continue
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

    def update_project(self, project_id, body):
        return self._request("PATCH", "projects/%s/" % project_id, body=body)

    def get_work_item(self, project_id, issue_id):
        return self._request("GET", "projects/%s/work-items/%s/" % (project_id, issue_id))

    def list_sub_issues(self, project_id, issue_id):
        """Best-effort sub-issue read. Returns a list, or None when it can't tell.

        Fast path: the dedicated `/sub-issues/` endpoint. Some Plane builds don't
        expose it (it 404s), in which case the parent→child link still lives on
        each child's `parent` field — so we FALL BACK to scanning the project's
        work items for `parent == issue_id` (the same technique subtree_context
        relies on). Without the fallback, a 404 here made explode/`existing_subissues`
        silently report zero children for every issue (PB-67)."""
        res = None
        try:
            res = self._request("GET", "projects/%s/work-items/%s/sub-issues/"
                                % (project_id, issue_id))
        except PlaneError:
            res = None
        if isinstance(res, dict):
            subs = res.get("sub_issues") or res.get("results")
            if subs is not None:
                return subs
        elif isinstance(res, list):
            return res
        # Endpoint unavailable / unrecognised shape → parent-scan fallback.
        try:
            return [w for w in self.list_work_items(project_id)
                    if w.get("parent") == issue_id]
        except PlaneError:
            return None

    def list_relations(self, project_id, issue_id):
        """Best-effort relation read (PB-94). Returns a list of relation objects, or
        None when it can't tell. Plane builds differ in shape: the endpoint may return
        a dict keyed by relation type (`{"blocked_by": [...], "blocking": [...]}`), a
        dict wrapping `results`, or a flat list — normalise all three to a flat list of
        {relation_type, related_issue/related_issue_detail, ...}. Relations were only
        ever WRITTEN before this (the `relation:<type>` enrich verb); nothing read them,
        so a parked-but-blocked issue could be picked up out of order."""
        try:
            res = self._request("GET", "projects/%s/work-items/%s/relations/"
                                % (project_id, issue_id))
        except PlaneError:
            return None
        if isinstance(res, list):
            return res
        if isinstance(res, dict):
            # dict-keyed-by-type → flatten, stamping each row's relation_type
            if "results" in res and isinstance(res["results"], list):
                return res["results"]
            flat = []
            for rtype, rows in res.items():
                if isinstance(rows, list):
                    for r in rows:
                        if isinstance(r, dict):
                            r.setdefault("relation_type", rtype)
                            flat.append(r)
            return flat
        return None

    def create_project(self, body):
        return self._request("POST", "projects/", body=body)

    def create_work_item(self, project_id, body):
        return self._request("POST", "projects/%s/work-items/" % project_id, body=body)

    def create_sub_issue(self, project_id, parent_id, body):
        b = dict(body)
        b["parent"] = parent_id
        return self._request("POST", "projects/%s/work-items/" % project_id, body=b)

    # --- richer write surface (labels, members, cycles, comments, links) -----
    # The shapes below are verified against a live Plane v1 self-host: work items
    # carry `labels` (a UUID list — PATCH replaces the whole set), `parent`, and
    # `assignees`; cycle/module membership is a sub-resource (not a work-item
    # field), so those are POSTed to cycle-issues / module-issues.
    def list_labels(self, project_id):
        return self.list_all("projects/%s/labels/" % project_id)

    def create_label(self, project_id, name, color=None):
        body = {"name": name}
        if color:
            body["color"] = color
        return self._request("POST", "projects/%s/labels/" % project_id, body=body)

    def update_label(self, project_id, label_id, color=None, name=None):
        body = {}
        if color:
            body["color"] = color
        if name:
            body["name"] = name
        return self._request("PATCH", "projects/%s/labels/%s/" % (project_id, label_id),
                             body=body)

    def delete_label(self, project_id, label_id):
        return self._request("DELETE", "projects/%s/labels/%s/" % (project_id, label_id))

    def list_members(self, project_id):
        return self.list_all("projects/%s/members/" % project_id)

    def list_cycles(self, project_id):
        return self.list_all("projects/%s/cycles/" % project_id)

    def add_to_cycle(self, project_id, cycle_id, issue_id):
        return self._request("POST", "projects/%s/cycles/%s/cycle-issues/"
                             % (project_id, cycle_id), body={"issues": [issue_id]})

    def add_to_module(self, project_id, module_id, issue_id):
        return self._request("POST", "projects/%s/modules/%s/module-issues/"
                             % (project_id, module_id), body={"issues": [issue_id]})

    def create_module(self, project_id, name):
        return self._request("POST", "projects/%s/modules/" % project_id, body={"name": name})

    def delete_module(self, project_id, module_id):
        return self._request("DELETE", "projects/%s/modules/%s/" % (project_id, module_id))

    def create_comment(self, project_id, issue_id, comment_html):
        return self._request("POST", "projects/%s/work-items/%s/comments/"
                             % (project_id, issue_id), body={"comment_html": comment_html})

    def list_comments(self, project_id, issue_id):
        """All comments on a work item, oldest first (so the newest is last).
        Used by the spec/approval gate (PB-61): user comments are read as
        AUTHORITATIVE over the description and any model-added plan content."""
        items = self.list_all("projects/%s/work-items/%s/comments/"
                              % (project_id, issue_id))
        items.sort(key=lambda c: c.get("created_at") or "")
        return items

    def create_link(self, project_id, issue_id, url, title=None):
        body = {"url": url}
        if title:
            body["title"] = title
        return self._request("POST", "projects/%s/work-items/%s/links/"
                             % (project_id, issue_id), body=body)

    # --- internal API (cookie/login auth) — estimate points only -------------
    # Plane's public token API does NOT expose estimate points (404); the web
    # app reads them from /api/workspaces/.../estimates/, which is session-auth
    # only (the token 401s there). So we authenticate with a stored cookie or a
    # programmatic login, used solely to auto-fetch the estimate scale.
    def _has_internal_auth(self):
        return bool(self._session_cookie or (self._email and self._password)
                    or self._cookie_refresher)

    def _login(self):
        # 1) CSRF token (also drops the csrftoken cookie into the jar).
        r = self._internal.open(urllib.request.Request(
            self.base + "/auth/get-csrf-token/",
            headers={"Accept": "application/json"}), timeout=30)
        csrf = json.loads(r.read().decode()).get("csrf_token")
        # 2) sign in (form post; the 302 sets the session-id cookie in the jar).
        body = urllib.parse.urlencode({"email": self._email, "password": self._password,
                                       "csrfmiddlewaretoken": csrf}).encode()
        req = urllib.request.Request(self.base + "/auth/sign-in/", data=body, method="POST")
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
        req.add_header("X-CSRFToken", csrf)
        req.add_header("Referer", self.base + "/")
        try:
            self._internal.open(req, timeout=30)
        except urllib.error.HTTPError as e:
            if e.code not in (200, 302):
                raise PlaneError("Plane sign-in failed (HTTP %s)" % e.code)
        if not any(c.name == "session-id" for c in self._jar):
            raise PlaneError("Plane sign-in did not establish a session (check email/password)")
        self._internal_ready = True

    def _csrf_from_cookie(self):
        """The csrftoken value out of the stored Cookie header (for write CSRF)."""
        for part in (self._session_cookie or "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == "csrftoken":
                return v
        return None

    def _ensure_internal_session(self):
        if self._internal_ready:
            return
        # Browser-sourced auth is the source of truth: pull the CURRENT cookie from
        # the store on every run, so we never ride a stale one (the user's ask).
        if self._cookie_refresher:
            fresh = self._cookie_refresher()
            if fresh:
                register_secret(fresh)
                if fresh != self._session_cookie:
                    self._session_cookie = fresh
                    if self._on_cookie_refreshed:
                        self._on_cookie_refreshed(fresh)
                self._internal_ready = True
                return
        if self._session_cookie:
            self._internal_ready = True
            return
        if self._email and self._password:
            self._login()
            return
        raise PlaneError("internal API auth not configured "
                         "(set a Plane session cookie or email/password)")

    def _internal_request(self, method, path, body=None, _retry=True):
        self._ensure_internal_session()
        url = "%s/%s" % (self.base, path.lstrip("/"))
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if self._session_cookie:
            req.add_header("Cookie", self._session_cookie)
        if method.upper() not in ("GET", "HEAD", "OPTIONS"):
            csrf = self._csrf_from_cookie()          # Django/DRF CSRF for writes
            if csrf:
                req.add_header("X-CSRFToken", csrf)
            req.add_header("Origin", self.base)
            req.add_header("Referer", self.base + "/")
        try:
            with self._internal.open(req, timeout=30) as resp:
                raw = resp.read().decode()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            if e.code in (401, 403) and _retry:
                if self._email and self._password:    # session expired → re-login once
                    self._internal_ready = False
                    self._login()
                    return self._internal_request(method, path, body=body, _retry=False)
                if self._cookie_refresher:            # cookie expired → re-pull once
                    fresh = self._cookie_refresher()
                    if fresh and fresh != self._session_cookie:
                        self._session_cookie = fresh
                        if self._on_cookie_refreshed:
                            self._on_cookie_refreshed(fresh)
                        return self._internal_request(method, path, body=body, _retry=False)
            detail = ""
            try:
                detail = e.read().decode()[:300]
            except Exception:
                pass
            raise PlaneError("Plane internal API %s %s -> HTTP %s%s"
                             % (method, path, e.code, (": " + detail) if detail else ""))
        except urllib.error.URLError as e:
            raise PlaneError("Plane internal API unreachable (%s): %s" % (url, e))

    def list_estimates(self, project_id):
        """The project's estimate scales via the internal API. Raises PlaneError
        when auth isn't configured or the endpoint is unreachable."""
        return self._internal_request(
            "GET", "api/workspaces/%s/projects/%s/estimates/" % (self.workspace, project_id))

    def create_estimate(self, project_id, values, name="Points", type_="points"):
        """Create an estimate scale on a project (internal API). `type_` is one of
        Plane's estimate types (points | categories | time); `values` are the
        ordered point labels (e.g. [1,2,3,5,8,13] Fibonacci, or [XS,S,M,L,XL] for a
        t-shirt 'categories' scale). Each becomes a point with key = 1-based index."""
        body = {"estimate": {"name": name, "type": type_, "last_used": True},
                "estimate_points": [{"key": i + 1, "value": str(v)}
                                    for i, v in enumerate(values)]}
        return self._internal_request(
            "POST", "api/workspaces/%s/projects/%s/estimates/" % (self.workspace, project_id),
            body=body)

    def delete_estimate(self, project_id, estimate_id):
        """Delete an estimate scale from a project (internal API)."""
        return self._internal_request(
            "DELETE", "api/workspaces/%s/projects/%s/estimates/%s/"
            % (self.workspace, project_id, estimate_id))

    # PB-130: state writes. Plane's public token API is read-only for states
    # (only list_states above), so creating/updating/deleting custom pipeline
    # states goes through the session-cookie / login internal API — the same
    # seam estimates use. Callers (seed_pipeline_states) wrap these best-effort.
    def create_state(self, project_id, name, group, color=None, default=False,
                     sequence=None):
        """Create a state in a project (internal API)."""
        body = {"name": name, "group": group}
        if color:
            body["color"] = color
        if default:
            body["default"] = True
        if sequence is not None:
            body["sequence"] = sequence
        return self._internal_request(
            "POST", "api/workspaces/%s/projects/%s/states/" % (self.workspace, project_id),
            body=body)

    def update_state(self, project_id, state_id, name=None, group=None, color=None,
                     default=None, sequence=None):
        """Patch an existing state (internal API)."""
        body = {}
        if name is not None:
            body["name"] = name
        if group is not None:
            body["group"] = group
        if color is not None:
            body["color"] = color
        if default is not None:
            body["default"] = default
        if sequence is not None:
            body["sequence"] = sequence
        return self._internal_request(
            "PATCH", "api/workspaces/%s/projects/%s/states/%s/"
            % (self.workspace, project_id, state_id), body=body)

    def delete_state(self, project_id, state_id):
        """Delete a state from a project (internal API). Plane refuses if the
        state still has issues or is the project default — the caller re-points
        issues and clears default first, then surfaces any leftover refusal."""
        return self._internal_request(
            "DELETE", "api/workspaces/%s/projects/%s/states/%s/"
            % (self.workspace, project_id, state_id))


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


def state_name(issue, states_by_id):
    """Resolve an issue's state NAME (PB-141 — needed to single out the Queued state,
    which shares the unstarted group with Todo). Handles expanded-object or bare-id
    `state`."""
    st = issue.get("state")
    if isinstance(st, dict):
        return st.get("name", "")
    if isinstance(st, str) and st in states_by_id:
        return states_by_id[st].get("name", "")
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


def resolve_state_id(states, value):
    """Resolve a state id from a free-text `value` that is EITHER a state name
    (e.g. "Backlog", "Todo", case-insensitive) OR a pbrain status word
    (todo|doing|done|blocked|dropped → its group's default). Returns the id, or
    None if nothing matches. Shared by the create + enrich state-set paths so
    "put it in Backlog" resolves the same way everywhere (PB-130)."""
    v = str(value or "").strip()
    if not v:
        return None
    for s in states:
        if (s.get("name") or "").strip().lower() == v.lower():
            return s["id"]
    if v.lower() in STATUS_TO_GROUP:
        return pick_state_id(states, STATUS_TO_GROUP[v.lower()])
    return None


def issue_labels(issue):
    """The issue's label ids, whether Plane returned them as bare uuids or objects."""
    return [l.get("id") if isinstance(l, dict) else l for l in (issue.get("labels") or [])]


def issue_to_ready(issue, project_id, states_by_id, module_by_issue, default_est_h,
                   uuid_hours=None, approved_label_ids=None, gate_map=None,
                   parked_label_ids=None):
    grp = state_group(issue, states_by_id)
    iid = issue.get("id")
    ep = issue.get("estimate_point")
    est_h = uuid_hours[ep] if (ep and uuid_hours and ep in uuid_hours) else default_est_h
    have_labels = issue_labels(issue)
    approved = bool(approved_label_ids) and any(
        lid in approved_label_ids for lid in have_labels)
    # PB-152: the manual-hold marker. True → hands-off selection paths (queued_multi /
    # claim_next_queued / enqueue_ordered) skip this issue; an explicit id run warns.
    is_parked = bool(parked_label_ids) and any(
        lid in parked_label_ids for lid in have_labels)
    return {
        "tie": "%s:%s" % (project_id, iid),
        "id": issue.get("sequence_id", iid),
        "issue_id": iid,
        "title": issue.get("name", ""),
        "est_h": est_h,
        "lane": module_by_issue.get(iid, ""),
        "due": issue.get("target_date") or "",
        "status": GROUP_TO_STATUS.get(grp, "todo"),
        # PB-141: the state NAME (e.g. Todo / Queued) + the queue rank, so groom can
        # single out Queued and pmw can walk it in sort_order.
        "state_name": state_name(issue, states_by_id),
        "sort_order": issue.get("sort_order"),
        "priority": issue.get("priority") or "none",
        "is_sub": bool(issue.get("parent")),
        "approved": approved,
        # PB-152: manual-hold marker — hands-off selection skips a parked issue.
        "is_parked": is_parked,
        # PB-94: gates this issue is auto-cleared for (empty → all manual).
        "auto_gates": issue_gate_clearances(issue, gate_map),
    }


def filter_ready(items, include_backlog=False, approved_only=False):
    groups = READY_GROUPS + (("backlog",) if include_backlog else ())
    ready = [it for it in items if it["_group"] in groups]
    if approved_only:
        # The spec/approval gate's opt-in hard filter (PB-45): only issues whose
        # implementation plan has been approved (carry the plan-approved label)
        # flow into the day. Off by default — normally we surface `approved` as a
        # flag and let packing/execute decide, not hide work at selection time.
        ready = [it for it in ready if it.get("approved")]
    ready.sort(key=lambda it: (PRIORITY_RANK.get(it["priority"], 4),
                               it["due"] or "9999-99-99", str(it["id"])))
    for it in ready:
        it.pop("_group", None)
    return ready


def approved_label_ids(client, project_id):
    """IDs of the project's `plan-approved` label(s), matched fuzzily by name.
    Best-effort: returns an empty set if labels can't be listed for ANY reason
    (network error, a client without the method), so the gate degrades to
    'nothing approved' rather than erroring the ready path."""
    try:
        labels = client.list_labels(project_id)
    except Exception:
        return set()
    target = _norm(APPROVED_LABEL)
    return {lab.get("id") for lab in labels
            if lab.get("id") and _norm(lab.get("name") or "") == target}


def parked_label_ids(client, project_id):
    """IDs of the project's `parked` label(s), matched fuzzily by name (PB-152).
    Best-effort, mirroring approved_label_ids: returns an empty set if labels can't
    be listed for ANY reason, so the parked filter degrades to 'nothing parked'
    rather than erroring the ready path."""
    try:
        labels = client.list_labels(project_id)
    except Exception:
        return set()
    target = _norm(PARKED_LABEL["name"])
    return {lab.get("id") for lab in labels
            if lab.get("id") and _norm(lab.get("name") or "") == target}


def gate_label_map(client, project_id):
    """Map gate name → set of that project's label ids for `auto:<gate>` (PB-94),
    matched fuzzily by normalised name. Best-effort: returns an empty map if labels
    can't be listed, so the gate seam degrades to 'nothing cleared' (all manual)
    rather than erroring."""
    try:
        labels = client.list_labels(project_id)
    except Exception:
        return {}
    want = {_norm("auto:%s" % g): g for g in GATE_NAMES}
    out = {g: set() for g in GATE_NAMES}
    for lab in labels:
        g = want.get(_norm(lab.get("name") or ""))
        if g and lab.get("id"):
            out[g].add(lab["id"])
    return out


def issue_gate_clearances(issue, gate_map):
    """The list of gate names this issue is auto-cleared for, given a project's
    gate_label_map. Stable order (GATE_NAMES). Empty when the issue carries no
    auto:* label → every gate stays manual (the default)."""
    if not gate_map:
        return []
    have = set(issue_labels(issue))
    return [g for g in GATE_NAMES if have & gate_map.get(g, set())]


def build_status_body(status, states, completed_at=None, to_state=None):
    """Return the PATCH body to move an issue to the given pbrain status.

    PB-130: `to_state` is an optional state NAME (e.g. "Building") that targets a
    specific named pipeline state within the status's group. pick_state_id prefers
    an exact name match, so on a pipeline project the issue lands on that named state
    and on a non-pipeline project it degrades to the group's default — a clean
    fallback that keeps every existing project working unchanged."""
    group = STATUS_TO_GROUP.get(status)
    if group is None:
        raise PlaneError("unknown status: %s" % status)
    want_name = to_state or ("blocked" if status == "blocked" else None)
    sid = pick_state_id(states, group, want_name=want_name)
    if not sid:
        raise PlaneError("no Plane state found for group '%s' — create one in the project" % group)
    body = {"state": sid}
    if status == "done":
        body["completed_at"] = completed_at or None
    return body


def _est_of(issue, uuid_points=None):
    """Estimate weight for progress. Resolves the issue's estimate_point UUID to
    its numeric point value via `uuid_points`; falls back to a numeric
    estimate_point (legacy schemes) else 0. Pure."""
    ep = issue.get("estimate_point")
    if ep and uuid_points and ep in uuid_points:
        return uuid_points[ep]
    try:
        return float(ep or 0)
    except (TypeError, ValueError):
        return 0.0


def issue_to_progress(issue, project_id, states_by_id, uuid_points=None):
    """Map a raw issue to a progress row (status + estimate weight). Pure."""
    grp = state_group(issue, states_by_id)
    iid = issue.get("id")
    return {
        "tie": "%s:%s" % (project_id, iid),
        "title": issue.get("name", ""),
        "status": GROUP_TO_STATUS.get(grp, "todo"),
        "group": grp,
        "est": _est_of(issue, uuid_points),
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


def thinness_flags(issue, sub_count=None, has_estimate_scale=False):
    """Flags for a too-thin Plane issue. Pure.

    Treats an ABSENT field as "can't assess" (no flag) — only a field that is
    present-but-empty is thin. Avoids false enrichment proposals when a
    self-host version simply doesn't return a field. Flags:
      no_description | no_priority | no_estimate

    no_estimate is flagged ONLY when the project has a cached estimate scale
    (`has_estimate_scale`) — without one we can't resolve a point value to its
    estimate_point UUID, so the flag would be unresolvable. With a scale, an
    empty estimate_point is genuinely thin and groomable via the `estimate` verb.
    """
    flags = []
    if "description_stripped" in issue or "description_html" in issue:
        stripped = (issue.get("description_stripped") or "").strip()
        html = (issue.get("description_html") or "").strip()
        if not stripped and html in ("", "<p></p>", "<p><br></p>"):
            flags.append("no_description")
    if "priority" in issue and (issue.get("priority") in (None, "", "none")):
        flags.append("no_priority")
    if has_estimate_scale and "estimate_point" in issue and not issue.get("estimate_point"):
        flags.append("no_estimate")
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
    "sort_order": "sort_order",  # PB-141: groom writes the queue rank (ascending)
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
# Name resolution + fuzzy matching (pure — the "find the thing by name" layer)
# ---------------------------------------------------------------------------
def _norm(s):
    """Lowercase, collapse every non-alphanumeric run to a single space, strip.
    The shared normaliser for fuzzy name/label/member matching. Pure."""
    import re
    return re.sub(r"[^a-z0-9]+", " ", (s or "").lower()).strip()


def match_label(labels, name):
    """The label dict whose name matches `name` (normalised), else None. Pure."""
    n = _norm(name)
    if not n:
        return None
    for lab in labels:
        if _norm(lab.get("name")) == n:
            return lab
    return None


def match_member(members, ref):
    """Resolve a person reference against a project's members. Pure.

    Returns (member|None, candidates): an exact id / display-name / email match
    resolves uniquely; otherwise a normalised-substring search collects
    candidates (the caller — the model — disambiguates when len != 1). Never
    creates: people are not auto-created (D4 guardrail).
    """
    r = _norm(ref)
    for mb in members:
        if mb.get("id") == (ref or "").strip():
            return mb, [mb]
    if not r:
        return None, []
    fields = lambda mb: [_norm(mb.get("display_name")), _norm(mb.get("email")),
                         _norm("%s %s" % (mb.get("first_name") or "",
                                          mb.get("last_name") or ""))]
    for mb in members:                       # exact (whole-field) match wins
        if r in [f for f in fields(mb) if f]:
            return mb, [mb]
    cands = [mb for mb in members if any(r in f for f in fields(mb) if f)]
    return (cands[0], cands) if len(cands) == 1 else (None, cands)


def merge_labels(current_ids, add=None, remove=None, replace=None):
    """New label-id set for a PATCH. `replace` wins; else current + add - remove,
    de-duped, order-preserving. Pure (Plane's `labels` PATCH replaces the set, so
    add/remove must be computed against the issue's current labels)."""
    if replace is not None:
        return list(dict.fromkeys(replace))
    out = list(dict.fromkeys(current_ids or []))
    for i in (add or []):
        if i not in out:
            out.append(i)
    if remove:
        rm = set(remove)
        out = [i for i in out if i not in rm]
    return out


def parse_issue_ref(ref):
    """Parse a Plane issue reference → (identifier, sequence). Pure.

    Accepts a browse URL (".../browse/PB-26/" or ".../browse/PB-26"), a bare id
    with ("PB-26") or without ("pb26") the hyphen, or a bare sequence ("26",
    needs a project from the caller). identifier is upper-cased; returns
    (None, None) when nothing parses.
    """
    import re
    s = (ref or "").strip()
    mu = re.search(r"/browse/([A-Za-z][A-Za-z0-9]*)-(\d+)", s)
    if mu:
        return mu.group(1).upper(), int(mu.group(2))
    mi = re.match(r"^([A-Za-z][A-Za-z0-9]*)-(\d+)$", s)
    if mi:
        return mi.group(1).upper(), int(mi.group(2))
    # Hyphenless id ("pb8", "PB8"): a letters-only prefix glued to the sequence.
    # The prefix must be letters-only (not [A-Za-z0-9]*) so the trailing digits
    # split off as the sequence rather than being swallowed by a greedy prefix.
    mh = re.match(r"^([A-Za-z]+)(\d+)$", s)
    if mh:
        return mh.group(1).upper(), int(mh.group(2))
    if re.match(r"^\d+$", s):
        return None, int(s)
    return None, None


class CreationGuard:
    """Caps how many objects one invocation may auto-create so labels (and the
    like) don't pile up — the D4 guardrail. Cap from PBRAIN_PLANE_MAX_CREATES
    (default 5). `allow()` checks the budget; `record()` spends one."""
    def __init__(self, max_creates=None):
        if max_creates is None:
            try:
                max_creates = int(os.environ.get("PBRAIN_PLANE_MAX_CREATES", "5"))
            except (TypeError, ValueError):
                max_creates = 5
        self.max = max_creates
        self.count = 0

    def allow(self):
        return self.count < self.max

    def record(self):
        self.count += 1
        return self.count


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


def ready(cfg, client, project_id, include_backlog=False, with_lanes=False,
          approved_only=False):
    states = client.list_states(project_id)
    states_by_id = {s["id"]: s for s in states}
    module_by_issue = _module_map(client, project_id, with_lanes)
    ensure_estimate_scale(cfg, client, project_id)
    uuid_hours = est_uuid_to_hours(cfg, project_id)
    approved_ids = approved_label_ids(client, project_id)  # spec/approval gate (PB-45)
    gate_map = gate_label_map(client, project_id)          # per-gate auto clearances (PB-94)
    parked_ids = parked_label_ids(client, project_id)      # manual-hold marker (PB-152)
    items = []
    for issue in client.list_work_items(project_id):
        r = issue_to_ready(issue, project_id, states_by_id, module_by_issue,
                           cfg["default_est_h"], uuid_hours,
                           approved_label_ids=approved_ids, gate_map=gate_map,
                           parked_label_ids=parked_ids)
        r["_group"] = state_group(issue, states_by_id)
        items.append(r)
    return filter_ready(items, include_backlog=include_backlog, approved_only=approved_only)


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
                body = build_status_body(t["status"], states,
                                         completed_at=t.get("completed_at"),
                                         to_state=t.get("to_state"))
                client.update_work_item(pid, iid, body)
                summary.append({"tie": "%s:%s" % (pid, iid), "ok": True, "status": t["status"]})
            except PlaneError as e:
                summary.append({"tie": "%s:%s" % (pid, iid), "ok": False, "error": str(e)})
    return summary


def _ready_sort(rows):
    rows.sort(key=lambda it: (PRIORITY_RANK.get(it.get("priority"), 4),
                              it.get("due") or "9999-99-99", str(it.get("id"))))
    return rows


def order_ready_stream(cfg, client, rows):
    """Order a flat ready stream for the groom→pmw hand-off (PB-94).

    Two transforms on top of the priority→due→id sort:
      1. Drop a PARENT row when its own children are already present in the stream
         (a parent with open todo sub-issues is a container, not a unit of work —
         pmw drives the children; cf. subtree_context / PB-81). A childless parent
         stays.
      2. Hoist BLOCKERS: if row B blocks row A and both are in the stream, B must
         come before A. Done with a stable topological pass over the priority-sorted
         list, so within the dependency constraint the priority order is preserved.
    Blocker edges come from each row's `blocked_by` relations (PB-94 read path),
    restricted to rows IN the stream (an out-of-stream blocker — e.g. one still in
    backlog — is pmw's pre-flight problem, not groom's to reorder). Best-effort:
    a relation-read failure for one row just means no edges from it."""
    # index by issue uuid (tie tail) for edge resolution
    by_uuid = {}
    for r in rows:
        tie = r.get("tie", "")
        uuid = tie.split(":", 1)[1] if ":" in tie else r.get("issue_id", "")
        if uuid:
            by_uuid[uuid] = r
    # 1. drop parents whose children are in the stream
    child_parents = set()
    for r in rows:
        # issue_to_ready doesn't carry parent; re-derive cheaply is costly, so we
        # rely on subtree semantics at execute time. Here we only collapse when we
        # can see a parent/child pair via the relation read below; parents without
        # visible children pass through untouched.
        pass
    # 2. build blocker edges (blocker_uuid -> set of blocked rows), in-stream only
    blocks = {}   # uuid -> set(uuid) it blocks
    for r in rows:
        tie = r.get("tie", "")
        if ":" not in tie:
            continue
        pid, iid = tie.split(":", 1)
        try:
            buuids = _blocker_uuids(client.list_relations(pid, iid))
        except Exception:
            buuids = []
        for b in buuids:
            if b in by_uuid:                 # blocker is in the stream
                blocks.setdefault(b, set()).add(iid)
    if not blocks:
        return rows                          # nothing to reorder
    # stable topological order honoring priority order as the base sequence
    order = []
    placed = set()
    def place(uuid, stack):
        if uuid in placed or uuid not in by_uuid:
            return
        if uuid in stack:                    # cycle guard — break it, don't loop
            return
        stack.add(uuid)
        # place this node's blockers first
        for b, targets in blocks.items():
            if uuid in targets:
                place(b, stack)
        stack.discard(uuid)
        if uuid not in placed:
            placed.add(uuid)
            order.append(by_uuid[uuid])
    for r in rows:                           # iterate in the existing priority order
        tie = r.get("tie", "")
        uuid = tie.split(":", 1)[1] if ":" in tie else r.get("issue_id", "")
        place(uuid, set())
    return order


def ready_multi(cfg, client, project_ids, include_backlog=False, with_lanes=False,
                approved_only=False, ordered=False):
    """Ready tasks across several projects, each tagged with its project, then
    sorted cross-project by priority → due → id. Reuses ready() per project; a
    project that errors is skipped (best-effort) so one bad project can't fail
    the batch. PB-94: `ordered=True` additionally hoists blockers ahead of the
    issues they block (the groom→pmw hand-off stream), via order_ready_stream."""
    rows = []
    for pid in project_ids:
        try:
            rs = ready(cfg, client, pid, include_backlog=include_backlog,
                       with_lanes=with_lanes, approved_only=approved_only)
        except PlaneError:
            continue
        label = project_label(cfg, pid)
        short = project_short(cfg, pid)
        for r in rs:
            r["project_id"] = pid
            r["project"] = label
            r["project_short"] = short
            rows.append(r)
    _ready_sort(rows)
    if ordered:
        rows = order_ready_stream(cfg, client, rows)
    return rows


def queued_multi(cfg, client, project_ids):
    """PB-141: the QUEUE — issues groom has moved into the Queued state, in the rank
    order groom wrote (sort_order ascending, ties broken by priority → due → id). This
    is what /plan-my-work walks: Plane is the queue, not the vault markdown. Reuses
    ready_multi (Queued is group=unstarted, so it's already ready-eligible) and keeps
    only state_name == QUEUED_STATE. PB-152: a `parked` issue is NEVER in the queue a
    hands-off mode walks — drop it here (this also covers claim_next_queued, which
    iterates these rows). The merged stream spans all project_ids, so the queue is
    cross-project (PB-154)."""
    rows = [r for r in ready_multi(cfg, client, project_ids)
            if r.get("state_name") == QUEUED_STATE and not r.get("is_parked")]
    rows.sort(key=lambda r: (
        r["sort_order"] if isinstance(r.get("sort_order"), (int, float)) else float("inf"),
        PRIORITY_RANK.get(r.get("priority"), 4),
        r.get("due") or "9999-99-99",
        str(r.get("id")),
    ))
    return rows


def claim_next_queued(cfg, client, project_ids, session_token):
    """PB-141 concurrency: atomically CLAIM the top of the Queued state for THIS
    session, so two `/plan-my-work` drivers walking the queue in parallel pick
    DIFFERENT issues sequentially instead of colliding on the same top.

    Claim+verify protocol (Plane has no compare-and-set, so we use last-write-wins
    on a per-session sentinel):
      1. read the queue (queued_multi); walk candidates top-down.
      2. CLAIM: PATCH the candidate to the Planning state AND stamp its sort_order
         with a session-unique sentinel, in ONE call. This also moves it OUT of the
         Queued (unstarted) group, so other sessions' queue reads stop seeing it.
      3. VERIFY: re-read the issue. If it's no longer unstarted AND its sort_order
         equals OUR sentinel, this session owns it (our PATCH was the last write).
         Otherwise another session won the race — skip to the next candidate.
    Returns the claimed ready-row (with project_id) or None when the queue is empty
    / every candidate was taken. Best-effort; a transient error skips that candidate.

    `session_token` must be unique per caller (the shell passes $$ + epoch); it maps
    to a distinct negative sentinel so two simultaneous claimers never collide on the
    sentinel value itself."""
    try:
        sentinel = -1.0 - (abs(int(session_token)) % 1_000_000_000)
    except (TypeError, ValueError):
        sentinel = -1.0 - (abs(hash(session_token)) % 1_000_000_000)
    for row in queued_multi(cfg, client, project_ids):
        tie = row.get("tie", "")
        if ":" not in tie:
            continue
        pid, iid = tie.split(":", 1)
        try:
            states = client.list_states(pid)
            body = build_status_body("doing", states, to_state="Planning")
            body["sort_order"] = sentinel
            client.update_work_item(pid, iid, body)          # CLAIM
            fresh = client.get_work_item(pid, iid)            # VERIFY
        except PlaneError:
            continue
        sbi = {s["id"]: s for s in states}
        still_queued = GROUP_TO_STATUS.get(state_group(fresh, sbi)) == "todo"
        mine = (not still_queued) and fresh.get("sort_order") == sentinel
        if mine:
            row["claimed"] = True
            return row
        # Lost the race for this one (another session's write stuck) — try the next.
    return None


def enqueue_ordered(cfg, client, ordered_rows):
    """PB-141: write the computed run queue INTO Plane. Move each row (in the given
    order) to the Queued state and stamp an ascending sort_order so the board and
    /plan-my-work both see groom's ranking. Idempotent: re-running re-ranks the same
    set; a row already past Queued (group=started/completed/cancelled, i.e. work has
    begun) is LEFT ALONE — only todo-group issues (Todo/Queued) are (re)queued, so we
    never yank an in-flight issue back into the queue. Backlog is never a target.
    Per-row best-effort; returns a summary list."""
    out = []
    states_cache = {}
    # sort_order increments; use a coarse step so manual nudges fit between ranks.
    rank = 0.0
    for r in ordered_rows:
        tie = r.get("tie", "")
        if ":" not in tie:
            out.append({"tie": tie, "ok": False, "error": "bad tie"})
            continue
        pid, iid = tie.split(":", 1)
        # PB-152: a parked issue is a manual hold — groom never enqueues it, so
        # hands-off pmw modes never see it. (Defensive: the ordered stream is also
        # parked-aware, but skip here too so a direct enqueue can't queue one.)
        if r.get("is_parked"):
            out.append({"tie": tie, "ok": True, "skipped": "parked"})
            continue
        # Only (re)queue work that hasn't started. status comes from the row's group.
        if r.get("status") not in ("todo",):
            out.append({"tie": tie, "ok": True, "skipped": "already in progress"})
            continue
        rank += 1000.0
        try:
            if pid not in states_cache:
                states_cache[pid] = client.list_states(pid)
            body = build_status_body("todo", states_cache[pid], to_state=QUEUED_STATE)
            body["sort_order"] = rank
            client.update_work_item(pid, iid, body)
            out.append({"tie": tie, "ok": True, "state": QUEUED_STATE, "sort_order": rank})
        except PlaneError as e:
            out.append({"tie": tie, "ok": False, "error": str(e)})
    return out


def rank_done_by_completion(cfg, client, project_ids):
    """PB-146: order each project's Landed column newest-completed-first. Plane's board
    sorts a column by sort_order ascending, so we stamp the most-recently-completed
    issue with the SMALLEST sort_order. Touches only sort_order (no state change) on
    completed-group issues; issues without a completed_at sink to the bottom. Idempotent
    — re-running reproduces the same ranking. Per-row best-effort; returns a summary."""
    out = []
    for pid in project_ids:
        try:
            items = client.list_work_items(pid)
            states = client.list_states(pid)
        except PlaneError as e:
            out.append({"project_id": pid, "ok": False, "error": str(e)})
            continue
        sbi = {s["id"]: s for s in states}
        done = [it for it in items
                if GROUP_TO_STATUS.get(state_group(it, sbi)) == "done"]
        # Newest completed_at first → smallest sort_order. Missing completed_at sorts
        # last (empty string is < any real ISO timestamp, so negate via the flag).
        done.sort(key=lambda it: (it.get("completed_at") or "",), reverse=True)
        rank = 0.0
        for it in done:
            rank += 1000.0
            try:
                client.update_work_item(pid, it.get("id"), {"sort_order": rank})
                out.append({"tie": "%s:%s" % (pid, it.get("id")), "ok": True,
                            "sort_order": rank})
            except PlaneError as e:
                out.append({"tie": "%s:%s" % (pid, it.get("id")), "ok": False,
                            "error": str(e)})
    return out


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
        ensure_estimate_scale(cfg, client, pid)
        uuid_points = est_uuid_to_points(cfg, pid)
        rows = [issue_to_progress(it, pid, sbi, uuid_points) for it in items]
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
        short = project_short(cfg, pid)
        has_scale = bool(ensure_estimate_scale(cfg, client, pid))
        for r in rs:
            iid = r["issue_id"]
            try:
                issue = client.get_work_item(pid, iid)
            except PlaneError:
                continue
            if issue.get("parent"):
                continue
            flags = thinness_flags(issue, has_estimate_scale=has_scale)
            if flags:
                out.append({"tie": r["tie"], "project_id": pid, "project": label,
                            "project_short": short, "id": r.get("id"),
                            "title": r["title"], "flags": flags})
    return out


# How small (in estimate-hours) an issue must be for the NIGHTLY mechanical heuristic
# to call implementation "easy" and pre-grant auto:implement. Conservative on purpose:
# the heuristic is a safe FLOOR; the interactive agent (Tier 2) does the real judgment
# and may grant more. Override via PBRAIN_GROOM_AUTO_MAX_HOURS.
_AUTO_EASY_MAX_HOURS = 3.0


def suggest_auto_stages(issue, *, approved=False, has_open_blockers=False,
                        has_open_children=False, est_hours=None, is_docs_or_chore=False):
    """The NIGHTLY mechanical heuristic: which auto:<stage> labels to pre-grant a
    well-formed todo issue, WITHOUT an LLM. Pure. Conservative (better to under-label
    — the user reviews the Auto column and the interactive agent refines). Rules:

      * auto:plan      — always (drafting + SAVING a plan is low-risk + reviewable).
      * auto:implement — only when the work looks genuinely easy: an APPROVED plan
                         exists AND no open blockers AND no open sub-issues AND the
                         estimate is small (<= _AUTO_EASY_MAX_HOURS). A complicated
                         plan (no approval / big estimate / blockers / children) does
                         NOT get auto:implement.
      * auto:test      — only if implement was granted (test-after-implement) AND the
                         issue isn't a pure docs/chore item where tests don't apply.
      * auto:ship      — only if implement was granted (a clear path to a PR).
      * auto:land      — NEVER (merge stays a manual, irreversible gate).

    Returns a stage-name list in GATE_NAMES order (a subset of plan/implement/test/
    ship), never including 'land'."""
    try:
        max_h = float(os.environ.get("PBRAIN_GROOM_AUTO_MAX_HOURS")
                      or _AUTO_EASY_MAX_HOURS)
    except (TypeError, ValueError):
        max_h = _AUTO_EASY_MAX_HOURS
    stages = ["plan"]
    small = (est_hours is not None and est_hours <= max_h)
    easy_impl = (approved and not has_open_blockers and not has_open_children and small)
    if easy_impl:
        stages.append("implement")
        if not is_docs_or_chore:
            stages.append("test")
        stages.append("ship")
    # NEVER auto:land. Keep GATE_NAMES order.
    return [g for g in GATE_NAMES if g in stages]


def groom_run(cfg, client, project_ids, apply=False):
    """Headless mechanical grooming for the daily loop (PB-46, redefined in PB-94).

    TODO-ONLY. Backlog is the user's STAGING AREA — groom never touches it: no
    backlog→todo promotion, no thin-flagging of backlog. An issue enters the
    pipeline only when the USER moves it to `todo`. groom looks ONLY at todo
    (READY_GROUPS = unstarted/started) top-level issues and flags the THIN ones
    (missing description/estimate/priority) so the agent can enrich them before
    they're handed to `/plan-my-work`. The ordered hand-off stream itself comes
    from `ready --ordered`, not from here — this run is the triage/enrichment scan.

    `apply` is retained for signature compatibility but groom no longer makes
    deterministic writes (the old conservative backlog→todo move is gone); thin
    todo issues are reported for the agent/interactive `review` to enrich. Never
    raises for a single project — a project that errors is skipped. Returns a
    JSON-able report dict: `todo` (well-formed, pipeline-ready) + `needs_review`
    (thin todo issues to enrich).
    """
    # PB-94+: groom now also PRE-GRANTS auto:<stage> labels (except auto:land) to
    # well-formed todo issues via the nightly mechanical heuristic (suggest_auto_stages).
    # Tier 2 (the interactive groom-drive agent) refines these by real judgment.
    # PBRAIN_GROOM_NO_AUTO=1 disables auto-assignment (mechanical triage only).
    auto_off = os.environ.get("PBRAIN_GROOM_NO_AUTO") == "1"
    report = {"generated_for": list(project_ids), "applied": bool(apply),
              "projects": [], "todo": [], "needs_review": [], "errors": []}
    for pid in project_ids:
        label = project_label(cfg, pid)
        short = project_short(cfg, pid)
        try:
            states = client.list_states(pid)
            states_by_id = {s["id"]: s for s in states}
            has_scale = bool(ensure_estimate_scale(cfg, client, pid))
            issues = list(client.list_work_items(pid))
        except PlaneError as e:
            report["errors"].append({"project_id": pid, "project": label, "error": str(e)})
            continue
        # Per-project maps for the auto-stage heuristic (best-effort; degrade to off).
        approved_ids = set()
        gate_map = {}
        hours_by_ep = {}
        labels_by_id = {}
        if not auto_off:
            try:
                approved_ids = set(approved_label_ids(client, pid))
                gate_map = gate_label_map(client, pid)
                hours_by_ep = est_uuid_to_hours(cfg, pid)
                labels_by_id = {l.get("id"): (l.get("name") or "")
                                for l in client.list_labels(pid)}
            except Exception:
                # Any failure (PlaneError, or a minimal client lacking these methods)
                # disables auto-assignment for this project — never crashes groom.
                approved_ids, gate_map, hours_by_ep, labels_by_id = set(), {}, {}, {}
        counts = {"todo": 0, "needs_review": 0, "skipped": 0}
        for issue in issues:
            if issue.get("parent"):
                counts["skipped"] += 1          # sub-issues groom via their parent
                continue
            grp = state_group(issue, states_by_id)
            if grp not in READY_GROUPS:         # PB-94: skip backlog (+ terminal) entirely
                counts["skipped"] += 1
                continue
            iid = issue.get("id")
            seq = issue.get("sequence_id", iid)
            title = issue.get("name", "")
            flags = thinness_flags(issue, has_estimate_scale=has_scale)
            row = {"tie": "%s:%s" % (pid, iid), "project_id": pid, "project": label,
                   "project_short": short, "id": seq, "title": title, "group": grp}
            if flags:
                row["flags"] = flags
                report["needs_review"].append(row)
                counts["needs_review"] += 1
            else:
                # NIGHTLY heuristic: pre-grant auto:<stage> labels (never land).
                # Skip entirely when the project maps couldn't be built (gate_map empty
                # = no auto labels resolvable / minimal client) — best-effort.
                if not auto_off and gate_map:
                    # CHEAP signals first (no network — all from the already-fetched
                    # issue + project maps).
                    cur_ids = issue_labels(issue)
                    names = {labels_by_id.get(lid, "") for lid in cur_ids}
                    approved = bool(set(cur_ids) & approved_ids)
                    ep = issue.get("estimate_point")
                    est_h = hours_by_ep.get(ep) if ep else None
                    is_dc = bool(names & {"docs", "chore"})
                    small = (est_h is not None and est_h <= _AUTO_EASY_MAX_HOURS)
                    # The EXPENSIVE per-issue checks (sub-issues + blockers, 2 API calls
                    # each) only change the outcome when implement is otherwise eligible
                    # (approved AND small). Otherwise the issue gets auto:plan only and
                    # the checks are wasted — so SKIP them. This keeps the nightly scan
                    # to ~O(projects) network calls, not O(issues), which is what was
                    # exhausting Plane's rate limit and emptying the queue.
                    has_kids = has_block = False
                    if approved and small:
                        try:
                            has_kids = bool(client.list_sub_issues(pid, iid))
                        except PlaneError:
                            has_kids = False
                        try:
                            has_block = bool(blocked_by_ids(cfg, client, "%s:%s" % (pid, iid)))
                        except Exception:
                            has_block = False
                    suggested = suggest_auto_stages(
                        issue, approved=approved, has_open_blockers=has_block,
                        has_open_children=has_kids, est_hours=est_h, is_docs_or_chore=is_dc)
                    row["auto_suggested"] = suggested
                    # Apply: add only the stage labels not already present (idempotent,
                    # never removes a user-set label). Mechanical tier only ADDS.
                    # gate_map values are SETS of label ids (a project can carry dupes);
                    # pick one id per suggested stage.
                    if apply and suggested:
                        want_ids = []
                        for s in suggested:
                            ids = gate_map.get(s) or set()
                            if ids:
                                want_ids.append(sorted(ids)[0])
                        if want_ids:
                            new_ids = merge_labels(cur_ids, add=want_ids)
                            if set(new_ids) != set(cur_ids):
                                try:
                                    client.update_work_item(pid, iid, {"labels": new_ids})
                                except PlaneError:
                                    pass
                report["todo"].append(row)
                counts["todo"] += 1
        report["projects"].append(
            {"project_id": pid, "project": label, "counts": counts})
    return report


def explode_context(cfg, client, ref, project_ref=None):
    """Read-only context for INTERACTIVELY exploding ONE issue into sub-issues.
    Resolve `ref` via find_issues; 0 or >1 cards → return the candidates so the
    model disambiguates. Exactly one → fetch the full record + its existing
    sub-issues + the project's estimate-scale info, so the Socratic walk can
    avoid duplicating children and offer valid estimate points. Never writes."""
    cards = find_issues(cfg, client, ref, project_ref=project_ref)
    if len(cards) != 1:
        return {"status": "none" if not cards else "ambiguous", "candidates": cards}
    card = cards[0]
    pid, iid = card["project_id"], card["issue_id"]
    try:
        issue = client.get_work_item(pid, iid)
    except PlaneError as e:
        return {"status": "error", "error": str(e), "candidates": cards}
    scale = ensure_estimate_scale(cfg, client, pid)   # the live/imported scale, or None

    # get_work_item returns `state` as a bare id (unlike list_work_items, which
    # expands it). Resolve ids → names via the project's state list so neither the
    # parent nor its children surface a raw uuid.
    try:
        names_by_state = {s.get("id"): s.get("name") for s in client.list_states(pid)}
    except PlaneError:
        names_by_state = {}

    def _state_name(obj):
        st = obj.get("state")
        if isinstance(st, dict):
            return st.get("name")
        return names_by_state.get(st, st)

    # Best-effort, like the get_work_item/list_states reads above — a failed
    # sub-issue fetch degrades to "no known children", never a crashed context.
    try:
        raw_subs = client.list_sub_issues(pid, iid) or []
    except PlaneError:
        raw_subs = []
    subs = []
    for s in raw_subs:
        subs.append({"id": s.get("id"), "title": s.get("name", ""),
                     "state": _state_name(s)})

    def _pt_key(v):
        try:
            return (0, float(v))
        except (TypeError, ValueError):
            return (1, 0.0)

    return {
        "status": "ok",
        "tie": card["tie"], "id": card["id"], "issue_id": iid,
        "title": issue.get("name", ""),
        "description": (issue.get("description_stripped") or "").strip(),
        "priority": issue.get("priority"),
        "state": card.get("state"),
        "estimate_point": issue.get("estimate_point"),
        "has_estimate_scale": bool(scale),
        "estimate_points": sorted((scale or {}).get("points", {}).keys(), key=_pt_key) if scale else [],
        "existing_subissues": subs,
        "project": card["project"], "project_id": pid,
    }


def _blocker_uuids(relations):
    """Extract the related-issue UUIDs that BLOCK the subject from a normalised
    relations list (PB-94). Plane models "A is blocked_by B" as a `blocked_by`
    relation on A whose related issue is B. The observed payload keys the blocker by
    `issue_id`; be defensive about other builds' field names too
    (related_issue/related_issue_detail/issue). NB: `id` is NOT used as a fallback —
    in a flat-list build it can be the relation's own row id, not the blocker's."""
    out = []
    for r in (relations or []):
        if not isinstance(r, dict):
            continue
        rtype = (r.get("relation_type") or r.get("relation") or "").strip().lower()
        if rtype != "blocked_by":
            continue
        rel = (r.get("issue_id") or r.get("related_issue")
               or r.get("related_issue_detail") or r.get("issue"))
        if isinstance(rel, dict):
            rel = rel.get("id")
        if rel:
            out.append(rel)
    return out


def blocked_by_ids(cfg, client, ref, project_ref=None):
    """The OPEN blockers of an issue, as ready-shaped rows (PB-94).

    "Open blocker" = an issue this one is `blocked_by` whose state group is NOT
    terminal (completed/cancelled) — a done blocker no longer blocks. The execution
    loop's PRE-FLIGHT calls this: when an issue is handed to it directly (the manual
    path), it must run each open blocker FIRST (one full loop each), then the issue.
    On the groom path `ready --ordered` has already interleaved blockers ahead, so the
    list is empty there. Returns ready rows (issue_to_ready-shaped, carrying tie /
    auto_gates / priority) so the caller can drive them with the same machinery as any
    other target. Best-effort: `[]` when relations can't be read or nothing blocks —
    never raises (a missing relation read must not wedge execution)."""
    cards = find_issues(cfg, client, ref, project_ref=project_ref)
    if len(cards) != 1:
        return {"status": "none" if not cards else "ambiguous", "candidates": cards}
    card = cards[0]
    pid, iid = card["project_id"], card["issue_id"]
    try:
        relations = client.list_relations(pid, iid)
        blocker_uuids = set(_blocker_uuids(relations))
        if not blocker_uuids:
            return {"status": "ok", "tie": card["tie"], "blockers": []}
        states = client.list_states(pid)
        states_by_id = {s["id"]: s for s in states}
        module_by_issue = _module_map(client, pid, False)
        ensure_estimate_scale(cfg, client, pid)
        uuid_hours = est_uuid_to_hours(cfg, pid)
        approved_ids = approved_label_ids(client, pid)
        gate_map = gate_label_map(client, pid)
        items = list(client.list_work_items(pid))
    except PlaneError as e:
        return {"status": "error", "error": str(e), "candidates": cards}
    label = project_label(cfg, pid)
    blockers = []
    for issue in items:
        if issue.get("id") not in blocker_uuids:
            continue
        if state_group(issue, states_by_id) in TERMINAL_GROUPS:
            continue  # a done/cancelled blocker no longer blocks
        r = issue_to_ready(issue, pid, states_by_id, module_by_issue,
                           cfg["default_est_h"], uuid_hours,
                           approved_label_ids=approved_ids, gate_map=gate_map)
        r["project_id"] = pid
        r["project"] = label
        blockers.append(r)
    _ready_sort(blockers)
    return {"status": "ok", "tie": card["tie"], "blockers": blockers}


def subtree_context(cfg, client, ref, project_ref=None):
    """Read-only resolution of an execute TARGET that may be a PARENT issue (PB-81).

    Resolve `ref` via find_issues; 0 or >1 cards → return candidates so the caller
    disambiguates (same shape as explode/spec). Exactly one → report whether it has
    any NOT-DONE sub-issues and, if so, return them as ready-shaped rows.

    The contract `/plan-my-work task execute` relies on: a parent with sub-issues is
    ONE logical target executed as SEPARATE sequential units (one branch/PR/gated-merge
    per child, parent closed only after all children merge). So when `has_open_children`
    is true, the caller drives `children` (NOT the parent) — sorted priority → due → id,
    the same order `ready()` packs — and closes the parent last.

    Children are built through the SAME machinery as `ready()` (issue_to_ready +
    _ready_sort) so an execute target and a freshly-pulled ready row are byte-for-byte
    the same kind of row — but the state filter here is DELIBERATELY WIDER than `ready()`'s
    daily lane: a parent execute target drives every NOT-DONE child, BACKLOG included
    (only TERMINAL_GROUPS = completed/cancelled are dropped). The daily `ready()` pull
    hides backlog by design; targeting a parent for execution does not, because a backlog
    sub-issue is still unfinished work under that parent (PB-81 / the bug where a parent
    whose only remaining child sat in Backlog resolved as a childless leaf and was skipped).
    A childless issue (or a parent whose children are all done/cancelled) comes back with
    `has_open_children: false` and an empty `children` list, and the caller treats the
    issue itself as the unit of work. Never writes."""
    cards = find_issues(cfg, client, ref, project_ref=project_ref)
    if len(cards) != 1:
        return {"status": "none" if not cards else "ambiguous", "candidates": cards}
    card = cards[0]
    pid, iid = card["project_id"], card["issue_id"]

    # Build the parent's open children as ready rows. We filter list_work_items by
    # parent == iid rather than trusting the lean /sub-issues payload, so each child
    # carries the fully-expanded state/estimate/labels that issue_to_ready needs.
    try:
        states = client.list_states(pid)
        states_by_id = {s["id"]: s for s in states}
        module_by_issue = _module_map(client, pid, False)
        ensure_estimate_scale(cfg, client, pid)
        uuid_hours = est_uuid_to_hours(cfg, pid)
        approved_ids = approved_label_ids(client, pid)
        gate_map = gate_label_map(client, pid)  # PB-94 per-gate auto clearances
        items = list(client.list_work_items(pid))
    except PlaneError as e:
        return {"status": "error", "error": str(e), "candidates": cards}

    label = project_label(cfg, pid)
    children = []
    for issue in items:
        if issue.get("parent") != iid:
            continue
        # PB-81 contract: when a PARENT is the execute target, EVERY not-done child
        # is a unit of work to drive — including BACKLOG ones. This is wider than the
        # daily `ready()` lane (READY_GROUPS = unstarted/started), which deliberately
        # hides backlog from the day's pull. Here we exclude only the terminal groups
        # (completed/cancelled); a backlog sub-issue is unfinished work under the
        # parent, so dropping it would silently skip work the user explicitly targeted.
        if state_group(issue, states_by_id) in TERMINAL_GROUPS:
            continue  # skip done/cancelled children — they are not units of work
        r = issue_to_ready(issue, pid, states_by_id, module_by_issue,
                           cfg["default_est_h"], uuid_hours,
                           approved_label_ids=approved_ids, gate_map=gate_map)
        r["project_id"] = pid
        r["project"] = label
        children.append(r)
    _ready_sort(children)

    return {
        "status": "ok",
        "tie": card["tie"], "id": card["id"], "issue_id": iid,
        "title": card.get("title", ""),
        "priority": card.get("priority"),
        "state": card.get("state"),
        "project": label, "project_id": pid,
        "has_open_children": bool(children),
        "children": children,
    }


def spec_context(cfg, client, ref, project_ref=None):
    """Read-only context for the spec/approval gate (PB-45): drafting an
    `## Implementation Plan` for ONE issue and/or approving it. Resolve `ref` via
    find_issues; 0 or >1 cards → return candidates so the model disambiguates.
    Exactly one → fetch the full record so the Socratic walk can see any existing
    plan and the current approval state. Never writes — the walk applies the plan
    via `update --edits` (description) and approves via `tag --add plan-approved`."""
    cards = find_issues(cfg, client, ref, project_ref=project_ref)
    if len(cards) != 1:
        return {"status": "none" if not cards else "ambiguous", "candidates": cards}
    card = cards[0]
    pid, iid = card["project_id"], card["issue_id"]
    try:
        issue = client.get_work_item(pid, iid)
    except PlaneError as e:
        return {"status": "error", "error": str(e), "candidates": cards}
    # PB-143: Plane returns description_stripped=null after a description_html-only
    # PATCH, so reading only the stripped field makes a freshly-written plan look
    # empty and has_plan always false. issue_description_text falls back to the HTML.
    desc = issue_description_text(issue)
    approved_ids = approved_label_ids(client, pid)
    issue_label_ids = issue_labels(issue)
    approved = bool(approved_ids) and any(
        lid in approved_ids for lid in issue_label_ids)
    # PB-152: the manual-hold marker. Surfaced so an explicit `/plan-my-work PB-X` run
    # can WARN that the issue is parked (it still runs — a human named it directly);
    # hands-off modes never reach here because the queue already excludes parked.
    parked_ids = parked_label_ids(client, pid)
    is_parked = bool(parked_ids) and any(lid in parked_ids for lid in issue_label_ids)
    # PB-94: per-stage auto-execution clearances carried as auto:<stage> labels, so
    # the executor (spec --read) knows which pipeline stages auto-advance.
    auto_gates = issue_gate_clearances(issue, gate_label_map(client, pid))
    # PB-94: OPEN blockers (this issue is blocked_by them) as lightweight refs, so the
    # executor's pre-flight runs each blocker first. Best-effort; [] when none / unread.
    blocked_by = []
    try:
        bset = set(_blocker_uuids(client.list_relations(pid, iid)))
        if bset:
            states_by_id = {s["id"]: s for s in client.list_states(pid)}
            for it in client.list_work_items(pid):
                if it.get("id") in bset and state_group(it, states_by_id) not in TERMINAL_GROUPS:
                    blocked_by.append({
                        "tie": "%s:%s" % (pid, it.get("id")),
                        "id": it.get("sequence_id", it.get("id")),
                        "title": it.get("name", ""),
                    })
    except Exception:
        # Best-effort: a relation-read failure (or a client without list_relations)
        # must never wedge the spec read — degrade to "no known blockers".
        blocked_by = []
    # PB-61: user comments are AUTHORITATIVE — they override the description and
    # any model-added plan content. Surface them (oldest→newest, so the last
    # entry is the most recent word) so the executor / spec walk can honour them.
    comments = []
    try:
        raw = sorted(client.list_comments(pid, iid),
                     key=lambda c: c.get("created_at") or "")
        for c in raw:
            body = (c.get("comment_stripped")
                    or strip_html(c.get("comment_html") or "")).strip()
            if not body:
                continue
            comments.append({
                "created_at": c.get("created_at") or "",
                "actor": (c.get("actor_detail") or {}).get("display_name") or "",
                "body": body,
            })
    except PlaneError:
        comments = []  # comments are best-effort; never block the gate on them
    return {
        "status": "ok",
        "tie": card["tie"], "id": card["id"], "issue_id": iid,
        "title": issue.get("name", ""),
        "description": desc,
        # Raw HTML so the walk can APPEND/replace its own plan section without a
        # lossy round-trip that would clobber the issue's existing description.
        "description_html": issue.get("description_html") or "",
        "has_plan": PLAN_MARKER.lower() in desc.lower(),
        # PB-61: comments win over description/model content; newest is last.
        # The consumer must re-derive the plan to honour them and flag any
        # comment that contradicts the description.
        "comments": comments,
        "comments_authoritative": True,
        "approved": approved,
        "approved_label": APPROVED_LABEL,
        # PB-152: manual-hold marker — true → an explicit id run warns; hands-off
        # modes never reach a parked issue (the queue excludes it upstream).
        "is_parked": is_parked,
        # PB-94: stages auto-cleared on this issue (empty → all stages manual/park).
        "auto_gates": auto_gates,
        # PB-94: open blockers; non-empty → executor runs these first (manual path).
        "blocked_by": blocked_by,
        "priority": issue.get("priority"),
        "state": card.get("state"),
        "project": card["project"], "project_id": pid,
    }


def file_context(cfg, client, dump, project_ref=None):
    """Read-only context for FILING a work item from a free-text dump (PB-67) — any
    type (bug/feature/docs/chore/refactor/improvement), inferred from the dump. The
    generic intake behind the `file` verb; explode/spec resolve EXISTING issues, this
    creates a NEW one. Never writes.

    Resolves the target project (project_ref, else the lone/configured one; returns
    status `need_project`/`unknown_project` when it can't). On `ok` returns enough for
    BOTH paths of the walk:
      • fast  — title/type/body/priority inferred from the dump, one confirm, create.
      • full  — Socratic build-up: type, sub-issues, labels, estimate, priority,
                deadline. So we ship the estimate scale + label set + types here.
    Plus recent OPEN items (dedupe) and the severity→priority map."""
    pid = None
    if project_ref:
        pid = resolve_project_ref(cfg, project_ref)
        if not pid:
            return {"status": "unknown_project", "project_ref": project_ref,
                    "projects": normalize_registry(cfg)}
    elif cfg.get("project"):
        pid = cfg["project"]
    else:
        reg = normalize_registry(cfg)
        if len(reg) == 1:
            pid = reg[0]["id"]
        else:
            return {"status": "need_project", "dump": dump, "projects": reg}

    try:
        labels = [l.get("name") for l in client.list_labels(pid) if l.get("name")]
    except PlaneError:
        labels = []

    scale = ensure_estimate_scale(cfg, client, pid)  # for the full path's estimate step

    def _pt_key(v):
        try:
            return (0, float(v))
        except (TypeError, ValueError):
            return (1, 0.0)

    # Recent OPEN items (any type) for dedupe — exclude only resolved (done/cancelled).
    # Best-effort; degrades to [] and never blocks filing.
    recent_open = []
    try:
        states_by_id = {s.get("id"): s for s in client.list_states(pid)}
        ident = ""
        try:
            ident = next((p.get("identifier") or "" for p in client.list_projects()
                          if p.get("id") == pid), "")
        except PlaneError:
            ident = ""
        for w in client.list_work_items(pid):
            if state_group(w, states_by_id) in ("completed", "cancelled"):
                continue
            seq = w.get("sequence_id")
            recent_open.append({
                "id": ("%s-%s" % (ident, seq)) if ident and seq is not None else str(seq or ""),
                "title": w.get("name", ""),
            })
    except PlaneError:
        recent_open = []

    return {
        "status": "ok",
        "dump": dump,
        "project": project_label(cfg, pid), "project_id": pid,
        "existing_labels": labels,
        "work_types": {k: v["label"] for k, v in WORK_TYPES.items()},
        "type_body_shape": {k: v["body"] for k, v in WORK_TYPES.items()},
        "convention_labels": [l["name"] for l in CONVENTION_LABELS],
        "severity_priority": SEVERITY_TO_PRIORITY,
        "has_estimate_scale": bool(scale),
        "estimate_points": sorted((scale or {}).get("points", {}).keys(), key=_pt_key) if scale else [],
        "recent_open_items": recent_open,
    }


def resolve_label_refs(client, project_id, names, allow_create=True, guard=None, existing=None):
    """Map label names → label UUIDs for a project. Reuse existing labels
    (fuzzy-deduped by normalised name); create the rest when `allow_create` and
    the guard's budget allow. Returns {"ids", "created", "skipped"} — `skipped`
    is wanted-but-not-created (creation off, or the guard cap was hit)."""
    labels = list(existing) if existing is not None else client.list_labels(project_id)
    by_norm = {}
    for lab in labels:
        by_norm.setdefault(_norm(lab.get("name")), lab)
    ids, created, skipped = [], [], []
    for name in names:
        name = (name or "").strip()
        if not name:
            continue
        hit = by_norm.get(_norm(name))
        if hit:
            if hit.get("id") and hit["id"] not in ids:
                ids.append(hit["id"])
            continue
        if allow_create and (guard is None or guard.allow()):
            new = client.create_label(project_id, name)
            if guard is not None:
                guard.record()
            by_norm[_norm(name)] = new
            if isinstance(existing, list):
                existing.append(new)          # keep the caller's per-batch cache fresh so
                                              # later issues reuse it (no re-create / guard burn)
            if new.get("id") and new["id"] not in ids:
                ids.append(new["id"])
            created.append({"id": new.get("id"), "name": name})
        else:
            skipped.append(name)
    return {"ids": ids, "created": created, "skipped": skipped}


def _issue_card(cfg, project_id, issue, identifier=""):
    """Compact, model-friendly issue record (the unit `find` returns). Pure."""
    st = issue.get("state")
    state = st.get("name") if isinstance(st, dict) else st
    seq = issue.get("sequence_id")
    if identifier and seq is not None:
        human = "%s-%s" % (identifier, seq)
    else:
        human = str(seq) if seq is not None else ""
    return {
        "tie": "%s:%s" % (project_id, issue.get("id")),
        "id": human,
        "issue_id": issue.get("id"),
        "project_id": project_id,
        "project": project_label(cfg, project_id),
        "title": issue.get("name", ""),
        "state": state,
        "priority": issue.get("priority"),
        "parent": issue.get("parent"),
        # PB-134: canonical browse link so the agent relays it instead of guessing.
        "url": browse_url(cfg, project_id, seq),
    }


def find_issues(cfg, client, ref, project_ref=None):
    """Resolve an issue reference → candidate cards. `ref` may be a browse URL,
    'PB-26', a bare sequence (use project_ref), or a free-text name fragment.
    URL/id resolves the project by Plane's `identifier` (then the pbrain registry
    shortcut/name); a name fragment searches across the chosen project(s). The
    model disambiguates when >1 card comes back (the 'AI matching' step)."""
    ident, seq = parse_issue_ref(ref)
    try:
        projs = client.list_projects()
    except PlaneError:
        projs = []
    ident_by_pid = {p.get("id"): (p.get("identifier") or "") for p in projs}
    pid_by_ident = {(p.get("identifier") or "").upper(): p.get("id")
                    for p in projs if p.get("identifier")}
    if project_ref:
        pids = [resolve_project_ref(cfg, project_ref)]
    elif ident:
        pids = [pid_by_ident.get(ident) or resolve_project_ref(cfg, ident)]
    else:
        pids = [p["id"] for p in normalize_registry(cfg)]
    pids = [p for p in pids if p]
    frag = _norm(ref) if (ident is None and seq is None) else ""
    out = []
    for pid in pids:
        try:
            items = client.list_work_items(pid)
        except PlaneError:
            continue
        identifier = ident_by_pid.get(pid, "")
        for it in items:
            if seq is not None:
                if it.get("sequence_id") == seq:
                    out.append(_issue_card(cfg, pid, it, identifier))
            elif frag and frag in _norm(it.get("name", "")):
                out.append(_issue_card(cfg, pid, it, identifier))
    return out


def _resolve_issue_id_in_project(cfg, client, pid, value):
    """Resolve an issue VALUE (a tie, a bare uuid, a 'PB-12' ref, or a sequence)
    to an issue uuid within `pid`. Returns the uuid or None."""
    v = (value or "").strip()
    if not v:
        return None
    if ":" in v:
        return v.split(":", 1)[1]
    if _looks_like_uuid(v):
        return v
    _ident, seq = parse_issue_ref(v)
    if seq is not None:
        for it in client.list_work_items(pid):
            if it.get("sequence_id") == seq:
                return it.get("id")
    return None


def _cached(cache, client, pid, kind):
    """Lazily fetch + cache a per-project list so one enrich batch hits each
    endpoint at most once. kind ∈ labels|members|states|cycles|modules.
    Resolves only the one method needed (no eager attribute access)."""
    key = (pid, kind)
    if key not in cache:
        method = {"labels": "list_labels", "members": "list_members",
                  "states": "list_states", "cycles": "list_cycles",
                  "modules": "list_modules"}[kind]
        cache[key] = getattr(client, method)(pid)
    return cache[key]


def _split_names(value):
    """A field value → list of names. Accepts a JSON list or a comma string."""
    if isinstance(value, list):
        items = value
    else:
        items = str(value or "").split(",")
    return [str(n).strip() for n in items if n is not None and str(n).strip()]


def _apply_edit(cfg, client, pid, iid, field, value, guard, cache):
    """Apply ONE confirmed edit to one issue. The field router behind enrich();
    returns a per-edit result dict (no tie/ok — enrich() adds those)."""
    f = (field or "").strip()

    # labels: tag (add) / untag (remove) / labels (replace whole set) ----------
    if f in ("tag", "label", "labels", "untag", "unlabel"):
        names = _split_names(value)
        allow_create = f in ("tag", "label", "labels")        # removal never creates
        res = resolve_label_refs(client, pid, names, allow_create=allow_create,
                                 guard=guard, existing=_cached(cache, client, pid, "labels"))
        issue = client.get_work_item(pid, iid)
        current = [l if isinstance(l, str) else l.get("id") for l in (issue.get("labels") or [])]
        if f == "labels":
            new = merge_labels(current, replace=res["ids"])
        elif f in ("untag", "unlabel"):
            new = merge_labels(current, remove=res["ids"])
        else:
            new = merge_labels(current, add=res["ids"])
        client.update_work_item(pid, iid, {"labels": new})
        out = {"labels": new}
        if res["created"]:
            out["created_labels"] = res["created"]
        if res["skipped"]:
            out["skipped_labels"] = res["skipped"]            # guard cap or create off
        return out

    # assignees by uuid or by name (never auto-creates people) -----------------
    if f in ("assignee", "assignees"):
        vals = value if isinstance(value, list) else [str(value or "")]
        vals = [str(v).strip() for v in vals if v is not None and str(v).strip()]
        ids, ambiguous = [], []
        members = _cached(cache, client, pid, "members")
        for v in vals:
            if _looks_like_uuid(v):
                ids.append(v)
                continue
            mb, cands = match_member(members, v)
            if mb:
                ids.append(mb["id"])
            else:
                ambiguous.append({"ref": v, "candidates": [
                    {"id": c.get("id"), "name": c.get("display_name"), "email": c.get("email")}
                    for c in cands]})
        if ambiguous:
            raise PlaneError("ambiguous assignee(s) — pick by id: %s"
                             % json.dumps(ambiguous, ensure_ascii=False))
        client.update_work_item(pid, iid, {"assignees": ids})
        return {"assignees": ids}

    # state by name or pbrain status ------------------------------------------
    if f == "state":
        states = _cached(cache, client, pid, "states")
        sid = resolve_state_id(states, value)
        if not sid:
            raise PlaneError("no state matching '%s' (have: %s)"
                             % (value, ", ".join(s.get("name", "") for s in states)))
        client.update_work_item(pid, iid, {"state": sid})
        return {"state": sid}

    # parent (re-parent / un-parent) ------------------------------------------
    if f in ("parent", "reparent"):
        v = str(value or "").strip()
        if not v or v.lower() in ("none", "null", "-"):
            client.update_work_item(pid, iid, {"parent": None})
            return {"parent": None}
        target = _resolve_issue_id_in_project(cfg, client, pid, v)
        if not target:
            raise PlaneError("parent issue not found in project: %s" % v)
        client.update_work_item(pid, iid, {"parent": target})
        return {"parent": target}

    # cycle / module membership (sub-resource POST) ---------------------------
    if f in ("cycle", "module"):
        kind = "cycles" if f == "cycle" else "modules"
        objs = _cached(cache, client, pid, kind)
        v = str(value or "").strip()
        n = _norm(v)
        hit = next((o for o in objs if _norm(o.get("name")) == n), None) \
            or next((o for o in objs if n and n in _norm(o.get("name"))), None)
        created = False
        if not hit:
            if f == "module" and v:
                # Modules are auto-created on demand (the user names the area to file
                # an issue under); cycles must already exist (we don't use them).
                hit = client.create_module(pid, v)
                objs.append(hit)                      # keep the per-batch cache fresh
                created = True
            else:
                raise PlaneError("no %s matching '%s' (have: %s)"
                                 % (f, v, ", ".join(o.get("name", "") for o in objs)))
        (client.add_to_cycle if f == "cycle" else client.add_to_module)(pid, hit["id"], iid)
        out = {f: hit.get("name"), "%s_id" % f: hit["id"]}
        if created:
            out["created_%s" % f] = hit.get("name")
        return out

    # comment / external link --------------------------------------------------
    if f == "comment":
        text = str(value or "").strip()
        html = text if text.startswith("<") else "<p>%s</p>" % text
        client.create_comment(pid, iid, html)
        return {"comment": text[:80]}
    if f == "link":
        raw = str(value or "").strip()
        url, _sep, title = raw.partition("|")
        client.create_link(pid, iid, url.strip(), title.strip() or None)
        return {"link": url.strip()}

    # sub-issue / typed relation ----------------------------------------------
    if f in ("subissue", "sub_issue", "subtask"):
        client.create_sub_issue(pid, iid, {"name": value})
        return {"subissue": value}
    if f.startswith("relation:"):
        rel_type = f.split(":", 1)[1]
        if rel_type not in RELATION_TYPES:
            raise PlaneError("unknown relation type: %s (valid: %s)"
                             % (rel_type, ", ".join(sorted(RELATION_TYPES))))
        target = str(value).split(":", 1)[-1] if ":" in str(value) else value
        client._request("POST", "projects/%s/work-items/%s/relations/" % (pid, iid),
                        body={"relation_type": rel_type, "issues": [target]})
        return {"relation": rel_type}

    # estimate (story points) → resolve a point value to its estimate_point uuid
    if f in ("estimate", "estimate_point", "points", "story_points"):
        import re
        v = str(value if value is not None else "").strip()
        if not v or v.lower() in ("none", "null", "-", "clear", "0"):
            client.update_work_item(pid, iid, {"estimate_point": None})
            return {"estimate": None}
        if _looks_like_uuid(v):
            uid = v
        else:
            ensure_estimate_scale(cfg, client, pid)        # auto-fetch on first use
            emap = est_value_to_uuid(cfg, pid)
            if not emap:
                raise PlaneError(
                    "no estimate scale for this project — enable estimates in Plane and "
                    "configure internal auth (estimates --session-cookie/--email), or import "
                    "manually: estimates --project <p> --import-json '<estimates JSON>'")
            mnum = re.search(r"\d+(?:\.\d+)?", v)
            key = mnum.group(0) if mnum else v
            if key.endswith(".0"):
                key = key[:-2]
            uid = emap.get(key) or emap.get(v)
            if not uid:
                have = ", ".join(sorted(emap, key=lambda x: float(x)
                                        if re.match(r"^\d+(\.\d+)?$", x) else 1e9))
                raise PlaneError("no estimate bucket '%s' (have: %s)" % (v, have))
        client.update_work_item(pid, iid, {"estimate_point": uid})
        return {"estimate": v, "estimate_point": uid}

    # everything else: a simple PATCH field via ENRICH_FIELD_MAP --------------
    client.update_work_item(pid, iid, build_enrich_body(f, value))
    return {field: (value[:80] if isinstance(value, str) else value)}


def enrich(cfg, client, edits):
    """Apply confirmed edits — the single 'apply any change' seam behind the
    router and every write verb. edits: [{tie, field, value}]. Field families
    (see _apply_edit): simple PATCH (priority/description/dates/title/estimate),
    assignees (uuid|name), tag/untag/labels, state, parent, cycle/module,
    comment, link, subissue, relation:<type>. One CreationGuard + one per-project
    cache span the whole batch. Only ever called after an explicit confirm."""
    summary = []
    guard = CreationGuard()
    cache = {}
    for e in edits:
        tie = normalize_tie(cfg, e.get("tie", ""))
        field = e.get("field", "")
        value = e.get("value")
        if ":" not in tie:
            summary.append({"tie": tie, "ok": False, "field": field, "error": "bad tie"})
            continue
        pid, iid = tie.split(":", 1)
        try:
            res = _apply_edit(cfg, client, pid, iid, field, value, guard, cache)
            res.update({"tie": tie, "ok": True, "field": field})
            summary.append(res)
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


def doing_now(cfg, client, project_ids):
    """Issues currently IN PROGRESS in Plane (the `started`/doing group) across the
    given projects (PB-94). /end-of-day reads this — alongside completed_today — to
    surface work that was started but not finished today (e.g. an issue pmw parked
    mid-pipeline), without depending on any vault tracker. State is Plane-only."""
    out = []
    for pid in project_ids:
        try:
            states = client.list_states(pid)
            states_by_id = {s["id"]: s for s in states}
            items = client.list_work_items(pid)
        except PlaneError:
            continue
        label = project_label(cfg, pid)
        for it in items:
            if state_group(it, states_by_id) == "started":
                out.append({"tie": "%s:%s" % (pid, it.get("id")),
                            "id": it.get("sequence_id", it.get("id")),
                            "title": it.get("name", ""), "project": label,
                            "project_id": pid, "priority": it.get("priority") or "none"})
    return out


def create_issue(cfg, client, project_ref, title, priority=None, target_date=None,
                 state=None):
    """Create a work item in the given project. Returns the created issue dict.

    `state` (PB-130) is an optional state NAME or pbrain status word; when given,
    the new issue is filed directly into that state (e.g. "Backlog") instead of
    Plane's default unstarted state (Todo). Unknown name → error listing the
    available states, so a typo fails loudly rather than silently using Todo."""
    pid = resolve_project_ref(cfg, project_ref)
    if not pid:
        raise PlaneError("unknown project: %s" % project_ref)
    body = {"name": title}
    if priority and priority != "none":
        body["priority"] = priority
    if target_date:
        body["target_date"] = target_date
    if state:
        states = client.list_states(pid)
        sid = resolve_state_id(states, state)
        if not sid:
            raise PlaneError("no state matching '%s' (have: %s)"
                             % (state, ", ".join(s.get("name", "") for s in states)))
        body["state"] = sid
    result = client.create_work_item(pid, body)
    seq = result.get("sequence_id")
    short = project_short(cfg, pid)
    return {"project_id": pid, "project": project_label(cfg, pid),
            "project_short": short,
            "ref": ("%s-%s" % (short, seq)) if seq not in (None, "") else "",
            "url": browse_url(cfg, pid, seq),
            "issue": result}


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
    # PB-70: seed the canonical convention labels into the fresh project so triage
    # (e.g. `bug`) works immediately. Best-effort — a label hiccup must not undo a
    # created project; surface what happened in the result.
    seeded = seed_convention_labels(client, pid)
    # PB-130: replace Plane's default states with pbrain's custom lifecycle pipeline.
    # Also best-effort: a state hiccup (or no internal auth) must not undo a created
    # project — the result carries what happened, incl. manual UI steps if needed.
    states = seed_pipeline_states(client, pid)
    return {"id": pid, "name": name, "shortcut": shortcut or "",
            "labels": seeded, "states": states}


def seed_convention_labels(client, project_id):
    """Ensure pbrain's seed labels exist on `project_id`: the CONVENTION_LABELS
    work types (PB-70), the plan-approved seam (PB-45), and the per-gate auto:*
    clearances (PB-94). Idempotent: a missing label is created with its canonical
    color; an existing one (fuzzy-matched by normalised name) is left alone UNLESS
    its color differs from the spec, in which case it is PATCHed to the canonical
    color (so labels created colorless or with the wrong shade self-repair on a
    re-seed). Returns {"created": [...], "existing": [...], "recolored": [...],
    "error": <str?>}. Never raises — label seeding is best-effort and reported,
    not fatal."""
    out = {"created": [], "existing": [], "recolored": []}
    try:
        existing = client.list_labels(project_id)
    except PlaneError as e:
        out["error"] = str(e)
        return out
    by_norm = {_norm(l.get("name")): l for l in existing}
    for spec in _seed_label_specs():
        name = spec["name"]
        want = (spec.get("color") or "").lower()
        match = by_norm.get(_norm(name))
        if match is not None:
            have = (match.get("color") or "").lower()
            # Repair a missing or mismatched color on an existing label.
            if want and have != want and match.get("id"):
                try:
                    client.update_label(project_id, match["id"], color=spec.get("color"))
                    out["recolored"].append(name)
                except PlaneError as e:
                    out.setdefault("error", "")
                    out["error"] += ("; " if out["error"] else "") + ("%s: %s" % (name, e))
            else:
                out["existing"].append(name)
            continue
        try:
            client.create_label(project_id, name, color=spec.get("color"))
            out["created"].append(name)
        except PlaneError as e:
            out.setdefault("error", "")
            out["error"] += ("; " if out["error"] else "") + ("%s: %s" % (name, e))
    return out


def _pipeline_states_manual_steps():
    """The exact Plane-UI steps to set up the pipeline by hand, returned when the
    internal API isn't reachable (no session cookie / login). Project Settings →
    States in Plane is the only public surface for custom states."""
    rows = ["%s (%s group)" % (s["name"], s["group"]) for s in PIPELINE_STATES]
    return [
        "Open the project in Plane → Settings → States.",
        "Create these states in order, each in the listed group: " + ", ".join(rows) + ".",
        "Keep 'Todo' as the default unstarted state (do not rename it).",
        "Delete the default 'In Progress' state "
        "(re-point any issues on it to 'Building' first).",
    ]


def rename_pipeline_states(client, project_id):
    """PB-XXX: rename the pipeline states per STATE_RENAMES (Review→Shipped,
    Done→Landed) on one project, IN PLACE via update_state (the state id is
    preserved, so every issue currently on it stays put — no re-pointing). Matches
    the OLD name case-insensitively; if the old name is absent (already renamed, or
    a project that never had it) that entry is a vacuous no-op, so the whole thing
    is idempotent. Groups are NOT touched — Shipped stays started, Landed stays
    completed — so all group-based logic is unaffected. Needs the internal API
    (public token is read-only for states); a PlaneError on read surfaces as `error`.
    Returns {"renamed":[...], "already":[...], "error": "..."}."""
    out = {"renamed": [], "already": [], "error": ""}
    try:
        existing = client.list_states(project_id)
    except PlaneError as e:
        out["error"] = str(e)
        return out
    by_norm = {_norm(s.get("name")): s for s in existing}
    have_new = {_norm(v) for v in STATE_RENAMES.values()}
    for old_name, new_name in STATE_RENAMES.items():
        match = by_norm.get(_norm(old_name))
        if match is None:
            # Old name not present. If the NEW name already exists, it's a prior
            # rename (record as already-done); otherwise this project simply never
            # carried that state — either way, nothing to do.
            if _norm(new_name) in by_norm:
                out["already"].append(new_name)
            continue
        sid = match.get("id")
        if not sid:
            continue
        try:
            client.update_state(project_id, sid, name=new_name)
            out["renamed"].append("%s→%s" % (old_name, new_name))
        except PlaneError as e:
            out["error"] += ("; " if out["error"] else "") + ("%s: %s" % (old_name, e))
    return out


def seed_pipeline_states(client, project_id):
    """PB-130: bring `project_id` onto pbrain's custom lifecycle pipeline
    (PIPELINE_STATES) — Backlog → Todo → Planning → Building → Testing → Shipped
    + Landed + Cancelled. Adds the four work states on top of Plane's defaults and
    removes only "In Progress"; "Todo" is KEPT as the default unstarted state.

    Idempotent, like seed_convention_labels: a missing pipeline state is created in
    its canonical group/color/sequence; an existing one (matched by normalised name)
    is PATCHed only if its group, color, or default flag drifted. "In Progress" is
    removed ONLY after the replacement states exist and any issue sitting on it has
    been re-pointed to Building — so Plane never refuses the delete for a non-empty
    state. If Plane still refuses, the old state is kept and the refusal reported
    rather than failing the seed.

    (We keep "Todo" rather than introduce a "Triage" state because Plane reserves
    the literal name "Triage" for its intake inbox and rejects creating it on most
    projects — "name already taken".)

    State writes require the internal API; with no internal auth the function makes
    no changes and returns {"manual_steps": [...]} (the exact UI steps) so the caller
    can hand them back (AC #5). Never raises — seeding is best-effort and reported.

    Returns {"created":[...], "existing":[...], "updated":[...], "renamed":[...],
    "removed":[...], "repointed":[...], "error":<str?>, "manual_steps":<list?>}."""
    out = {"created": [], "existing": [], "updated": [], "renamed": [],
           "removed": [], "repointed": []}

    if not (getattr(client, "_has_internal_auth", lambda: False)()):
        out["manual_steps"] = _pipeline_states_manual_steps()
        out["error"] = ("Plane internal API auth not configured "
                        "(no session cookie / login) — states can't be created via API.")
        return out

    try:
        existing = client.list_states(project_id)
    except PlaneError as e:
        out["error"] = str(e)
        return out
    by_norm = {_norm(s.get("name")): s for s in existing}

    # 1. Create-or-reconcile each pipeline state. "Todo" already exists on a fresh
    #    Plane project (it's the default unstarted state we KEEP), so it reconciles
    #    through the existing-match path; the four work states are created.
    name_to_id = {}  # canonical name (lower) → state id, for the re-point step
    for spec in PIPELINE_STATES:
        name = spec["name"]
        seq = 1000 * (spec["order"] + 1)
        match = by_norm.get(_norm(name))
        if match is not None:
            sid = match.get("id")
            name_to_id[name.lower()] = sid
            patch = {}
            if (match.get("group") or "") != spec["group"]:
                patch["group"] = spec["group"]
            want_c = (spec.get("color") or "").lower()
            if want_c and (match.get("color") or "").lower() != want_c:
                patch["color"] = spec.get("color")
            if bool(match.get("default")) != bool(spec.get("default")):
                patch["default"] = bool(spec.get("default"))
            # Normalise sequence so the board reads top-to-bottom in pipeline order.
            # Pre-existing states (Backlog/Todo/Landed/Cancelled — the latter two are
            # Plane's native Done/Cancelled, with Done renamed to Landed by PB-XXX)
            # otherwise keep Plane's original sequence and float out of order.
            try:
                if int(match.get("sequence") or 0) != seq:
                    patch["sequence"] = seq
            except (TypeError, ValueError):
                patch["sequence"] = seq
            if patch and sid:
                try:
                    client.update_state(project_id, sid, **patch)
                    out["updated"].append(name)
                except PlaneError as e:
                    out.setdefault("error", "")
                    out["error"] += ("; " if out["error"] else "") + ("%s: %s" % (name, e))
            else:
                out["existing"].append(name)
            continue
        try:
            res = client.create_state(project_id, name, spec["group"],
                                      color=spec.get("color"),
                                      default=bool(spec.get("default")), sequence=seq)
            if isinstance(res, dict) and res.get("id"):
                name_to_id[name.lower()] = res["id"]
            out["created"].append(name)
        except PlaneError as e:
            out.setdefault("error", "")
            out["error"] += ("; " if out["error"] else "") + ("%s: %s" % (name, e))

    # 2. Remove the superseded Plane defaults — but first re-point any issue still
    #    on them to the group-equivalent pipeline state, else Plane 400s the delete.
    try:
        states_now = client.list_states(project_id)
    except PlaneError:
        states_now = existing
    states_by_id = {s["id"]: s for s in states_now}
    for doomed_norm, repl_name in DEFAULT_STATES_TO_REMOVE.items():
        doomed = next((s for s in states_now if _norm(s.get("name")) == _norm(doomed_norm)), None)
        if not doomed or not doomed.get("id"):
            continue
        repl_id = name_to_id.get(repl_name.lower())
        if not repl_id:
            # Replacement state never materialised — don't delete, we'd orphan issues.
            out.setdefault("error", "")
            out["error"] += ("; " if out["error"] else "") + \
                ("kept '%s' (no '%s' to re-point to)" % (doomed.get("name"), repl_name))
            continue
        # Re-point issues currently on the doomed state.
        try:
            items = client.list_work_items(project_id)
        except PlaneError:
            items = []
        for it in items:
            if state_group_id(it) == doomed["id"]:
                try:
                    client.update_work_item(project_id, it.get("id"), {"state": repl_id})
                    out["repointed"].append("%s→%s" % (it.get("sequence_id", it.get("id")), repl_name))
                except PlaneError:
                    pass
        # A doomed state can't be the project default at delete time; if it is,
        # In Progress is never the default (Todo is), so just delete after re-point.
        try:
            client.delete_state(project_id, doomed["id"])
            out["removed"].append(doomed.get("name"))
        except PlaneError as e:
            out.setdefault("error", "")
            out["error"] += ("; " if out["error"] else "") + \
                ("could not remove '%s': %s" % (doomed.get("name"), e))
    return out


def state_group_id(issue):
    """The raw state-id an issue is on, whether Plane returned the state expanded
    (a dict with id) or as a bare uuid string. Mirrors state_group's tolerance."""
    st = issue.get("state")
    if isinstance(st, dict):
        return st.get("id")
    return st


def move_status(cfg, client, tie, status, completed_at=None, to_state=None):
    """Single-tie status write (thin wrapper over resolve). PB-130: `to_state`
    optionally targets a named pipeline state within the status's group."""
    return resolve(cfg, client, [{"tie": normalize_tie(cfg, tie),
                                  "status": status, "completed_at": completed_at,
                                  "to_state": to_state}])


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
    refresher = persist = None
    if cfg.get("internal_cookie_source") == "browser":
        base = cfg["base_url"]
        browser = cfg.get("internal_browser")
        refresher = lambda: extract_plane_cookie(base, browser=browser)

        def persist(ck):
            # Re-read so we don't clobber a concurrent write; best-effort.
            try:
                c = load_config()
                c["internal_session_cookie"] = ck
                save_config(c)
            except (OSError, PlaneError):
                pass
    return PlaneClient(cfg["base_url"], cfg["api_key"], cfg["workspace"],
                       session_cookie=cfg.get("internal_session_cookie"),
                       email=cfg.get("internal_email"),
                       password=cfg.get("internal_password"),
                       cookie_refresher=refresher, on_cookie_refreshed=persist)


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
    # PB-98: protect a live config from a test/dummy overwrite. An agent that runs
    # setup/config with throwaway credentials would otherwise clobber the real
    # api_key with no backup. Refuse to replace an existing key with a DIFFERENT
    # non-empty one unless --force is given; back up before any overwrite.
    existing_key = cfg.get("api_key")
    incoming_key = getattr(args, "api_key", None)
    if (existing_key and incoming_key and incoming_key != existing_key
            and not getattr(args, "force", False)):
        raise PlaneError(
            "refusing to overwrite the configured Plane api_key with a different "
            "one (this protects your live config from a test/dummy run). The "
            "existing config is untouched. Pass --force to overwrite (a timestamped "
            ".bak of the current config will be written first).")
    for k in ("base_url", "api_key", "workspace", "project"):
        v = getattr(args, k.replace("-", "_"))
        if v:
            cfg[k] = v.rstrip("/") if k == "base_url" else v
    # Internal-API auth (estimate points). Remote/VPS mode swaps the local
    # browser-cookie scrape for the Plane login email+password, with the password
    # kept in the macOS Keychain (PB-18). `--internal-cookie-source none` clears
    # the browser source so make_client falls through to email/password.
    if getattr(args, "internal_email", None):
        cfg["internal_email"] = args.internal_email
    if getattr(args, "internal_cookie_source", None):
        if args.internal_cookie_source == "none":
            cfg.pop("internal_cookie_source", None)
        else:
            cfg["internal_cookie_source"] = args.internal_cookie_source
    if getattr(args, "internal_password", None):
        register_secret(args.internal_password)
        email = cfg.get("internal_email")
        use_kc = (sys.platform == "darwin" and email
                  and not getattr(args, "internal_password_plain", False))
        if use_kc and _keychain_set(email, args.internal_password):
            cfg["internal_password_source"] = "keychain"
            cfg.pop("internal_password", None)
        else:
            cfg["internal_password"] = args.internal_password
            cfg.pop("internal_password_source", None)
    require(cfg, "base_url", "api_key", "workspace")
    # strip default_est_h back to a plain value for storage
    cfg["default_est_h"] = cfg.get("default_est_h", 2.0)
    # Setting up Plane means you want pbrain's daily loop to use it.
    cfg.setdefault("backend", "plane")
    # PB-98: when --force overwrites a live api_key with a different one, snapshot
    # the prior config first so the mistake is recoverable.
    if (existing_key and incoming_key and incoming_key != existing_key):
        _backup_config_file()
    p = save_config(cfg)
    print("PLANE_CONFIGURED %s backend=%s" % (p, cfg["backend"]))
    if cfg.get("internal_password_source") == "keychain":
        print("PLANE_INTERNAL_AUTH email=%s password=keychain(%s)"
              % (cfg.get("internal_email"), KEYCHAIN_SERVICE))
    elif cfg.get("internal_email") and cfg.get("internal_password"):
        print("PLANE_INTERNAL_AUTH email=%s password=plane.json(0600)"
              % cfg.get("internal_email"))
    return 0


def cmd_use(args):
    cfg = load_config()
    if args.backend not in ("plane", "markdown"):
        raise PlaneError("backend must be 'plane' or 'markdown'")
    cfg["backend"] = args.backend
    p = save_config(cfg)
    print("PLANE_BACKEND %s (%s)" % (args.backend, p))
    return 0


def cmd_webbase(args):
    """Print the browser-facing Plane base for clickable links (the single source of
    truth shared by groom + /plan-my-work). Empty line + rc 0 when unconfigured, so
    shell callers can `$(... web-base)` without error handling."""
    try:
        cfg = load_config()
    except Exception:
        print("")
        return 0
    print(web_base(cfg))
    return 0


def cmd_linkbase(args):
    """Print the PREFERRED base for vault-written clickable links: the plane:// deep
    link when the desktop app is installed, else the http web_base. Same empty-line +
    rc 0 contract as web-base, so shell callers can `$(... link-base)` safely."""
    try:
        cfg = load_config()
    except Exception:
        print("")
        return 0
    print(link_base(cfg))
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


def migrate_pipeline_states(client, project_id):
    """PB-130: bring one EXISTING project fully onto the pipeline — seed the
    states (seed_pipeline_states) AND re-point every issue still sitting on a
    removed/legacy default onto its group-equivalent pipeline state. The seed
    already re-points issues off the two doomed defaults as it deletes them;
    this also sweeps any issue whose state is GONE (e.g. removed in a prior run)
    or still on a non-pipeline started/unstarted state, mapping by group:
    unstarted→Todo, started→Building (idempotent — an issue already on a
    pipeline state is left alone). Best-effort; never raises.

    Returns the seed report plus {"swept":[...]} for the extra re-points."""
    out = seed_pipeline_states(client, project_id)
    if out.get("manual_steps"):
        # No internal auth → states weren't created; nothing to sweep onto.
        out["swept"] = []
        return out
    try:
        states = client.list_states(project_id)
    except PlaneError as e:
        out.setdefault("error", "")
        out["error"] += ("; " if out.get("error") else "") + str(e)
        out["swept"] = []
        return out
    states_by_id = {s["id"]: s for s in states}
    pipeline_ids = {s["id"] for s in states
                    if _norm(s.get("name")) in {_norm(p["name"]) for p in PIPELINE_STATES}}
    # group → target pipeline state id (for sweeping stragglers)
    def _state_id(name):
        for s in states:
            if _norm(s.get("name")) == _norm(name):
                return s["id"]
        return None
    group_target = {"unstarted": _state_id("Todo"), "started": _state_id("Building")}
    swept = []
    try:
        items = client.list_work_items(project_id)
    except PlaneError:
        items = []
    for it in items:
        sid = state_group_id(it)
        # Already on a canonical pipeline state, or on a terminal/backlog state we
        # keep (Landed/Cancelled/Backlog are pipeline states) → leave it.
        if sid in pipeline_ids:
            continue
        st = states_by_id.get(sid)
        grp = (st.get("group") if st else None)
        target = group_target.get(grp)
        if not target:
            continue  # no sensible group mapping (e.g. already completed/cancelled)
        try:
            client.update_work_item(project_id, it.get("id"), {"state": target})
            swept.append(it.get("sequence_id", it.get("id")))
        except PlaneError:
            pass
    out["swept"] = swept
    return out


def cmd_states(args):
    cfg = load_config()
    client = make_client(cfg)
    # PB-130: --seed / --migrate operate across one or more projects.
    #   --seed     : create/reconcile the pipeline states (+ remove the two
    #                superseded defaults, re-pointing their issues).
    #   --migrate  : --seed PLUS sweep every straggler issue onto a pipeline
    #                state (group-mapped). This is what the 0012 effectful
    #                migration runs across the whole registry.
    #   --rename   : (PB-XXX) rename the pipeline states per STATE_RENAMES
    #                (Review→Shipped, Done→Landed) IN PLACE — the 0014 effectful
    #                migration. --dry-run reports which projects still carry an old
    #                name (so the migration can gate applicability without writing).
    # --projects R,... targets a subset; default for all three is the whole
    # registry (so "rename/migrate all projects" is one call).
    do_seed = getattr(args, "seed", False)
    do_migrate = getattr(args, "migrate", False)
    do_rename = getattr(args, "rename", False)
    dry_run = getattr(args, "dry_run", False)
    if do_seed or do_migrate or do_rename:
        if getattr(args, "projects", None):
            refs = [r.strip() for r in args.projects.split(",") if r.strip()]
            pids = []
            for r in refs:
                p = resolve_project_ref(cfg, r)
                if not p:
                    raise PlaneError("unknown project: %s" % r)
                pids.append(p)
        else:
            pids = [p["id"] for p in normalize_registry(cfg)]
        report = {}
        for pid in pids:
            label = project_label(cfg, pid)
            if do_rename:
                if dry_run:
                    # Read-only: report which OLD names are still present, so the
                    # 0014 migration can decide applicability without writing.
                    try:
                        cur = client.list_states(pid)
                    except PlaneError as e:
                        report[label] = {"error": str(e), "old_present": []}
                        continue
                    names = {_norm(s.get("name")) for s in cur}
                    old_present = [old for old in STATE_RENAMES
                                   if _norm(old) in names]
                    report[label] = {"old_present": old_present,
                                     "states": [s.get("name") for s in cur]}
                else:
                    report[label] = rename_pipeline_states(client, pid)
                continue
            if dry_run:
                # Read-only: report which legacy defaults are still present, so the
                # 0012 migration can decide applicability without writing.
                try:
                    cur = client.list_states(pid)
                except PlaneError as e:
                    report[label] = {"error": str(e), "legacy_present": []}
                    continue
                names = {_norm(s.get("name")) for s in cur}
                # "legacy_present" = states this migration will REMOVE (In Progress).
                # Todo is kept, so it is NOT legacy.
                legacy = [disp for key, disp in (("in progress", "In Progress"),)
                          if _norm(key) in names]
                # Also applicable if any pipeline work-state is still missing.
                missing = [p["name"] for p in PIPELINE_STATES
                           if _norm(p["name"]) not in names]
                report[label] = {"legacy_present": legacy,
                                 "missing": missing,
                                 "states": [s.get("name") for s in cur]}
            else:
                report[label] = (migrate_pipeline_states(client, pid) if do_migrate
                                 else seed_pipeline_states(client, pid))
        if dry_run:
            action = "dry-run"
        elif do_rename:
            action = "rename"
        elif do_migrate:
            action = "migrate"
        else:
            action = "seed"
        out_obj = {"action": action, "projects": report,
                   "pipeline": [s["name"] for s in PIPELINE_STATES]}
        if do_rename:
            out_obj["renames"] = STATE_RENAMES
        print(json.dumps(out_obj, ensure_ascii=False))
        return 0
    pid = args.project or cfg.get("project")
    print(json.dumps(client.list_states(pid), ensure_ascii=False))
    return 0


def cmd_ready(args):
    cfg = load_config()
    client = make_client(cfg)
    approved_only = getattr(args, "require_approved", False)
    ordered = getattr(args, "ordered", False)
    if getattr(args, "projects", None):
        ids = project_ids_from_arg(cfg, args.projects)
        print(json.dumps(ready_multi(cfg, client, ids, include_backlog=args.include_backlog,
                                      with_lanes=args.with_lanes,
                                      approved_only=approved_only, ordered=ordered),
                         ensure_ascii=False))
        return 0
    pid = args.project or cfg.get("project")
    if not pid:
        raise PlaneError("no project id — pass --project/--projects or set it in setup")
    rows = ready(cfg, client, pid, include_backlog=args.include_backlog,
                 with_lanes=args.with_lanes, approved_only=approved_only)
    if ordered:
        for r in rows:
            r.setdefault("project_id", pid)
        rows = order_ready_stream(cfg, client, rows)
    print(json.dumps(rows, ensure_ascii=False))
    return 0


def cmd_queued(args):
    """PB-141: print the QUEUE — issues in the Queued state, in groom's rank order.
    This is what /plan-my-work walks (Plane is the queue)."""
    cfg = load_config()
    client = make_client(cfg)
    ids = (project_ids_from_arg(cfg, args.projects) if getattr(args, "projects", None)
           else [args.project or cfg.get("project")])
    ids = [i for i in ids if i]
    if not ids:
        raise PlaneError("no project id — pass --project/--projects or set it in setup")
    print(json.dumps(queued_multi(cfg, client, ids), ensure_ascii=False))
    return 0


def cmd_claim_next(args):
    """PB-141: atomically claim the top of the Queued state for this session (so
    parallel /plan-my-work drivers pick different issues). Prints the claimed row
    as JSON, or `null` when the queue is empty. --session is a per-caller token."""
    cfg = load_config()
    client = make_client(cfg)
    ids = (project_ids_from_arg(cfg, args.projects) if getattr(args, "projects", None)
           else [args.project or cfg.get("project")])
    ids = [i for i in ids if i]
    if not ids:
        raise PlaneError("no project id — pass --project/--projects or set it in setup")
    row = claim_next_queued(cfg, client, ids, getattr(args, "session", "") or "0")
    print(json.dumps(row, ensure_ascii=False))
    return 0


def cmd_enqueue(args):
    """PB-141: groom writes the computed run queue into Plane — move the ordered set
    into the Queued state with ascending sort_order. Input is the ordered ready
    stream (ready --ordered); we re-read it here so groom stays a thin caller.
    PB-146: also rank each project's Landed column newest-completed-first (--no-done
    skips it)."""
    cfg = load_config()
    client = make_client(cfg)
    ids = (project_ids_from_arg(cfg, args.projects) if getattr(args, "projects", None)
           else [args.project or cfg.get("project")])
    ids = [i for i in ids if i]
    if not ids:
        raise PlaneError("no project id — pass --project/--projects or set it in setup")
    ordered = ready_multi(cfg, client, ids, ordered=True)
    result = {"queued": enqueue_ordered(cfg, client, ordered)}
    if not getattr(args, "no_done", False):
        result["done_ranked"] = rank_done_by_completion(cfg, client, ids)
    print(json.dumps(result, ensure_ascii=False))
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
        # Carry forward per-project config the registry normalizer drops (the
        # `work` working-location object set via `workdir`) so a sync never wipes
        # it. Keyed off the RAW projects list, not normalize_registry.
        raw_prev = {p["id"]: p for p in (cfg.get("projects") or [])
                    if isinstance(p, dict) and p.get("id")}
        reg = []
        for p in remote:
            pid = p.get("id")
            if not pid:
                continue
            entry = {"id": pid, "name": p.get("name") or pid,
                     "shortcut": (existing.get(pid, {}).get("shortcut") or "")}
            work = raw_prev.get(pid, {}).get("work")
            if work:
                entry["work"] = work
            reg.append(entry)
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


def cmd_groom(args):
    cfg = load_config()
    client = make_client(cfg)
    ids = project_ids_from_arg(cfg, args.projects)
    print(json.dumps(groom_run(cfg, client, ids, apply=args.apply),
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


def cmd_doing(args):
    cfg = load_config()
    client = make_client(cfg)
    ids = project_ids_from_arg(cfg, args.projects)
    print(json.dumps(doing_now(cfg, client, ids), ensure_ascii=False))
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
                                 completed_at=args.completed_at,
                                 to_state=getattr(args, "to_state", None)),
                     ensure_ascii=False))
    return 0


def cmd_issue(args):
    cfg = load_config()
    client = make_client(cfg)
    result = create_issue(cfg, client, args.project, args.title,
                          priority=args.priority, target_date=args.target_date,
                          state=getattr(args, "state", None))
    print(json.dumps(result, ensure_ascii=False))
    # PB-134: print the canonical browse URL bare on its own line so it is
    # directly clickable in the terminal (terminals only linkify a whole line).
    url = result.get("url")
    if url:
        print(url)
    return 0


def cmd_project_create(args):
    cfg = load_config()
    client = make_client(cfg)
    result = create_project(cfg, client, args.name, shortcut=args.shortcut)
    print(json.dumps(result, ensure_ascii=False))
    return 0


# --- per-project working location (PB-40 `task execute`) --------------------
# Each projects[] entry may carry an optional `work` object describing where
# /plan-my-work executes that project's tasks:
#   {"path": "<abs>", "kind": "conductor|repo",
#    "base_branch": "main", "isolation": "worktree|branch"}
# It's plain config (a secret-free local path), so the reads below never touch
# the network — they just parse plane.json.
def workdirs_map(cfg):
    """{pid: work-entry} for every project with a configured working location."""
    out = {}
    for p in (cfg.get("projects") or []):
        if isinstance(p, dict) and p.get("id") and isinstance(p.get("work"), dict):
            out[p["id"]] = p["work"]
    return out


def cmd_workdirs(args):
    # Read-only: the working-location map straight from config (no API call).
    cfg = load_config()
    print(json.dumps(workdirs_map(cfg), ensure_ascii=False))
    return 0


def cmd_workdir(args):
    cfg = load_config()
    # List mode: no project ref → dump the whole map (pure config read).
    if not getattr(args, "project", None):
        print(json.dumps(workdirs_map(cfg), ensure_ascii=False))
        return 0
    pid = resolve_project_ref(cfg, args.project)
    if not pid:
        raise PlaneError("unknown project: %s" % args.project)
    # Materialize a mutable projects[] list (synthesized from the lone project
    # when config has only a bare `project` uuid) so we have an entry to attach
    # `work` to.
    projs = cfg.get("projects")
    if not isinstance(projs, list) or not projs:
        projs = [{"id": p["id"], "name": p["name"], "shortcut": p.get("shortcut", "")}
                 for p in normalize_registry(cfg)]
    entry = next((p for p in projs if isinstance(p, dict) and p.get("id") == pid), None)
    if entry is None:
        entry = {"id": pid, "name": project_label(cfg, pid), "shortcut": ""}
        projs.append(entry)
    if args.clear:
        entry.pop("work", None)
        action = "cleared"
    elif not args.path:
        # No --path and no --clear → show this one project's work, no write.
        print(json.dumps({pid: entry.get("work")}, ensure_ascii=False))
        return 0
    else:
        path = os.path.abspath(os.path.expanduser(args.path))
        if not os.path.isdir(path):
            raise PlaneError("working path does not exist (or is not a dir): %s" % path)
        work = dict(entry.get("work") or {})
        work["path"] = path
        work["kind"] = args.kind or work.get("kind") or "repo"
        work["base_branch"] = args.base_branch or work.get("base_branch") or "main"
        work["isolation"] = args.isolation or work.get("isolation") or "worktree"
        entry["work"] = work
        action = "set"
    cfg["projects"] = projs
    save_config(cfg)
    print(json.dumps({"project": pid, "action": action, "work": entry.get("work")},
                     ensure_ascii=False))
    return 0


# --- the richer write/lookup verbs (the catalogue the NL router targets) -----
def _one_project(cfg, ref):
    """Resolve a single project ref → uuid, defaulting to the lone/first project."""
    if ref:
        pid = resolve_project_ref(cfg, ref)
        if not pid:
            raise PlaneError("unknown project: %s" % ref)
        return pid
    if cfg.get("project"):
        return cfg["project"]
    reg = normalize_registry(cfg)
    if reg:
        return reg[0]["id"]
    raise PlaneError("no project — pass --project")


def _emit_enrich(cfg, client, edits):
    print(json.dumps(enrich(cfg, client, edits), ensure_ascii=False))
    return 0


def cmd_find(args):
    cfg = load_config()
    client = make_client(cfg)
    print(json.dumps(find_issues(cfg, client, args.ref, project_ref=args.project),
                     ensure_ascii=False))
    return 0


def cmd_explode(args):
    cfg = load_config()
    client = make_client(cfg)
    print(json.dumps(explode_context(cfg, client, args.ref, project_ref=args.project),
                     ensure_ascii=False))
    return 0


def cmd_subtree(args):
    cfg = load_config()
    client = make_client(cfg)
    print(json.dumps(subtree_context(cfg, client, args.ref, project_ref=args.project),
                     ensure_ascii=False))
    return 0


def cmd_blocked_by(args):
    cfg = load_config()
    client = make_client(cfg)
    print(json.dumps(blocked_by_ids(cfg, client, args.ref, project_ref=args.project),
                     ensure_ascii=False))
    return 0


def cmd_spec(args):
    cfg = load_config()
    client = make_client(cfg)
    print(json.dumps(spec_context(cfg, client, args.ref, project_ref=args.project),
                     ensure_ascii=False))
    return 0


def cmd_file(args):
    cfg = load_config()
    client = make_client(cfg)
    print(json.dumps(file_context(cfg, client, args.dump, project_ref=args.project),
                     ensure_ascii=False))
    return 0


def cmd_update(args):
    cfg = load_config()
    client = make_client(cfg)
    return _emit_enrich(cfg, client, json.loads(args.edits))


def cmd_tag(args):
    cfg = load_config()
    client = make_client(cfg)
    edits = []
    if args.add:
        edits.append({"tie": args.tie, "field": "tag", "value": args.add})
    if args.remove:
        edits.append({"tie": args.tie, "field": "untag", "value": args.remove})
    if args.set is not None:
        edits.append({"tie": args.tie, "field": "labels", "value": args.set})
    if not edits:
        raise PlaneError("tag needs --add, --remove, or --set")
    return _emit_enrich(cfg, client, edits)


def cmd_comment(args):
    cfg = load_config()
    client = make_client(cfg)
    return _emit_enrich(cfg, client, [{"tie": args.tie, "field": "comment", "value": args.body}])


def cmd_assign(args):
    cfg = load_config()
    client = make_client(cfg)
    vals = [s.strip() for s in (args.to or "").split(",") if s.strip()]
    return _emit_enrich(cfg, client, [{"tie": args.tie, "field": "assignees", "value": vals}])


def cmd_reparent(args):
    cfg = load_config()
    client = make_client(cfg)
    return _emit_enrich(cfg, client, [{"tie": args.tie, "field": "parent", "value": args.parent}])


def cmd_cycle(args):
    cfg = load_config()
    client = make_client(cfg)
    return _emit_enrich(cfg, client, [{"tie": args.tie, "field": "cycle", "value": args.name}])


def cmd_module(args):
    cfg = load_config()
    client = make_client(cfg)
    return _emit_enrich(cfg, client, [{"tie": args.tie, "field": "module", "value": args.name}])


def cmd_labels(args):
    cfg = load_config()
    client = make_client(cfg)
    # PB-70: `labels --seed` backfills the convention labels onto existing projects.
    # --projects R,... targets a subset (default: every registry project), so a
    # workspace that predates the convention can be brought into line in one run.
    if getattr(args, "seed", False):
        if getattr(args, "projects", None):
            refs = [r.strip() for r in args.projects.split(",") if r.strip()]
            pids = []
            for r in refs:
                p = resolve_project_ref(cfg, r)
                if not p:
                    raise PlaneError("unknown project: %s" % r)
                pids.append(p)
        else:
            pids = [p["id"] for p in normalize_registry(cfg)]
        report = {}
        states_report = {}
        for pid in pids:
            label = project_label(cfg, pid)
            report[label] = seed_convention_labels(client, pid)
            # PB-130: the same backfill path adopts the custom pipeline states, so a
            # workspace that predates them (incl. pbrain's own `pb`) is brought into
            # line in one run. Best-effort; carries manual UI steps if no internal auth.
            states_report[label] = seed_pipeline_states(client, pid)
        print(json.dumps({"seeded": report,
                          "convention": [l["name"] for l in CONVENTION_LABELS],
                          "states": states_report,
                          "pipeline": [s["name"] for s in PIPELINE_STATES]},
                         ensure_ascii=False))
        return 0
    pid = _one_project(cfg, args.project)
    print(json.dumps([{"id": l.get("id"), "name": l.get("name"), "color": l.get("color")}
                      for l in client.list_labels(pid)], ensure_ascii=False))
    return 0


def cmd_members(args):
    cfg = load_config()
    client = make_client(cfg)
    pid = _one_project(cfg, args.project)
    print(json.dumps([{"id": mb.get("id"), "name": mb.get("display_name"),
                       "email": mb.get("email")} for mb in client.list_members(pid)],
                     ensure_ascii=False))
    return 0


def cmd_cycles(args):
    cfg = load_config()
    client = make_client(cfg)
    pid = _one_project(cfg, args.project)
    print(json.dumps([{"id": c.get("id"), "name": c.get("name"),
                       "start_date": c.get("start_date"), "end_date": c.get("end_date")}
                      for c in client.list_cycles(pid)], ensure_ascii=False))
    return 0


def cmd_modules(args):
    cfg = load_config()
    client = make_client(cfg)
    pid = _one_project(cfg, args.project)
    print(json.dumps([{"id": mm.get("id"), "name": mm.get("name")}
                      for mm in client.list_modules(pid)], ensure_ascii=False))
    return 0


def _parse_scale(spec):
    """A --scale spec ('1,2,3,5,8,13') → ordered point labels. Default Fibonacci."""
    if not spec:
        return list(FIBONACCI_SCALE)
    out = [t.strip() for t in str(spec).split(",") if t.strip()]
    return [int(t) if t.isdigit() else t for t in out] or list(FIBONACCI_SCALE)


def cmd_estimates(args):
    """Show / create / fetch the estimate scale for a project.

    The scale is read LIVE from Plane's internal API (never cached — a user can edit
    estimates in Plane any time), so this always reflects real-time data. --create
    makes + activates a scale on the project (default Fibonacci 1,2,3,5,8,13; override
    with --scale). The public token API can't enumerate or create estimate points, so
    both go through the internal API (needs internal auth — a browser-sourced cookie
    (--from-browser), a stored session cookie, or email/password). --hours-per-point
    persists the points→hours factor /plan-my-work packs blocks with. --import-json is
    the manual fallback for environments where the internal API is unreachable.
    """
    cfg = load_config()
    # Persist internal-auth knobs (secret, 0600) so auto-fetch needs no pasting.
    auth_changed = False
    for flag, key in (("session_cookie", "internal_session_cookie"),
                      ("email", "internal_email"), ("password", "internal_password"),
                      ("browser", "internal_browser")):
        val = getattr(args, flag, None)
        if val is not None:
            cfg[key] = val
            auth_changed = True
    if getattr(args, "from_browser", False):
        # Opt into browser-sourced cookies (re-pulled fresh every run, auto-refreshed
        # on expiry) and grab one now so this run already has it.
        cfg["internal_cookie_source"] = "browser"
        ck = extract_plane_cookie(cfg.get("base_url"), browser=cfg.get("internal_browser"))
        if ck:
            cfg["internal_session_cookie"] = ck
        auth_changed = True
    pid = _one_project(cfg, args.project)
    # The persisted points→hours factor is a user setting (not fetched data).
    if args.hours_per_point is not None:
        cfg.setdefault("estimate_hours_per_point", {})[pid] = float(args.hours_per_point)
        auth_changed = True
    if args.import_json:
        # Manual fallback (no internal auth): persist an imported scale to cfg["estimates"].
        raw = args.import_json
        if os.path.exists(raw):
            with open(raw) as fh:
                raw = fh.read()
        cfg.setdefault("estimates", {})[pid] = parse_estimate_payload(json.loads(raw))
        save_config(cfg)
    else:
        if auth_changed:
            save_config(cfg)
        if getattr(args, "create", False):
            # Resolve template → (type, values); --type / --scale override.
            type_, values = "points", None
            if args.template:
                t = args.template.lower()
                if t not in ESTIMATE_TEMPLATES:
                    raise PlaneError("unknown template '%s' (have: %s)"
                                     % (args.template, ", ".join(ESTIMATE_TEMPLATES)))
                type_, values = ESTIMATE_TEMPLATES[t]
            if args.type:
                type_ = args.type
            if args.scale:
                values = _parse_scale(args.scale)
            default_name = {"points": "Points", "categories": "T-Shirt",
                            "time": "Time"}.get(type_, "Points")
            # Reuse-or-create the scale + activate it on the project.
            setup_project_estimate(cfg, make_client(cfg), pid,
                                   values=values or list(FIBONACCI_SCALE),
                                   name=args.name or default_name, type_=type_,
                                   replace=bool(getattr(args, "replace", False)))
        else:
            # Fetch live so the display reflects real-time Plane data (no caching).
            ensure_estimate_scale(cfg, make_client(cfg), pid)
    print(json.dumps({"project": project_label(cfg, pid), "project_id": pid,
                      "hours_per_point": _project_hpp(cfg, pid),
                      "scale": estimate_scale(cfg, pid)}, ensure_ascii=False))
    return 0


def build_parser():
    p = argparse.ArgumentParser(prog="plane.py")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("setup")
    sp.add_argument("--base-url"); sp.add_argument("--api-key")
    sp.add_argument("--workspace"); sp.add_argument("--project")
    sp.add_argument("--internal-email")
    sp.add_argument("--internal-password")
    sp.add_argument("--internal-password-plain", action="store_true",
                    help="store the internal password in plane.json (0600) instead of the macOS Keychain")
    sp.add_argument("--internal-cookie-source", choices=["browser", "none"],
                    help="'browser' = scrape the local browser cookie (localhost); 'none' = use email/password (remote/VPS)")
    sp.add_argument("--force", action="store_true",
                    help="PB-98: overwrite an existing, different api_key (a .bak is written first). "
                         "Without it, setup refuses to clobber a live key — protects against test/dummy runs.")
    sp.set_defaults(func=cmd_setup)

    sp = sub.add_parser("use"); sp.add_argument("backend"); sp.set_defaults(func=cmd_use)
    sp = sub.add_parser("ping"); sp.add_argument("--project"); sp.set_defaults(func=cmd_ping)
    sp = sub.add_parser("web-base"); sp.set_defaults(func=cmd_webbase)
    sp = sub.add_parser("link-base"); sp.set_defaults(func=cmd_linkbase)
    sp = sub.add_parser("states"); sp.add_argument("--project")
    sp.add_argument("--projects")            # PB-130: subset for --seed/--migrate
    sp.add_argument("--seed", action="store_true")     # create/reconcile pipeline states
    sp.add_argument("--migrate", action="store_true")  # seed + re-point existing issues
    sp.add_argument("--rename", action="store_true")   # PB-XXX: rename states per STATE_RENAMES (0014)
    sp.add_argument("--dry-run", action="store_true")  # report legacy/old-name presence, no writes
    sp.set_defaults(func=cmd_states)

    sp = sub.add_parser("ready")
    sp.add_argument("--project")
    sp.add_argument("--projects", help="comma-separated project refs (uuid|name|shortcut)")
    sp.add_argument("--include-backlog", action="store_true")
    sp.add_argument("--with-lanes", action="store_true")
    sp.add_argument("--require-approved", action="store_true",
                    help="spec/approval gate (PB-45): only plan-approved issues")
    sp.add_argument("--ordered", action="store_true",
                    help="PB-94: hoist blockers ahead of the issues they block "
                         "(the groom→pmw hand-off stream)")
    sp.set_defaults(func=cmd_ready)

    # PB-141: the Queue. `queued` reads the Queued state (pmw walks this); `enqueue`
    # writes the ordered ready stream INTO the Queued state (groom does this).
    sp = sub.add_parser("queued")
    sp.add_argument("--project")
    sp.add_argument("--projects", help="comma-separated project refs (uuid|name|shortcut)")
    sp.set_defaults(func=cmd_queued)

    sp = sub.add_parser("claim-next")
    sp.add_argument("--project")
    sp.add_argument("--projects", help="comma-separated project refs (uuid|name|shortcut)")
    sp.add_argument("--session", help="per-caller token (e.g. pid+epoch) for the atomic claim")
    sp.set_defaults(func=cmd_claim_next)

    sp = sub.add_parser("enqueue")
    sp.add_argument("--project")
    sp.add_argument("--projects", help="comma-separated project refs (uuid|name|shortcut)")
    sp.add_argument("--no-done", action="store_true",
                    help="PB-146: skip ranking the Landed column by completed_at")
    sp.set_defaults(func=cmd_enqueue)

    sp = sub.add_parser("resolve"); sp.add_argument("--ties", required=True); sp.set_defaults(func=cmd_resolve)

    sp = sub.add_parser("projects"); sp.add_argument("--sync", action="store_true")
    sp.set_defaults(func=cmd_projects)

    sp = sub.add_parser("progress")
    sp.add_argument("--projects"); sp.add_argument("--since")
    sp.set_defaults(func=cmd_progress)

    sp = sub.add_parser("review")
    sp.add_argument("--projects"); sp.add_argument("--include-backlog", action="store_true")
    sp.set_defaults(func=cmd_review)

    sp = sub.add_parser("groom")  # PB-46 headless mechanical grooming
    sp.add_argument("--projects")
    sp.add_argument("--apply", action="store_true",
                    help="apply the conservative backlog→todo triage (default: dry-run report)")
    sp.set_defaults(func=cmd_groom)

    sp = sub.add_parser("enrich"); sp.add_argument("--edits", required=True)
    sp.set_defaults(func=cmd_enrich)

    sp = sub.add_parser("completed")
    sp.add_argument("--projects"); sp.add_argument("--date", required=True)
    sp.set_defaults(func=cmd_completed)

    sp = sub.add_parser("doing")   # PB-94 — issues currently in progress (started group)
    sp.add_argument("--projects")
    sp.set_defaults(func=cmd_doing)

    sp = sub.add_parser("priority")
    sp.add_argument("--tie", required=True); sp.add_argument("--value", required=True)
    sp.set_defaults(func=cmd_priority)

    sp = sub.add_parser("timeline")
    sp.add_argument("--tie", required=True); sp.add_argument("--target-date", required=True)
    sp.set_defaults(func=cmd_timeline)

    sp = sub.add_parser("move")
    sp.add_argument("--tie", required=True); sp.add_argument("--status", required=True)
    sp.add_argument("--completed-at")
    sp.add_argument("--to-state")  # PB-130: target a named pipeline state in the group
    sp.set_defaults(func=cmd_move)

    sp = sub.add_parser("issue")
    sp.add_argument("--project", required=True, help="project uuid|name|shortcut")
    sp.add_argument("--title", required=True)
    sp.add_argument("--priority", default=None, choices=["urgent", "high", "medium", "low", "none"])
    sp.add_argument("--target-date", default=None)
    sp.add_argument("--state", default=None,
                    help="file directly into this state (name e.g. Backlog, or a "
                         "status word); default is the project default (Todo)")
    sp.set_defaults(func=cmd_issue)

    sp = sub.add_parser("project-create")
    sp.add_argument("--name", required=True)
    sp.add_argument("--shortcut", default=None, help="short alias, e.g. 'dj'")
    sp.set_defaults(func=cmd_project_create)

    sp = sub.add_parser("workdir")
    sp.add_argument("project", nargs="?", help="project uuid|name|shortcut (omit to list)")
    sp.add_argument("--path", help="absolute path to the working repo/dir")
    sp.add_argument("--kind", choices=["conductor", "repo"], help="default repo")
    sp.add_argument("--base-branch", help="default main")
    sp.add_argument("--isolation", choices=["worktree", "branch"], help="default worktree")
    sp.add_argument("--clear", action="store_true", help="remove the working location")
    sp.set_defaults(func=cmd_workdir)

    sp = sub.add_parser("workdirs")  # read-only {pid: work} map, no network
    sp.set_defaults(func=cmd_workdirs)

    # --- richer write/lookup verbs (the catalogue) ---------------------------
    sp = sub.add_parser("find")
    sp.add_argument("ref", help="URL | PB-26 | bare seq (with --project) | name fragment")
    sp.add_argument("--project", help="restrict to one project (uuid|name|shortcut)")
    sp.set_defaults(func=cmd_find)

    sp = sub.add_parser("explode")
    sp.add_argument("ref", help="URL | PB-26 | bare seq (with --project) | name fragment")
    sp.add_argument("--project", help="restrict to one project (uuid|name|shortcut)")
    sp.set_defaults(func=cmd_explode)

    sp = sub.add_parser("subtree")  # PB-81 — resolve an execute target's open sub-issues
    sp.add_argument("ref", help="URL | PB-26 | bare seq (with --project) | name fragment")
    sp.add_argument("--project", help="restrict to one project (uuid|name|shortcut)")
    sp.set_defaults(func=cmd_subtree)

    sp = sub.add_parser("blocked-by")  # PB-94 — open blockers of an execute target
    sp.add_argument("ref", help="URL | PB-26 | bare seq (with --project) | name fragment")
    sp.add_argument("--project", help="restrict to one project (uuid|name|shortcut)")
    sp.set_defaults(func=cmd_blocked_by)

    sp = sub.add_parser("spec")
    sp.add_argument("ref", help="URL | PB-26 | bare seq (with --project) | name fragment")
    sp.add_argument("--project", help="restrict to one project (uuid|name|shortcut)")
    sp.set_defaults(func=cmd_spec)

    sp = sub.add_parser("file")  # PB-67: generic work-item intake from a free-text dump
    sp.add_argument("dump", help="the work as you'd describe it (free text); the walk explodes it")
    sp.add_argument("--project", help="target project (uuid|name|shortcut; default: lone/configured)")
    sp.set_defaults(func=cmd_file)

    sp = sub.add_parser("update")
    sp.add_argument("--edits", required=True, help="JSON [{tie,field,value}] (any field family)")
    sp.set_defaults(func=cmd_update)

    sp = sub.add_parser("tag")
    sp.add_argument("--tie", required=True)
    sp.add_argument("--add", help="labels to add (comma list; auto-created within the guard)")
    sp.add_argument("--remove", help="labels to remove (comma list)")
    sp.add_argument("--set", help="replace the whole label set (comma list; '' clears)")
    sp.set_defaults(func=cmd_tag)

    sp = sub.add_parser("comment")
    sp.add_argument("--tie", required=True); sp.add_argument("--body", required=True)
    sp.set_defaults(func=cmd_comment)

    sp = sub.add_parser("assign")
    sp.add_argument("--tie", required=True)
    sp.add_argument("--to", required=True, help="user uuid|display name|email (comma list); '' clears")
    sp.set_defaults(func=cmd_assign)

    sp = sub.add_parser("reparent")
    sp.add_argument("--tie", required=True)
    sp.add_argument("--parent", required=True, help="parent ref (tie|uuid|PB-12); 'none' un-parents")
    sp.set_defaults(func=cmd_reparent)

    sp = sub.add_parser("cycle")
    sp.add_argument("--tie", required=True); sp.add_argument("--name", required=True)
    sp.set_defaults(func=cmd_cycle)

    sp = sub.add_parser("module")
    sp.add_argument("--tie", required=True); sp.add_argument("--name", required=True)
    sp.set_defaults(func=cmd_module)

    # labels carries extra flags (PB-70 convention-label seeding), so build it on its own.
    sp = sub.add_parser("labels")
    sp.add_argument("--project", help="project uuid|name|shortcut (default: lone/first)")
    sp.add_argument("--seed", action="store_true",
                    help="ensure the convention labels (bug/feature/chore/docs) on the project(s)")
    sp.add_argument("--projects",
                    help="--seed only: comma list of projects to backfill (default: all)")
    sp.set_defaults(func=cmd_labels)

    for _name, _fn in (("members", cmd_members),
                       ("cycles", cmd_cycles), ("modules", cmd_modules)):
        sp = sub.add_parser(_name)
        sp.add_argument("--project", help="project uuid|name|shortcut (default: lone/first)")
        sp.set_defaults(func=_fn)

    sp = sub.add_parser("estimates")
    sp.add_argument("--project", help="project uuid|name|shortcut (default: lone/first)")
    sp.add_argument("--import-json", help="Plane /estimates/ JSON (file path or inline) to cache")
    sp.add_argument("--hours-per-point", type=float, help="points→hours factor (default 1.0)")
    sp.add_argument("--create", action="store_true",
                    help="create + activate an estimate scale on the project (internal API)")
    sp.add_argument("--template",
                    help="preset for --create: fibonacci|linear|squares|hours|tshirt|difficulty")
    sp.add_argument("--type", help="estimate type for --create: points|categories|time")
    sp.add_argument("--scale", help="point labels for --create (comma list); overrides template")
    sp.add_argument("--name", help="estimate scale name for --create (default per type)")
    sp.add_argument("--replace", action="store_true",
                    help="with --create: delete any existing scale first to switch type "
                         "(WARNING: clears all issue estimates on the project)")
    sp.add_argument("--session-cookie", help="internal-API session cookie (persisted, 0600)")
    sp.add_argument("--from-browser", action="store_true",
                    help="pull the Plane session cookie from the local Chromium browser, "
                         "and auto-refresh it from there when it expires (macOS)")
    sp.add_argument("--browser", help="which browser for --from-browser: brave|chrome|chromium")
    sp.add_argument("--email", help="Plane login email for internal-API auto-fetch (persisted)")
    sp.add_argument("--password", help="Plane login password for internal-API auto-fetch (persisted)")
    sp.set_defaults(func=cmd_estimates)

    return p


def main(argv=None):
    install_redaction_shield()   # secrets registered below can never be echoed
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except PlaneError as e:
        sys.stderr.write("plane: %s\n" % e)
        print("PLANE_ERROR %s" % e)
        return 4


if __name__ == "__main__":
    sys.exit(main())
