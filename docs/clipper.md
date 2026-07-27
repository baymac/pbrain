# /clipper

Save online content as a clean, readable long-form piece in the vault — a "clip". Two kinds of source are supported:

- **Videos** — the script extracts the captions and Claude reframes them into flowing prose. **Faithful, not summarized:** it keeps the speaker's words, meaning, and order — just adds punctuation and paragraphs, drops filler and noise (ads, channel plugs, "smash subscribe", off-topic self-intros), and trims immediate repetition. The result reads like a blog post or essay, roughly as long as what was actually said.
- **X longform articles** — the article text is already written prose, so it's saved **verbatim**; only extraction artifacts are cleaned up. Nothing is reworded or summarized.

It's built around **platform subcommands**:

| Subcommand | Source |
|---|---|
| `x` | X / Twitter — **video or longform article** (auto-detected) |
| `yt` | YouTube video |

**Default destination:** `$VAULT_DIR/agent-work/clips/<platform>/<slug>.md`

## Videos vs. articles on X

`/clipper x <url>` handles both and picks the path from the **URL shape**:

| URL | Path |
|---|---|
| `x.com/i/articles/…` | article |
| `x.com/<handle>/article/…` | article |
| `x.com/<handle>/status/…` | video |

Articles are read with a **headless browser** rather than `yt-dlp`. X renders longform articles client-side, so a plain fetch returns only the "JavaScript is not available" shell — there's no way to read one without a browser. The browser runs through [`uv`](https://docs.astral.sh/uv/) in an ephemeral environment (Playwright + Chromium, cached after the first run), so nothing is added to pbrain's own dependencies. **Video clipping is unaffected and needs no `uv`.**

Both paths share the **same session**: the cookie jar you already use for video is exported and handed to the browser, so there's no separate login to maintain. Only `x.com` / `twitter.com` cookies are forwarded.

## How it works

The script does all the technical work so nothing has to be figured out at run time:

1. **Cookies.** X gates videos, captions, and articles behind a logged-in session, so by default the script reads your **Brave** cookies (`--cookies-from-browser brave`). Point it elsewhere with `PBRAIN_CLIPPER_COOKIES_BROWSER` (e.g. `chrome`, `safari`, `brave:Profile 1`, or `none`) or a `cookies.txt` via `PBRAIN_CLIPPER_COOKIES_FILE`.
2. **Captions** *(video)*. It downloads the subtitle track with `yt-dlp` and cleans the VTT — strips inline timing tags and the rolling-window duplication that auto-captions produce — into a plain transcript.
3. **Fallback** *(video)*. If the video has no caption track, it downloads the audio and transcribes it locally with **FluidAudio's Parakeet TDT v3** CoreML model — the same model the Muesli app uses. It reuses the model already on disk (e.g. cached by Muesli) and only downloads it if it's missing. If the transcriber binary hasn't been built yet, it tells you to run `/clipper transcriber install` once.
4. **Extraction** *(article)*. It loads the page in headless Chromium, scrolls to hydrate lazy content, locates the article body, and converts it to Markdown. Images stay as absolute X CDN links (never inlined), so the clip stays small.
5. **Write.** Claude reframes the transcript (video) or cleans extraction artifacts (article) and writes the file.

## The Parakeet v3 transcriber (one-time setup)

For caption-less videos, clipper transcribes locally with Parakeet v3 via [FluidAudio](https://github.com/FluidInference/FluidAudio). There's no prebuilt CLI, so the first time you need it:

```
/clipper transcriber install   # builds fluidaudiocli from source (~1–3 min), then it's cached
/clipper transcriber status    # shows whether the binary + v3 model are present
```

- The build needs **git + the Swift toolchain** (Xcode command line tools: `xcode-select --install`). FluidAudio has no external dependencies, so the build is self-contained.
- The **Parakeet v3 model** auto-downloads on first transcription, or is reused in place if it's already cached at `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml` (e.g. from Muesli). This is the only model clipper uses.
- `ffmpeg` is needed to extract the audio (`brew install ffmpeg`).

## Requirements

- **`yt-dlp`** — `brew install yt-dlp` or `pip install -U yt-dlp`. (Videos; also used to export the cookie jar for articles.)
- A logged-in browser for X (Brave by default), so the cookie jar can authorize the fetch.
- **For caption-less videos only:** `ffmpeg` + the one-time `/clipper transcriber install` (git + Swift toolchain).
- **For X articles only:** [`uv`](https://docs.astral.sh/uv/) — `brew install uv`. Chromium downloads once on first use (~90 MB) and is cached under `~/.cache/pbrain/playwright`.

## Overrides

| Env var | Effect |
|---|---|
| `PBRAIN_VAULT` | Vault root (default: iCloud Obsidian path) |
| `PBRAIN_CLIPPER_DIR` | Clips parent dir (`<platform>` are subdirs) |
| `PBRAIN_CLIPPER_COOKIES_BROWSER` | Browser cookie jar (default `brave`; `none` disables) |
| `PBRAIN_CLIPPER_COOKIES_FILE` | Path to a Netscape `cookies.txt` (wins over the browser jar) |
| `PBRAIN_CLIPPER_SUB_LANGS` | `yt-dlp --sub-langs` (default `en,en-orig,en-US,en-GB`) |
| `PBRAIN_CLIPPER_FLUIDAUDIO_BIN` | Use a specific `fluidaudiocli` binary (skips the build) |
| `PBRAIN_CLIPPER_FLUIDAUDIO_DIR` | Where the CLI is cloned + built (default `~/.config/pbrain/fluidaudio`) |
| `PBRAIN_CLIPPER_FLUIDAUDIO_REF` | FluidAudio git tag to build (default `v0.15.4`) |
| `PBRAIN_CLIPPER_FLUIDAUDIO_MODEL_DIR` | Parakeet v3 model dir to reuse (default: the FluidAudio cache path) |

## Examples

```
/clipper x save this video https://x.com/someone/status/123456789
/clipper x https://twitter.com/someone/status/123456789
/clipper yt https://www.youtube.com/watch?v=abc123
```

Clips land in `agent-work/clips/` and are searchable via `/recall`.
