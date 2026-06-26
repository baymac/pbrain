#!/usr/bin/env bash
# pbrain test environment switcher.
#
# MUST BE SOURCED — it sets env vars in the current shell:
#   source scripts/test-env.sh on [--full]   # activate test mode
#   source scripts/test-env.sh off            # restore real setup
#   source scripts/test-env.sh status         # show current mode
#   source scripts/test-env.sh clear          # wipe test data + deactivate
#
# Env var persistence:
#   Sourcing sets vars in the current interactive shell immediately.
#   Vars are also written to ~/.zshenv so that Claude Code's Bash tool
#   (which spawns a fresh zsh per command) picks them up without any
#   extra steps. 'off' and 'clear' remove the ~/.zshenv block.
#
# Without --full (minimal):
#   Creates an empty isolated vault + config dir. Copies plane.json so
#   Plane still works. Commands start with a clean slate (no profiles).
#
# With --full:
#   Same isolation, but seeds the test environment with copies of your
#   real profiles and state so commands behave as they would in production:
#     ~/.config/pbrain/  →  ~/.config/pbrain-test/pbrain/
#       plane.json, pbrain.db (sqlite3 backup), habit-suggest-seen,
#       diet-profile.json, fitness-activities.json, plan-profile.json
#     vault/.pbrain/     →  ~/pbrain-test-vault/.pbrain/
#       prefs, quality-log, migrations ledger (so migrations don't re-run)
#     vault/life/        →  ~/pbrain-test-vault/life/
#     vault/fitness/     →  ~/pbrain-test-vault/fitness/
#     vault/agent-work/  →  ~/pbrain-test-vault/agent-work/
#       all pbrain entries (daily plans, habit logs, fitness logs, diet
#       logs, journal, gratitude, thoughts, weekly reviews, brainstorms,
#       research, notes, etc.) plus versioned profiles and libraries
#
# ISOLATION GUARANTEE: all copies are independent deep copies, not symlinks.
# Once --full seeds the test env, every subsequent read and write goes to
# ~/pbrain-test-vault and ~/.config/pbrain-test/pbrain/ exclusively.
# The real vault and ~/.config/pbrain/ are never touched after the copy.
#
# The only shared state is the compiled *.app/ bundles in ~/.config/pbrain/
# (read-only binaries, no stored state) and Apple Reminders if you use /remind
# (an external system outside pbrain's file scope).

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "Error: this script must be sourced, not executed." >&2
  echo "  Use: source scripts/test-env.sh on|off|status" >&2
  exit 1
fi

