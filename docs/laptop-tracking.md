# /laptop-tracking

A resident macOS daemon that records, per day, **which app you're in and for how long**, and for the browser **which website (domain)** your time goes to — excluding time the machine is away. At end of day (or on demand) it renders a usage summary into the vault.

The honesty is the point. A naive "frontmost app" logger lies twice: it counts a two-hour movie as idle (no keystrokes), and it flattens "4h in Chrome" into one bar. This tracker fixes both — **media-aware idle** (a held power assertion means a video/music counts as active even with zero input) and **domain-level browser attribution** (4h Chrome → 2h github.com · 1h youtube.com · 1h gmail.com).

**Write target:** `$VAULT_DIR/life/laptop-tracking/YYYY-MM-DD.md` (host + path). The granular record lives in a **local-only** SQLite DB (`~/.config/pbrain/tracker.db`) that is **never synced to the vault** — only the derived daily markdown is. The captured URL keeps host and path (so a **Top pages** table can show `github.com/anthropics/claude-code` distinct from `github.com/settings`); the `?query=…` string is dropped at capture by design — that's the privacy boundary (tokens, search terms, secrets).

## How it works

```
NSWorkspace app-switch  ─┐
~10s poll timer         ─┴─►  active?  ──►  kind=foreground: one row per (app, domain) ACTIVE span
                              = unlocked & not screensaver & not asleep            │
                              & (input idle < 5m OR a prevent-idle assertion held) │
                                                                                   │
                         background media? ──► kind=bg_media: audio/video in bg,  │
                              = IOKit prevent-idle held without frontmost focus     │
                                                                                   ▼
                                                          ~/.config/pbrain/tracker.db
                                                          (active segments: foreground + bg_media)
                                                                      │ render (end of day / on demand)
                                                                      ▼
                                                  vault/life/laptop-tracking/<date>.md
```

- **Only active time is stored**, as one row per contiguous `(app, domain)` span. Away / idle / locked / asleep is **not** a row — it's the gap *between* segments, computed at render time. This halves writes and means no 24/7 idle churn on your battery.
- The daemon stores **raw** signals (raw bundle id, raw URL host, an attribution reason); the Python renderer does all normalization (`www.` stripping, domain rollup) and active/away classification, so the edge-case logic is unit-tested.
- **Crash-safe:** while active, every poll bumps the live span's end (a heartbeat), so a crash or hard power-off loses at most one poll interval. Sleep closes the span and wake opens a fresh one; a local-midnight rollover splits the span so each day buckets correctly.

## Opt-in

The tracker is **off by default** — nothing runs until you enable it. `/plan-my-day` nudges you **once** to set it up; if you decline, it never asks again (and you can enable it yourself anytime). Enabling = `start`, disabling = `stop`.

## Commands

| Command | What it does |
|---|---|
| `/laptop-tracking start` | **Enable.** Build the daemon (compiles `lib/pbrain-tracker.swift` on demand), create the DB, install + launch the LaunchAgent (resident, relaunches at login). Alias: `enable`. |
| `/laptop-tracking access` | One-time, per-browser **Automation** grant. Open the browsers you want tracked, then approve each prompt. Without it, browser time still counts at the app level — just without a domain. |
| `/laptop-tracking status` | Is the daemon running? today's quick numbers (active time, top app). |
| `/laptop-tracking report [<date>]` | Render `life/laptop-tracking/<date>.md` from the DB (default today). This is the on-demand finalize. |
| `/laptop-tracking stop` | **Disable.** Stop and uninstall the daemon. Alias: `disable`. |
| `/laptop-tracking decline` | Opt out of the `/plan-my-day` setup nudge without starting anything (it won't ask again). |

`/end-of-day` also renders today's report automatically (no-op if the tracker isn't set up) and weaves one grounded line into the close, so the daily report shows up as part of your close.

## The daily report

**Past days** (day is complete) show a full 00:00 → 24:00 window, so away time includes any untracked tail (laptop off or asleep before midnight). **Today's report** (in progress) shows "so far" with the actual last activity as the endpoint — no inflated away time on a live day.

```markdown
# Laptop usage — 2026-06-07

- **Active time:** 5h 12m
- **Day window:** 00:00 → 24:00 (full day)       ← past day; "Tracked window: … so far" for today
- **Active vs away:** 5h 12m active · 18h 48m away (22% active)

## Top apps
| App | Active time | % |
| Google Chrome | 2h 40m | 51% |
| ...

## Top browser domains
| Domain | Active time | % |
| github.com | 1h 30m | 56% |
| youtube.com/watch?v=dQw4w9WgXcQ | 45m | 28% |   ← per-video row (YouTube only)
| ...

## Browser attribution

Browser time with no recorded domain, by reason:

| Reason | Active time |
|--------|------------|
| permission not granted | 12m |   ← only shown when some browser time wasn't cleanly attributed

## Background media

Audio/video playing in the background (excluded from active/away accounting):

| App | Background time |
|-----|----------------|
| Spotify | 1h 20m |
```

