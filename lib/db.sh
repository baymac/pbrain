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

# /laptop-tracking gets its OWN database (Decision 1A), isolated from the shared
# pbrain.db that habits/reminders use. The tracker daemon is the only resident,
# high-churn writer in pbrain (a heartbeat UPDATE every ~10s while active); giving
# it a separate file means its WAL traffic and any corruption blast radius never
# touch the habits/reminders store. It is local-only and never synced to the vault.
PBRAIN_TRACKER_DB_FILE="${PBRAIN_TRACKER_DB_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/tracker.db}"
export PBRAIN_TRACKER_DB_FILE

pbrain_db_file() { printf '%s\n' "$PBRAIN_DB_FILE"; }
pbrain_tracker_db_file() { printf '%s\n' "$PBRAIN_TRACKER_DB_FILE"; }

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

    -- habit_reminders is the per-day map between a linked habit and the Apple
    -- Reminder that notifies it. A linked habit gets ONE one-shot reminder per
    -- scheduled day (not a recurring Apple reminder): the reminder is purely a
    -- notification + a familiar checkbox surface — pbrain owns the habit data.
    -- One row per (habit_id, date): reminder_id is the EKReminder for that day,
    -- status tracks our side of the sync. The PK is the idempotency guard for
    -- "create today's reminder if it's not already there".
    CREATE TABLE IF NOT EXISTS habit_reminders (
        habit_id    TEXT NOT NULL,                 -- stable habit slug (profile id)
        occurred_on TEXT NOT NULL,                 -- YYYY-MM-DD (local) the reminder is for
        reminder_id TEXT NOT NULL,                 -- EKReminder calendarItemIdentifier (the one-shot)
        status      TEXT NOT NULL DEFAULT 'pending',-- pending | done | cancelled
        created_at  TEXT NOT NULL,
        resolved_at TEXT,                          -- when it reached done/cancelled
        PRIMARY KEY (habit_id, occurred_on)
    );
    CREATE INDEX IF NOT EXISTS idx_habit_reminders_date ON habit_reminders(occurred_on);

    -- /remind-blocking is the SOLE owner of these tables (/remind is Apple
    -- Calendar-only and never touches the DB). The model is split in two:
    --
    --   reminder_schedules  = a recurring SERIES (the cadence). One row per
    --                         recurring reminder; cron is the source of truth.
    --                         next_due_at caches the next computed fire and is
    --                         advanced every time an occurrence is processed —
    --                         whether it actually fired or was missed — so the
    --                         series can NEVER die from a skipped/locked fire.
    --   reminders           = individual OCCURRENCES (instances / the log). One
    --                         row per fire. schedule_id links back to the series
    --                         (NULL for true one-shots). Each instance carries
    --                         its own terminal status, so per-occurrence history
    --                         survives and resolving one never touches the series.
    CREATE TABLE IF NOT EXISTS reminder_schedules (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        text          TEXT NOT NULL,
        cron          TEXT NOT NULL,                  -- 5-field cron expr (min hour dom month dow)
        block_seconds INTEGER NOT NULL DEFAULT 0,     -- overlay stay/countdown secs (0 = until skipped)
        hold_seconds  INTEGER NOT NULL DEFAULT 3,     -- seconds the user holds Control to skip
        status        TEXT NOT NULL DEFAULT 'active', -- active|cancelled|deleted (deleted = user-cancelled)
        next_due_at   TEXT,                           -- next computed fire 'YYYY-MM-DD HH:MM' (cache)
        source        TEXT,
        created_at    TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_schedules_status ON reminder_schedules(status);

    CREATE TABLE IF NOT EXISTS reminders (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        schedule_id   INTEGER,                        -- reminder_schedules.id; NULL = one-shot
        text          TEXT NOT NULL,
        due_at        TEXT NOT NULL,                  -- when this occurrence fires 'YYYY-MM-DD HH:MM' (local)
        block_seconds INTEGER NOT NULL DEFAULT 0,     -- overlay stay/countdown secs (0 = until skipped)
        hold_seconds  INTEGER NOT NULL DEFAULT 3,     -- seconds the user holds Control to skip
        status        TEXT NOT NULL DEFAULT 'pending',-- pending|done|skipped|missed|cancelled
        fired_at      TEXT,                           -- when the overlay was shown (NULL = never shown)
        resolved_at   TEXT,                           -- when it reached a terminal state
        source        TEXT,
        created_at    TEXT NOT NULL,
        UNIQUE(schedule_id, due_at)                   -- one occurrence per (series, time); blocks double-spawn
    );
    CREATE INDEX IF NOT EXISTS idx_reminders_status ON reminders(status);
    CREATE INDEX IF NOT EXISTS idx_reminders_due    ON reminders(due_at);
    -- idx_reminders_sched is on the new schedule_id column, so it's created
    -- AFTER the redesign migration below (an old-shape table lacks that column).
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

    # --- reminders redesign migration: conflated row → schedule + instances ---
    # The old `reminders` table conflated the recurrence definition and the
    # current occurrence into ONE row (rewritten in place each fire). The new
    # model splits them (reminder_schedules + per-occurrence reminders). Detect
    # the old shape by the absence of `schedule_id` and rebuild ONCE. Only PENDING
    # BLOCKING rows carry over — non-blocking rows were the old /remind
    # notification queue, now dead (/remind is Calendar-only). One-time + guarded,
    # so it's a no-op on fresh DBs (which already have the new shape) and on
    # already-migrated DBs.
    rcols = [r[1] for r in con.execute("PRAGMA table_info(reminders)").fetchall()]
    if rcols and "schedule_id" not in rcols:
        old = con.execute(
            "SELECT text, due_at, repeat, cron, block_seconds, hold_seconds, source, created_at "
            "FROM reminders WHERE status='pending' AND block_seconds IS NOT NULL AND due_at IS NOT NULL"
        ).fetchall()
        con.execute("DROP TABLE reminders")
        con.executescript("""
        CREATE TABLE reminders (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            schedule_id   INTEGER,
            text          TEXT NOT NULL,
            due_at        TEXT NOT NULL,
            block_seconds INTEGER NOT NULL DEFAULT 0,
            hold_seconds  INTEGER NOT NULL DEFAULT 5,
            status        TEXT NOT NULL DEFAULT 'pending',
            fired_at      TEXT,
            resolved_at   TEXT,
            source        TEXT,
            created_at    TEXT NOT NULL,
            UNIQUE(schedule_id, due_at)
        );
        CREATE INDEX IF NOT EXISTS idx_reminders_status ON reminders(status);
        CREATE INDEX IF NOT EXISTS idx_reminders_due    ON reminders(due_at);
        CREATE INDEX IF NOT EXISTS idx_reminders_sched  ON reminders(schedule_id);
        """)
        for text, due_at, repeat, cron, block_seconds, hold_seconds, source, created_at in old:
            bs = int(block_seconds or 0)
            hs = int(hold_seconds or 3)
            # Legacy `repeat` token (daily/weekdays/weekly/monthly) → cron. The
            # new model is cron-only; map the four old tokens onto the due time.
            rep = (repeat or "").strip().lower()
            if not cron and rep:
                hh, mm = 9, 0
                try:
                    import datetime as _dt
                    hh, mm = _dt.datetime.strptime(due_at.strip(), "%Y-%m-%d %H:%M").time().hour, \
                             _dt.datetime.strptime(due_at.strip(), "%Y-%m-%d %H:%M").time().minute
                except Exception:
                    pass
                cron = {"daily":    f"{mm} {hh} * * *",
                        "weekdays": f"{mm} {hh} * * 1-5",
                        "weekly":   f"{mm} {hh} * * *",   # best-effort; user can re-add for a specific weekday
                        "monthly":  f"{mm} {hh} 1 * *"}.get(rep)
            if cron:
                sc = con.execute(
                    "INSERT INTO reminder_schedules (text, cron, block_seconds, hold_seconds, status, next_due_at, source, created_at) "
                    "VALUES (?,?,?,?, 'active', ?, ?, ?)",
                    (text, cron, bs, hs, due_at, source, created_at or due_at),
                )
                con.execute(
                    "INSERT INTO reminders (schedule_id, text, due_at, block_seconds, hold_seconds, status, source, created_at) "
                    "VALUES (?,?,?,?,?, 'pending', ?, ?)",
                    (sc.lastrowid, text, due_at, bs, hs, source, created_at or due_at),
                )
            else:
                con.execute(
                    "INSERT INTO reminders (schedule_id, text, due_at, block_seconds, hold_seconds, status, source, created_at) "
                    "VALUES (NULL,?,?,?,?, 'pending', ?, ?)",
                    (text, due_at, bs, hs, source, created_at or due_at),
                )

    # --- reminders: add mark_done column (Option-hold-to-done mode) -----------
    # Older DBs predate the mark-done mode. Add the column once, with a DEFAULT
    # of 0 (duration-based, the original behaviour) so existing rows are unaffected.
    rcols2 = [r[1] for r in con.execute("PRAGMA table_info(reminders)").fetchall()]
    if rcols2 and "mark_done" not in rcols2:
        con.execute("ALTER TABLE reminders ADD COLUMN mark_done INTEGER NOT NULL DEFAULT 0")
    scols = [r[1] for r in con.execute("PRAGMA table_info(reminder_schedules)").fetchall()]
    if scols and "mark_done" not in scols:
        con.execute("ALTER TABLE reminder_schedules ADD COLUMN mark_done INTEGER NOT NULL DEFAULT 0")

    # habit_id indexes — created after the column is guaranteed to exist on
    # every code path (fresh CREATE TABLE above, or the ALTER just now).
    con.executescript("""
    CREATE INDEX IF NOT EXISTS idx_habit_events_hid ON habit_events(habit_id);
    -- one row per (habit_id, day): logging the same habit again that day
    -- (from any command) updates the row rather than adding a second event.
    CREATE UNIQUE INDEX IF NOT EXISTS idx_habit_events_uniq
        ON habit_events(habit_id, occurred_on);
    -- reminders.schedule_id index — safe now that the column is guaranteed to
    -- exist on every path (fresh new-shape CREATE, or the redesign rebuild).
    CREATE INDEX IF NOT EXISTS idx_reminders_sched ON reminders(schedule_id);
    """)

    con.commit()
    con.close()
except Exception:
    pass
PYEOF
  return 0
}

