#!/usr/bin/env bash
set -euo pipefail

# loose-ends.sh
# Read-only surfacing command. pbrain generates a lot of "open loop" data —
# brainstorms, open questions, todos, tomorrow-seeds, focus areas — but nothing
# reflects it back. This aggregates the unresolved threads and flags stale items
# so the vault can push context at you instead of just storing it.
#
# Gathers 5 signals via inline Python (stdlib only), emits a labeled context
# block, and the .md instructs Claude to synthesize a tight report. WRITES
# NOTHING — it's a dashboard, idempotent and safe to re-run.
#
# Overrides:
#   PBRAIN_VAULT              — vault root
#   PBRAIN_STALE_DAYS         — age (days) at which an item counts as stale (default 7)
#   PBRAIN_LOOSE_ENDS_LOOKBACK — how far back (days) to scan recent files (default 30)
#   PBRAIN_JOURNAL_DIR        — daily journals (open questions)
#   PBRAIN_BRAINSTORMS_DIR    — brainstorms parent (tbd/ is the active bucket)
#   PBRAIN_PLAN_DIR           — daily plans (todos, tomorrow-seeds)
#   PBRAIN_PLAN_PROFILE_FILE  — goals profile markdown, JSON in a fenced block (focus drift)
#
# Usage:
#   /loose-ends

_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
source "$_SCRIPT_DIR/../lib/vault.sh"

# Surface this user's standing preferences for /loose-ends (emits nothing if none set).
pbrain_emit_prefs "loose-ends" || true

JOURNAL_DIR="${PBRAIN_JOURNAL_DIR:-$VAULT_DIR/life/daily-tracking}"
BRAINSTORMS_DIR="${PBRAIN_BRAINSTORMS_DIR:-$VAULT_DIR/agent-work/brainstorms}"
TBD_DIR="$BRAINSTORMS_DIR/tbd"
PLAN_DIR="${PBRAIN_PLAN_DIR:-$VAULT_DIR/life/daily-planning}"
PROFILE_FILE="${PBRAIN_PLAN_PROFILE_FILE:-$VAULT_DIR/life/Goals Profile.md}"

STALE_DAYS="${PBRAIN_STALE_DAYS:-7}"
LOOKBACK="${PBRAIN_LOOSE_ENDS_LOOKBACK:-30}"

TODAY="$(date +%Y-%m-%d)"

# Extract the profile's JSON (from its fenced block) up front; pass it to the
# scan rather than the file path, so the parsing logic lives in one place.
PROFILE_JSON="$(pbrain_profile_json "$PROFILE_FILE")"

echo "LOOSE_ENDS_SCAN"
echo "vault: $VAULT_DIR"
echo "generated: $TODAY"
echo "stale_days: $STALE_DAYS"
echo "lookback_days: $LOOKBACK"
echo ""

python3 - "$TODAY" "$STALE_DAYS" "$LOOKBACK" "$VAULT_DIR" "$TBD_DIR" "$JOURNAL_DIR" "$PLAN_DIR" "$PROFILE_JSON" <<'PYEOF'
import os, re, sys, glob, json, datetime

today      = datetime.date.fromisoformat(sys.argv[1])
stale_days = int(sys.argv[2])
lookback   = int(sys.argv[3])
vault      = sys.argv[4]
tbd_dir    = sys.argv[5]
journal_dir = sys.argv[6]
plan_dir   = sys.argv[7]
profile_json = sys.argv[8]

cutoff = today - datetime.timedelta(days=lookback)

def read_text(p):
    try:
        with open(p, encoding="utf-8") as fh:
            return fh.read()
    except Exception:
        return None

def frontmatter(text):
    fm = {}
    if text and text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            for line in text[3:end].splitlines():
                m = re.match(r'^([A-Za-z0-9_]+):\s*(.*)$', line)
                if m:
                    fm[m.group(1)] = m.group(2).strip().strip('"')
    return fm

