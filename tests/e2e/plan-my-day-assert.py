#!/usr/bin/env python3
"""plan-my-day-assert.py — parse a generated daily-planning file and check its
work blocks + breaks against the plans-profile block_layout_policy / break_minutes
(PB-186).

argv: 1 = plan markdown file, 2 = policy JSON string {session, break:{min,median,max}, policy}
Prints the verdict JSON on stdout (ok, problems, blocks, breaks, rows, ...).

Rules enforced:
  - work blocks are FIXED at session_length_min; a short work block is allowed
    ONLY when it is the last work block (end-of-day) or it abuts a hard anchor
    (a fixed event/meal/wind-down on the very next row). Any other short block,
    or an over-long block, is a violation.
  - breaks must sit within break_minutes [min, max]; longer than max means the
    break was extended/padded (forbidden); shorter than min is also flagged.
"""
import json, sys, re

plan = open(sys.argv[1]).read()
pol = json.loads(sys.argv[2])
sess = int(pol["session"]); br = pol["break"]
bmin, bmed, bmax = int(br["min"]), int(br["median"]), int(br["max"])
buffers = pol.get("activity_buffers", {}) or {}
meal_minutes = pol.get("meal_minutes", {}) or {}     # {slot: minutes} (user-set)
meal_default = int(pol.get("meal_default", 30))      # default/cap when unset
post_meal_nap = pol.get("post_meal_nap", {}) or {}   # {after, minutes, fixed}

# 'now' (HH:MM) — optional; enables the future-✓ guard. None disables it.
NOW_MIN = None
if len(sys.argv) > 3 and re.match(r'^\d{1,2}:\d{2}$', sys.argv[3] or ""):
    _h, _m = sys.argv[3].split(":"); NOW_MIN = int(_h) * 60 + int(_m)

# Max plausible single non-meal rest/idle block (minutes). A longer "rest /
# settle" row is padding, ✓ or not.
MAX_REST_BLOCK = 120

# Shared meal/fuel matcher (used by both the mega-rest guard and the padding loop).
MEAL_RE_TOP = re.compile(r'\b(lunch|dinner|breakfast|meal|fuel|eat|snack|shake)\b', re.I)

# The largest legitimate PRE-activity reservation across configured activities
# (e.g. football/gym commute_before_min). Anything a "buffer/prep/travel/kit"
# row reserves beyond this — when work could have filled it — is padding that
# steals work time (the PB-186 follow-up bug).
def max_commute_before():
    vals = []
    for a in buffers.values():
        if isinstance(a, dict):
            v = a.get("commute_before_min") or a.get("buffer_before_min")
            if isinstance(v, (int, float)): vals.append(int(v))
    return max(vals) if vals else None
COMMUTE_BEFORE = max_commute_before()

# Pull rows from the "Today at a glance" table. Two formats are tolerated:
#   (a) markdown:  | HH:MM–HH:MM | action | tie |
#   (b) JSON-ish:  {"Time":"HH:MM–HH:MM","Action":"...","Tie":"..."}
# Each row becomes (start, end, action, tie).
rows = []
# (b) JSON objects first
for m in re.finditer(r'\{[^{}]*"Time"\s*:\s*"([^"]*)"[^{}]*\}', plan):
    obj = m.group(0)
    tm = re.search(r'(\d{1,2}:\d{2})\s*[–\-—]\s*(\d{1,2}:\d{2})', m.group(1))
    if not tm:
        continue
    act = (re.search(r'"Action"\s*:\s*"([^"]*)"', obj) or [None, ""])[1]
    tie = (re.search(r'"Tie"\s*:\s*"([^"]*)"', obj) or [None, ""])[1]
    rows.append((tm.group(1), tm.group(2), act.strip(), tie.strip()))
# (a) markdown rows, if no JSON rows found
if not rows:
    for line in plan.splitlines():
        if "|" not in line:
            continue
        tm = re.search(r'(\d{1,2}:\d{2})\s*[–\-—]\s*(\d{1,2}:\d{2})', line)
        if not tm:
            continue
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        act = cells[1] if len(cells) > 1 else ""
        tie = cells[2] if len(cells) > 2 else ""
        rows.append((tm.group(1), tm.group(2), act, tie))

def mins(t):
    h, m = t.split(":"); return int(h) * 60 + int(m)

def dur(s, e):
    d = mins(e) - mins(s)
    return d + 24 * 60 if d < 0 else d

