---
description: Habit tracking. First run interviews you one question at a time to build a versioned habits profile — each habit with its own criteria (daily / N-per-week / N-per-month, build or limit) and a priority. Day-to-day tracking lives in dated markdown files (life/habit-tracking/<date>.md) you tick like a checklist; a SQLite store is synced from them for analysis. Afterward it shows your progress vs each criteria (✅ met / ⏳ not yet / ⚠️ over), top 20 by priority. Habits are auto-marked from your journaling + planning sessions. Once your diet + fitness profiles exist, the scored defaults "Eat clean" (clean-meal ratio) and "Sleep well" (deviation vs your normal sleep window) are seeded automatically.
argument-hint: (none) | track | list | history --name "X" | scores [--date YYYY-MM-DD] | profile show|new|commit
---
Run this with the Bash tool first (substituting any argument for `$ARGUMENTS`), then follow the INSTRUCTIONS block in its output:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/habits.sh" "$ARGUMENTS"
```

The script prints one of:

- `HABITS_SETUP_PROFILE` — first run, no profile yet. Follow its INSTRUCTIONS: ask ONE question at a time, starting with "suggest from your entries, or specify yourself?", then gather each habit's own criteria and create it with the `add` subcommand (which mints a stable id and writes valid JSON — never hand-edit the file).
- `HABITS_DASHBOARD` — profile exists. Give a tight read of the rollup (lead with what needs attention — ⚠️ over-cap, ⏳ high-priority not yet met, nice streaks), then offer to open today's tracker, mark a habit, add/edit/archive one, or show history. Use the subcommands shown; never hand-edit the profile JSON or the tracking table directly. Daily build habits can be linked to a per-day Apple Reminder kept in two-way sync (🔔 in the rollup); this is opt-in per habit — only when the user asks, set one up (`reminder --id <id> --link --time HH:MM`, or `--decline`), don't proactively nag. The dashboard output also carries a HABIT EXTRACTION block: if the user has evidenced any tracked habit in this session (this turn or a later one — e.g. "I had one unclean meal"), MARK it per that block instead of waiting to be asked, so progress updates in the same run. Marking is idempotent, so it's safe.
- `HABITS_TRACK_FILE` — today's dated tracking markdown was created/refreshed; tell the user where it is and that they can tick the Done column (or you'll mark cells as they mention habits).
- `HABITS_LIST` — just relay the configured habits.
- `HISTORY: …` — relay the event history for that habit.
- `HABITS_PROFILE_SHOW` / `HABITS_PROFILE_NEW` / `HABITS_PROFILE_COMMITTED` — the versioned-profile subcommand (`profile show|new|commit`). The profile lives in the store at `life/habit-tracking/.profile/habits-profile.vN.md`; day-to-day `add`/`edit`/`archive` keep amending the latest version in place (living document) — `profile new` mints a draft only for structural redesigns, `profile commit` freezes it. **Never auto-commit a draft:** after any change to a draft, show what changed and ask "Want to lock this in?" — only run `profile commit` on explicit yes / "lock" / "commit". More edits → keep modifying the same open draft, do NOT mint a new version. If a draft is already open at session start, continue editing it.

Tracking model: the dated `life/habit-tracking/<date>.md` files are the human-facing log; the SQLite DB is synced from them (read commands sync first; `/end-of-day` consolidates). Mark habits with `mark` (ticks the md), not `log`. Don't pad. This is a dashboard, not a coaching session.

Scored habits: never pick the score yourself — pass raw inputs and the profile rule computes the 0–100 value (the model only classifies; `score_from_spec` in `lib/habits.sh` — the canonical reference — does the math). The scoring types and how to feed them:

- `slip_ladder` — counts → ladder index.
- `meal_ratio` (Eat clean) — score = 100·clean/(clean+unclean) meals; `mark --name "Eat clean" --good <clean meals> --bad <unclean meals>` (scales with how many meals the day had).
- `deviation` (Sleep well) — slips from the circular bed-time diff vs `normal_time` (per `unit_minutes`) + hours shortfall vs `normal_hours` (per `unit_hours`), ladder-indexed; `mark --name "Sleep well" --actual-time HH:MM --actual-hours N.N` (bed time + slept hours; normal window from the fitness profile).
- `weighted_completion` (Work the plan) — score = 100·earned/possible; per-task weight = `difficulty_weights[difficulty]` (easy1/normal2/hard3/nightmare5) × priority boost (`1 + max(0, priority_pivot−priority)·priority_step`, pivot 3 step 0.25); credit = `status_credit[status]` (done1/partial0.5/dropped,carried0); every planned task is in the denominator (overplanning costs you); pass `--items '[{"priority":1,"difficulty":"hard","status":"done"},…]'`.
- `session_volume` (Train) — skipped→0; strength/duration with planned>0 & actual present → 100·clamp(actual/planned,0,volume_cap) (cap 1.0); else binary 100·status_credit[status] (completed100/partial50); pass `--session '{"mode":"strength|duration|binary","status":…,"planned":N,"actual":N}'`.
- `focus_ratio` (Deep work) — score = 100·work/(work+distraction) of *active* minutes; `work_categories`/`distraction_categories` default `["work"]`/`["social","entertainment"]`; `neutral`+`afk` excluded; w+d=0 → unmarked; pass `--focus '{"work":120,"social":30,…}'`.
- `checklist` — fixed daily set of named weighted `components`; score = 100·sum(done weights)/sum(all weights); pass parts done by name or id as `--done '[…]'`.

When a seeding line ("Added default habit: …") appears in the output, mention it to the user in one line.

Habit↔reminder linking: per-day ONE-SHOT reminder on the days the schedule is due (not Apple-recurring); the link is an intent on the habit (`"reminder":{"state":"linked","time":"HH:MM"}`), while the per-day reminder ids live in the DB table `habit_reminders(habit_id,occurred_on,reminder_id,status)` (idempotency PK). Two-way sync runs via `reminders-ensure` / `reminders-sync [--sweep]`. `reminders-reschedule --habit <name> --time HH:MM [--date]` moves a pending one-shot's due time (used by `/plan-my-day` to align it with the planned block); it returns one of `RESCHEDULED | NOT_LINKED | NOT_FOUND | UNAVAILABLE`.