def file_date(path, text):
    fm = frontmatter(text or "")
    for key in ("date", "created"):
        v = fm.get(key)
        if v:
            try:
                return datetime.date.fromisoformat(v[:10])
            except Exception:
                pass
    m = re.match(r'(\d{4}-\d{2}-\d{2})', os.path.basename(path))
    if m:
        try:
            return datetime.date.fromisoformat(m.group(1))
        except Exception:
            pass
    try:
        return datetime.date.fromtimestamp(os.path.getmtime(path))
    except Exception:
        return None

def section_lines(text, heading):
    """Lines under a heading (e.g. '## Open questions'), up to the next heading."""
    out, capturing = [], False
    target = heading.strip().lower()
    for ln in (text or "").splitlines():
        if re.match(r'^#{1,6}\s', ln):
            if capturing:
                break
            if ln.strip().lower() == target:
                capturing = True
            continue
        if capturing:
            out.append(ln)
    return out

def rel(p):
    try:
        return os.path.relpath(p, vault)
    except Exception:
        return p

def emit(header, lines):
    print(f"--- {header} ---")
    if lines:
        for l in lines:
            print(l)
    else:
        print("(none)")
    print("")

# ---------------------------------------------------------------------------
# 1. Stale ideas — tbd brainstorms >= stale_days old.
# ---------------------------------------------------------------------------
stale = []
for f in glob.glob(os.path.join(tbd_dir, "*.md")):
    text = read_text(f)
    if text is None:
        continue
    d = file_date(f, text)
    if d is None:
        continue
    age = (today - d).days
    if age >= stale_days:
        fm = frontmatter(text)
        title = fm.get("title", "")
        if not title:
            hm = re.search(r'^#\s+(.+)', text, re.MULTILINE)
            title = hm.group(1).strip() if hm else ""
        slug = os.path.basename(f)[:-3]
        stale.append((age, slug, title, rel(f)))
stale.sort(reverse=True)  # oldest (highest age) first
emit(f"STALE IDEAS (tbd brainstorms >= {stale_days}d old, oldest first)",
     [f'- [{a}d] {s} — "{t}" ({r})' if t else f'- [{a}d] {s} ({r})'
      for a, s, t, r in stale])

# ---------------------------------------------------------------------------
# 2. Unanswered questions — '## Open questions' in recent daily journals
#    (answer is empty or '—' => unresolved) + open-question bullets in tbd.
# ---------------------------------------------------------------------------
def unresolved_in_journal(lines):
    res, i, n = [], 0, len(lines)
    while i < n:
        qm = re.match(r'^-\s+(.*)$', lines[i])
        if qm:
            q = qm.group(1).strip()
            ans, j = [], i + 1
            while j < n and not re.match(r'^-\s+', lines[j]):
                if lines[j].strip():
                    ans.append(lines[j].strip())
                j += 1
            ans_text = " ".join(ans).strip()
            if not ans_text or ans_text in ("—", "-"):
                res.append(q)
            i = j
        else:
            i += 1
    return res

q_lines = []
journal_files = sorted(glob.glob(os.path.join(journal_dir, "*.md")))
for f in journal_files:
    text = read_text(f)
    d = file_date(f, text)
    if d is None or d < cutoff:
        continue
    for q in unresolved_in_journal(section_lines(text, "## Open questions")):
        q_lines.append((d, f'- "{q}" — {d.isoformat()} ({rel(f)})'))

# Open-question bullets sitting in tbd brainstorms (open by nature).
for f in glob.glob(os.path.join(tbd_dir, "*.md")):
    text = read_text(f)
    if text is None:
        continue
    d = file_date(f, text) or today
    for ln in section_lines(text, "## Open questions"):
        bm = re.match(r'^-\s+(.*)$', ln)
        if bm and bm.group(1).strip() not in ("", "—"):
            q_lines.append((d, f'- "{bm.group(1).strip()}" — brainstorm: {os.path.basename(f)[:-3]} ({rel(f)})'))

q_lines.sort(key=lambda x: x[0])  # oldest first
emit("UNANSWERED QUESTIONS (journals + tbd brainstorms, oldest first)",
     [l for _, l in q_lines])

