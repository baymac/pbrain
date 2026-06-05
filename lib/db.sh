#!/usr/bin/env bash
# pbrain shared SQLite store — sourced by lib/vault.sh.
#
# One small local SQLite database under ~/.config/pbrain holds operational
# state that benefits from queryable storage rather than markdown: the habit
# EVENT LOG and the reminders QUEUE. Human-facing definitions (the habits
# profile, the food library) stay as vault markdown so they're browsable in
# Obsidian — only the event/queue data lives here. The DB is local-only (not in
# the vault) by design: it's per-machine operational state, like the diet /
# fitness JSON configs already in ~/.config/pbrain.
#
# Exposes:
#   PBRAIN_DB_FILE        resolved DB path (exported)
#   pbrain_db_file        echo the resolved path
#   pbrain_db_init        create the schema idempotently (CREATE TABLE IF NOT EXISTS)
#
# Requires python3 (already a hard pbrain dependency); sqlite3 is stdlib, so no
# external package and no dependency on the sqlite3 CLI binary.
#
# Like the other lib/ helpers, this NEVER exits non-zero and NEVER prints to
# stderr on the happy path — it is sourced into every command, which runs under
# `set -euo pipefail`, so a fault here must not take the command down.
#
# Env knobs:
#   PBRAIN_DB_FILE   override the DB path (default ~/.config/pbrain/pbrain.db)

PBRAIN_DB_FILE="${PBRAIN_DB_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/pbrain.db}"
export PBRAIN_DB_FILE

pbrain_db_file() { printf '%s\n' "$PBRAIN_DB_FILE"; }

