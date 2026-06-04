#!/usr/bin/env bash
set -euo pipefail

# codex-install.sh — make pbrain interoperable with the OpenAI Codex CLI.
#
# pbrain is primarily a Claude Code plugin. Its slash commands are .md + .sh
# pairs in commands/, and the .sh scripts are the SINGLE SOURCE OF TRUTH (they
# resolve the vault, read ~/.config/pbrain/*, and emit INSTRUCTIONS that any
# capable agent follows). This installer lets Codex run those exact same scripts
# by generating, in $CODEX_HOME (default ~/.codex):
#
#   skills/pbrain-<cmd>/SKILL.md   one Codex AGENT SKILL per pbrain command — a
#                                  thin wrapper that runs the SAME commands/<cmd>.sh.
#                                  Skills are Codex's supported, default-on reusable
#                                  capability (custom prompts are deprecated). Codex
#                                  surfaces each skill's name + description, and the
#                                  user invokes it by name (`journal`), explicitly
#                                  (`$pbrain-journal`), or implicitly (Codex auto-
#                                  selects on the description). The .sh path is baked
#                                  in (Codex has no CLAUDE_PLUGIN_ROOT). No '$'
#                                  escaping is needed: skills are read from disk
#                                  verbatim — unlike custom prompts, Codex does NOT
#                                  expand $NAME placeholders in a skill body, so
#                                  $VAULT_DIR / $ARGUMENTS survive as literal text.
#                                  Excludes init-obsidian and codex-install
#                                  (Claude-side setup that runs before / alongside).
#
#   AGENTS.md                      a delimited, managed pbrain block carrying the
#                                  cross-command behaviour Codex needs (how to
#                                  invoke, morning sequence, ride-along blocks,
#                                  vault write rules, launch command). Scoped so it
#                                  only applies to pbrain work.
#
# Nothing about the vault or config is duplicated: the generated skills resolve
# the vault and read ~/.config/pbrain/* at RUNTIME, exactly like the Claude
# commands. So running pbrain via Codex one day and Claude Code the next shares
# one source of truth (scripts, vault, config, SQLite DB) and cannot conflict.
#
# Run this from Claude Code AFTER /init-obsidian. Idempotent — re-running
# refreshes every skill, re-bakes the path, prunes stale managed skills, cleans
# up any old managed custom-prompts from earlier versions, and rewrites the
# managed AGENTS.md block in place.
#
# Env knobs:
#   PBRAIN_DEV_DIR   live repo path; when set at install time it is baked into the
#                    generated skills (so a dev's Codex runs the live repo too).
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

# Path baked into the generated Codex skills. A dev who has PBRAIN_DEV_DIR set
# gets skills that point at their live repo; everyone else gets this install.
PBRAIN_ROOT="${PBRAIN_DEV_DIR:-$REPO_ROOT}"

# Codex targets.
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
SKILLS_DIR="$CODEX_HOME/skills"
PROMPTS_DIR="$CODEX_HOME/prompts"   # only touched to clean up legacy managed prompts
AGENTS_FILE="$CODEX_HOME/AGENTS.md"

if [[ ! -d "$CMD_DIR" ]]; then
  echo "codex-install: command sources not found at $CMD_DIR" >&2
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

mkdir -p "$SKILLS_DIR"

# --- Generate one Codex skill per pbrain command, prune stale managed skills,
#     and clean up legacy managed custom-prompts from earlier installer versions.
# The transform is deterministic; Python (stdlib only) does the string work.
python3 - "$CMD_DIR" "$SKILLS_DIR" "$PROMPTS_DIR" "$PBRAIN_ROOT" <<'PYEOF'
import glob, os, re, shutil, sys

cmd_dir, skills_dir, prompts_dir, pbrain_root = \
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

# Claude-side setup commands that do NOT get a Codex skill.
EXCLUDE = {"init-obsidian", "codex-install"}
MARKER = "pbrain-codex-managed"

# The exact path token every command .md uses to locate its .sh under Claude
# Code. Codex has no CLAUDE_PLUGIN_ROOT, so we bake an absolute path instead.
TOKEN = "${PBRAIN_DEV_DIR:-${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/marketplaces/pbrain}}"
TOKEN_RE = re.compile(r"\$\{PBRAIN_DEV_DIR:-\$\{CLAUDE_PLUGIN_ROOT:-[^{}]*\}\}")

FM_RE = re.compile(r"^---\n(.*?)\n---\n(.*)$", re.S)
DESC_RE = re.compile(r"^description:[ \t]*(.*)$", re.M)

