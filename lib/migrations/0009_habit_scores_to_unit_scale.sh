#!/usr/bin/env bash
# Migration 0009 (AUTO, owner: habits): rescale historical scored-habit values
# from the old 0–100 scale to the unit 0.0–1.0 scale.
#
# score_from_spec now returns a 0–1 unit score for EVERY scored habit (only the
# model differs); the seed targets/ladders moved to 0–1 too. Historical scores
# already logged on the 0–100 scale (Deep work 82, Sleep well 50, Train 89,
# Supplements 67, …) must be divided by 100 so weekly/monthly rollups don't mix
# scales. Eat-clean's slip_ladder always produced 0–1, so its rows are already
# correct and are left alone (the >1 guard skips them).
#
# Scored values live in THREE places that must stay consistent:
#   • the active habits PROFILE — each scored habit's measure_target (the 0–1
#     goal line) and, for ladder models (deviation/slip_ladder), the ladder
#     RUNGS, which score_from_spec returns verbatim. A 0–100 ladder left in the
#     profile would keep scoring 0–100 forever, so the rungs themselves move to
#     0–1 ([100,90,75,50,25,0] → [1,0.9,0.75,0.5,0.25,0]).
#   • the md Count cell in life/habit-tracking/<date>.md  (the source of truth;
#     `consolidate` re-derives the DB from it, so leaving the md on 0–100 would
#     let a future re-consolidate reintroduce old-scale numbers), and
#   • habit_events.amount in the SQLite store (what rollups/scores read now).
# All three are rescaled. A habit is treated as on the 0–100 scale when its
# ladder has a rung > 1, or (for ratio models) its measure_target > 1. eat-clean
# keeps its existing slip_ladder [1,0.6,0.3,0] (already 0–1) and its own
# measure_target untouched — its rungs ≤ 1 mark it as not-0–100. Measured
# amounts (Water 2.5 L, Sugar 45 g) are never touched (their habits aren't
# scored). The derived Progress / Criteria md columns regenerate on the next
# `track` for a date; this pass fixes the stored profile + Count + DB.
#
# Idempotent + non-destructive: the DB and every edited md file are copied under
# .pbrain/backup/ first. Applicable while any scored row (md or DB) still reads
# > 1; once all are ≤ 1 it stops firing.

MIGRATION_KIND=auto
MIGRATION_OWNER="habits"

_pbrain_m0009_profile() {
  if declare -F pbrain_habits_profile_file >/dev/null 2>&1; then
    pbrain_habits_profile_file
    return 0
  fi
  local f store latest
  f="${PBRAIN_HABITS_PROFILE_FILE:-}"
  if [[ -n "$f" && -f "$f" ]]; then printf '%s\n' "$f"; return 0; fi
  store="${PBRAIN_HABIT_TRACK_DIR:-$VAULT_DIR/life/habit-tracking}/.profile"
  latest="$(ls -1 "$store"/habits-profile.v*.md 2>/dev/null \
            | sed -E 's/.*habits-profile\.v([0-9]+)\.md/\1 &/' \
            | sort -n | tail -n1 | cut -d' ' -f2-)"
  if [[ -n "$latest" && -f "$latest" ]]; then printf '%s\n' "$latest"; return 0; fi
  [[ -f "$VAULT_DIR/life/Habits Profile.md" ]] && printf '%s\n' "$VAULT_DIR/life/Habits Profile.md"
  return 0
}

_pbrain_m0009_trackdir() {
  printf '%s\n' "${PBRAIN_HABIT_TRACK_DIR:-$VAULT_DIR/life/habit-tracking}"
}

_pbrain_m0009_db() {
  printf '%s\n' "${PBRAIN_DB_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/pbrain.db}"
}

