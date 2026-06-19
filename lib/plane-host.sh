#!/usr/bin/env bash
# pbrain Plane VPS-hosting helpers — sourced by commands/init-plane.sh and
# commands/project-manager.sh.
#
# Implements PB-18: move the self-hosted Plane off localhost onto an always-on
# VPS so the phone can reach it and it survives the laptop being off. This is the
# REMOTE counterpart to the local wizard in init-plane.sh and to the backup layer
# in lib/plane-backup.sh.
#
# Design (per the PB-18 scoping decisions):
#   * The VPS host/port/ssh-key are REUSED from the backup config's `vps` block
#     (~/.config/pbrain/plane-backup.json, via pbrain_pbk_load) so hosting and
#     backups share one box + key. Explicit PLH_VPS_* env overrides win, and a
#     brand-new user with no backup configured can pass them through.
#   * Plane's own installer (setup.sh) is an interactive menu — driving it over
#     SSH is brittle, so the actual Plane install + the domain/TLS path ship as
#     GUIDES (printed runbooks, like init-plane.sh's `github`), not automation.
#   * The two pieces pbrain DOES automate over SSH are the clean, non-interactive
#     ones: quick-vpn (the no-domain access layer) and the remote backup import.
#   * `wire` repoints pbrain at the remote URL and, for remote, swaps the local
#     browser-cookie internal auth for email+password (password → macOS Keychain;
#     see lib/plane.py KEYCHAIN_SERVICE).
#
# No-domain access uses the user's own WireGuard tool, baymac/quick-vpn (NOT a
# third-party SaaS like Tailscale): `host vpn` reuses an existing quick-vpn client
# (creating none) or installs quick-vpn + creates one, then prints the client
# config / QR for the phone. Full tunnel is quick-vpn's default; split tunnel is
# applied by rewriting the client conf's AllowedIPs to the VPN subnet.
#
# bash-3.2-safe and best-effort, like the sibling helpers. Remote work runs over a
# non-interactive ssh (BatchMode) so a headless run can't hang on a prompt.

# Resolve the engine (lib/plane.py) relative to THIS file so `wire` works whether
# sourced from init-plane.sh or project-manager.sh.
_PLH_LIB_DIR="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PLH_ENGINE="${PLH_ENGINE:-$_PLH_LIB_DIR/plane.py}"
PLH_QVPN_INSTALL_URL="${PLH_QVPN_INSTALL_URL:-https://raw.githubusercontent.com/baymac/quick-vpn/main/install.sh}"

# Pull in pbrain_pbk_load (VPS creds + backup path) if it isn't already sourced —
# init-plane.sh sources us standalone; project-manager.sh already has it.
if ! declare -f pbrain_pbk_load >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  [[ -f "$_PLH_LIB_DIR/plane-backup.sh" ]] && source "$_PLH_LIB_DIR/plane-backup.sh"
fi

# Resolve VPS host/port/key into PLH_HOST/PLH_PORT/PLH_KEY. Backup config supplies
# the defaults; PLH_VPS_* env overrides. Returns 0 only when a host is known.
pbrain_plh_resolve() {
  if declare -f pbrain_pbk_load >/dev/null 2>&1; then
    eval "$(pbrain_pbk_load)" 2>/dev/null || true
  fi
  PLH_HOST="${PLH_VPS_HOST:-${PBK_VPS_HOST:-}}"
  PLH_PORT="${PLH_VPS_PORT:-${PBK_VPS_PORT:-22}}"
  PLH_KEY="${PLH_VPS_KEY:-${PBK_VPS_KEY:-}}"
  PLH_BACKUP_PATH="${PLH_VPS_PATH:-${PBK_VPS_PATH:-}}"
  [[ -n "$PLH_HOST" ]]
}

# Echo the ssh command prefix (no host). Relies on PLH_* being resolved.
pbrain_plh_sshcmd() {
  local c="ssh -p ${PLH_PORT:-22} -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15"
  [[ -n "${PLH_KEY:-}" ]] && c="$c -i ${PLH_KEY}"
  printf '%s\n' "$c"
}

