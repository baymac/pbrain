#!/usr/bin/env bash
# groom-triage-guard — PreToolUse gatekeeper for the AUTONOMOUS nightly groom.
#
# WHY THIS EXISTS
# ---------------
# The autonomous groom (claude -p "/project-manager groom") must be TRIAGE-ONLY:
# enrich + label issues in Plane, NEVER execute them (no git, branches, PRs, merges,
# or repo edits). We tried to enforce that with --allowedTools / --disallowedTools
# globs, but Claude Code's Bash permission matching does NOT reliably match the
# skill's variable-laden commands (e.g. `bash "${PBRAIN_DEV_DIR:-…}/…sh" "groom"`),
# so scoped allow/deny patterns either denied everything (turn-1 block) or let git
# through. A PreToolUse HOOK is real code that inspects the actual command string —
# the reliable boundary where globs fail.
#
# CONTRACT
# --------
# PreToolUse hooks receive a JSON event on stdin: {tool_name, tool_input:{command,…}}.
# We emit a JSON decision on stdout:
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
#                          "permissionDecisionReason":"…"}}  -> hard-block
# Anything else (empty / allow) lets the normal permission flow proceed. We only ever
# DENY — we never widen permissions — so this hook can only make the agent safer.
#
# Active ONLY when PBRAIN_GROOM_TRIAGE_GUARD=1 (set by the autonomous wrapper), so it
# never interferes with a normal interactive session.

set -euo pipefail

# Off unless the autonomous groom turned it on — interactive sessions are unaffected.
[[ "${PBRAIN_GROOM_TRIAGE_GUARD:-0}" == "1" ]] || exit 0

payload="$(cat 2>/dev/null || true)"

# Pull tool_name + the command (best-effort; stdlib python, no deps).
read -r tool cmd <<EOF
$(printf '%s' "$payload" | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("? ?"); sys.exit()
t=d.get("tool_name","?")
c=(d.get("tool_input") or {}).get("command","")
# collapse whitespace/newlines so the regex sees one line
c=" ".join(c.split())
print(t, c)
' 2>/dev/null || printf '? ?')
EOF

deny() {
  # Emit the structured deny decision + a reason the agent will see.
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
    "$(printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  exit 0
}

REASON="TRIAGE-ONLY: the autonomous groom may enrich + label Plane issues but must NOT execute them. This command touches code/git/PR — blocked. Do triage only and stop."

# Block repo-editing tools outright.
case "$tool" in
  Edit|Write|NotebookEdit|MultiEdit)
    deny "$REASON" ;;
esac

# For Bash, block execution/VCS/PR verbs anywhere in the (whitespace-collapsed) command.
# Word-boundary-ish matching so 'digit' won't trip 'git'. Covers piped/chained forms.
if [[ "$tool" == "Bash" ]]; then
  low="$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')"
  # Match the blocked program only when it's in COMMAND position — at the very start,
  # or right after a shell separator (| & ; && || ( backtick newline) — optionally
  # prefixed by rtk/sudo/env/command. This blocks `git push`, `cd x && git commit`,
  # `rtk git status`, but NOT the word "git" inside a quoted argument (e.g. a comment
  # body "git is great") or a path — so triage text that mentions git isn't blocked.
  sep='(^|[|&;`(]|&&|\|\|)[[:space:]]*'
  pre='((rtk|sudo|env|command|exec|xargs|nice|nohup)[[:space:]]+)*'
  verbs='(git|gh|hub)'
  if printf '%s' "$low" | grep -qE "${sep}${pre}${verbs}([[:space:]]|$)"; then
    deny "$REASON"
  fi
  # plan-my-work is execution wherever it appears (it's the only thing that runs the
  # pipeline) — block the script/skill name anywhere, even as a bash arg.
  if printf '%s' "$low" | grep -qE 'plan-my-work(\.sh)?'; then
    deny "$REASON"
  fi
  # Shipping subverbs in COMMAND position (after a separator + optional prefix/program),
  # to catch non-git shippers like `make deploy` / `npm run publish`. Command-position
  # only, so the words "deploy"/"publish" inside a Plane comment body are NOT blocked.
  ship='(push|merge|rebase|worktree|cherry-pick|publish|deploy)'
  if printf '%s' "$low" | grep -qE "${sep}${pre}[a-z0-9_./-]+([[:space:]]+(run|exec))?[[:space:]]+${ship}([[:space:]]|$)"; then
    deny "$REASON"
  fi
fi

# Default: allow (emit nothing → normal permission flow).
exit 0