# Shared Python core. argv: <mode> <profile> <trackdir> <db> <backupdir>
# mode "check" -> exit 0 iff there is work to do; "apply" -> do the rescale.
_pbrain_m0009_py() {
  python3 - "$1" "$(_pbrain_m0009_profile)" "$(_pbrain_m0009_trackdir)" \
                 "$(_pbrain_m0009_db)" "$VAULT_DIR/.pbrain/backup" <<'PYEOF'
import json, os, re, sys, glob, shutil, sqlite3

mode, profile, trackdir, db, backup = sys.argv[1:6]

# --- scored-habit name/id sets from the active profile -----------------------
scored_ids, scored_names = set(), set()
try:
    with open(profile) as fh:
        m = re.search(r"```json\s*\n(.*?)```", fh.read(), re.DOTALL)
    data = json.loads(m.group(1)) if m else {}
    for h in (data.get("habits") or []):
        if isinstance(h.get("scoring"), dict):
            hid = str(h.get("id", "")).strip()
            nm = str(h.get("name", "")).strip().lower()
            if hid:
                scored_ids.add(hid)
            if nm:
                scored_names.add(nm)
except Exception:
    pass

def is_float_gt1(s):
    s = (s or "").strip()
    try:
        return float(s) > 1.0
    except (TypeError, ValueError):
        return False

def _num(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None

# --- scan / edit the active habits profile -----------------------------------
# A scored habit is on the 0–100 scale when its ladder has a rung > 1, or (for
# ratio models with no 0–1 ladder) its measure_target > 1. Those get rescaled:
# every ladder rung and the measure_target are divided by 100. eat-clean's
# ladder rungs are ≤ 1, so it (and its own measure_target) is left untouched.
def process_profile(edit):
    try:
        with open(profile) as fh:
            ptext = fh.read()
    except Exception:
        return False
    m = re.search(r"(```json\s*\n)(.*?)(```)", ptext, re.DOTALL)
    if not m:
        return False
    try:
        pdata = json.loads(m.group(2))
    except Exception:
        return False
    changed = False
    for h in (pdata.get("habits") or []):
        sc = h.get("scoring")
        if not isinstance(sc, dict):
            continue
        ladder = sc.get("ladder")
        has_ladder = isinstance(ladder, list) and bool(ladder)
        ladder_is_0_100 = has_ladder and any((_num(v) or 0) > 1 for v in ladder)
        mt = _num(h.get("measure_target"))
        on_0_100 = ladder_is_0_100 or (not has_ladder and mt is not None and mt > 1)
        if not on_0_100:
            continue  # eat-clean (unit ladder) / already-unit ratio
        if not edit:
            return True
        if ladder_is_0_100:
            sc["ladder"] = [round(_num(v) / 100.0, 2) if _num(v) is not None else v
                            for v in ladder]
            changed = True
        if mt is not None and mt > 1:
            h["measure_target"] = round(mt / 100.0, 2)
            changed = True
    if edit and changed:
        os.makedirs(backup, exist_ok=True)
        shutil.copy2(profile, os.path.join(backup, os.path.basename(profile) + ".pre-0009"))
        new_json = json.dumps(pdata, indent=2)
        out = ptext[:m.start()] + m.group(1) + new_json + "\n" + m.group(3) + ptext[m.end():]
        with open(profile, "w") as fh:
            fh.write(out)
    return changed

# --- scan / edit the dated md Count cells ------------------------------------
# Table: | Habit | Criteria | Progress | Done | Count | Note |  (Count = idx 4
# among the cells between the outer pipes). Only scored-habit rows with a
# Count > 1 are rescaled.
def md_files():
    return sorted(glob.glob(os.path.join(trackdir, "*.md")))

def process_md(path, edit):
    try:
        with open(path) as fh:
            lines = fh.readlines()
    except Exception:
        return False
    changed = False
    for i, line in enumerate(lines):
        if not line.lstrip().startswith("|"):
            continue
        # split the table row into cells (drop the empty edges from outer pipes)
        raw = line.rstrip("\n")
        cells = raw.split("|")
        if len(cells) < 7:
            continue
        name = cells[1].strip().lower()
        if name in ("habit", "") or set(cells[1].strip()) <= {"-", " "}:
            continue  # header / separator
        if name not in scored_names:
            continue
        count = cells[5].strip()
        if not is_float_gt1(count):
            continue
        if not edit:
            return True  # work exists (check mode)
        new_val = round(float(count) / 100.0, 2)
        new_txt = ("%g" % new_val)
        # preserve the cell's surrounding spacing
        cells[5] = cells[5].replace(count, new_txt, 1)
        lines[i] = "|".join(cells) + "\n"
        changed = True
    if edit and changed:
        os.makedirs(os.path.join(backup, "habit-tracking"), exist_ok=True)
        shutil.copy2(path, os.path.join(backup, "habit-tracking", os.path.basename(path)))
        with open(path, "w") as fh:
            fh.writelines(lines)
    return changed

# --- scan / edit the DB ------------------------------------------------------
def db_has_work():
    if not scored_ids or not os.path.exists(db):
        return False
    try:
        con = sqlite3.connect(db, timeout=5)
        q = ("SELECT COUNT(*) FROM habit_events WHERE amount > 1.0 AND habit_id IN (%s)"
             % ",".join("?" * len(scored_ids)))
        n = con.execute(q, list(scored_ids)).fetchone()[0]
        con.close()
        return n > 0
    except Exception:
        return False

def db_rescale():
    if not db_has_work():
        return False
    os.makedirs(backup, exist_ok=True)
    shutil.copy2(db, os.path.join(backup, "pbrain.db.pre-0009"))
    con = sqlite3.connect(db, timeout=5)
    con.execute("PRAGMA busy_timeout=5000")
    q = ("UPDATE habit_events SET amount = round(amount / 100.0, 2) "
         "WHERE amount > 1.0 AND habit_id IN (%s)" % ",".join("?" * len(scored_ids)))
    con.execute(q, list(scored_ids))
    con.commit()
    con.close()
    return True

if not scored_names and not scored_ids:
    sys.exit(1)  # nothing scored -> nothing to do

if mode == "check":
    if process_profile(edit=False) or db_has_work():
        sys.exit(0)
    for p in md_files():
        if process_md(p, edit=False):
            sys.exit(0)
    sys.exit(1)

# apply
did = process_profile(edit=True)
if db_rescale():
    did = True
for p in md_files():
    if process_md(p, edit=True):
        did = True
sys.exit(0)
PYEOF
}

migration_applicable() {
  command -v python3 >/dev/null 2>&1 || return 1
  local profile
  profile="$(_pbrain_m0009_profile)"
  [[ -n "$profile" && -f "$profile" ]] || return 1
  _pbrain_m0009_py check
}

migration_apply() {
  command -v python3 >/dev/null 2>&1 || return 1
  mkdir -p "$VAULT_DIR/.pbrain/backup"
  _pbrain_m0009_py apply || return 1
  echo "Rescaled historical scored-habit values to the 0–1 unit scale (md + DB; originals parked in .pbrain/backup/)"
}
