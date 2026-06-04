#!/usr/bin/env bash
set -euo pipefail

# pbrain-codex-install.sh — make pbrain interoperable with the OpenAI Codex CLI.
#
# pbrain is primarily a Claude Code plugin. Its slash commands are .md + .sh
# pairs in commands/, and the .sh scripts are the SINGLE SOURCE OF TRUTH (they
# resolve the vault, read ~/.config/pbrain/*, and emit INSTRUCTIONS that any
# capable agent follows). This installer lets Codex run those exact same scripts
# by generating, in $CODEX_HOME (default ~/.codex):
#
#   prompts/pbrain-<cmd>.md   one Codex custom prompt per pbrain command — a thin
#                             wrapper that runs the SAME commands/<cmd>.sh. The
#                             .sh path is baked in (Codex has no CLAUDE_PLUGIN_ROOT)
#                             and every '$' except '$ARGUMENTS' is escaped to '$$'
#                             so Codex's prompt-placeholder expansion can't mangle
#                             shell vars / prose ($VAULT_DIR etc.). Excludes
#                             init-obsidian and pbrain-codex-install (Claude-side
#                             setup that runs before / alongside this).
#
#   AGENTS.md                 a delimited, managed pbrain block carrying the
#                             cross-command behaviour Codex needs (morning
#                             sequence, ride-along blocks, vault write rules, the
#                             launch command). Scoped so it only applies to pbrain
#                             work — it won't pollute unrelated Codex sessions.
#
# Nothing about the vault or config is duplicated: the generated prompts resolve
# the vault and read ~/.config/pbrain/* at RUNTIME, exactly like the Claude
# commands. So running pbrain via Codex one day and Claude Code the next shares
# one source of truth (scripts, vault, config, SQLite DB) and cannot conflict.
#
# Run this from Claude Code AFTER /init-obsidian. Idempotent — re-running
# refreshes every prompt, re-bakes the path, prunes stale managed prompts, and
# rewrites the managed AGENTS.md block in place.
#
# Env knobs:
#   PBRAIN_DEV_DIR   live repo path; when set at install time it is baked into the
#                    generated prompts (so a dev's Codex runs the live repo too).
#   CODEX_HOME       Codex home dir (default ~/.codex).