# Create the laptop-tracking schema in its OWN database (Decision 1A). Idempotent
# CREATE TABLE IF NOT EXISTS; safe to call at the top of any tracker codepath and
# from the daemon's startup. WAL + busy_timeout=5000 on the connection, matching
# the shared store — two processes touch tracker.db (the resident Swift writer and
# the brief python renderer), so both must agree on the journal mode and timeout.
# Returns 0 even if python3 is missing or the DB can't be opened.
#
# tracker_segments holds ONE row per (app, host) ACTIVE span (Decision T1: only
# active time is persisted; away/idle/locked/asleep is the ABSENCE of a row and is
# derived from the gap between segments at render time). The daemon stores RAW
# signals (Decision 3A) — raw_host straight from AppleScript, no normalization;
# the python renderer normalizes the domain and classifies active/away. The
# attribution enum (Decision T2) explains any browser row whose domain is NULL.
pbrain_tracker_db_init() {
  command -v python3 >/dev/null 2>&1 || return 0
  local db="${1:-$PBRAIN_TRACKER_DB_FILE}"
  mkdir -p "$(dirname "$db")" 2>/dev/null || true
  python3 - "$db" <<'PYEOF' 2>/dev/null || true
import sqlite3, sys
db = sys.argv[1]
try:
    con = sqlite3.connect(db, timeout=5)
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA busy_timeout=5000")
    con.executescript("""
    CREATE TABLE IF NOT EXISTS tracker_segments (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        started_at    INTEGER NOT NULL,   -- epoch seconds, UTC
        ended_at      INTEGER,            -- epoch seconds, UTC; NULL = currently-open active row
        occurred_on   TEXT NOT NULL,      -- YYYY-MM-DD (LOCAL day-bucket key; midnight-split)
        app_bundle_id TEXT,               -- raw bundle id (e.g. com.google.Chrome); NULL if none
        app_name      TEXT,               -- raw localized display-name snapshot
        raw_host      TEXT,               -- raw URL host from AppleScript; NULL if not applicable
        raw_path      TEXT,               -- raw "host/path[?v=…]" for page-level rollup; NULL if not applicable
        attribution   TEXT NOT NULL DEFAULT 'ok'  -- ok|tcc_denied|timeout|non_web|not_browser
    );
    -- Day-bucket reads (the renderer queries one occurred_on at a time).
    CREATE INDEX IF NOT EXISTS idx_tracker_seg_day ON tracker_segments(occurred_on);
    -- Startup sweep finds the (at most one) dangling open row fast.
    CREATE INDEX IF NOT EXISTS idx_tracker_seg_open ON tracker_segments(ended_at);
    """)
    con.commit()
    con.close()
except Exception:
    pass
PYEOF
  return 0
}
