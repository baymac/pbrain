#!/usr/bin/env bash
# pbrain self-improvement loop — sourced by lib/vault.sh.
#
# Defines one function:
#
#   pbrain_emit_self_improve <command-name> [plan-file] [plan-label]
#
# When a command owns a core plan (e.g. /diet-journal owns Diet Plan.md), it
# passes the plan's path + a human label as the 2nd/3rd args. The reflection
# then gains a PLAN UPDATE route: lasting plan changes the user raised in-session
# are proposed against that plan file under the same propose->explicit-yes->write
# discipline used for preference capture. Commands with no plan call it with just
# the command name, and the plan route is omitted.
#
# Emitted at the END of a command's output (after its work/INSTRUCTIONS), it
# prints a terse "reflect on feedback" instruction block that tells the calling
# Claude session to capture standing preferences or quality fixes the user
# raised DURING the session — but only when there was a genuine correction or
# stated preference. On neutral sessions it stays silent (the agent emits
# nothing). This block rides along on every command run, so it is deliberately
# short to keep the per-run token cost tiny.
#
# Three modes, selected by PBRAIN_SELF_IMPROVE (default: prefs):
#   off    — disabled entirely; emit nothing.
#   prefs  — capture user preferences to ~/.config/pbrain/prefs/<cmd>.md and
#            quality fixes to ~/.config/pbrain/feedback/<cmd>.md. Never edits
#            command source. This is the right mode for everyone, including
#            plugin users, because it writes outside the plugin install and so
#            survives `/plugin update`.
#   dev    — everything `prefs` does, PLUS the agent may propose edits to the
#            live command source under $PBRAIN_DEV_DIR/commands/. Honoured ONLY
#            when PBRAIN_DEV_DIR is set (points at the editable repo); otherwise
#            it silently degrades to `prefs`.
#
# Env knobs:
#   PBRAIN_SELF_IMPROVE   off | prefs | dev   (default prefs)
#   PBRAIN_DEV_DIR        live repo path; required for `dev` mode source edits
#   PBRAIN_PREFS_DIR      override prefs dir    (default ~/.config/pbrain/prefs)
#   PBRAIN_FEEDBACK_DIR   override feedback dir (default ~/.config/pbrain/feedback)
#
# Like lib/prefs.sh, this NEVER exits non-zero — it is sourced into commands
# running under `set -euo pipefail`. Call sites still append `|| true`.