_pbrain_test_env() {
  local cmd="${1:-status}"
  local full=false
  [[ "${2:-}" == "--full" ]] && full=true

  local real_xdg="${XDG_CONFIG_HOME:-$HOME/.config}"
  local test_xdg="$HOME/.config/pbrain-test"
  local test_vault="$HOME/pbrain-test-vault"
  local zshenv="$HOME/.zshenv"

  # Resolve real vault path now, before we override PBRAIN_VAULT
  local real_vault=""
  if [[ -n "${PBRAIN_VAULT:-}" ]]; then
    real_vault="$PBRAIN_VAULT"
  elif [[ -f "$real_xdg/pbrain/vault" ]]; then
    real_vault="$(head -n1 "$real_xdg/pbrain/vault")"
    real_vault="${real_vault/#\~/$HOME}"
  else
    real_vault="$HOME/Library/Mobile Documents/iCloud~md~obsidian/Documents/vault"
  fi

  # Manage a clearly-marked block in ~/.zshenv so all zsh subprocesses
  # (including the Bash tool's fresh shell per command) see the env vars.
  _pbrain_sync_zshenv() {
    local action="${1:-remove}"  # add | remove
    # Remove any existing block first (idempotent)
    python3 - "$zshenv" <<'PYEOF'
import sys, os, re
path = sys.argv[1]
if not os.path.exists(path):
    open(path, 'w').close()
content = open(path).read()
content = re.sub(r'\n?# BEGIN pbrain-test-env\n.*?# END pbrain-test-env\n?', '', content, flags=re.DOTALL)
# Normalise trailing newline
content = content.rstrip('\n')
if content:
    content += '\n'
open(path, 'w').write(content)
PYEOF
    if [[ "$action" == "add" ]]; then
      {
        printf '\n# BEGIN pbrain-test-env\n'
        printf 'export PBRAIN_VAULT="%s"\n' "$test_vault"
        printf 'export XDG_CONFIG_HOME="%s"\n' "$test_xdg"
        printf 'export PBRAIN_UPDATE_CHECK=0\n'
        printf '# END pbrain-test-env\n'
      } >> "$zshenv"
      echo "  wrote env vars to ~/.zshenv (Bash tool will use test vault immediately)"
    else
      echo "  removed env vars from ~/.zshenv"
    fi
  }

  case "$cmd" in
    on)
      # ── Minimal setup (always runs) ──────────────────────────────────────
      mkdir -p "$test_xdg/pbrain"
      if [[ ! -d "$test_vault" ]]; then
        mkdir -p "$test_vault"
        echo "  created test vault at $test_vault"
      fi
      # Write vault pointer so config-file resolution also works
      printf '%s\n' "$test_vault" > "$test_xdg/pbrain/vault"

      # Copy plane.json so Plane integration works
      local real_plane="$real_xdg/pbrain/plane.json"
      local test_plane="$test_xdg/pbrain/plane.json"
      if [[ -f "$real_plane" && ! -f "$test_plane" ]]; then
        cp "$real_plane" "$test_plane"
        echo "  copied plane.json"
      fi

      # ── Full setup (--full only) ──────────────────────────────────────────
      if $full; then
        echo "  seeding test environment from real setup..."

        # Use sqlite3 backup for a clean DB snapshot (handles WAL correctly)
        local real_db="$real_xdg/pbrain/pbrain.db"
        local test_db="$test_xdg/pbrain/pbrain.db"
        if [[ -f "$real_db" && ! -f "$test_db" ]]; then
          if command -v sqlite3 >/dev/null 2>&1; then
            sqlite3 "$real_db" ".backup $test_db"
            echo "  copied pbrain.db (sqlite3 backup)"
          else
            cp "$real_db" "$test_db"
            echo "  copied pbrain.db (cp fallback — sqlite3 not found)"
          fi
        fi

        # Small flat state files (skip lock, app bundles, WAL files, tracker DB, vault pointer)
        local f
        for f in habit-suggest-seen diet-profile.json fitness-activities.json plan-profile.json; do
          if [[ -f "$real_xdg/pbrain/$f" && ! -f "$test_xdg/pbrain/$f" ]]; then
            cp "$real_xdg/pbrain/$f" "$test_xdg/pbrain/$f"
            echo "  copied $f"
          fi
        done

        # vault/.pbrain/ — prefs, quality-log, migrations ledger
        if [[ -d "$real_vault/.pbrain" ]]; then
          mkdir -p "$test_vault/.pbrain"
          cp -rp "$real_vault/.pbrain/." "$test_vault/.pbrain/"
          echo "  copied vault/.pbrain/ (prefs + migrations ledger)"
        fi

        # life/ fitness/ agent-work/ — all pbrain entries + versioned profiles + libraries
        local d
        for d in life fitness agent-work; do
          if [[ -d "$real_vault/$d" ]]; then
            mkdir -p "$test_vault/$d"
            cp -rp "$real_vault/$d/." "$test_vault/$d/"
            echo "  copied vault/$d/"
          fi
        done
      fi

      # ── Persist to ~/.zshenv + activate in current shell ─────────────────
      _pbrain_sync_zshenv add

      export PBRAIN_VAULT="$test_vault"
      export XDG_CONFIG_HOME="$test_xdg"
      export PBRAIN_UPDATE_CHECK=0

      echo "pbrain TEST MODE: ON${full:+ (full seed)}"
      echo "  vault  → $test_vault"
      echo "  config → $test_xdg/pbrain/"
      ;;

    off)
      _pbrain_sync_zshenv remove
      unset PBRAIN_VAULT XDG_CONFIG_HOME PBRAIN_UPDATE_CHECK
      echo "pbrain TEST MODE: OFF — real setup restored"
      ;;

    clear)
      # Refuse to run outside test mode — safety guard against wiping real data
      if [[ "${PBRAIN_VAULT:-}" != "$test_vault" ]]; then
        echo "Error: 'clear' only works while test mode is ON." >&2
        echo "  Run: source scripts/test-env.sh on" >&2
        return 1
      fi
      echo "Clearing test environment:"
      echo "  rm -rf $test_vault"
      echo "  rm -rf $test_xdg/pbrain/"
      rm -rf "$test_vault"
      rm -rf "$test_xdg/pbrain"
      _pbrain_sync_zshenv remove
      unset PBRAIN_VAULT XDG_CONFIG_HOME PBRAIN_UPDATE_CHECK
      echo "Done — test mode deactivated."
      ;;

    status)
      if [[ "${PBRAIN_VAULT:-}" == "$test_vault" ]]; then
        echo "pbrain TEST MODE: ON (current shell)"
        echo "  vault  = $PBRAIN_VAULT"
        echo "  config = ${XDG_CONFIG_HOME}/pbrain/"
      else
        echo "pbrain TEST MODE: OFF in current shell"
        [[ -n "${PBRAIN_VAULT:-}" ]] && echo "  vault  = $PBRAIN_VAULT  (PBRAIN_VAULT override)"
      fi
      if grep -q "BEGIN pbrain-test-env" "$zshenv" 2>/dev/null; then
        echo "  ~/.zshenv: test env block ACTIVE (Bash tool uses test vault)"
      else
        echo "  ~/.zshenv: no test env block (Bash tool uses real vault)"
      fi
      ;;

    *)
      echo "Usage: source scripts/test-env.sh on [--full] | off | clear | status" >&2
      return 1
      ;;
  esac

  unset -f _pbrain_sync_zshenv
}

_pbrain_test_env "$@"
unset -f _pbrain_test_env
