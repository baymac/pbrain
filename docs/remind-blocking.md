# /remind-blocking

Reminders that fire as a **full-screen blocking overlay** instead of a dismissible notification — the "Take a break" pattern. When one fires, a **10-second warning panel** appears top-right first: small, non-intrusive, with a **Skip** button so you can dismiss it before the overlay takes over. If you don't skip, the opaque screen drops over **every display**, above the menu bar and Dock, with your message shown huge and (optionally) a countdown. Each occurrence resolves to exactly one outcome:

- **Click Skip in the warning panel** → dismissed before the overlay fires (same result as skipped)
- **Hold Control (⌃)** for a few seconds on the overlay → **skipped** (a deliberate hold, so it can't be hit by accident)
- **Let the countdown run out** → **done** — you waited out the full break. *This is the only way to get a "done".*
- **The Mac sleeps or the screen locks** while it's up, or it comes due while you're away past a grace window → **missed**

There is no "mark done" shortcut — `done` means strictly that the allotted time elapsed. The overlay writes the outcome to that occurrence on the way out, so nothing lingers as "mark me off later."

Use it for the moments you actually want to be *forced* to stop and notice — stretch breaks, posture nudges, screen-time hard stops, "step away now" cutoffs. For routine pings, use plain [`/remind`](remind.md) — those are notifications you can glance past.

`/remind-blocking` is the **sole** owner of pbrain's SQLite reminders store and the background poller. (`/remind` is Apple Calendar-only and never touches the DB.) A recurring reminder is a **series** (`reminder_schedules`, defined by a cron expression); each fire is its own **occurrence** row, so per-occurrence history survives and resolving one never disturbs the series.

## Setting one

```bash
/remind-blocking take a break every saturday and tuesday at 2pm and 5pm for 5 minutes
/remind-blocking stand up and stretch tomorrow 10am          # one-off, stays until you skip it
/remind-blocking hard stop on screens every weekday at 11pm for 10 min
/remind-blocking look away from the screen every 20 minutes for 30 seconds
```

The command resolves the time **relative to now** and sets:

- **Schedule** — any cadence you can describe. Behind the scenes it's stored as a **cron expression** (`minute hour day-of-month month day-of-week`), which the command builds from your words. That's what gives it full flexibility — multiple times per day, specific weekdays, step intervals:
  | You say | cron |
  |---|---|
  | every weekday at 9am | `0 9 * * 1-5` |
  | Saturday & Tuesday, 2pm and 5pm | `0 14,17 * * 2,6` |
  | every hour at 5 past | `5 * * * *` |
  | every 5 minutes | `*/5 * * * *` |
  | 1st of each month, 11pm | `0 23 1 * *` |

  A one-off ("tomorrow 10am", "in 90 minutes") is just a single due time, no cron.
- **Duration** — how long the overlay stays on screen / counts down. "for 5 minutes" → 5:00. Omit it and the overlay **stays until you hold Control to skip it** (no countdown).
- **Hold-to-skip** — seconds of continuous Control-key hold required to dismiss early. Default **5s**; ask for more/less if you want harder or softer friction.

Keep the message short — it's rendered very large (e.g. "Take a break", "Stand up", "Stop — hard limit").

> **Resolution is 1 minute.** The poller ticks every ~60s, matching cron's finest granularity. So *sub-minute* cadences ("every 30 seconds") aren't firable — the schedule rounds to the minute, and the command will tell you. Everything from "every minute" upward works.

> **One overlay at a time.** If two reminders come due together (or one fires while another is still on your screen), they **queue** — only one overlay shows; the next fires on the following tick once you've dismissed the first. Nothing is dropped.

## Trying it

```bash
/remind-blocking test
```

shows one overlay **right now** (10s, hold 3s to skip) so you can see it. Add `--text`, `--duration`, `--hold`, or `--background <hex>` to preview a specific look.

## Managing them

```bash
/remind-blocking list           # active series (S<id>) + pending one-shots (R<id>)
```

The list tags each entry with a handle: a recurring **series** as `S<id>`, a one-shot **occurrence** as `R<id>`. To cancel, just say so ("cancel the break reminder", "stop the stretch one", "remove R3") — it matches your words to a handle. Cancelling a **series** (`S<id>`) stops the whole thing; cancelling a one-shot (`R<id>`, or a bare number) drops just that occurrence.

## How firing works

A blocking overlay is **time-sensitive** — a "take a break at 3pm" screen is useless (and jarring) if it ambushes you at 6pm. So **blocking overlays fire only via the background poller**, which ticks every ~60s and goes off within a minute of the due time. There are no opportunistic callers: running `/plan-my-day` or `/end-of-day` never pops a stale overlay. (The only way to summon one on demand is `/remind-blocking test`.)

This means the **poller must be running** for a blocking reminder to fire on schedule. Your first `/remind-blocking add` installs it automatically (the `com.pbrain.reminders` launchd agent — nothing extra to install).

When an occurrence comes due, the poller does one of three things:

- **Fires** it (shows the overlay) if it's within the **grace window** (default 10 min, override `PBRAIN_REMIND_GRACE_SECONDS`) and the screen is unlocked.
- **Defers** it — leaves it pending, untouched — if the screen is locked but it's still within grace (so unlocking soon still gets you the reminder), or if another overlay is already up (one at a time).
- **Misses** it — marks it `missed`, no overlay — if it's overdue beyond the grace window (the Mac was asleep/off, or locked too long). A break that's an hour late is moot, so it's reconciled instead of fired.

**A recurring series survives all of this.** Whether an occurrence fires or is missed, the poller immediately schedules the next one from the cron expression — so a missed/locked/asleep fire never breaks the chain. The *only* thing that stops a series is cancelling it.

> **Heads-up:** because firing is poller-only, a blocking reminder won't fire while the Mac is asleep/off. On wake, anything overdue beyond grace is marked `missed` (not fired late, not fired once-per-missed-cycle), and the series rolls on. If you need a hard guarantee at an exact second, that's outside what a 60s poller offers.

### The overlay app

The overlay is drawn by **pbrain's own tiny app** (`pbrain-overlay.app`), compiled on demand from a Swift source with `swiftc` (Apple Command Line Tools — already on any dev Mac) and cached at `~/.config/pbrain/pbrain-overlay.app`. Same packaging trick as the notifier: a real app bundle launches reliably even from the background poller. If `swiftc` isn't available, a blocking reminder **degrades to a normal notification** so it still surfaces.

The overlay sets macOS kiosk options while it's up — it hides the Dock and menu bar and disables Cmd-Tab, force-quit, and Hide. This is *friction, not a prison*: it makes skipping deliberate, not impossible. Hold Control to skip (or finish the countdown for a "done") and it tears down instantly, writing the outcome straight to that occurrence's row via SQLite.

**Sleep / lock safety — with lock-persist.** A live overlay now **hides on screen lock and re-appears on unlock**, with the countdown adjusted for the locked duration — so a break you were mid-way through isn't silently lost. Sleep is treated differently: if the Mac sleeps (not just locks), the overlay dismisses itself and resolves to `missed` (it can't meaningfully resume across a sleep). Three guards prevent orphaned overlays: the poller **won't fire** a new overlay while the screen is locked (leaving it pending so it pops once you're back, or marking it `missed` if it ages past the grace window); a live overlay **dismisses itself** if sleep fires during the warning phase; and the grace window stops anything from firing hours late on wake. Set `PBRAIN_SCREEN_LOCKED=1` to force the poller to treat the screen as locked (a manual "don't interrupt me" switch); `0` forces unlocked.

## Defaults and overrides

| Env var | Effect | Default |
|---|---|---|
| `PBRAIN_DB_FILE` | SQLite DB path (shared with `/habits`) | `~/.config/pbrain/pbrain.db` |
| `PBRAIN_OVERLAY_APP` | Where the compiled overlay app is cached/built | `~/.config/pbrain/pbrain-overlay.app` |
| `PBRAIN_OVERLAY_BG` | Default overlay background colour (hex, e.g. `#1e3a5f`) | unset → slate |
| `PBRAIN_REMIND_GRACE_SECONDS` | How overdue an occurrence may be and still fire; past it → `missed` | `600` (10 min) |
| `PBRAIN_SCREEN_LOCKED` | Override the screen-lock probe: `1` = treat as locked (defer overlays), `0` = unlocked | unset → auto-detect via `ioreg` |

**Subcommands (the script's API — you normally just type natural language):** `add --text … ( --due … | --cron "<expr>" ) [--duration <seconds>] [--hold <seconds>]`, `test`, `list`, `cancel <handle>` (`S<id>` series / `R<id>` one-shot), `tick`, `install`, `uninstall`.

**Note:** macOS only (uses the bundled overlay app / launchd).
