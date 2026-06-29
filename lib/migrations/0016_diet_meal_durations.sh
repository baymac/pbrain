#!/usr/bin/env bash
# Migration 0016 (AUTO): diet profile meal durations + optional post-meal nap.
# PB-186.
#
# The diet profile carried meal SLOTS and meal TIMES but no DURATIONS, so
# /plan-my-day invented meal-slot lengths (e.g. a 45-min lunch). The rule: each
# meal occupies a bounded slot — default 30 min — and the user may set a longer
# per-meal duration explicitly. A post-meal nap/rest is OPTIONAL and, unless the
# user pins a fixed nap, is treated as a normal break (governed by the plans
# profile's break_minutes band).
#
# This migration adds, in the latest committed diet profile:
#   meal_minutes        — {slot: minutes} for every slot in meal_slots,
#                         defaulting each to 30 (the cap when unset). The user can
#                         later raise a specific meal's duration.
#   meal_minutes_default — 30 (the fallback for any slot/meal without an entry,
#                         and the assumption when NO diet profile exists at all).
#   post_meal_nap       — {"after": <slot|null>, "minutes": <int|null>,
#                          "fixed": false}. Off by default (after=null). When the
#                         user sets a slot + minutes and fixed=true, the planner
#                         honors that exact nap and never shrinks it; otherwise a
#                         post-meal nap is just a break within break_minutes.
#
# AUTO, idempotent (no-op once meal_minutes + post_meal_nap exist), backs up the
# original under .pbrain/backup/. No version bump (a living-document structural
# fold, like 0011/0015).

MIGRATION_KIND=auto

_pbrain_m0016_py() {
  command -v python3 >/dev/null 2>&1 || return 1
  export PBRAIN_M0016_MODE="$1"
  python3 - "${VAULT_DIR:-}" <<'PYEOF'
import os, re, sys, json, shutil

vault = sys.argv[1]
if not vault:
    sys.exit(1)
mode = os.environ.get("PBRAIN_M0016_MODE", "check")

diet_dir = os.environ.get("PBRAIN_DIET_DIR") or os.path.join(vault, "fitness/diet-tracking")
store = os.path.join(diet_dir, ".profile")
explicit = os.environ.get("PBRAIN_DIET_PROFILE_FILE")

def latest_profile():
    if explicit and os.path.isfile(explicit):
        return explicit
    if not os.path.isdir(store):
        return None
    best, best_n = None, -1
    for fn in os.listdir(store):
        m = re.match(r"diet-profile\.v(\d+)\.md$", fn)
        if not m:
            continue
        fp = os.path.join(store, fn)
        if re.search(r"^committed:\s*true", open(fp, encoding="utf-8").read(400), re.M):
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
    # No diet profile — nothing to migrate. /plan-my-day uses the 30-min default
    # at runtime; there is no file to fold into. Vacuously done.
    sys.exit(2 if mode == "check" else 0)

text = open(prof, encoding="utf-8").read()
data, m = load_json_block(text)
if not isinstance(data, dict) or m is None:
    sys.exit(2 if mode == "check" else 0)

has_minutes = isinstance(data.get("meal_minutes"), dict)
has_default = isinstance(data.get("meal_minutes_default"), int)
has_nap = isinstance(data.get("post_meal_nap"), dict)
pending = not (has_minutes and has_default and has_nap)

if mode == "check":
    sys.exit(0 if pending else 2)
if not pending:
    sys.exit(0)

# --- APPLY ---------------------------------------------------------------
slots = data.get("meal_slots")
if not isinstance(slots, list):
    # derive from meal_times keys if slots absent
    mt = data.get("meal_times")
    slots = list(mt.keys()) if isinstance(mt, dict) else []

if not has_default:
    data["meal_minutes_default"] = 30
if not has_minutes:
    data["meal_minutes"] = {s: 30 for s in slots}   # default cap; user may raise
if not has_nap:
    data["post_meal_nap"] = {"after": None, "minutes": None, "fixed": False}

backup = os.path.join(vault, ".pbrain", "backup", "0016_diet_meal_durations")
os.makedirs(backup, exist_ok=True)
shutil.copy2(prof, os.path.join(backup, os.path.basename(prof) + ".before.md"))

new_block = "```json\n" + json.dumps(data, indent=2, ensure_ascii=False) + "\n```"
new_text = text[:m.start()] + new_block + text[m.end():]
tmp = prof + ".0016.tmp"
with open(tmp, "w", encoding="utf-8") as fh:
    fh.write(new_text)
os.replace(tmp, prof)
sys.stderr.write("0016 added meal_minutes (default 30) + post_meal_nap to %s\n" % os.path.basename(prof))
sys.exit(0)
PYEOF
}

migration_applicable() {
  [[ -n "${VAULT_DIR:-}" ]] || return 1
  _pbrain_m0016_py check
}

migration_apply() {
  _pbrain_m0016_py apply
}