# Run a remote command string on the VPS. Resolves creds first.
pbrain_plh_run() {
  pbrain_plh_resolve || {
    echo "PLH_ERR no VPS host configured — set one via /project-manager backup config --vps-host …, or export PLH_VPS_HOST" >&2
    return 1
  }
  local ssh; ssh="$(pbrain_plh_sshcmd)"
  $ssh "$PLH_HOST" "$@"
}

# ---------------------------------------------------------------------------
# probe — read-only state of the VPS (reachability + what's already installed)
# ---------------------------------------------------------------------------
pbrain_plh_probe() {
  if ! pbrain_plh_resolve; then
    echo "PLH_PROBE configured=no"
    echo "No VPS is configured. Set one with /project-manager backup config --vps-host <user@host> --ssh-key <path>,"
    echo "or pass PLH_VPS_HOST / PLH_VPS_KEY."
    return 0
  fi
  echo "PLH_PROBE host=$PLH_HOST port=$PLH_PORT backup_path=${PLH_BACKUP_PATH:-?}"
  pbrain_plh_run '
    echo "reachable: yes"
    echo "os: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
    echo "docker: $(command -v docker >/dev/null 2>&1 && echo yes || echo no)"
    echo "docker_running: $(docker info >/dev/null 2>&1 && echo yes || echo no)"
    echo "plane_running: $(docker ps --format "{{.Names}}" 2>/dev/null | grep -qi plane && echo yes || echo no)"
    echo "qvpn: $(command -v qvpn >/dev/null 2>&1 && echo yes || echo no)"
    echo "wg_up: $(command -v wg >/dev/null 2>&1 && wg show 2>/dev/null | grep -q interface && echo yes || echo no)"
    echo "wg_clients: $(ls /etc/wireguard/clients/*.conf 2>/dev/null | wc -l | tr -d " ")"
    echo "mem_available: $(free -h 2>/dev/null | awk "/^Mem:/{print \$7}")"
  ' 2>&1 || { echo "reachable: no"; echo "(ssh failed — check the host/key and that your VPN/route to it is up)"; }
}