# ---------------------------------------------------------------------------
# 3. Open todos — unchecked '- [ ]' across recent daily plans.
# ---------------------------------------------------------------------------
todos = []
plan_files = sorted(glob.glob(os.path.join(plan_dir, "*.md")))
for f in plan_files:
    text = read_text(f)
    d = file_date(f, text)
    if d is None or d < cutoff:
        continue
    for ln in (text or "").splitlines():
        tm = re.match(r'^\s*-\s+\[ \]\s+(.*)$', ln)
        if tm and tm.group(1).strip():
            todos.append((d, f'- [ ] {tm.group(1).strip()} — {d.isoformat()} ({rel(f)})'))
todos.sort(key=lambda x: x[0])
emit("OPEN TODOS (unchecked boxes in recent plans, oldest first)",
     [l for _, l in todos])

# ---------------------------------------------------------------------------
# 4. Recurring tomorrow-seeds — '### Tomorrow seed' bullets repeating across
#    recent plans (= something that keeps getting deferred).
# ---------------------------------------------------------------------------
seed_dates = {}   # normalized seed -> set of dates
seed_label = {}   # normalized seed -> original text
for f in plan_files:
    text = read_text(f)
    d = file_date(f, text)
    if d is None or d < cutoff:
        continue
    for ln in section_lines(text, "### Tomorrow seed"):
        sm = re.match(r'^-\s+(.*)$', ln)
        if sm:
            raw = sm.group(1).strip()
            if not raw or raw == "—":
                continue
            norm = re.sub(r'[^a-z0-9 ]', '', raw.lower()).strip()
            norm = re.sub(r'\s+', ' ', norm)
            if not norm:
                continue
            seed_dates.setdefault(norm, set()).add(d.isoformat())
            seed_label.setdefault(norm, raw)

recurring = sorted(
    ((len(ds), seed_label[k], sorted(ds)) for k, ds in seed_dates.items() if len(ds) >= 2),
    reverse=True,
)
emit("RECURRING TOMORROW-SEEDS (deferred >= 2 days)",
     [f'- "{label}" — appeared {n}x ({", ".join(ds)})' for n, label, ds in recurring])

# ---------------------------------------------------------------------------
# 5. Focus drift — current_focus goals not mentioned in last stale_days plans.
# ---------------------------------------------------------------------------
STOP = set("the a an and or to of for in on at by with from is are was were be been "
           "this that these those will would should could can may might must i you we "
           "they it my your our their its not no so too very just into onto about over "
           "under out up down off more most than any some week month ongoing".split())

def sig_words(s):
    return {w for w in re.findall(r'[a-z0-9]+', s.lower()) if len(w) >= 4 and w not in STOP}

focus_lines = []
ptext = profile_json
goals = []
if ptext:
    try:
        pdata = json.loads(ptext)
        goals = [g.get("goal", "") for g in pdata.get("current_focus", []) if g.get("goal")]
    except Exception:
        focus_lines.append("(goals profile present but its JSON block is unreadable — skipping focus drift)")

if goals:
    drift_cutoff = today - datetime.timedelta(days=stale_days)
    # Build per-plan (date, text) for plans within stale_days window.
    recent = []
    for f in plan_files:
        text = read_text(f)
        d = file_date(f, text)
        if d is None or d < drift_cutoff:
            continue
        recent.append((d, (text or "").lower()))
    for goal in goals:
        gwords = sig_words(goal)
        last_seen = None
        for d, txt in recent:
            mentioned = goal.lower() in txt or (
                gwords and len(gwords & set(re.findall(r'[a-z0-9]+', txt))) >= max(1, (len(gwords) + 1) // 2)
            )
            if mentioned and (last_seen is None or d > last_seen):
                last_seen = d
        if last_seen is None:
            focus_lines.append(f'- "{goal}" — not mentioned in plans for the last {stale_days}d')
elif not focus_lines:
    focus_lines.append("(no current_focus goals in profile — nothing to check)")

emit(f"FOCUS DRIFT (current_focus goals quiet >= {stale_days}d)", focus_lines)
PYEOF

echo "--- END LOOSE_ENDS_SCAN ---"

# Self-improvement: capture standing preferences / quality fixes the user
# raised this session (silent unless there was genuine feedback).
pbrain_emit_self_improve "loose-ends" || true