# A STRONG work signal: an explicit "Block N" / "focus work" / "deep work" row.
# A bare "pbrain" mention is only a weak hint (it shows up inside morning-routine
# item lists too), so it counts as work ONLY when the row is not clearly a life
# anchor.
STRONG_WORK_RE = re.compile(r'block\s*\d|focus work|deep work|focus block', re.I)
WEAK_WORK_RE = re.compile(r'\bpbrain\b|\byt-?copilot\b|\bkickapp\b|\bmeloro\b', re.I)
BREAK_RE = re.compile(r'\bbreak\b', re.I)
WIND_RE = re.compile(r'wind[- ]?down|\bbed\b', re.I)
# Rows that are LIFE anchors / routine — never work, even if they mention pbrain
# in a list (e.g. "Wake + morning routine (… pbrain)").
NONWORK_RE = re.compile(
    r'\b(wake|morning routine|get[- ]?ready|shower|breakfast|lunch|dinner|meal|fuel|'
    r'eat|snack|shake|nap|rest|settle|leisure|downtime|relax|commute|travel|'
    r'football|gym|match|class|walk|wind[- ]?down|bed|chores?)\b', re.I)

def classify(action, tie=""):
    a = (action or "").lower(); t = (tie or "").lower()
    if BREAK_RE.search(a):
        return "break"
    if WIND_RE.search(a):
        return "winddown"
    # An explicit "Block N" / "focus work" row IS work, even if its label mentions
    # an anchor in passing (e.g. "Work block 1 (trimmed, lunch hard stop)").
    if STRONG_WORK_RE.search(a):
        return "work"
    # Weak signal (pbrain/project tie) counts as work ONLY when the row isn't a
    # life-anchor/routine row.
    if (WEAK_WORK_RE.search(a) or t == "pbrain" or WEAK_WORK_RE.search(t)) and not NONWORK_RE.search(a):
        return "work"
    return "anchor"

# A ✓-prefixed row is ALREADY-DONE / banked work recorded as it actually
# happened (the user did it this morning) — not a forward-planned block. The
# fixed-block / break rules only govern forward planning, so done rows are
# excluded from the size checks.
def is_done(action):
    # ✓ may be a prefix OR a suffix ("Wake ✓"); treat either as already-done.
    return "✓" in (action or "") or "☑" in (action or "") or "✔" in (action or "")

blocks = []; breaks = []
for i, (s, e, act, tie) in enumerate(rows):
    if is_done(act):
        continue
    k = classify(act, tie); d = dur(s, e)
    if k == "work":
        blocks.append({"start": s, "end": e, "dur": d, "action": act, "idx": i})
    elif k == "break":
        breaks.append({"start": s, "end": e, "dur": d, "action": act, "idx": i})

# rows for downstream code expect 3-tuples (s,e,action); keep a compat view.
rows3 = [(s, e, act) for (s, e, act, tie) in rows]

problems = []

# GUARD A — fabricated completion: a ✓-done row may only cover PAST time. A ✓
# row whose end is in the future means the model claimed it already happened to
# dodge planning (e.g. "14:30–21:00 ✓ Rest" recorded at 20:00).
if NOW_MIN is not None:
    for (s, e, act, tie) in rows:
        if not is_done(act):
            continue
        try:
            es = mins(e)
        except Exception:
            continue
        # allow a 15-min grace; ignore the day-wrap bed row (end == 00:00→1440 only if start late)
        if es != 0 and es > NOW_MIN + 15:
            problems.append("fabricated ✓: '" + act[:30] + "' marked done but ends " + e +
                            " (after now " + sys.argv[3] + ") — future time cannot be already-done; plan it as forward work")

# GUARD B — implausible mega-rest: a single non-meal rest/idle/settle block over
# MAX_REST_BLOCK minutes is padding (work should fill it), ✓ or not.
REST_RE = re.compile(r'\b(rest|settle|idle|downtime|leisure|relax|nap)\b', re.I)
for (s, e, act, tie) in rows:
    if MEAL_RE_TOP.search(act):  # meals/fuel excluded
        continue
    if not REST_RE.search(act):
        continue
    d = dur(s, e)
    if d > MAX_REST_BLOCK:
        problems.append("mega-rest: '" + act[:30] + "' = " + str(d) +
                        "min exceeds the " + str(MAX_REST_BLOCK) + "min plausible rest cap — that is unplanned work time (padding)")

# GUARD C — meal duration: a meal occupies its configured duration, else the
# 30-min default, and NEVER more unless explicitly set longer for that slot.
# A row is a MEAL only if it's about eating — not a prep/wrap/travel row that
# merely mentions a meal ("Wrap + prep for lunch out" is NOT a meal).
MEAL_ONLY_RE = re.compile(r'\b(lunch|dinner|breakfast|brunch|meal)\b', re.I)
NOT_MEAL_RE = re.compile(r'\b(prep|wrap|travel|commute|get[- ]?ready|head out|leave for|pre[- ])\b', re.I)
def meal_cap_for(action):
    a = action.lower()
    for slot, mins in meal_minutes.items():
        if slot.lower() in a:
            try:
                return int(mins)               # user-configured duration for this slot
            except Exception:
                return meal_default
    return meal_default