# --- Resolve this script's real location (deref symlinks), then the repo root.
_PB_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_PB_SRC" ]]; do
  _PB_LINK="$(readlink "$_PB_SRC")"
  [[ "$_PB_LINK" = /* ]] && _PB_SRC="$_PB_LINK" || _PB_SRC="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)/$_PB_LINK"
done
_SCRIPT_DIR="$(cd -P -- "$(dirname -- "$_PB_SRC")" && pwd -P)"
unset _PB_SRC _PB_LINK
REPO_ROOT="$(cd -P -- "$_SCRIPT_DIR/.." && pwd -P)"
CMD_DIR="$REPO_ROOT/commands"

# Path baked into the generated Codex prompts. A dev who has PBRAIN_DEV_DIR set
# gets prompts that point at their live repo; everyone else gets this install.
PBRAIN_ROOT="${PBRAIN_DEV_DIR:-$REPO_ROOT}"

# Codex targets.
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
PROMPTS_DIR="$CODEX_HOME/prompts"
AGENTS_FILE="$CODEX_HOME/AGENTS.md"

if [[ ! -d "$CMD_DIR" ]]; then
  echo "pbrain-codex-install: command sources not found at $CMD_DIR" >&2
  exit 1
fi

# --- Resolve the vault READ-ONLY (same order as lib/vault.sh) without exiting if
#     it is missing. This installer is a setup command and must run pre-vault.
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/vault"
VAULT_DIR=""
VAULT_SOURCE="default"
if [[ -n "${PBRAIN_VAULT:-}" ]]; then
  VAULT_DIR="$PBRAIN_VAULT"
  VAULT_SOURCE="env"
elif [[ -f "$CONFIG_FILE" ]]; then
  _v="$(head -n1 "$CONFIG_FILE" 2>/dev/null || true)"
  _v="${_v#"${_v%%[![:space:]]*}"}"
  _v="${_v%"${_v##*[![:space:]]}"}"
  if [[ -n "$_v" ]]; then
    VAULT_DIR="${_v/#\~/$HOME}"
    VAULT_SOURCE="config"
  fi
  unset _v
fi
if [[ -z "$VAULT_DIR" ]]; then
  VAULT_DIR="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault"
  VAULT_SOURCE="default"
fi
if [[ -d "$VAULT_DIR" ]]; then VAULT_EXISTS=yes; else VAULT_EXISTS=no; fi

mkdir -p "$PROMPTS_DIR"

# --- Generate one Codex custom prompt per pbrain command + prune stale ones. ---
# The transform is deterministic; Python (stdlib only) does the string work.
python3 - "$CMD_DIR" "$PROMPTS_DIR" "$PBRAIN_ROOT" <<'PYEOF'
import glob, os, re, sys

cmd_dir, prompts_dir, pbrain_root = sys.argv[1], sys.argv[2], sys.argv[3]

# Claude-side setup commands that do NOT get a Codex prompt.
EXCLUDE = {"init-obsidian", "pbrain-codex-install"}
MARKER = "pbrain-codex-managed"

# The exact path token every command .md uses to locate its .sh under Claude
# Code. Codex has no CLAUDE_PLUGIN_ROOT, so we bake an absolute path instead.
TOKEN = "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}"
TOKEN_RE = re.compile(r"\$\{PBRAIN_DEV_DIR:-\$\{CLAUDE_PLUGIN_ROOT:-[^{}]*\}\}")

sources = sorted(
    os.path.splitext(os.path.basename(p))[0]
    for p in glob.glob(os.path.join(cmd_dir, "*.md"))
)
gen_names = [n for n in sources if n not in EXCLUDE]
gen_set = set(gen_names)
# Longest first so /diet-journal is rewritten before /journal, etc.
by_len = sorted(gen_names, key=len, reverse=True)

FM_RE = re.compile(r"^(---\n.*?\n---\n)(.*)$", re.S)
ARGS_SENTINEL = "\x00ARGS\x00"
PATH_SENTINEL = "\x00ROOT\x00"


def transform(text, name):
    m = FM_RE.match(text)
    fm, body = (m.group(1), m.group(2)) if m else ("", text)

    # 1. Stand the .sh path aside behind a sentinel (exact match first, regex as
    #    a safety net). We splice the real path back in LAST — after the
    #    $-escaping below — so a '$' that happens to live in the install path
    #    (even the literal string "$ARGUMENTS", e.g. a dir named that) can't be
    #    mistaken for the user-argument placeholder.
    if TOKEN in body:
        body = body.replace(TOKEN, PATH_SENTINEL)
    body = TOKEN_RE.sub(lambda _m: PATH_SENTINEL, body)

    # 2. Point references to pbrain's OWN slash commands at their Codex names.
    #    /journal -> /prompts:pbrain-journal. Non-pbrain refs (e.g. /office-hours)
    #    and /init-obsidian are left untouched. Boundaries keep us from matching
    #    inside paths like commands/journal.sh.
    for n in by_len:
        body = re.sub(
            r"(?<![\w/-])/" + re.escape(n) + r"(?![\w-])",
            "/prompts:pbrain-" + n,
            body,
        )

    # 3. Codex runs shell directly — soften Claude's "the Bash tool" phrasing.
    body = body.replace("with the Bash tool", "in your shell")
    body = body.replace("the Bash tool", "your shell")

    # 4. Escape every '$' to '$$' EXCEPT the one real placeholder, $ARGUMENTS.
    #    Codex expands $NAME placeholders in a prompt body; without this, prose
    #    like $VAULT_DIR and the shell vars in any code block would be mangled.
    body = body.replace("${ARGUMENTS}", ARGS_SENTINEL).replace("$ARGUMENTS", ARGS_SENTINEL)
    body = body.replace("$", "$$")
    body = body.replace(ARGS_SENTINEL, "$ARGUMENTS")

    # 5. Splice the real path back in. A '$' in the path becomes '$$' so Codex
    #    emits it literally; the normal (no-'$') path is inserted verbatim.
    body = body.replace(PATH_SENTINEL, pbrain_root.replace("$", "$$"))

    header = (
        "<!-- %s | AUTOGENERATED from commands/%s.md by /pbrain-codex-install.\n"
        "     Do NOT edit here — edit the source in the pbrain repo and re-run\n"
        "     /pbrain-codex-install (from Claude Code) to refresh. -->\n" % (MARKER, name)
    )
    return fm + header + body


generated = []
skipped_unmanaged = []
for name in gen_names:
    src = os.path.join(cmd_dir, name + ".md")
    sh = os.path.join(cmd_dir, name + ".sh")
    # A prompt that points at a missing .sh would fail cryptically at runtime —
    # skip it instead of shipping a broken wrapper.
    if not os.path.exists(sh):
        print("WARN: %s has no matching %s — skipped" % (src, sh), file=sys.stderr)
        continue
    try:
        with open(src, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        print("WARN: could not read %s (%s) — skipped" % (src, e), file=sys.stderr)
        continue
    dst = os.path.join(prompts_dir, "pbrain-%s.md" % name)
    # Safety: never clobber a same-named prompt the user authored. We only own
    # files carrying our marker — the same rule the stale-prune below uses.
    if os.path.exists(dst):
        try:
            with open(dst, encoding="utf-8") as fh:
                if MARKER not in fh.read():
                    print("SKIP: %s exists and is not pbrain-managed — left untouched" % dst, file=sys.stderr)
                    skipped_unmanaged.append(name)
                    continue
        except OSError:
            pass
    out = transform(text, name)
    tmp = dst + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(out)
        os.replace(tmp, dst)
    except OSError as e:
        print("WARN: could not write %s (%s) — skipped" % (dst, e), file=sys.stderr)
        continue
    generated.append(name)

# Prune stale managed prompts (command renamed/removed). Only ever delete files
# that carry OUR marker — never touch the user's own Codex prompts.
removed = []
for f in glob.glob(os.path.join(prompts_dir, "pbrain-*.md")):
    base = os.path.basename(f)
    name = base[len("pbrain-"):-len(".md")]
    if name in gen_set:
        continue
    try:
        with open(f, encoding="utf-8") as fh:
            if MARKER in fh.read():
                os.remove(f)
                removed.append(name)
    except OSError:
        pass

print("PROMPTS_GENERATED=%d" % len(generated))
print("PROMPTS_LIST=%s" % " ".join("pbrain-%s" % n for n in generated))
if removed:
    print("PROMPTS_PRUNED=%s" % " ".join("pbrain-%s" % n for n in removed))
if skipped_unmanaged:
    print("PROMPTS_SKIPPED_UNMANAGED=%s" % " ".join("pbrain-%s" % n for n in skipped_unmanaged))
PYEOF

# --- Write / refresh the managed pbrain block in $CODEX_HOME/AGENTS.md. ---
python3 - "$AGENTS_FILE" "$VAULT_DIR" "$VAULT_EXISTS" <<'PYEOF'
import os, re, sys

agents_file, vault_dir, vault_exists = sys.argv[1], sys.argv[2], sys.argv[3]

START = "<!-- >>> pbrain (managed by /pbrain-codex-install) — do not edit between these markers; re-run /pbrain-codex-install to refresh >>> -->"
END = "<!-- <<< pbrain (managed by /pbrain-codex-install) <<< -->"

if vault_exists == "yes":
    vault_ref = vault_dir
    launch = ('codex --sandbox workspace-write '
              '--add-dir "%s" --add-dir "$HOME/.config/pbrain"' % vault_dir)
else:
    vault_ref = "your pbrain vault (set up via /init-obsidian from Claude Code)"
    launch = ('codex --sandbox workspace-write '
              '--add-dir "<your-vault-path>" --add-dir "$HOME/.config/pbrain"')

block = """%s
## pbrain (Obsidian daily-ritual commands)

These rules apply **only** when you are running a pbrain command (a
`/prompts:pbrain-*` custom prompt) or working inside the pbrain Obsidian vault
(`%s`). Ignore them for any unrelated work.

pbrain is primarily a Claude Code plugin. This block plus the
`~/.codex/prompts/pbrain-*.md` prompts let Codex run the **same** commands
against the **same** vault and config. The shell scripts are the single source
of truth: every prompt just runs one of them, and you then follow the
`INSTRUCTIONS:` block it prints to stdout.

**Invoking pbrain here.** Each command is a Codex custom prompt named
`pbrain-<command>` (e.g. `/prompts:pbrain-journal`,
`/prompts:pbrain-plan-my-day`). Where a pbrain instruction mentions a slash
command such as `/journal` or `/gratitude-journal`, the Codex equivalent is
`/prompts:pbrain-journal`, `/prompts:pbrain-gratitude-journal`, and so on.
Vault setup (`/init-obsidian`) and the Codex installer itself run from Claude
Code, not Codex.

**Morning sequence (journal → gratitude → everything else).** Before running
any pbrain command other than `journal`, `gratitude-journal`, or `remind`,
check today's files (use today's date as `YYYY-MM-DD`):
1. If `%s/life/daily-tracking/<TODAY>.md` is missing → suggest running
   `/prompts:pbrain-journal` first, then pause.
2. Else if `%s/life/gratitude-journal/<TODAY>.md` is missing → suggest
   `/prompts:pbrain-gratitude-journal` next, then pause.
Suggest once, never block. A standing `USER PREFERENCES` skip (below) overrides
this — and every other built-in nudge.

**Ride-along blocks.** pbrain scripts print labelled blocks in their output —
`USER PREFERENCES`, `SELF-IMPROVE CHECK`, `HABIT EXTRACTION`, `HABIT SUGGEST`,
and a single `UPGRADE_AVAILABLE <old> <new>` line. Each block carries its own
instructions; follow them inline. For `UPGRADE_AVAILABLE`, tell the user a newer
pbrain is out and that `/plugin update pbrain` (from Claude Code) upgrades it,
then continue the command's real work.

**Writing into the vault.** Agent-generated content goes under `agent-work/`
(`brainstorms/`, `drafts/`, `notes/`, `research/`, `people/`, `chat-history/`).
User-curated folders (`life/`, `fitness/`, `startup/`, …) are off-limits unless
a command writes there by design or the user says so. The daily journal under
`life/daily-tracking/` is user-owned — the journal command only stubs it.

**Sandbox / launch.** pbrain writes to the vault and to `~/.config/pbrain`
(config, prefs, the local SQLite DB). Launch Codex with BOTH writable, e.g.:

    %s

Include both `--add-dir` flags every time: without the `~/.config/pbrain` one,
commands still run but preferences, reminders, and habit state can't be saved —
so they silently desync from Claude Code. The background version check wants
network and silently no-ops without it (expected, harmless). One-time setup that
writes elsewhere — vault creation (`/init-obsidian`) and the background reminder
poller (`/remind install`, which writes `~/Library/LaunchAgents`) — is best run
from Claude Code; everyday `/prompts:pbrain-remind` (add / list / done) works
fine here.
%s""" % (START, vault_ref, vault_ref, vault_ref, launch, END)

block_re = re.compile(
    re.escape(START) + r".*?" + re.escape(END), re.S
)

if os.path.exists(agents_file):
    try:
        with open(agents_file, encoding="utf-8") as f:
            content = f.read()
    except OSError as e:
        print("WARN: could not read %s (%s) — skipping AGENTS.md update" % (agents_file, e), file=sys.stderr)
        sys.exit(0)
    if block_re.search(content):
        content = block_re.sub(lambda _m: block, content)
        action = "updated"
    else:
        if content and not content.endswith("\n"):
            content += "\n"
        content = content + ("\n" if content else "") + block + "\n"
        action = "appended"
else:
    content = block + "\n"
    action = "created"

_agents_dir = os.path.dirname(agents_file)
if _agents_dir:
    os.makedirs(_agents_dir, exist_ok=True)
tmp = agents_file + ".tmp"
try:
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(content)
    os.replace(tmp, agents_file)
except OSError as e:
    print("WARN: could not write %s (%s) — check permissions and re-run" % (agents_file, e), file=sys.stderr)
    sys.exit(0)
print("AGENTS_BLOCK=%s" % action)
PYEOF

# --- Recap for the calling agent to relay. ---
if command -v codex >/dev/null 2>&1; then
  CODEX_DETECTED=yes
else
  CODEX_DETECTED=no
fi

n_prompts="$(ls "$PROMPTS_DIR"/pbrain-*.md 2>/dev/null | wc -l | tr -d ' ')"

echo
echo "PBRAIN_CODEX_INSTALLED"
echo "prompts_dir=$PROMPTS_DIR"
echo "prompts_count=$n_prompts"
echo "agents_file=$AGENTS_FILE"
echo "pbrain_root_baked=$PBRAIN_ROOT"
echo "codex_detected=$CODEX_DETECTED"
if [[ "$VAULT_EXISTS" == "yes" ]]; then
  echo "vault=$VAULT_DIR"
  echo "vault_source=$VAULT_SOURCE"
else
  echo "vault=NOT_CONFIGURED"
fi
echo
echo "launch_command:"
if [[ "$VAULT_EXISTS" == "yes" ]]; then
  echo "  codex --sandbox workspace-write --add-dir \"$VAULT_DIR\" --add-dir \"\$HOME/.config/pbrain\""
else
  echo "  codex --sandbox workspace-write --add-dir \"<your-vault-path>\" --add-dir \"\$HOME/.config/pbrain\""
fi
echo
cat <<'INSTR'
INSTRUCTIONS (for the calling agent): relay this to the user concisely.

1. Confirm pbrain is now usable from the OpenAI Codex CLI: every pbrain command
   is installed as a Codex custom prompt named `/prompts:pbrain-<command>`
   (e.g. `/prompts:pbrain-journal`, `/prompts:pbrain-plan-my-day`,
   `/prompts:pbrain-brainstorm "idea"`). They run the SAME shell scripts as the
   Claude commands and read the SAME vault + `~/.config/pbrain` config + SQLite
   DB — so it is safe to alternate between Codex and Claude Code with no
   conflicts and one source of truth.

2. Tell the user HOW TO LAUNCH Codex so pbrain can write to the vault and config
   without per-write approval — show the `launch_command` printed above verbatim
   (it already has the resolved vault path). Mention they can wrap it in a shell
   alias. Then inside Codex they type `/prompts:pbrain-journal`, etc.

3. If `vault=NOT_CONFIGURED`: tell them to run `/init-obsidian` from Claude Code
   first, then re-run `/pbrain-codex-install` so the vault path gets baked into
   the launch command and the AGENTS.md block.

4. If `codex_detected=no`: note that the Codex CLI was not found on PATH — the
   prompts and AGENTS.md block are installed and will work once Codex is
   installed (https://developers.openai.com/codex/cli).

5. Note it is idempotent: re-run `/pbrain-codex-install` from Claude Code after
   moving/reinstalling pbrain or when new commands ship.

Keep it tight — a short confirmation plus the launch command and one example
invocation is enough. Do not paste this whole block back.
INSTR
