#!/usr/bin/env bash
# Migration 0015 (AUTO): plan-my-day break triplet + fixed-block layout policy.
# PB-186.
#
# The plans-profile's working_style.break_min held a SINGLE break duration, and
# the block-layout rules lived only as prose in plan.txt + other_prefs. The
# layout step could therefore shrink mid-day work blocks arbitrarily and pad
# breaks to fill gaps — the PB-186 bug.
#
# This migration formalizes the rules as STRUCTURED config so plan.txt consumes
# them and the e2e harness can assert on them:
#
#   working_style.break_minutes = { min, median, max }
#       derived from the ONE user-entered break_min:
#         median = break_min          (the user's stated duration)
#         min    = round(break_min/2) (may shrink toward this to squeeze work)
#         max    = round(break_min*1.5)(never exceed; breaks are never padded)
#       break_min is KEPT (back-compat alias = median) so older readers still work.
#
#   working_style.block_layout_policy = {
#       work_block_minutes: session_length_min,   # fixed target
#       work_blocks_fixed: true,                   # do NOT shrink mid-day
#       trim_only_at: ["end_of_day", "hard_anchor"], # the only places to trim
#       squeeze: "max",                            # fit as many full blocks as possible
#       break_default: "median",                   # default break length
#       break_may_shrink_to: "min",                # to reclaim work time
#       break_never_extend: true                   # never pad a break to fill a gap
#   }
#
# AUTO: pure local edit of the latest plans-profile JSON block, in place,
# idempotent (re-running is a no-op once break_minutes + block_layout_policy
# exist). The original is parked under .pbrain/backup/ before editing. No version
# bump (a living-document structural fold, like 0011); the owning command surfaces
# the new fields on its next run.

MIGRATION_KIND=auto

_pbrain_m0015_py() {
  command -v python3 >/dev/null 2>&1 || return 1
  export PBRAIN_M0015_MODE="$1"
  python3 - "${VAULT_DIR:-}" <<'PYEOF'
import os, re, sys, json, shutil

vault = sys.argv[1]
if not vault:
    sys.exit(1)
mode = os.environ.get("PBRAIN_M0015_MODE", "check")

# Resolve the plan-my-day profile store (mirror the command's own resolution).
plan_dir = os.environ.get("PBRAIN_PLAN_DIR") or os.path.join(vault, "life/daily-planning")
store = os.path.join(plan_dir, ".profile")
# An explicit profile-file override always wins.
explicit = os.environ.get("PBRAIN_PLAN_PROFILE_FILE")

def latest_profile():
    if explicit and os.path.isfile(explicit):
        return explicit
    if not os.path.isdir(store):
        return None
    # highest committed plans-profile.vN.md (committed: true in frontmatter)
    best = None
    best_n = -1
    for fn in os.listdir(store):
        m = re.match(r"plans-profile\.v(\d+)\.md$", fn)
        if not m:
            continue
        fp = os.path.join(store, fn)
        head = open(fp, encoding="utf-8").read(400)
        if re.search(r"^committed:\s*true", head, re.M):
            n = int(m.group(1))
            if n > best_n:
                best_n, best = n, fp
    return best

def load_json_block(text):
    m = re.search(r"```json\s*(\{.*?\})\s*```", text, re.S)
    if not m:
        return None, None
    try:
        return json.loads(m.group(1)), m
    except Exception:
        return None, m

prof = latest_profile()
if not prof:
    # Nothing to migrate (no profile yet) — vacuously done.
    sys.exit(2 if mode == "check" else 0)

text = open(prof, encoding="utf-8").read()
data, m = load_json_block(text)
if not isinstance(data, dict) or m is None:
    sys.exit(2 if mode == "check" else 0)

ws = data.get("working_style")
if not isinstance(ws, dict):
    sys.exit(2 if mode == "check" else 0)

has_triplet = isinstance(ws.get("break_minutes"), dict)
has_policy = isinstance(ws.get("block_layout_policy"), dict)
pending = not (has_triplet and has_policy)

if mode == "check":
    sys.exit(0 if pending else 2)   # 0 = work pending (applicable), 2 = nothing to do

if not pending:
    sys.exit(0)

# --- APPLY ---------------------------------------------------------------
base_break = ws.get("break_min")
if not isinstance(base_break, (int, float)):
    base_break = 30  # safe default if absent
base_break = int(round(base_break))
sess = ws.get("session_length_min")
sess = int(round(sess)) if isinstance(sess, (int, float)) else 90

if not has_triplet:
    ws["break_minutes"] = {
        "min": int(round(base_break / 2)),
        "median": base_break,
        "max": int(round(base_break * 1.5)),
    }
    # keep break_min as a back-compat alias = median
    ws["break_min"] = base_break

if not has_policy:
    ws["block_layout_policy"] = {
        "work_block_minutes": sess,
        "work_blocks_fixed": True,
        "trim_only_at": ["end_of_day", "hard_anchor"],
        "squeeze": "max",
        "break_default": "median",
        "break_may_shrink_to": "min",
        "break_never_extend": True,
    }

data["working_style"] = ws

backup = os.path.join(vault, ".pbrain", "backup", "0015_plan_break_triplet_block_policy")
os.makedirs(backup, exist_ok=True)
shutil.copy2(prof, os.path.join(backup, os.path.basename(prof) + ".before.md"))

new_block = "```json\n" + json.dumps(data, indent=2, ensure_ascii=False) + "\n```"
new_text = text[:m.start()] + new_block + text[m.end():]
tmp = prof + ".0015.tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(new_text)
os.replace(tmp, prof)
sys.stderr.write("0015 added break_minutes triplet + block_layout_policy to %s\n" % os.path.basename(prof))
sys.exit(0)
PYEOF
}

migration_applicable() {
  [[ -n "${VAULT_DIR:-}" ]] || return 1
  _pbrain_m0015_py check
}

migration_apply() {
  _pbrain_m0015_py apply
}