sources = sorted(
    os.path.splitext(os.path.basename(p))[0]
    for p in glob.glob(os.path.join(cmd_dir, "*.md"))
)
gen_names = [n for n in sources if n not in EXCLUDE]
gen_set = set(gen_names)


def yaml_dq(s):
    # YAML double-quoted scalar — bulletproof against ':' '#' quotes etc.
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def transform(text, name):
    m = FM_RE.match(text)
    fm_inner, body = (m.group(1), m.group(2)) if m else ("", text)
    dm = DESC_RE.search(fm_inner)
    description = dm.group(1).strip() if dm else ("pbrain %s command." % name)

    # 1. Bake the literal .sh path in place of the Claude-only path token
    #    (exact match first, regex as a safety net).
    body = body.replace(TOKEN, pbrain_root)
    body = TOKEN_RE.sub(lambda _m: pbrain_root, body)

    # 2. Codex runs shell directly — soften Claude's "the Bash tool" phrasing.
    body = body.replace("with the Bash tool", "in your shell")
    body = body.replace("the Bash tool", "your shell")

    # NOTE: no '$' escaping. Skills are read from disk verbatim; Codex does NOT
    # expand $NAME placeholders in a skill body (unlike the deprecated custom
    # prompts), so $VAULT_DIR / shell vars / prose survive as-is. $ARGUMENTS
    # likewise stays literal — the body's own prose ("substituting the user's
    # topic for $ARGUMENTS") tells the agent to splice the user's input in.
    # pbrain's own /<cmd> refs and non-pbrain refs (/office-hours) are left
    # verbatim too — they're prose the agent maps via the skills it can see.

    header = (
        "---\n"
        "name: pbrain-%s\n"
        "description: %s\n"
        "---\n"
        "<!-- %s | AUTOGENERATED from commands/%s.md by /codex-install.\n"
        "     Do NOT edit here — edit the source in the pbrain repo and re-run\n"
        "     /codex-install (from Claude Code) to refresh. -->\n"
        % (name, yaml_dq(description), MARKER, name)
    )
    return header + body


generated = []
skipped_unmanaged = []
for name in gen_names:
    src = os.path.join(cmd_dir, name + ".md")
    sh = os.path.join(cmd_dir, name + ".sh")
    # A skill that points at a missing .sh would fail cryptically at runtime —
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
    skill_dir = os.path.join(skills_dir, "pbrain-%s" % name)
    dst = os.path.join(skill_dir, "SKILL.md")
    # Safety: never clobber a same-named skill the user authored. We only own
    # SKILL.md files carrying our marker — the same rule the stale-prune uses.
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
    try:
        os.makedirs(skill_dir, exist_ok=True)
        tmp = dst + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(out)
        os.replace(tmp, dst)
    except OSError as e:
        print("WARN: could not write %s (%s) — skipped" % (dst, e), file=sys.stderr)
        continue
    generated.append(name)

# Prune stale managed skills (command renamed/removed). Only ever delete a
# pbrain-*/ skill dir whose SKILL.md carries OUR marker — never the user's own.
removed = []
for d in glob.glob(os.path.join(skills_dir, "pbrain-*")):
    if not os.path.isdir(d):
        continue
    name = os.path.basename(d)[len("pbrain-"):]
    if name in gen_set:
        continue
    sk = os.path.join(d, "SKILL.md")
    try:
        with open(sk, encoding="utf-8") as fh:
            owned = MARKER in fh.read()
    except OSError:
        owned = False
    if owned:
        try:
            shutil.rmtree(d)
            removed.append(name)
        except OSError:
            pass

# One-time migration cleanup: earlier installer versions wrote managed custom
# prompts to $CODEX_HOME/prompts/pbrain-<cmd>.md. Custom prompts are deprecated
# (and broken on current Codex), so remove ONLY the ones carrying our marker.
legacy = []
for f in glob.glob(os.path.join(prompts_dir, "pbrain-*.md")):
    try:
        with open(f, encoding="utf-8") as fh:
            if MARKER in fh.read():
                os.remove(f)
                legacy.append(os.path.basename(f)[:-len(".md")])
    except OSError:
        pass

print("SKILLS_GENERATED=%d" % len(generated))
print("SKILLS_LIST=%s" % " ".join("pbrain-%s" % n for n in generated))
if removed:
    print("SKILLS_PRUNED=%s" % " ".join("pbrain-%s" % n for n in removed))
if skipped_unmanaged:
    print("SKILLS_SKIPPED_UNMANAGED=%s" % " ".join("pbrain-%s" % n for n in skipped_unmanaged))
if legacy:
    print("LEGACY_PROMPTS_REMOVED=%s" % " ".join(legacy))
PYEOF

