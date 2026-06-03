# Self-improvement loop

Every pbrain command (except `/init-obsidian`, which runs before a vault exists) can learn from how you use it. When you correct a command or state a standing preference — "stop asking three questions, just ask one", "always use metric", "drop the gratitude nudge" — the command offers to remember it, and applies it on every future run. Nothing is silent and nothing is automatic: the loop only speaks up when you actually gave feedback, and it never writes without an explicit yes.

It's two halves, both carried by shared helpers (`lib/prefs.sh`, `lib/self-improve.sh`) that ride along on every command:

- **Read side** — at the start of a run, the command injects your saved preferences for that command into context, so it behaves the way you asked last time.
- **Write side** — at the end of a run, *if* you gave genuine feedback this session, the command classifies it and offers to save it.

## What gets captured, and where

Feedback splits into kinds, which go to different places:

| Kind | Means | Goes to | Survives `/plugin update`? |
|---|---|---|---|
| **Preference (command)** | How *you* want one command to behave | `~/.config/pbrain/prefs/<command>.md` | yes (outside the plugin) |
| **Preference (global)** | How *you* want every command to behave | `~/.config/pbrain/prefs/_global.md` | yes (outside the plugin) |
| **Quality fix** | A bug or improvement that helps *everyone* | `~/.config/pbrain/feedback/<command>.md` | yes |
| **Plan change** | A lasting change to a core plan you own | the plan file itself (your vault) | yes (it's your content) |

Preferences are read back and injected on the next run — that's the half that actually closes the loop. The global file is injected on *every* command, before that command's own prefs.

### Turning off suggestions and nudges

Every built-in suggestion yields to a standing preference that says to skip it — preferences always win over a default nudge. Tell any command "stop suggesting `/journal` or `/gratitude-journal` before other commands" (or "stop nudging me about X") and it saves that to the **global** file, so it takes effect across *all* commands — not just the one you were running. This matters because a nudge like the morning-sequence journal/gratitude check fires from many commands (`/plan-my-day`, `/brainstorm`, `/diet-journal`, `/fitness-journal`, `/organize-clippings`, …); a per-command preference could only silence one of them, so these cross-command skips live in `_global.md`. A preference that's specific to one command ("ask only one question in `/journal`") still goes to that command's file. You can also edit `_global.md` by hand any time. Quality fixes are collected for you to send upstream; after saving one, the command offers to open a GitHub issue (only if `gh` is installed and you say yes). The prefs and feedback files are plain markdown, one per command, editable by hand any time.

### Plan changes (in-session, same discipline)

The commands that own a core plan also watch for lasting *plan* changes — and they all do it the same way:

| Command | Plan it can update |
|---|---|
| `/plan-my-day` | `Goals Profile.md` |
| `/diet-journal` | `Diet Plan.md` |
| `/fitness-journal` | gym plan + per-activity fitness plans |
| `/weekly-review` | all of the above (its richer Step 4 pass over the whole week) |

If you say something mid-session that implies a standing change — "bump my protein target to 180", "drop leg day", "my focus this month is X" — the command proposes the specific edit to that plan file, shows it, and writes it **only on an explicit per-change yes**. A one-off meal, a single workout, or just answering the command's questions does *not* count — same conservative trigger as preferences. (When the goals profile is edited, its fenced JSON block is kept valid.) This is the same propose→confirm→write flow everywhere, so updating any plan feels identical.

## Modes

Behavior is set by `PBRAIN_SELF_IMPROVE`:

| Value | Behavior |
|---|---|
| `prefs` *(default)* | Capture preferences and quality fixes as above. Never edits command source. The right mode for everyone, including plugin users — it writes outside the plugin install, so it survives updates. |
| `off` | Disabled entirely. Commands emit nothing extra. |
| `dev` | Everything `prefs` does, **plus** the agent may propose edits to the live command source under `$PBRAIN_DEV_DIR/commands/`. Honoured only when `PBRAIN_DEV_DIR` is set (points at your editable clone); otherwise it silently falls back to `prefs`. |

**Dev mode is for pbrain's own development.** When a quality fix should change the command itself, the agent proposes a concrete diff and waits for an explicit yes — it never auto-writes source. It also warns first if your dev clone's working tree is dirty or sitting on `main`, so a captured edit doesn't tangle with unrelated work.

| Env var | Effect | Default |
|---|---|---|
| `PBRAIN_SELF_IMPROVE` | `off` / `prefs` / `dev` | `prefs` |
| `PBRAIN_DEV_DIR` | Path to the editable repo; required for `dev` source edits | — |
| `PBRAIN_PREFS_DIR` | Where preferences live (`_global.md` + per-command `<cmd>.md`) | `~/.config/pbrain/prefs` |
| `PBRAIN_FEEDBACK_DIR` | Where quality-fix notes live | `~/.config/pbrain/feedback` |

## Behavior you can count on

- **Silent unless you gave feedback.** Just answering a command's questions, a one-off request for today only, or neutral conversation do **not** trigger it. It fires only on an explicit standing preference or correction. When in doubt, it stays quiet.
- **Confirm before writing.** It shows you the exact line(s) it would save and waits for a yes.
- **Consolidate, don't pile up.** When saving a preference, it reads the existing file first and updates the related line instead of appending a duplicate — and reconciles with you if a new preference contradicts an old one. Your prefs file stays small and coherent.
- **Never breaks a command.** The helpers are written to never fail the command they're attached to, even if a file is missing or malformed.

## Examples

```bash
# Default — capture preferences as you go
/journal

# Turn it off for a session
PBRAIN_SELF_IMPROVE=off /plan-my-day

# Developer: allow proposed source edits against your clone
PBRAIN_SELF_IMPROVE=dev PBRAIN_DEV_DIR=~/code/pbrain /diet-journal
```

A captured `~/.config/pbrain/prefs/journal.md` might read:

```markdown
- Ask at most one open question, not three.
- Keep the saved entry in my own words — don't paraphrase into tidy prose.
```

On the next `/journal`, those lines are injected into context and the command honours them.

## Related: weekly plan enrichment

`/weekly-review` applies the same propose-then-write discipline to your *plans* rather than command behavior — at week's end it proposes evidence-tied updates to your goals profile, diet plan, and fitness plans. All three are user-owned vault files and treated identically: proposed into the review, edited in place only on an explicit per-change yes. See [`weekly-review.md`](weekly-review.md).
