# Self-improvement loop

Every pbrain command (except `/init-obsidian`, which runs before a vault exists) can learn from how you use it. When you correct a command or state a standing preference — "stop asking three questions, just ask one", "always use metric", "drop the gratitude nudge" — the command offers to remember it, and applies it on every future run. Nothing is silent and nothing is automatic: the loop only speaks up when you actually gave feedback, and it never writes without an explicit yes.

Preferences and feedback moved from `~/.config/pbrain/` into the vault (migration 0001 copies existing files across automatically), so they sync to every device with the rest of your vault.

It's two halves, both carried by shared helpers (`lib/prefs.sh`, `lib/self-improve.sh`) that ride along on every command:

- **Read side** — at the start of a run, the command injects your saved preferences for that command into context, so it behaves the way you asked last time.
- **Write side** — at the end of a run, *if* you gave genuine feedback this session, the command classifies it and offers to save it.

## What gets captured, and where

Feedback splits into kinds, which go to different places:

| Kind | Means | Goes to | Survives `/plugin update`? |
|---|---|---|---|
| **Preference (command)** | How *you* want one command to behave | `$VAULT_DIR/.pbrain/<command>/prefs.md` | yes (your vault) |
| **Preference (global)** | How *you* want every command to behave | `$VAULT_DIR/.pbrain/_global/prefs.md` | yes (your vault) |
| **Quality fix** | A bug or improvement that helps *everyone* | `$VAULT_DIR/.pbrain/<command>/feedback.md` | yes |
| **Profile change** | A lasting change to a core profile you own | the versioned profile (your vault) | yes (it's your content) |

Preferences are read back and injected on the next run — that's the half that actually closes the loop. The global file is injected on *every* command, before that command's own prefs.

### Turning off suggestions and nudges

Every built-in suggestion yields to a standing preference that says to skip it — preferences always win over a default nudge. Tell any command "stop suggesting `/journal` or `/gratitude-journal` before other commands" (or "stop nudging me about X") and it saves that to the **global** file, so it takes effect across *all* commands — not just the one you were running. This matters because a nudge like the morning-sequence journal/gratitude check fires from many commands (`/plan-my-day`, `/brainstorm`, `/diet-journal`, `/fitness-journal`, `/organize-clippings`, …); a per-command preference could only silence one of them, so these cross-command skips live in `_global/prefs.md`. A preference that's specific to one command ("ask only one question in `/journal`") still goes to that command's file. You can also edit `_global/prefs.md` by hand any time. Quality fixes are collected for you to send upstream; after saving one, the command offers to open a GitHub issue (only if `gh` is installed and you say yes). The prefs and feedback files are plain markdown, one per command, editable by hand any time.

### Profile changes (in-session, same discipline)

The commands that own a core profile also watch for lasting *profile* changes — and they all do it the same way:

| Command | Profile it can update |
|---|---|
| `/plan-my-day` | goals profile (+ work/goals libraries) |
| `/diet-journal` | diet profile |
| `/fitness-journal` | fitness profile, library + per-activity profiles |
| `/weekly-review` | all of the above (its richer Step 4 improvements pass, which mints new profile versions) |

If you say something mid-session that implies a standing change — "bump my protein target to 180", "drop leg day", "my focus this month is X" — the command proposes the specific edit to that profile, shows it, and writes it **only on an explicit per-change yes**. A one-off meal, a single workout, or just answering the command's questions does *not* count — same conservative trigger as preferences. (Fenced JSON blocks are kept valid; committed profile versions are immutable, so structural changes go through `profile new` → `profile commit`.) This is the same propose→confirm→write flow everywhere, so updating any profile feels identical.

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
| `PBRAIN_PREFS_DIR` | Preferences ROOT (`_global/prefs.md` + per-command `<cmd>/prefs.md`) | `$VAULT_DIR/.pbrain` |
| `PBRAIN_FEEDBACK_DIR` | Quality-fix ROOT (per-command `<cmd>/feedback.md`) | `$VAULT_DIR/.pbrain` |

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

A captured `$VAULT_DIR/.pbrain/journal/prefs.md` might read:

```markdown
- Ask at most one open question, not three.
- Keep the saved entry in my own words — don't paraphrase into tidy prose.
```

On the next `/journal`, those lines are injected into context and the command honours them.

## Related: weekly improvements

`/weekly-review` applies the same propose-then-confirm discipline to your *profiles* rather than command behavior — at week's end it builds a per-command improvement list, walks it one item at a time, and mints a new committed profile version for whatever you approve. See [`weekly-review.md`](weekly-review.md).