# --- Write / refresh the managed pbrain block in $CODEX_HOME/AGENTS.md. ---
python3 - "$AGENTS_FILE" "$VAULT_DIR" "$VAULT_EXISTS" <<'PYEOF'
import os, re, sys

agents_file, vault_dir, vault_exists = sys.argv[1], sys.argv[2], sys.argv[3]

START = "<!-- >>> pbrain (managed by /codex-install) — do not edit between these markers; re-run /codex-install to refresh >>> -->"
END = "<!-- <<< pbrain (managed by /codex-install) <<< -->"

if vault_exists == "yes":
    vault_ref = vault_dir
    launch = ('codex-pbrain  (or: codex --sandbox workspace-write '
              '--add-dir "%s" --add-dir "$HOME/.config/pbrain")' % vault_dir)
else:
    vault_ref = "your pbrain vault (set up via /init-obsidian from Claude Code)"
    launch = ('codex --sandbox workspace-write '
              '--add-dir "<your-vault-path>" --add-dir "$HOME/.config/pbrain"')

block = """%s
## pbrain (Obsidian daily-ritual commands)

These rules apply **only** when you are running a pbrain command or working
inside the pbrain Obsidian vault (`%s`). Ignore them for any unrelated work.

pbrain is primarily a Claude Code plugin. Each command is installed here as a
Codex **skill** named `pbrain-<command>` (under `$CODEX_HOME/skills/`). A skill
body just runs the **same** shared shell script against the **same** vault and
config, then tells you to follow the `INSTRUCTIONS:` block it prints to stdout —
the script is the single source of truth, so do exactly what that block says.

**Invoking pbrain.** Use a command by name — say `journal`, `plan my day`,
`brainstorm should I build X`, `remind me to …` — or reference the skill
explicitly as `$pbrain-journal`. Codex also auto-selects the matching skill when
your request fits its description. Do **not** type `/journal`: Codex rejects
unknown `/slash` commands before the model sees them. For commands that take
input (`brainstorm`, `remind`, `recall`, `habits`), just include it in your
message — the skill splices it into the script call.

Vault setup (`init-obsidian`) and this installer (`codex-install`) run from
Claude Code only — they are not installed as skills here.

**Morning sequence (journal → gratitude → everything else).** Before running
any pbrain command other than `journal`, `gratitude-journal`, or `remind`,
check today's files (use today's date as `YYYY-MM-DD`):
1. If `%s/life/daily-tracking/<TODAY>.md` is missing → suggest `journal` first.
2. Else if `%s/life/gratitude-journal/<TODAY>.md` is missing → suggest
   `gratitude-journal` next.
Suggest once, never block. A standing `USER PREFERENCES` skip overrides this.

**Ride-along blocks.** pbrain scripts print labelled blocks in their output —
`USER PREFERENCES`, `SELF-IMPROVE CHECK`, `HABIT EXTRACTION`, `HABIT SUGGEST`,
and a single `UPGRADE_AVAILABLE <old> <new>` line. Each block carries its own
instructions; follow them inline. For `UPGRADE_AVAILABLE`, tell the user a newer
pbrain is out and that `/plugin update pbrain` (from Claude Code) upgrades it,
then continue the command work.

**Writing into the vault.** Agent-generated content goes under `agent-work/`
(`brainstorms/`, `drafts/`, `notes/`, `research/`, `people/`, `chat-history/`).
User-curated folders (`life/`, `fitness/`, `startup/`, …) are off-limits unless
a command writes there by design or the user says so.

**Sandbox / launch.** Use the `codex-pbrain` shell function (written to your RC
by `/codex-install`) to launch with the correct sandbox flags. Or manually:

    %s

%s""" % (START, vault_ref, vault_ref, vault_ref, launch, END)

block_re = re.compile(re.escape(START) + r".*?" + re.escape(END), re.S)

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

# --- Write a `codex-pbrain` shell function to the user's RC file(s). ---
# Resolves vault dynamically at call-time (same order as lib/vault.sh), so the
# function stays correct even if the vault is later moved.
python3 - "$HOME" <<'PYEOF'
import os, re, sys

home = sys.argv[1]

START = "# >>> pbrain-managed: codex-pbrain >>>"
END   = "# <<< pbrain-managed: codex-pbrain <<<"

