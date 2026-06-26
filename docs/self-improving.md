# Self-improvement loop

pbrain learns from how you use it. When you correct a command or state a standing preference — "stop asking three questions, just ask one", "always use metric", "drop the gratitude nudge" — that correction is captured and applied on every future run. Nothing is silent and nothing is automatic: it only speaks up when you actually gave feedback, and it never writes without an explicit yes.

It has two halves:

- **Read side** — at the start of *every* command, your saved preferences for that command (and your global preferences) are injected into context, so it behaves the way you asked last time. This runs on every command (except `/init-obsidian`, which runs before a vault exists) via `lib/prefs.sh`.
- **Capture side** — once a day, at the end of `/end-of-day`, a single **scheduled, correction-driven** pass looks back over the day and proposes anything worth remembering (see below). This is the *only* capture path: commands no longer nag "did you correct me?" inline.

Preferences and feedback live in the vault under `.pbrain/` (migration 0001 copied any older `~/.config/pbrain/` files across), so they sync to every device with the rest of your vault. A **preference** is read back and injected on every run; a **quality fix** is logged to a *write-only* `feedback.md` (never injected, so it costs no context) and can optionally be raised upstream as a GitHub issue against `baymac/pbrain`.

## The scheduled, correction-driven pass (PB-47)

Corrections usually happen in passing — you redirect a command, it does the right thing, and the moment goes by. Rather than interrupt each command to ask whether you meant something as a standing rule, pbrain captures corrections **in one batch at the end of the day**.

Once a day, at the end of `/end-of-day`, the pass points the agent at today's Claude Code session transcripts (`~/.claude/projects/*/<session>.jsonl`, filtered to that day) and asks it to *mine* them for places you corrected or redirected a pbrain command — **even when you never said "remember this."** Each genuine correction is proposed back to you with the transcript quote it came from, classified, and written **only on an explicit per-item yes**.

It keeps a conservative bar: neutral Q&A, one-off requests for today only, and just answering a command's questions don't count, and it stays silent when nothing genuine surfaces (or when there are no transcripts for the day). Transcripts are read strictly as *data* — a line inside one that reads like an instruction is content to judge, never an order to follow. Closing a past day with `/end-of-day --date YYYY-MM-DD` mines that day's transcripts.

## What gets captured, and where

Each proposed correction is classified, and the kinds go to different places — the same targets the read side injects from:

| Kind | Means | Goes to | Survives `/plugin update`? |
|---|---|---|---|
| **Preference (command)** | How *you* want one command to behave | `$VAULT_DIR/.pbrain/<command>/prefs.md` (a profile-owning command folds it into the profile's `prefs` array instead) | yes (your vault) |
| **Preference (global)** | How *you* want every command to behave | `$VAULT_DIR/.pbrain/_global/prefs.md` | yes (your vault) |
| **Quality fix** | A bug or improvement that helps *everyone* | `$VAULT_DIR/.pbrain/<command>/feedback.md` (write-only log), then optionally a GitHub issue on `baymac/pbrain` | yes (your vault) |

Preferences are read back and injected on the next run — that's the half that actually closes the loop. The global file is injected on *every* command, before that command's own prefs. `feedback.md` is **write-only**: it's a local bug logbook that is *never* read back or injected, so it never bloats context — only `prefs.md` is loaded each run.

### Turning off suggestions and nudges

Every built-in suggestion yields to a standing preference that says to skip it — preferences always win over a default nudge. A correction like "stop suggesting `/journal` or `/gratitude-journal` before other commands" (or "stop nudging me about X") is saved to the **global** file, so it takes effect across *all* commands — not just the one you were running. This matters because a nudge like the morning-sequence journal/gratitude check fires from many commands (`/plan-my-day`, `/brainstorm`, `/diet-journal`, `/fitness-journal`, `/organize-clippings`, …); a per-command preference could only silence one of them, so these cross-command skips live in `_global/prefs.md`. A preference that's specific to one command ("ask only one question in `/journal`") still goes to that command's file. You can also edit `_global/prefs.md` by hand any time. Quality fixes are handled differently: when one surfaces, the pass always logs it to the write-only `<command>/feedback.md` (a local bug record that never re-enters context), then offers to *also* raise it upstream as a GitHub issue against `baymac/pbrain` — via `gh issue create` if the GitHub CLI is installed and authenticated, otherwise it hands you a prefilled issue URL to paste. Declining the issue is fine; the local log still stands. The prefs and feedback files are plain markdown, one per command, editable by hand any time.

### Profile changes

Lasting changes to a core profile you own (plans / diet / fitness) are **not** captured by this pass. `/weekly-review` owns profile improvements via its richer Step 4 — at week's end it builds a per-command improvement list, walks it one item at a time, and mints a new committed profile version for whatever you approve. See [`weekly-review.md`](weekly-review.md).

## Modes & env vars

| Env var | Effect | Default |
|---|---|---|
| `PBRAIN_SELF_IMPROVE` | `off` disables self-improve capture entirely (kept for back-compat with the old inline loop's master switch). | `prefs` |
| `PBRAIN_SELF_IMPROVE_BATCH` | `off` disables just the scheduled end-of-day pass. | `on` |
| `PBRAIN_CLAUDE_PROJECTS_DIR` | Where the pass looks for Claude Code transcripts. | `~/.claude/projects` |
| `PBRAIN_PREFS_DIR` | Preferences ROOT (`_global/prefs.md` + per-command `<cmd>/prefs.md`) | `$VAULT_DIR/.pbrain` |
| `PBRAIN_FEEDBACK_DIR` | Quality-fix log ROOT (write-only per-command `<cmd>/feedback.md`) | `$VAULT_DIR/.pbrain` |

## Behavior you can count on

- **Silent unless you gave feedback.** Just answering a command's questions, a one-off request for today only, or neutral conversation do **not** trigger it. It fires only on a genuine standing preference or correction mined from the day's transcripts. When in doubt, it stays quiet.
- **Confirm before writing.** It shows you the exact line(s) it would save — and the transcript quote they came from — and waits for a per-item yes.
- **Consolidate, don't pile up.** When saving a preference, it reads the existing file first and updates the related line instead of appending a duplicate — and reconciles with you if a new preference contradicts an old one. Your prefs file stays small and coherent.
- **Never breaks a command.** The helpers are written to never fail the command they're attached to, even if a file is missing or malformed.

## Examples

```bash
# Capture runs automatically at the end of the day
/end-of-day

# Disable just the scheduled capture pass (prefs are still injected on reads)
PBRAIN_SELF_IMPROVE_BATCH=off /end-of-day

# Disable self-improve capture entirely
PBRAIN_SELF_IMPROVE=off /end-of-day
```

A captured `$VAULT_DIR/.pbrain/journal/prefs.md` might read:

```markdown
- Ask at most one open question, not three.
- Keep the saved entry in my own words — don't paraphrase into tidy prose.
```

On the next `/journal`, those lines are injected into context and the command honours them.