Three report features worth knowing:

- **Full-day window for past days.** Away time is the gap from day-start to next midnight, so "time offline" (laptop closed before midnight) is included. Today's report uses the last recorded activity as the endpoint instead, labeled "so far".
- **Per-video YouTube tracking.** Watch time on `youtube.com/watch`, `m.youtube.com`, and `music.youtube.com` now breaks out per video ID (`?v=`) in the Top pages table, so each video gets its own row. All other query parameters are still dropped (tokens, search terms, etc.).
- **Browser attribution table.** When Chrome or Safari time has no recorded domain, a `## Browser attribution` table explains why — permission not granted, tab lookup timed out, or non-web window. Unaccounted browser time is visible, not silently dropped.
- **Background media section.** Audio or video playing in the background (music, PiP video) is tracked separately as `kind = bg_media` — it is **never counted toward your foreground active time or focus blocks**. It appears in its own `## Background media` section at the bottom of the report, so you can see background listening without it polluting your focus stats.

## Requirements & permissions

- **macOS only**, and needs **`swiftc`** (Xcode Command Line Tools — `xcode-select --install`) to build the daemon on first `start`. No external packages.
- **Automation (Apple Events)** consent per browser, granted via `/laptop-tracking access`. The daemon never triggers the consent dialog itself (a launchd process can't) — it only checks consent and degrades gracefully when it's missing. A pbrain upgrade that changes the daemon source may re-show the one-time prompt once.
- Covers **Safari + Chrome-family** (Chrome, Brave, Edge, Arc, Vivaldi, Opera). **Firefox** app-time counts, but its domain isn't read (no clean AppleScript URL access).
- Runs as a **LaunchAgent in the GUI session** — it tracks while you're logged in, and relaunches at login. It does not (and can't) run while logged out.

## Manual verification (the daemon can't run headless in CI)

```bash
# build + run in the foreground against a throwaway DB, switch between apps/tabs for a bit:
swiftc -suppress-warnings lib/pbrain-tracker.swift -o /tmp/pbtrack
/tmp/pbtrack --db /tmp/t.db --poll-seconds 2 &
# ... use a browser, lock the screen, play a video ...
kill %1
sqlite3 /tmp/t.db 'select app_name, raw_host, attribution, ended_at-started_at dur from tracker_segments'
PBRAIN_TRACKER_DB_FILE=/tmp/t.db bash commands/laptop-tracking.sh report
```

The bash + Python read/render path is covered by `tests/tracker.bats` (schema, gap-derived away, domain normalization, attribution rollup, and the critical "a DB read failure never clobbers an existing report" regression).

## Overrides

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root |
| `PBRAIN_TRACKER_DIR` | Markdown write dir (default `$VAULT_DIR/life/laptop-tracking`) |
| `PBRAIN_TRACKER_DB_FILE` | Segment DB (default `~/.config/pbrain/tracker.db`) — local-only, never synced |
| `PBRAIN_TRACKER_APP` | Compiled daemon app (default `~/.config/pbrain/pbrain-tracker.app`) |
| `PBRAIN_TRACKER_POLL` | Daemon poll interval, seconds (default `10`) |
| `PBRAIN_TRACKER_IDLE` | Idle-away threshold, seconds (default `300`) |
| `PBRAIN_TRACKER_TOPN` | Rows in the top apps/domains tables (default `12`) |

## What it deliberately doesn't do

- **No live/periodic markdown updates** — the md renders at end-of-day (and on demand), so iCloud isn't churned all day.
- **No HTML / menubar dashboard yet** — the granular DB is built so those can be layered on later without re-instrumenting (see TODOS).
- **No query strings (with one allowlisted exception)** — the captured URL keeps host **and path** (so `github.com/anthropics/claude-code` is distinct from `github.com/settings`), but the `?query=…` is dropped at capture: that's where tokens, search terms, and session secrets live. The **one exception** is YouTube's `v=` video ID — it identifies content, not a secret, so it's kept to give per-video rows in the Top pages table. All other query params, including `&list=`, `&t=`, and any search terms, are still dropped. The path (and the `?v=` ID for YouTube) stays local-only in `tracker.db` and renders into the **Top pages** table; only the per-day md travels with the vault.
- **No cross-machine DB sync** — `tracker.db` is per-machine local state; only the derived md travels with the vault.