# Create the schema if it doesn't exist yet. Idempotent: re-running on an
# existing DB is a no-op. Safe to call at the top of any command that touches
# the DB. Returns 0 even if python3 is missing or the DB can't be opened.
pbrain_db_init() {
  command -v python3 >/dev/null 2>&1 || return 0
  local db="${1:-$PBRAIN_DB_FILE}"
  mkdir -p "$(dirname "$db")" 2>/dev/null || true
  python3 - "$db" <<'PYEOF' 2>/dev/null || true
import sqlite3, sys
db = sys.argv[1]
try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA busy_timeout=5000")
    con.executescript("""
    -- habit_events is keyed by a STABLE habit_id (a slug minted once per habit
    -- and never changed), NOT by the display name. Renaming a habit changes only
    -- its name in the profile; its history stays attached via habit_id. The
    -- `habit` column is a name SNAPSHOT at log time (handy for history listings
    -- and debugging) — it is never the join key. Fresh DBs get this shape; older
    -- DBs are migrated to it below.
    CREATE TABLE IF NOT EXISTS habit_events (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        habit_id    TEXT,                          -- stable slug; the real key
        habit       TEXT NOT NULL,                 -- display-name snapshot at log time
        occurred_on TEXT NOT NULL,                 -- YYYY-MM-DD (local)
        count       INTEGER NOT NULL DEFAULT 1,    -- occurrence count (times done that day)
        amount      REAL,                          -- measured value for that day (e.g. 2.5 L); NULL = unmeasured habit
        source      TEXT NOT NULL DEFAULT '',      -- command that logged it
        note        TEXT,
        created_at  TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_habit_events_habit ON habit_events(habit);
    CREATE INDEX IF NOT EXISTS idx_habit_events_date  ON habit_events(occurred_on);

    CREATE TABLE IF NOT EXISTS reminders (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        text       TEXT NOT NULL,
        due_at     TEXT,                            -- 'YYYY-MM-DD HH:MM' or 'YYYY-MM-DD' (local); NULL = someday
        repeat     TEXT,                            -- daily|weekdays|weekly|monthly|NULL (legacy token; cron supersedes it)
        status     TEXT NOT NULL DEFAULT 'pending', -- pending|done|cancelled
        source     TEXT,
        created_at TEXT NOT NULL,
        fired_at   TEXT,                            -- last time a notification fired (NULL = not yet)
        done_at    TEXT,
        block_seconds INTEGER,                      -- NULL = normal notification reminder; set = full-screen blocking overlay that stays/counts down this many seconds (0 = until dismissed)
        hold_seconds  INTEGER,                      -- seconds the user must hold space to skip a blocking overlay (NULL = default 5)
        cron       TEXT                             -- 5-field cron expr (min hour dom month dow); recurrence source of truth when set. due_at holds the NEXT computed fire time.
    );
    CREATE INDEX IF NOT EXISTS idx_reminders_status ON reminders(status);
    CREATE INDEX IF NOT EXISTS idx_reminders_due    ON reminders(due_at);
    """)

    # --- habit_events migration: key by stable habit_id ------------------
    # Older DBs (created before the habit_id redesign) have habit_events
    # without a habit_id column and a UNIQUE index on (habit, occurred_on).
    # Migrate them in place, exactly once. Guarded by a PRAGMA table_info
    # check so this is a no-op on fresh and already-migrated DBs.
    #
    #   ┌─ old row ───────────────┐        ┌─ migrated row ─────────────────┐
    #   │ habit="Meditate"        │   ─►   │ habit_id="meditate"            │
    #   │ occurred_on, count, ... │        │ habit="Meditate" (snapshot)    │
    #   └─────────────────────────┘        │ occurred_on, count, ...        │
    #                                       └────────────────────────────────┘
    #
    # The backfill slug MUST match commands/habits.sh + lib/habits.sh
    # (pbrain_habit_slug) so migrated events line up with the profile's
    # habit ids. Algorithm is pinned by tests/db.bats + tests/habits.bats.
    cols = [r[1] for r in con.execute("PRAGMA table_info(habit_events)").fetchall()]
    if cols and "habit_id" not in cols:
        import re
        con.execute("ALTER TABLE habit_events ADD COLUMN habit_id TEXT")

        def _slug(name):
            s = re.sub(r"[^a-z0-9]+", "-", (name or "").strip().lower()).strip("-")
            return s or "habit"

        for rid, nm in con.execute(
            "SELECT id, habit FROM habit_events WHERE habit_id IS NULL OR habit_id=''"
        ).fetchall():
            con.execute("UPDATE habit_events SET habit_id=? WHERE id=?", (_slug(nm), rid))

        # Two distinct names can slugify to the same id on the same day
        # (e.g. "Walk" and "walk!"). Collapse such collisions to one row
        # (keep the earliest) before the unique index goes on.
        con.execute(
            "DELETE FROM habit_events WHERE id NOT IN "
            "(SELECT MIN(id) FROM habit_events GROUP BY habit_id, occurred_on)"
        )
        # Drop the old (habit, occurred_on) unique index; the new one below
        # re-keys on (habit_id, occurred_on).
        con.execute("DROP INDEX IF EXISTS idx_habit_events_uniq")

    # --- habit_events migration: add the measured `amount` column ---------
    # First-class quantity tracking stores a per-day measured value (e.g.
    # 2.5 L of water) here; older DBs predate it. Add it once, nullable, so
    # existing rows (unmeasured) stay NULL. Guarded by the same table_info
    # check so it's a no-op on fresh and already-migrated DBs.
    if cols and "amount" not in cols:
        con.execute("ALTER TABLE habit_events ADD COLUMN amount REAL")

    # --- reminders migration: add the blocking-overlay columns -------------
    # /remind-blocking stores full-screen "take a break" reminders in this same
    # table: block_seconds turns a row into a blocking overlay (how long it
    # stays / counts down; 0 = until dismissed) and hold_seconds sets the
    # hold-space-to-skip duration. Older DBs predate both; add them once,
    # nullable, so existing notification reminders stay NULL (= non-blocking).
    # Guarded by table_info so it's a no-op on fresh and already-migrated DBs.
    rcols = [r[1] for r in con.execute("PRAGMA table_info(reminders)").fetchall()]
    if rcols and "block_seconds" not in rcols:
        con.execute("ALTER TABLE reminders ADD COLUMN block_seconds INTEGER")
    if rcols and "hold_seconds" not in rcols:
        con.execute("ALTER TABLE reminders ADD COLUMN hold_seconds INTEGER")
    # cron: a 5-field cron expression driving flexible recurrence (multi-time,
    # multi-day, step ranges) for /remind-blocking. due_at carries the next
    # computed fire; the tick recomputes it from cron after each fire. Older DBs
    # predate the column; add it once, nullable. No-op on fresh/migrated DBs.
    if rcols and "cron" not in rcols:
        con.execute("ALTER TABLE reminders ADD COLUMN cron TEXT")

    # habit_id indexes — created after the column is guaranteed to exist on
    # every code path (fresh CREATE TABLE above, or the ALTER just now).
    con.executescript("""
    CREATE INDEX IF NOT EXISTS idx_habit_events_hid ON habit_events(habit_id);
    -- one row per (habit_id, day): logging the same habit again that day
    -- (from any command) updates the row rather than adding a second event.
    CREATE UNIQUE INDEX IF NOT EXISTS idx_habit_events_uniq
        ON habit_events(habit_id, occurred_on);
    """)

    con.commit()
    con.close()
except Exception:
    pass
PYEOF
  return 0
}