# ---------------------------------------------------------------------------
# vpn — no-domain access via quick-vpn (WireGuard). Reuse-or-install, then show
# the client config. $1 client name (default phone). $2 tunnel mode full|split.
# ---------------------------------------------------------------------------
pbrain_plh_vpn() {
  local name="${1:-phone}" mode="${2:-full}"
  pbrain_plh_resolve || { echo "PLH_ERR no VPS host configured" >&2; return 1; }
  local probe
  probe="$(pbrain_plh_run '
    command -v qvpn >/dev/null 2>&1 && echo QVPN=yes || echo QVPN=no
    (command -v wg >/dev/null 2>&1 && wg show 2>/dev/null | grep -q interface) && echo WG=yes || echo WG=no
    echo CLIENTS_BEGIN
    ls /etc/wireguard/clients/*.conf 2>/dev/null | sed "s#.*/##;s#\.conf\$##"
    echo CLIENTS_END
  ' 2>/dev/null)" || { echo "PLH_ERR could not reach the VPS" >&2; return 1; }

  local has_qvpn has_wg clients
  has_qvpn="$(printf '%s\n' "$probe" | sed -n 's/^QVPN=//p')"
  has_wg="$(printf '%s\n' "$probe" | sed -n 's/^WG=//p')"
  clients="$(printf '%s\n' "$probe" | awk '/^CLIENTS_BEGIN$/{f=1;next}/^CLIENTS_END$/{f=0}f')"

  # A WireGuard server set up by hand (no quick-vpn) — do NOT clobber it. Surface
  # the existing clients so the user can reuse one, and stop.
  if [[ "$has_qvpn" == "no" && "$has_wg" == "yes" ]]; then
    echo "PLH_VPN_EXISTING_WG (WireGuard is already running, not managed by quick-vpn — leaving it untouched)"
    echo "Existing client configs on the VPS (reuse one for the phone; pbrain won't modify them):"
    printf '%s\n' "$clients" | sed 's/^/  - /'
    echo "Point pbrain at the WireGuard server IP, e.g.: host wire --base-url http://<wg-server-ip>:1800"
    return 0
  fi

  # quick-vpn present with a usable client → reuse it, create nothing.
  if [[ "$has_qvpn" == "yes" ]]; then
    local pick="$name"
    if ! printf '%s\n' "$clients" | grep -qx "$name"; then
      pick="$(printf '%s\n' "$clients" | head -1)"
    fi
    if [[ -n "$pick" ]]; then
      echo "PLH_VPN_REUSED client=$pick (existing quick-vpn client — no new client created)"
    else
      echo "PLH_VPN_ADD client=$name (quick-vpn present, no client yet)"
      pbrain_plh_run "qvpn add $(printf '%q' "$name") -y >/dev/null 2>&1 || true"
      pick="$name"
    fi
    pbrain_plh_vpn_show "$pick" "$mode"
    return 0
  fi

  # Nothing yet → install quick-vpn + init the first client.
  echo "PLH_VPN_INSTALL (installing quick-vpn + initialising WireGuard on the VPS)…"
  pbrain_plh_run "curl -fsSL $(printf '%q' "$PLH_QVPN_INSTALL_URL") | sudo bash >/dev/null 2>&1 || true"
  pbrain_plh_run "CLIENT_NAME=$(printf '%q' "$name") qvpn init -y >/dev/null 2>&1 || sudo qvpn init -y >/dev/null 2>&1 || true"
  pbrain_plh_vpn_show "$name" "$mode"
}