func = r"""codex-pbrain() {
  local _vault
  if [ -n "${PBRAIN_VAULT:-}" ]; then
    _vault="$PBRAIN_VAULT"
  elif [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/vault" ]; then
    _vault="$(head -n1 "${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/vault" 2>/dev/null || true)"
    case "$_vault" in "~"*) _vault="$HOME${_vault#~}" ;; esac
  else
    _vault="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault"
  fi
  echo ""
  echo "pbrain — invoke a command by name (Codex skills, no slash):"
  echo "  journal          gratitude-journal  plan-my-day"
  echo "  brainstorm       habits             remind"
  echo "  fitness-journal  diet-journal       weekly-review"
  echo "  end-of-day       recall             loose-ends"
  echo ""
  echo "Just say the name (e.g. \"journal\") or \$pbrain-journal. Codex auto-picks too."
  echo ""
  exec codex --sandbox workspace-write \
    --add-dir "$_vault" \
    --add-dir "${XDG_CONFIG_HOME:-$HOME/.config}/pbrain" \
    "$@"
}"""

block = "%s\n%s\n%s" % (START, func, END)
block_re = re.compile(re.escape(START) + r".*?" + re.escape(END), re.S)

candidates = [
    os.path.join(home, ".zshrc"),
    os.path.join(home, ".bashrc"),
    os.path.join(home, ".bash_profile"),
]
targets = [f for f in candidates if os.path.exists(f)]
if not targets:
    targets = [os.path.join(home, ".zshrc")]

results = []
for rc in targets:
    try:
        content = open(rc, encoding="utf-8").read() if os.path.exists(rc) else ""
    except OSError as e:
        print("WARN: could not read %s (%s) — skipped" % (rc, e), file=sys.stderr)
        continue
    if block_re.search(content):
        content = block_re.sub(block, content)
        action = "updated"
    else:
        if content and not content.endswith("\n"):
            content += "\n"
        content += "\n" + block + "\n"
        action = "added"
    tmp = rc + ".pbrain.tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp, rc)
    except OSError as e:
        print("WARN: could not write %s (%s) — skipped" % (rc, e), file=sys.stderr)
        continue
    results.append((rc, action))

for rc, action in results:
    print("SHELL_FUNC_%s=%s" % (action.upper(), rc))
if not results:
    print("SHELL_FUNC_ERROR=no writable RC file found")
PYEOF

# --- Recap for the calling agent to relay. ---
if command -v codex >/dev/null 2>&1; then
  CODEX_DETECTED=yes
else
  CODEX_DETECTED=no
fi

n_skills="$(ls -d "$SKILLS_DIR"/pbrain-*/ 2>/dev/null | wc -l | tr -d ' ')"

echo
echo "PBRAIN_CODEX_INSTALLED"
echo "skills_dir=$SKILLS_DIR"
echo "skills_count=$n_skills"
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
   is installed as a Codex SKILL named `pbrain-<command>` under
   `$CODEX_HOME/skills/`. Skills are Codex's supported, default-on mechanism
   (custom prompts are deprecated). How the user invokes one: by plain command
   name (`journal`, `plan my day`, `brainstorm should I build X`), explicitly as
   `$pbrain-journal`, or just by describing the task — Codex auto-selects on the
   skill's description. A literal `/journal` does NOT work (Codex rejects unknown
   `/slash` commands). Each skill runs the SAME shell script as the Claude
   command, against the SAME vault + `~/.config/pbrain` config + SQLite DB — so
   it is safe to alternate between Codex and Claude Code with one source of truth.

2. Tell the user HOW TO LAUNCH Codex: a `codex-pbrain` shell function has been
   written to their RC file(s) (see `SHELL_FUNC_ADDED` / `SHELL_FUNC_UPDATED`
   lines above for which files). After running `source ~/.zshrc` (or opening a
   new terminal), they just type `codex-pbrain` and it launches Codex pre-wired
   with the correct sandbox flags. Then inside Codex they invoke a command by
   name, e.g. `journal` (not `/journal`). If `SHELL_FUNC_ERROR` appears, show the
   raw `launch_command` as a fallback.

3. If `LEGACY_PROMPTS_REMOVED` appears: an earlier pbrain version installed Codex
   custom prompts; those are deprecated and have now been cleaned up in favour of
   skills. Nothing for the user to do.

4. If `vault=NOT_CONFIGURED`: tell them to run `/init-obsidian` from Claude Code
   first, then re-run `/codex-install` so the vault path gets baked into the
   launch command and the AGENTS.md block.

5. If `codex_detected=no`: note that the Codex CLI was not found on PATH — the
   skills and AGENTS.md block are installed and will work once Codex is installed
   (https://developers.openai.com/codex/cli).

6. Note it is idempotent: re-run `/codex-install` from Claude Code after
   moving/reinstalling pbrain or when new commands ship.

Keep it tight — a short confirmation plus the launch command and one example
invocation is enough. Do not paste this whole block back.
INSTR
