---
description: Summarize a vault folder of notes / transcripts into a faithful, prompt-driven summary written under agent-work/. Subcommands per content type — `webinar` first — each carrying its own summarize prompt. The script does the mechanical work (resolve the folder, walk it, concatenate every .md/.txt into one corpus); you only reframe that corpus into prose following the type's prompt.
argument-hint: webinar <vault-folder>
---
Run this with the Bash tool first (substituting the user's words for `$ARGUMENTS`), then follow the INSTRUCTIONS in the token it prints:

```bash
bash "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}/commands/summarize.sh" $ARGUMENTS
```

`summarize` reads a **vault folder** of notes/transcripts and writes a faithful, prompt-driven summary into the vault. The first arg is the **content type** (a subcommand); the rest is the folder (a vault path or an Obsidian `[[link]]`). Filler words are ignored, so "summarize webinar this folder Trading/Webinars/June" passes through as `webinar Trading/Webinars/June`.

It mirrors `/clipper`'s shape: the **script** owns every mechanical step — it resolves the input folder against the vault, walks it (every `.md`/`.txt`, recursively, sorted), and concatenates the files into one **RAW CORPUS** behind `--- <file> ---` headers — and hands that to you. Each content type carries its **own summarize prompt** (in `commands/templates/summarize/<type>.txt`); your only job is to reframe the corpus into prose that follows that prompt, then write the file. It prints one of:

- `SUMMARIZE_WRITE` — the success path. The data block has the metadata (type, `source_folder`, `file_count`, `corpus_words`, `output_file`, `captured`) and the **RAW CORPUS**. Follow the per-type instructions appended after it (loaded from `templates/summarize/<type>.txt`): produce the summary the prompt dictates — for `webinar`, a faithful full capture of everything said about trading (keep all **tools / strategies / markets**, strip course-selling + interpersonal filler), NOT a lossy TL;DR. Write the file to `output_file` with the given frontmatter, then confirm the title + path in one line.
- `SUMMARIZE_USAGE` — no type (or `help`) was given. Relay the supported content types in one line and ask which folder to summarize.
- `SUMMARIZE_UNKNOWN_TYPE` — the first arg isn't a known content type (only `webinar` so far). Tell the user and ask them to re-run as `summarize webinar <folder>`.
- `SUMMARIZE_NO_INPUT` — a type but no folder. Ask which vault folder to summarize, then re-run.
- `SUMMARIZE_NOT_FOUND` — the path doesn't resolve to a vault folder (`reason: missing`) or resolves outside the vault (`reason: outside-vault`). summarize only reads vault folders — relay the gist and ask for a vault folder. Don't fabricate.
- `SUMMARIZE_EMPTY` — the folder exists but has no `.md`/`.txt` files to read. Tell the user and ask for a folder that contains notes/transcripts.

Default write path: `$VAULT_DIR/agent-work/summaries/<type>/<slug>.md` (slug = the folder name; collisions get a dated suffix, so it never overwrites). Override the parent with `PBRAIN_SUMMARIZE_DIR`; the gathered file extensions with `PBRAIN_SUMMARIZE_EXTS` (default `md,txt`). The input is always **read-only** — "in-place full update" in the webinar prompt means the summary covers everything said, not that the source notes are edited.
