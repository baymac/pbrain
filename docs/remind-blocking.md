# /remind-blocking

Reminders that fire as a **full-screen blocking overlay** instead of a dismissible notification — the "Take a break" pattern. When one fires, an opaque screen drops over **every display**, above the menu bar and Dock, with your message shown huge and (optionally) a countdown. Two deliberate hold gestures resolve it (each held so it can't be hit by accident):

- **Hold Control (⌃)** → **skip** → marks the reminder **cancelled**
- **Hold Return (⏎)** → **mark done** → marks it **done**
- **Let the countdown run out** → counts as **done** (you waited out the break)

So a fired blocking reminder doesn't linger as "mark me off later" — the overlay resolves it in the DB on the way out. (Repeating reminders are the exception: the series has already advanced to its next occurrence by the time the overlay shows, so the gestures just dismiss *this* occurrence without touching the schedule — skipping one daily break never cancels the whole habit.)

Use it for the moments you actually want to be *forced* to stop and notice — stretch breaks, posture nudges, screen-time hard stops, "step away now" cutoffs. For routine pings, use plain [`/remind`](remind.md) — those are notifications you can glance past.

Blocking reminders share the same scheduling engine, SQLite store, and background poller as `/remind`; they're just rows with a duration attached.

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
/remind-blocking list           # pending blocking reminders, with durations
/remind-blocking                # list + fire any due NOTIFICATION reminders (not overlays — see below)
```

To cancel one, just say so ("cancel the break reminder", "remove #3") — it matches your words to an id.

## How firing works

A blocking overlay is **time-sensitive** — a "take a break at 3pm" screen is useless (and jarring) if it ambushes you at 6pm. So unlike `/remind`'s notifications, **blocking overlays fire only via the background poller**, which ticks every ~60s and so goes off within a minute of the due time.

This means the **poller must be running** for a blocking reminder to fire on schedule. Your first `/remind-blocking add` installs it automatically (it's the same `com.pbrain.reminders` launchd agent `/remind` uses — nothing extra to install).

What they deliberately do **not** do: fire **opportunistically**. Running `/remind-blocking`, `/plan-my-day`, or `/end-of-day` will fire your due *notification* reminders as a catch-up, but it will **not** pop a stale overlay — that path is `notify-only` for exactly this reason. (The only way to summon an overlay on demand is `/remind-blocking test`.)

Repeating ones roll forward to their next occurrence after firing; one-shots fire once and then read as **fired** in the list.

> **Heads-up:** because firing is poller-only, a blocking reminder won't fire while you're logged out / the Mac is asleep. On wake, the poller fires it once as a catch-up (not once per missed cycle). If you need a hard guarantee at an exact second, that's outside what a 60s poller offers.

### The overlay app

The overlay is drawn by **pbrain's own tiny app** (`pbrain-overlay.app`), compiled on demand from a Swift source with `swiftc` (Apple Command Line Tools — already on any dev Mac) and cached at `~/.config/pbrain/pbrain-overlay.app`. Same packaging trick as the notifier: a real app bundle launches reliably even from the background poller. If `swiftc` isn't available, a blocking reminder **degrades to a normal notification** so it still surfaces.

The overlay sets macOS kiosk options while it's up — it hides the Dock and menu bar and disables Cmd-Tab, force-quit, and Hide. This is *friction, not a prison*: it makes skipping deliberate, not impossible. Hold Control to skip / Return to mark done (or finish the countdown) and it tears down instantly, writing the resolution straight to the reminder row via SQLite.

**Sleep / lock safety.** An overlay must never linger invisibly behind the lock screen or across a sleep — that's how a stack of them piles up overnight and eats memory. Two guards prevent it: the poller **won't fire** a new overlay while the screen is locked (it leaves the reminder pending so it pops once you're back), and a live overlay **dismisses itself** the moment the Mac sleeps or the screen locks. Set `PBRAIN_SCREEN_LOCKED=1` to force the poller to treat the screen as locked (a manual "don't interrupt me" switch); `0` forces unlocked.

## Defaults and overrides

| Env var | Effect | Default |
|---|---|---|
| `PBRAIN_DB_FILE` | SQLite DB path (shared with `/remind`, `/habits`) | `~/.config/pbrain/pbrain.db` |
| `PBRAIN_OVERLAY_APP` | Where the compiled overlay app is cached/built | `~/.config/pbrain/pbrain-overlay.app` |
| `PBRAIN_OVERLAY_BG` | Default overlay background colour (hex, e.g. `#1e3a5f`) | unset → slate |
| `PBRAIN_SCREEN_LOCKED` | Override the screen-lock probe: `1` = treat as locked (defer overlays), `0` = unlocked | unset → auto-detect via `ioreg` |

**Subcommands (the script's API — you normally just type natural language):** `add --text … ( --due … | --cron "<expr>" ) [--duration <seconds>] [--hold <seconds>]`, `test`, `list`, `done <id>`, `cancel <id>`, `tick`, `install`, `uninstall`.

**Note:** macOS only (uses the bundled overlay app / launchd).
