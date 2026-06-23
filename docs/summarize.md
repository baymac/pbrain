# /summarize

Summarize a **vault folder** of notes or transcripts into a faithful, prompt-driven summary written back into the vault. You point it at a folder; the script reads every note inside and concatenates them, and Claude reframes the corpus into a clean summary following a per-type **summarize prompt**. The input is always read-only — the summary lands in a new file under `agent-work/`, your source notes are never touched.

It's built around **content-type subcommands** (the same shape as `/clipper`'s platform subcommands), starting with one:

| Subcommand | Source | Summarize prompt |
|---|---|---|
| `webinar` | a folder of (trading) webinar transcripts | full faithful capture — keep every tool / strategy / market, strip course-selling + interpersonal filler |

**Default destination:** `$VAULT_DIR/agent-work/summaries/<type>/<slug>.md`

## How it works

The script does the mechanical work so nothing has to be figured out at run time:

1. **Resolve the folder.** The input is a vault folder — a vault-relative path, an absolute path inside the vault, or an Obsidian `[[link]]`. It's resolved against the vault root and refused if it points outside the vault or doesn't exist.
2. **Gather the corpus.** It walks the folder recursively, collects every `.md` and `.txt` file (sorted, dotfiles/dotdirs skipped), and concatenates them into one **RAW CORPUS** with a `--- <relative path> ---` header before each file, so multi-session folders stay legible.
3. **Hand off to the model.** It emits `SUMMARIZE_WRITE` with the corpus + metadata, then appends the per-type instructions from `commands/templates/summarize/<type>.txt`. Claude follows that prompt to produce the summary and writes it to the output path.

The split is deliberate: the `.sh` is the deterministic half (resolve, walk, concatenate, choose the path), and the model only reframes the corpus into faithful prose the prompt dictates — never a lossy TL;DR beyond what the prompt asks for.

## Usage

```
/summarize webinar <vault-folder>
```

Filler words are ignored, so "summarize webinar this folder Trading/Webinars/June" works the same as `webinar Trading/Webinars/June`.

The output filename is the folder's slug; if it already exists, a dated suffix is added so a re-run never overwrites a prior summary.

## Environment

| Variable | Default | Purpose |
|---|---|---|
| `PBRAIN_SUMMARIZE_DIR` | `$VAULT_DIR/agent-work/summaries` | Parent dir; each content type gets a `<type>/` subdir under it. |
| `PBRAIN_SUMMARIZE_EXTS` | `md,txt` | Comma-separated file extensions to gather. |

## Adding a content type

Each type is a subcommand backed by its own prompt template. To add one (e.g. `lecture`, `meeting`): add the type to the `case` in `commands/summarize.sh`, drop a `commands/templates/summarize/<type>.txt` prompt (use `webinar.txt` as the model — it must reference `${OUT_FILE}`, `${TYPE}`, `${TODAY}`), and note it in this doc + the command index.
