# pbrain — Promo Design System

A promo film, not a user guide. The story is **compounding**: a quiet daily ritual that, left running for months, becomes a second brain you own. Tone is calm, premium, local-first. The tension is **machine vs human** — terminal scaffolding (monospace) holding personal reflection (serif).

## Palette (dark, violet-tinted — Obsidian heritage)

| Token | Hex | Use |
|---|---|---|
| `bg` | `#0c0a12` | Canvas. Near-black, tinted violet. Never pure #000. |
| `bg-raise` | `#15121f` | Raised panels, cards, terminal blocks. |
| `fg` | `#ece8f4` | Primary text (warm off-white). |
| `fg-dim` | `#9a93ad` | Secondary text, labels, metadata. |
| `violet` | `#a786ff` | PRIMARY accent. Obsidian heritage. Focal text, glow, command sigils. |
| `violet-deep` | `#6d4dd6` | Deeper violet for glows/gradients. |
| `coral` | `#e8a06a` | WARM accent — the human beat (journal, gratitude, ritual). Use sparingly. |
| `line` | `#2a2438` | Hairline rules, dividers, grid. |
| `ok` | `#7fd4a8` | "done" / checkmark / streak-complete green. |

Glows: violet at 15-25% for atmosphere, full saturation for focal hits. Coral only on human/reflection beats.

## Typography

Two voices in conversation — not a hierarchy.

- **Statements / hero (human voice):** `Source Serif 4` — clean, premium transitional serif. Weights 300 (light, contemplative) and 900 (display). Extreme weight contrast. `letter-spacing: -0.02em` on display.
- **Machine / commands / data / labels (system voice):** `JetBrains Mono` — terminal scaffolding. Weights 400–700. Used for slash commands, file paths, dates, counters, metadata. `font-variant-numeric: tabular-nums` on all numbers/counters.

Serif speaks the user's reflection; mono speaks the tool. That disagreement IS the product: a machine ritual that produces human continuity.

Sizes (video scale): hero 96–160px, statements 56–80px, body 30–38px, labels/mono-meta 20–26px.

## Motion

Calm/premium energy. Primary transition: **blur crossfade** (`sine.inOut`, 0.5–0.7s, 20–28px blur) — "this continues." Accent: **focus pull** into the centerpiece (the compounding beat) and a soft **color dip** on the final outro. No glitch, no zoom-through — restraint over flash.

Entrances decelerate (`.out`), vary eases (power3 / expo / sine / power2), enter from varied directions. Ambient motion every scene: slow violet glow breathing, faint drift. Stillness after the peak.

## What NOT to do

- No gradient text (`background-clip: text`).
- No left-edge accent stripes on cards.
- No pure `#000` / `#fff` — always the tinted tokens.
- No two sans-serifs. Serif + mono only.
- No cyan / neon. Violet + warm coral is the whole story.
- No feature-grid "user guide" energy. This sells the *feeling of compounding*, not a command list.
- No zoom-through or glitch transitions. Calm and premium.
