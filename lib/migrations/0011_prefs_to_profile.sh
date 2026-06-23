#!/usr/bin/env bash
# Migration 0011 (AUTO): fold profile-owning commands' standing prefs into their
# versioned profile (PB-37).
#
#   old: $VAULT_DIR/.pbrain/<cmd>/prefs.md            (flat free-form markdown)
#   new: <cmd's profile>.v<N>.md  ->  top-level "prefs" array in the JSON block
#
# Only the four commands that OWN a profile are folded:
#   plan-my-day     -> plans-profile   (life/daily-planning/.profile)
#   habits          -> habits-profile  (life/habit-tracking/.profile)
#   fitness-journal -> fitness-profile (fitness/daily-tracking/.profile)
#   diet-journal    -> diet-profile    (fitness/diet-tracking/.profile)
#
# This is a MECHANICAL fold: each non-empty pref line is appended verbatim to the
# profile's "prefs" array (the generic fallback bucket). Semantic re-homing into a
# specific field is left to future pref captures (lib/self-improve.sh) — it needs
# judgement, which an AUTO migration can't do. The edit is IN PLACE on the latest
# version (committed or draft); the frontmatter version is NOT bumped (capturing a
# pref is a living-document edit, like the food/habits libraries). The original
# prefs.md and a pre-edit copy of the profile are parked under .pbrain/backup/.
#
# PB-60 — the generic "prefs" array this migration writes into is a FALLBACK
# bucket, not a final resting place. lib/prefs.sh re-dumps that array verbatim as
# a raw per-command block every run, so any folded pref that is actually a
# semantic profile field (a day-shape rule → typical_day, a working-style nuance
# → working_style, an anchor → daily_anchors) gets surfaced as raw text even
# though the command already consumes the structural copy. The right end state is
# to re-home such prefs into their field (minting the next profile version) and
# drop them from the generic array — see the PB-60 note in lib/prefs.sh. This
# migration intentionally does NOT attempt that re-homing (no judgement in an AUTO
# pass); it just lands prefs somewhere durable so nothing is lost.
#
# Profile-less commands (weekly-review, end-of-day, …) and _global/prefs.md are
# left untouched — they keep using flat prefs.md. Idempotent: once a prefs.md has
# been folded and parked, re-running is a no-op.

MIGRATION_KIND=auto
MIGRATION_OWNER=""

