# Screenshots

Visuals for the pbrain README. Capture and drop them here, then reference from the root `README.md`.

## What to capture

The README needs three images at minimum, in this priority order:

### 1. `hero.png` — single image, top of README
The "what does this actually look like" shot. Best option: a side-by-side of Obsidian (showing the vault file tree + an open daily journal) and a Claude Code terminal window mid-`/plan-my-day` conversation. Crop tight. ~1200px wide.

### 2. `plan-my-day.png` — `/plan-my-day` output
A full plan, anchored on the user's goals profile, with today's fitness session called out. Show the agent's plan and a hint of the dialogue above it.

### 3. `weekly-review.png` — `/weekly-review` synthesis
The agent's 3-5 bullet "here's what I'm seeing from your week" block, followed by the three questions. This is the closest pbrain comes to a "wow" demo — show it.

## Optional but nice

- `vault-tree.png` — Obsidian sidebar showing the canonical folder layout (`life/`, `fitness/`, `agent-work/`, etc.).
- `gratitude-journal.png` — the three-question gratitude flow, especially the rotating reflection question.
- `recall.png` — `/recall <topic>` printing matches across multiple folders, plus the agent's synthesis.

## Capture conventions

- macOS: `Cmd+Shift+4 → space → click window` for clean per-window grabs.
- Use a vault populated with at least 2 weeks of real-looking entries — empty templates do not sell the tool.
- Scrub anything personal (full names, addresses, real metrics you'd rather not publish). Use the private `.nosync/` dir for the real entries; capture from a separate demo vault if needed.
- Keep image width ≤ 1200px so the README doesn't blow out on narrow viewports.
- Prefer PNG over GIF. If you want motion, one short MP4 in `docs/videos/` and a static thumbnail PNG here.

## After capture

Reference the images in `README.md` with relative paths:

```markdown
![pbrain in action](docs/images/hero.png)
```

A "Screenshots" section just below the headline is the conventional spot. Update [`CHANGELOG.md`](../../CHANGELOG.md) under `[Unreleased]` when you add them.