# Print a quick-vpn client config (and apply split-tunnel if asked). The conf is
# sensitive (it carries the client private key) — it is shown so the user can
# import it on the phone; never log it elsewhere.
pbrain_plh_vpn_show() {
  local name="${1:?client}" mode="${2:-full}"
  if [[ "$mode" == "split" ]]; then
    # quick-vpn hardcodes full-tunnel (AllowedIPs=0.0.0.0/0, ::/0) with no flag, so
    # rewrite the client conf's AllowedIPs to just the VPN subnet (derived from the
    # client Address line) — only the CLIENT's routes change; the server is untouched.
    pbrain_plh_run "
      f=/etc/wireguard/clients/$(printf '%q' "$name").conf
      if [ -f \"\$f\" ]; then
        sub=\$(awk -F'[ ./]' '/^Address/{print \$3\".\"\$4\".\"\$5\".0/24\"; exit}' \"\$f\")
        [ -n \"\$sub\" ] && sed -i \"s#^AllowedIPs.*#AllowedIPs = \$sub#\" \"\$f\"
      fi
    " 2>/dev/null || true
    echo "PLH_VPN_SPLIT applied (client routes only the VPN subnet through the tunnel)"
  fi
  echo "PLH_VPN_CLIENT name=$name"
  echo "--- client config (import on the phone; treat as a secret) ---"
  pbrain_plh_run "qvpn show $(printf '%q' "$name") --conf-only 2>/dev/null || cat /etc/wireguard/clients/$(printf '%q' "$name").conf 2>/dev/null"
  echo "--- end ---"
  echo "QR (on the VPS): /etc/wireguard/clients/${name}_qr.png  (or: qvpn show $name --qr-only)"
}

# ---------------------------------------------------------------------------
# import — restore a backup tarball that already lives ON the VPS into the
# VPS-hosted Plane. DESTRUCTIVE (overwrites the DB + uploads). Requires --yes.
# $1 = tarball basename or "latest" (default latest). $2 = "--yes".
# ---------------------------------------------------------------------------
pbrain_plh_import() {
  local which="${1:-latest}" confirmed="${2:-}"
  pbrain_plh_resolve || { echo "PLH_ERR no VPS host configured" >&2; return 1; }
  local dir="${PLH_BACKUP_PATH:-/root/pbrain-plane-backups}"
  if [[ "$confirmed" != "--yes" ]]; then
    echo "PLH_ERR import is destructive (overwrites the VPS Plane DB + uploads) — re-run with --yes" >&2
    echo "Backups available on the VPS ($dir):" >&2
    pbrain_plh_run "ls -1t $(printf '%q' "$dir")/plane-*.tar.gz 2>/dev/null | head -10" >&2 || true
    return 1
  fi
  echo "PLH_IMPORT dir=$dir which=$which"
  # The whole restore runs ON the VPS: pick the tarball, discover Plane's Postgres
  # container + uploads volume + creds (same shape as pbrain_pbk_discover), unpack,
  # pg_restore, untar uploads. Passed as a remote bash script over ssh.
  pbrain_plh_run "DIR=$(printf '%q' "$dir") WHICH=$(printf '%q' "$which") bash -s" <<'REMOTE'
set -u
if [ "$WHICH" = "latest" ] || [ -z "$WHICH" ]; then
  TAR="$(ls -1t "$DIR"/plane-*.tar.gz 2>/dev/null | head -1)"
else
  TAR="$DIR/$WHICH"
fi
[ -f "$TAR" ] || { echo "PLH_ERR no backup tarball found in $DIR"; exit 1; }
echo "→ restoring from $(basename "$TAR")"

ROWS="$(docker ps --format '{{.Names}}\t{{.Image}}' 2>/dev/null)"
DBC="$(printf '%s\n' "$ROWS" | awk -F'\t' 'tolower($2) ~ /postgres/ && tolower($1) ~ /plane/ {print $1; exit}')"
[ -n "$DBC" ] || DBC="$(printf '%s\n' "$ROWS" | awk -F'\t' 'tolower($2) ~ /postgres/ && tolower($1) ~ /plane/ {print $1; exit}')"
[ -n "$DBC" ] || { echo "PLH_ERR no Plane Postgres container running on the VPS — bring Plane up first"; exit 1; }
HELPER="$(docker inspect "$DBC" --format '{{.Config.Image}}' 2>/dev/null)"
ENVL="$(docker inspect "$DBC" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null)"
PGUSER="$(printf '%s\n' "$ENVL" | awk -F= '/^POSTGRES_USER=/{print $2}' | tail -1)"; [ -n "$PGUSER" ] || PGUSER=postgres
PGPASS="$(printf '%s\n' "$ENVL" | awk -F= '/^POSTGRES_PASSWORD=/{print $2}' | tail -1)"
PGDB="$(printf '%s\n' "$ENVL" | awk -F= '/^POSTGRES_DB=/{print $2}' | tail -1)"; [ -n "$PGDB" ] || PGDB=plane
VOL="$(docker volume ls --format '{{.Name}}' 2>/dev/null | awk 'tolower($0) ~ /_uploads$/ && tolower($0) ~ /plane/ {print; exit}')"
[ -n "$VOL" ] || VOL="$(docker volume ls --format '{{.Name}}' 2>/dev/null | awk 'tolower($0) ~ /_uploads$/ {print; exit}')"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
tar xzf "$TAR" -C "$WORK" || { echo "PLH_ERR could not unpack tarball"; exit 1; }
SNAP="$(find "$WORK" -maxdepth 1 -type d -name 'plane-*' | head -1)"
[ -n "$SNAP" ] && [ -f "$SNAP/db.dump" ] || { echo "PLH_ERR snapshot has no db.dump"; exit 1; }

echo "→ pg_restore into $PGDB (container $DBC)…"
docker exec -i -e PGPASSWORD="$PGPASS" "$DBC" \
  pg_restore --clean --if-exists --no-owner -U "$PGUSER" -h 127.0.0.1 -d "$PGDB" \
  < "$SNAP/db.dump" 2>"$WORK/err" || echo "PLH_WARN pg_restore reported: $(tail -3 "$WORK/err" 2>/dev/null)"

if [ -f "$SNAP/uploads.tar.gz" ] && [ -n "$VOL" ]; then
  echo "→ restoring uploads volume ($VOL)…"
  docker run --rm -i -v "$VOL":/data "$HELPER" \
    sh -c 'rm -rf /data/* /data/..?* 2>/dev/null; tar xzf - -C /data' < "$SNAP/uploads.tar.gz" 2>/dev/null \
    || echo "PLH_WARN could not restore uploads"
fi
echo "PLH_IMPORTED $(basename "$TAR")"
echo "→ restart Plane workers to pick up the restored data (docker compose restart in the Plane dir)"
REMOTE
}

# ---------------------------------------------------------------------------
# wire — point pbrain at the remote Plane and switch internal auth to
# email/password (password → Keychain). $1 base_url, $2 email, $3 password.
# ---------------------------------------------------------------------------
pbrain_plh_wire() {
  local base="${1:?base_url}" email="${2:-}" pw="${3:-}"
  [[ -f "$PLH_ENGINE" ]] || { echo "PLH_ERR lib/plane.py not found at $PLH_ENGINE" >&2; return 1; }
  local -a a=(setup --base-url "$base" --internal-cookie-source none)
  [[ -n "$email" ]] && a+=(--internal-email "$email")
  [[ -n "$pw" ]] && a+=(--internal-password "$pw")
  python3 "$PLH_ENGINE" "${a[@]}"
}

# ---------------------------------------------------------------------------
# deploy / domain — GUIDES (printed runbooks). Plane's setup.sh is interactive
# and the domain/TLS path is DNS-bound, so these are walked, not automated.
# ---------------------------------------------------------------------------
pbrain_plh_deploy_guide() {
  pbrain_plh_resolve >/dev/null 2>&1 || true
  local port="${1:-1800}"
  cat <<GUIDE
PLH_DEPLOY_GUIDE host=${PLH_HOST:-<vps>} port=$port
Run these ON the VPS (ssh in first) to stand Plane up off the public ports so it
sits behind your VPN / a reverse proxy, not on 80/443:

  ssh ${PLH_KEY:+-i $PLH_KEY }${PLH_HOST:-<user@vps>}
  mkdir -p /opt/plane-selfhost && cd /opt/plane-selfhost
  curl -fsSL -o setup.sh https://github.com/makeplane/plane/releases/latest/download/setup.sh
  chmod +x setup.sh && ./setup.sh          # menu → Install, then Start
  # then move Plane off :80 onto :$port (edit plane.env):
  #   APP_DOMAIN=<wg-server-ip>:$port
  #   LISTEN_HTTP_PORT=$port
  docker compose --env-file plane.env up -d

Then back on the laptop:
  - import your data:   /project-manager backup restore  (or: host import latest --yes)
  - wire pbrain:        host wire --base-url http://<wg-server-ip>:$port
GUIDE
}

pbrain_plh_domain_guide() {
  local domain="${1:-plane.example.com}"
  cat <<GUIDE
PLH_DOMAIN_GUIDE domain=$domain
A public domain lets Plane's bundled Caddy issue TLS automatically. Steps (manual —
DNS + the provider firewall can't be driven from here):

  1) DNS: add an A record  $domain → <VPS public IP>  and wait for it to resolve.
  2) Provider firewall: open inbound TCP 80 AND 443 to the VPS.
  3) On the VPS, in Plane's plane.env:
       APP_DOMAIN=$domain
       LISTEN_HTTP_PORT=80          # Caddy also binds 443 for the TLS challenge
       ufw allow 80/tcp; ufw allow 443/tcp
       docker compose --env-file plane.env up -d
  4) Verify https://$domain loads, then wire pbrain:
       host wire --base-url https://$domain --internal-email <you@mail> --internal-password <pw>

TLS will fail if step 1 hasn't propagated — confirm the A record resolves first.
GUIDE
}