# Run the worker in either "check" (exit 0 iff work pending) or "apply" mode.
_pbrain_m0011_py() {
  command -v python3 >/dev/null 2>&1 || return 1
  PBRAIN_M0011_MODE="$1" \
  PBRAIN_M0011_PREFS_ROOT="${PBRAIN_PREFS_DIR:-${VAULT_DIR:-}/.pbrain}" \
  python3 - "${VAULT_DIR:-}" <<'PYEOF'
import os, re, sys, json, shutil

vault = sys.argv[1]
if not vault:
    sys.exit(1)
mode = os.environ.get("PBRAIN_M0011_MODE", "check")
prefs_root = os.environ.get("PBRAIN_M0011_PREFS_ROOT") or os.path.join(vault, ".pbrain")
backup = os.path.join(vault, ".pbrain", "backup", "0011_prefs_to_profile")

# (cmd, dir_env, dir_default, base, file_env)
COMMANDS = [
    ("plan-my-day", "PBRAIN_PLAN_DIR", "life/daily-planning", "plans-profile", "PBRAIN_PLAN_PROFILE_FILE"),
    ("habits", "PBRAIN_HABIT_TRACK_DIR", "life/habit-tracking", "habits-profile", "PBRAIN_HABITS_PROFILE_FILE"),
    ("fitness-journal", "PBRAIN_FITNESS_DIR", "fitness/daily-tracking", "fitness-profile", None),
    ("diet-journal", "PBRAIN_DIET_DIR", "fitness/diet-tracking", "diet-profile", "PBRAIN_DIET_PROFILE_FILE"),
]


def store_dir(dir_env, dir_default):
    base = os.environ.get(dir_env) or os.path.join(vault, dir_default)
    return os.path.join(base, ".profile")


def latest_profile(dir_env, dir_default, base, file_env):
    # Explicit per-command file override wins (matches the command's own resolve).
    if file_env:
        fp = os.environ.get(file_env)
        if fp and os.path.isfile(fp):
            return fp
    store = store_dir(dir_env, dir_default)
    if not os.path.isdir(store):
        return None
    best, best_n = None, -1
    pat = re.compile(r"^" + re.escape(base) + r"\.v(\d+)\.md$")
    for name in os.listdir(store):
        m = pat.match(name)
        if m:
            n = int(m.group(1))
            if n > best_n:
                best, best_n = os.path.join(store, name), n
    return best


def prefs_entries(path):
    """Each non-empty, non-heading line of the prefs.md -> one entry (bullet
    markers stripped)."""
    out = []
    try:
        text = open(path, encoding="utf-8").read()
    except Exception:
        return out
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("#"):          # markdown heading — skip
            continue
        line = re.sub(r"^[-*•]\s+", "", line)  # strip bullet marker
        line = line.strip()
        if line:
            out.append(line)
    return out


def load_json_block(text):
    m = re.search(r"```json\s*\n(.*?)```", text, re.DOTALL)
    if not m:
        return None, None
    try:
        return json.loads(m.group(1)), m
    except Exception:
        return None, m


def pending_pairs():
    """Yield (cmd, prefs_md, profile, entries) for each cmd with work to do:
    a non-empty prefs.md, a resolvable profile, and at least one entry not yet
    present in the profile's prefs array."""
    for cmd, dir_env, dir_default, base, file_env in COMMANDS:
        prefs_md = os.path.join(prefs_root, cmd, "prefs.md")
        if not (os.path.isfile(prefs_md) and os.path.getsize(prefs_md) > 0):
            continue
        entries = prefs_entries(prefs_md)
        if not entries:
            continue
        profile = latest_profile(dir_env, dir_default, base, file_env)
        if not profile:
            continue
        data, m = load_json_block(open(profile, encoding="utf-8").read())
        if not isinstance(data, dict) or m is None:
            continue
        existing = data.get("prefs")
        existing = existing if isinstance(existing, list) else []
        existing_s = {str(x).strip() for x in existing}
        new = [e for e in entries if e not in existing_s]
        # Work pending if there are entries to add OR the prefs.md still needs
        # parking (already-folded but un-moved, e.g. an interrupted prior run).
        yield (cmd, prefs_md, profile, entries, new)


pairs = list(pending_pairs())

if mode == "check":
    sys.exit(0 if pairs else 1)

# apply
if not pairs:
    sys.exit(0)
os.makedirs(backup, exist_ok=True)
migrated = []
for cmd, prefs_md, profile, entries, new in pairs:
    text = open(profile, encoding="utf-8").read()
    data, m = load_json_block(text)
    if not isinstance(data, dict) or m is None:
        continue
    arr = data.get("prefs")
    arr = arr if isinstance(arr, list) else []
    seen = {str(x).strip() for x in arr}
    for e in entries:
        if e not in seen:
            arr.append(e)
            seen.add(e)
    data["prefs"] = arr
    # Back up the profile before editing, then splice the JSON block in place
    # (frontmatter and surrounding markdown untouched; no version bump).
    shutil.copy2(profile, os.path.join(backup, "%s-%s.before.md" % (cmd, os.path.basename(profile))))
    new_block = "```json\n" + json.dumps(data, indent=2, ensure_ascii=False) + "\n```"
    new_text = text[:m.start()] + new_block + text[m.end():]
    tmp = profile + ".0011.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(new_text)
    os.replace(tmp, profile)
    # Park the original prefs.md (move, non-destructive — kept in backup).
    shutil.move(prefs_md, os.path.join(backup, "%s-prefs.md" % cmd))
    migrated.append(cmd)

if migrated:
    sys.stderr.write("0011 folded prefs into profiles: " + ", ".join(migrated) + "\n")
sys.exit(0)
PYEOF
}

migration_applicable() {
  [[ -n "${VAULT_DIR:-}" ]] || return 1
  _pbrain_m0011_py check
}

migration_apply() {
  _pbrain_m0011_py apply
}