for (s, e, act, tie) in rows:
    if is_done(act):
        continue
    if classify(act, tie) in ("work", "break", "winddown"):
        continue                         # a work/break row that merely mentions "lunch" is not a meal
    if not MEAL_ONLY_RE.search(act) or NOT_MEAL_RE.search(act):
        continue                         # prep/wrap/travel-for-lunch rows are not the meal itself
    # skip "pre-football meal/fuel" style rows that are really fuel snacks
    d = dur(s, e); cap = meal_cap_for(act)
    if d > cap:
        problems.append("meal too long: '" + act[:30] + "' = " + str(d) +
                        "min > " + str(cap) + "min — meals are " + str(cap) +
                        "min (set a longer duration in the diet profile to allow more)")

# GUARD D — post-meal nap/rest is a BREAK and obeys break_minutes, UNLESS the
# diet profile pins a fixed nap (then it must be exactly that length).
NAP_RE = re.compile(r'\bnap\b', re.I)
nap_fixed = bool(post_meal_nap.get("fixed")) and post_meal_nap.get("minutes")
nap_fixed_min = int(post_meal_nap["minutes"]) if nap_fixed else None
for i, (s, e, act, tie) in enumerate(rows):
    if is_done(act):
        continue
    # a nap, OR a rest/settle directly after a meal row
    prev_is_meal = i > 0 and MEAL_ONLY_RE.search(rows[i-1][2] or "")
    if not (NAP_RE.search(act) or (prev_is_meal and REST_RE.search(act))):
        continue
    d = dur(s, e)
    if nap_fixed_min is not None:
        if d != nap_fixed_min:
            problems.append("nap: '" + act[:24] + "' = " + str(d) +
                            "min but a FIXED " + str(nap_fixed_min) + "min nap is set — must match exactly, never shrink")
    else:
        if d > bmax:
            problems.append("post-meal nap/rest: '" + act[:24] + "' = " + str(d) +
                            "min > break max " + str(bmax) + " — a nap is a break, keep it within " +
                            str(bmin) + ".." + str(bmax))

# Guard against a vacuous pass: if the plan clearly contains FORWARD focus work
# (a non-✓ "Block N / focus work" row) but the parser found NO work blocks,
# that's a parse/labeling failure, not a pass.
forward_work = any(
    (not is_done(a)) and (re.search(r'block\s*\d|focus work|deep work', a, re.I) or (t.lower() == "pbrain"))
    for (s, e, a, t) in rows
)
if not blocks and forward_work:
    problems.append("parser found 0 forward work blocks though the plan has focus/pbrain work — labeling/format not asserted (treat as FAIL, not vacuous pass)")

last_work_idx = max((b["idx"] for b in blocks), default=-1)
for b in blocks:
    if b["dur"] == sess:
        continue
    nxt = rows[b["idx"] + 1] if b["idx"] + 1 < len(rows) else None
    abuts_anchor = bool(nxt) and classify(nxt[2], nxt[3]) in ("anchor", "winddown")
    is_last = (b["idx"] == last_work_idx)
    label = b["action"][:32]
    if b["dur"] > sess:
        problems.append(label + ": block " + str(b["dur"]) + "min LONGER than session " + str(sess) + " (over-long)")
    elif not (is_last or abuts_anchor):
        problems.append(label + ": mid-day block " + str(b["dur"]) + "min < session " + str(sess) + " and not at end/hard-anchor (shrunk for no reason)")

# Helper: is there a hard anchor / long non-work stretch / wind-down soon after
# row index i (within `lookahead` rows)? Justifies a below-median break.
def anchor_or_longrest_near(i, lookahead=3):
    for j in range(i + 1, min(i + 1 + lookahead, len(rows))):
        s2, e2, a2, t2 = rows[j]
        k2 = classify(a2, t2)
        if k2 in ("winddown",):
            return True
        if k2 == "anchor":
            # a real activity/event or a long (>= session) non-work stretch
            if re.search(r'\b(football|gym|match|class|event|commute|appointment|call|meeting)\b', a2, re.I):
                return True
            if dur(s2, e2) >= sess:
                return True
    return False