pbrain_emit_self_improve() {
  local cmd mode prefs_dir feedback_dir prefs_file feedback_file global_file
  local dev_dir dev_branch dev_dirty plan_file plan_label
  cmd="${1:-}"
  [[ -n "$cmd" ]] || return 0
  # Optional: a core plan this command owns. When both are passed, the reflection
  # gains a PLAN UPDATE route so lasting plan changes the user raised in-session
  # are proposed against the actual plan file (same propose->explicit-yes->write
  # discipline as the prefs capture above).
  plan_file="${2:-}"
  plan_label="${3:-}"

  mode="${PBRAIN_SELF_IMPROVE:-prefs}"
  case "$mode" in
    off)
      return 0
      ;;
    dev)
      # dev mode requires a live repo to edit; otherwise fall back to prefs.
      if [[ -z "${PBRAIN_DEV_DIR:-}" ]]; then
        mode="prefs"
      fi
      ;;
    prefs)
      ;;
    *)
      # Unknown value — fail safe to prefs rather than off, so a typo doesn't
      # silently disable capture.
      mode="prefs"
      ;;
  esac

  prefs_dir="${PBRAIN_PREFS_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/prefs}"
  feedback_dir="${PBRAIN_FEEDBACK_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/pbrain/feedback}"
  prefs_file="$prefs_dir/$cmd.md"
  global_file="$prefs_dir/_global.md"
  feedback_file="$feedback_dir/$cmd.md"

  printf '%s\n' ""
  printf '%s\n' "--- SELF-IMPROVE CHECK (mode: $mode) ---"
  printf '%s\n' "Run this ONLY after the command's work above is fully complete."
  printf '%s\n' ""
  printf '%s\n' "Reflect: did the user, DURING this session, explicitly correct you, ask you"
  printf '%s\n' "to do something differently as a standing rule, or state a lasting preference"
  printf '%s\n' "about how /$cmd should behave?"
  printf '%s\n' ""
  printf '%s\n' "Stay SILENT (do nothing, end normally) if not. These do NOT count: the user"
  printf '%s\n' "simply answering your questions, a one-off request for today only, neutral"
  printf '%s\n' "conversation, or you guessing they might want a change. When in doubt, silent."
  printf '%s\n' ""
  printf '%s\n' "Only if there was a genuine standing preference or correction:"
  printf '%s\n' "  1. Classify each item as either:"
  printf '%s\n' "     - PREFERENCE: how this user wants pbrain to behave. Sub-classify scope:"
  printf '%s\n' "         * GLOBAL  — applies across commands, NOT just /$cmd. Anything that"
  printf '%s\n' "           silences a suggestion/nudge fired by more than one command belongs"
  printf '%s\n' "           here (e.g. \"stop suggesting /journal or /gratitude-journal before"
  printf '%s\n' "           other commands\", \"don't nudge me about X anywhere\"). The"
  printf '%s\n' "           morning-sequence check is global — a skip of it is GLOBAL."
  printf '%s\n' "         * COMMAND — applies to /$cmd only (how /$cmd itself should behave)."
  printf '%s\n' "     - QUALITY FIX: a bug or improvement that would help everyone."
  printf '%s\n' "  2. Show the exact line(s) you would save and get an explicit yes before"
  printf '%s\n' "     writing anything."
  printf '%s\n' "  3. On yes:"
  printf '%s\n' "     - PREFERENCE (GLOBAL) -> consolidate into $global_file. Read it first;"
  printf '%s\n' "       update a related line rather than duplicating. Create the file if missing."
  printf '%s\n' "     - PREFERENCE (COMMAND) -> consolidate into $prefs_file. Read it first; if a"
  printf '%s\n' "       related line already exists, update/replace it (reconcile any contradiction"
  printf '%s\n' "       with the user) instead of appending a duplicate. Create the file if missing."
  printf '%s\n' "     - QUALITY FIX -> append to $feedback_file (create if missing). Then offer"
  printf '%s\n' "       once: \"Want me to open a GitHub issue for this?\" Only run \`gh issue"
  printf '%s\n' "       create\` if they say yes AND \`gh\` is available."

  if [[ "$mode" == "dev" ]]; then
    dev_dir="$PBRAIN_DEV_DIR"
    printf '%s\n' "  4. DEV MODE: if a QUALITY FIX should change the command itself, you MAY"
    printf '%s\n' "     propose an edit to the live source at $dev_dir/commands/$cmd.sh (or"
    printf '%s\n' "     $cmd.md). ALWAYS show the concrete diff and get an explicit yes before"
    printf '%s\n' "     writing. NEVER auto-apply source edits."
    # CQ3 — warn about the dev repo's git state before any source edit.
    if command -v git >/dev/null 2>&1 && git -C "$dev_dir" rev-parse --git-dir >/dev/null 2>&1; then
      dev_branch="$(git -C "$dev_dir" branch --show-current 2>/dev/null || true)"
      dev_dirty="$(git -C "$dev_dir" status --porcelain 2>/dev/null || true)"
      if [[ -n "$dev_dirty" ]]; then
        printf '%s\n' "     NOTE: the dev repo at $dev_dir has uncommitted changes — warn the user"
        printf '%s\n' "     before editing source so the change does not tangle with unrelated work."
      fi
      if [[ "$dev_branch" == "main" || "$dev_branch" == "master" ]]; then
        printf '%s\n' "     NOTE: the dev repo is on '$dev_branch' — suggest a feature branch before"
        printf '%s\n' "     editing source."
      fi
    fi
  fi

  if [[ -n "$plan_file" && -n "$plan_label" ]]; then
    printf '%s\n' ""
    printf '%s\n' "PLAN UPDATE — also reflect: did the user say something this session that"
    printf '%s\n' "implies a LASTING change to their $plan_label (the plan at $plan_file), as"
    printf '%s\n' "opposed to just today's entry/log?"
    printf '%s\n' "  Counts: changing a target or goal, adding or dropping part of the plan, a"
    printf '%s\n' "  new standing constraint or preference about the plan itself."
    printf '%s\n' "  Does NOT count: a one-off meal/workout/event, today's mood, or the user"
    printf '%s\n' "  just answering your questions. When in doubt, stay silent."
    printf '%s\n' "  If yes: propose the specific edit to the relevant plan file, show it, and"
    printf '%s\n' "  write it ONLY on an explicit per-change yes — never auto-apply. Keep any"
    printf '%s\n' "  fenced JSON code block in the plan valid."
  fi

  printf '%s\n' "--- END SELF-IMPROVE CHECK ---"
  return 0
}
