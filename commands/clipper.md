---
description: Save an online video as a clean, readable long-form transcript ("clip") in the vault. Subcommands per platform — `x` (X / Twitter) and `yt` (YouTube). The script does all the technical work (cookies, download, subtitle selection, VTT cleanup, audio-transcription fallback) and hands you a clean transcript; you only reframe it into faithful, lightly-cleaned prose — not a summary.
argument-hint: x <url> | yt <url>
---
Run this with the Bash tool first (substituting the user's words for `$ARGUMENTS`), then follow the INSTRUCTIONS in the token it prints:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/clipper.sh" $ARGUMENTS
```

`clipper` saves a video as a readable piece in the vault. The first arg is the **platform** (`x` or `yt`); the rest is the URL. Filler words are ignored, so "clipper x save this video https://x.com/…" passes through as `x https://x.com/…`. When the user says *"clipper save this video <url>"* without a platform, infer it from the URL host (`x.com`/`twitter.com` → `x`, `youtube.com`/`youtu.be` → `yt`) and pass that as the first arg.

The **script** owns every technical step so you don't have to at runtime: it reads browser cookies (Brave by default — X gates video + captions behind a session), pulls metadata, downloads the subtitle track, cleans the VTT (strips inline timing tags and the rolling-window duplication of auto-captions), and — if there's no caption track — falls back to transcribing the audio locally with **FluidAudio's Parakeet TDT v3** model (the same model Muesli uses). It then prints one of:

- `CLIPPER_SAVE` — the success path. The data block has the metadata (title, author, source_url, duration, …), the **POST / DESCRIPTION TEXT** (the author's own written caption, context only), and the **RAW TRANSCRIPT** (already de-duplicated; `transcript_source` says whether it came from captions or Parakeet v3). Follow `commands/templates/clipper/write.txt`: reframe the transcript into clean prose — **faithful and near-verbatim, lightly cleaned, NOT summarized**. Fix punctuation/paragraphs, drop filler + restated phrases + ads/intros/plugs, keep the speaker's wording and length. Write the file to `output_file` with the given frontmatter, then confirm the title + path in one line.
- `CLIPPER_NO_TRANSCRIPT` — no captions, and either the Parakeet v3 transcriber isn't built (`fluidaudio_bin: (not built)`) or transcription produced nothing. If it's not built, tell the user to run `/clipper transcriber install` once (a ~1–3 min build of `fluidaudiocli`; the v3 model then downloads on first use), then re-run. Either way, offer to save just the post's own text as a short note. Do **not** invent a transcript.
- `CLIPPER_TRANSCRIBER_INSTALL` / `CLIPPER_TRANSCRIBER_STATUS` — output of `transcriber install|status`. `install` builds + caches the `fluidaudiocli` binary from source (needs git + the Swift toolchain); the build runs synchronously, so invoke that Bash call with an **extended timeout** (a few minutes). `status` reports whether the binary + the Parakeet v3 model are present. Relay the result in one line.
- `CLIPPER_FETCH_FAILED` — yt-dlp couldn't read the video (private/age-gated/region-locked, bad URL, or stale/locked cookies). Relay the gist of the error; suggest closing the browser or pointing `PBRAIN_CLIPPER_COOKIES_BROWSER` / `PBRAIN_CLIPPER_COOKIES_FILE` elsewhere. Don't fabricate.
- `CLIPPER_NO_YTDLP` — yt-dlp isn't installed; tell the user to install it (`brew install yt-dlp` / `pip install -U yt-dlp`).
- `CLIPPER_NO_URL` / `CLIPPER_UNKNOWN_PLATFORM` / `CLIPPER_USAGE` — ask for the URL / explain the supported platforms.

Default write path: `$VAULT/agent-work/clips/<platform>/<slug>.md` (override `PBRAIN_CLIPPER_DIR`). Cookie source: `PBRAIN_CLIPPER_COOKIES_BROWSER` (default `brave`; `none` disables) or `PBRAIN_CLIPPER_COOKIES_FILE`. The transcriber reuses the cached Parakeet v3 model at `~/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml` when present (and only that model); otherwise the CLI downloads it on first use.
