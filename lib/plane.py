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
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)  # secret → 0600
    with os.fdopen(fd, "w") as fh:
        json.dump(persistable, fh, indent=2)
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

    def update_project(self, project_id, body):
        return self._request("PATCH", "projects/%s/" % project_id, body=body)

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
            raise PlaneError("Plane internal API %s %s -> HTTP %s" % (method, path, e.code))
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


def issue_to_ready(issue, project_id, states_by_id, module_by_issue, default_est_h,
                   uuid_hours=None):
    grp = state_group(issue, states_by_id)
    iid = issue.get("id")
    ep = issue.get("estimate_point")
    est_h = uuid_hours[ep] if (ep and uuid_hours and ep in uuid_hours) else default_est_h
    return {
        "tie": "%s:%s" % (project_id, iid),
        "id": issue.get("sequence_id", iid),
        "issue_id": iid,
        "title": issue.get("name", ""),
        "est_h": est_h,
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
    ("PB-26"), or a bare sequence ("26", needs a project from the caller).
    identifier is upper-cased; returns (None, None) when nothing parses.
    """
    import re
    s = (ref or "").strip()
    mu = re.search(r"/browse/([A-Za-z][A-Za-z0-9]*)-(\d+)", s)
    if mu:
        return mu.group(1).upper(), int(mu.group(2))
    mi = re.match(r"^([A-Za-z][A-Za-z0-9]*)-(\d+)$", s)
    if mi:
        return mi.group(1).upper(), int(mi.group(2))
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


def ready(cfg, client, project_id, include_backlog=False, with_lanes=False):
    states = client.list_states(project_id)
    states_by_id = {s["id"]: s for s in states}
    module_by_issue = _module_map(client, project_id, with_lanes)
    ensure_estimate_scale(cfg, client, project_id)
    uuid_hours = est_uuid_to_hours(cfg, project_id)
    items = []
    for issue in client.list_work_items(project_id):
        r = issue_to_ready(issue, project_id, states_by_id, module_by_issue,
                           cfg["default_est_h"], uuid_hours)
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
                            "id": r.get("id"), "title": r["title"], "flags": flags})
    return out


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
        v = str(value or "").strip()
        sid = next((s["id"] for s in states
                    if (s.get("name") or "").strip().lower() == v.lower()), None)
        if not sid and v.lower() in STATUS_TO_GROUP:
            sid = pick_state_id(states, STATUS_TO_GROUP[v.lower()])
        if not sid:
            raise PlaneError("no state matching '%s' (have: %s)"
                             % (v, ", ".join(s.get("name", "") for s in states)))
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

    # --- richer write/lookup verbs (the catalogue) ---------------------------
    sp = sub.add_parser("find")
    sp.add_argument("ref", help="URL | PB-26 | bare seq (with --project) | name fragment")
    sp.add_argument("--project", help="restrict to one project (uuid|name|shortcut)")
    sp.set_defaults(func=cmd_find)

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

    for _name, _fn in (("labels", cmd_labels), ("members", cmd_members),
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