below_median = 0
for bk in breaks:
    label = bk["action"][:32]
    if bk["dur"] > bmax:
        problems.append(label + ": break " + str(bk["dur"]) + "min > max " + str(bmax) + " (break extended/padded)")
    if bk["dur"] < bmin:
        problems.append(label + ": break " + str(bk["dur"]) + "min < min " + str(bmin) + " (break too short)")
    # A break BELOW median must be justified: a full block follows it (the
    # reclaimed minutes helped bank it) OR a hard anchor / long rest / wind-down
    # is near. A gratuitous below-median break (between two full mid-day blocks,
    # no anchor in sight) is the "lots of 15-min breaks" smell.
    if bmin <= bk["dur"] < bmed:
        below_median += 1
        idx = bk["idx"]
        nxt = rows[idx + 1] if idx + 1 < len(rows) else None
        next_is_full_block = bool(nxt) and classify(nxt[2], nxt[3]) == "work" and dur(nxt[0], nxt[1]) == sess
        if not (next_is_full_block or anchor_or_longrest_near(idx)):
            problems.append(label + ": break " + str(bk["dur"]) + "min is below median " +
                            str(bmed) + " with no reason (no full block banked, no anchor/long-rest near) — breaks default to median")

# Smell check: if there are several breaks and the MAJORITY are below median,
# the planner is min-defaulting instead of using median.
if len(breaks) >= 3 and below_median * 2 > len(breaks):
    problems.append("most breaks (" + str(below_median) + "/" + str(len(breaks)) +
                    ") are below median " + str(bmed) + " — median should be the common case, not min")

# Padded pre-activity buffer detection. The only legitimate pre-activity
# reservation is COMMUTE_BEFORE (+ an explicit commute row). Any OTHER non-work,
# non-meal row sitting in the window between the last work-capable slot and the
# activity's commute — kit prep / get-ready / travel / snack / buffer / "settle"
# — is padding that should have been work.
PAD_RE = re.compile(r'\b(kit prep|get[- ]?ready|prep|buffer|travel|warm[- ]?up|snack|shake|settle|wind[- ]?down)\b', re.I)
COMMUTE_RE = re.compile(r'\bcommute\b', re.I)
MEAL_RE = re.compile(r'\b(lunch|dinner|breakfast|meal|fuel|eat)\b', re.I)
# Find the ACTIVITY start row (football match / gym session) to bound the
# "pre-activity" window. Require it to be the actual session — a long row tied to
# a fitness category — not an incidental mention like "rest pre-football" or a
# commute row. Prefer the match/session row (tie = Fit body, duration >= 60).
act_idx = None
for i, (s, e, a, t) in enumerate(rows):
    if COMMUTE_RE.search(a):
        continue
    al = a.lower()
    # the real session row: explicit match/session wording, or a Fit-body-tied
    # row of session length; exclude "pre-..."/"settle"/"rest" framing.
    looks_session = (re.search(r'\b(match|session|workout|kickoff)\b', al)
                     or (re.search(r'\b(football|gym)\b', al)
                         and not re.search(r'\b(pre|rest|settle|prep|fuel|meal|commute)\b', al)))
    if looks_session:
        act_idx = i; break

if COMMUTE_BEFORE is not None and act_idx is not None:
    # The pre-activity window is ONLY the stretch AFTER the last forward work
    # block (or meal) before the activity — i.e. the gap the model should fill
    # with work up to commute-start. A morning "ease-in" row before any work is
    # NOT pre-activity padding, so scan starts at the last work/meal index.
    win_start = 0
    for i, (s, e, a, t) in enumerate(rows):
        if i >= act_idx:
            break
        if (not is_done(a)) and (classify(a, t) == "work" or MEAL_RE_TOP.search(a)):
            win_start = i
    for i, (s, e, act, tie) in enumerate(rows):
        if i <= win_start or i >= act_idx:
            continue
        if is_done(act):                 # already-done rows are history, not padding
            continue
        k = classify(act, tie)
        if k in ("work", "break"):       # legit work/break handled above
            continue
        if k == "winddown":              # genuine wind-down is fine
            continue
        if COMMUTE_RE.search(act) or MEAL_RE.search(act):   # commute + meals are legit
            continue
        d = dur(s, e)
        # No keyword gate any more: an anchor row this long in the pre-activity
        # window, that isn't a meal/commute/wind-down, is stolen work time.
        if d > COMMUTE_BEFORE + 10:       # 10-min grace
            kind_note = "padding" if PAD_RE.search(act) else "idle/rest filler"
            problems.append("pre-activity '" + act[:28] + "' = " + str(d) +
                            "min — only " + str(COMMUTE_BEFORE) +
                            "min commute is reserved before the activity; the rest should be work (" + kind_note + ")")

print(json.dumps({
    "ok": not problems, "problems": problems,
    "session": sess, "break": br,
    "n_work": len(blocks), "n_break": len(breaks),
    "blocks": blocks, "breaks": breaks, "rows": rows3,
}, ensure_ascii=False))
