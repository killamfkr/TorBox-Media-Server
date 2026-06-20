#!/usr/bin/env bash
# CasaOS / Ubuntu bootstrap for TorBox Media Server.
#
# One-liner (API key required — curl|bash cannot prompt interactively):
#   curl -fsSL https://raw.githubusercontent.com/killamfkr/TorBox-Media-Server/main/install-casaos.sh | TORBOX_API_KEY="your-key" bash
set -euo pipefail

REPO_URL="${TORBOX_REPO_URL:-https://github.com/killamfkr/TorBox-Media-Server.git}"
REPO_DIR="${TORBOX_REPO_DIR:-/DATA/AppData/torbox-media-server-src}"
INSTALL_DIR="${TORBOX_INSTALL_DIR:-/DATA/AppData/torbox-media-server}"
export TORBOX_MOUNT_DIR="${TORBOX_MOUNT_DIR:-/DATA/Media/torbox-media}"
export TORBOX_CASAOS=true

if [[ ! -d /DATA ]]; then
    REPO_DIR="${HOME}/.local/share/torbox-media-server-src"
    INSTALL_DIR="${HOME}/torbox-media-server"
    export TORBOX_MOUNT_DIR="${TORBOX_MOUNT_DIR:-${HOME}/torbox-media-mount}"
fi

log() { echo -e "\033[0;36m[CasaOS]\033[0m $*"; }
err() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

run_root() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    elif command -v sudo &>/dev/null; then
        sudo "$@"
    else
        err "Need root/sudo to run: $*"
        exit 1
    fi
}

ensure_pkg() {
    local pkg="$1"
    command -v "$pkg" &>/dev/null && return 0
    log "Installing ${pkg}..."
    if command -v apt-get &>/dev/null; then
        run_root apt-get update -qq
        run_root apt-get install -y "$pkg"
    elif command -v pacman &>/dev/null; then
        run_root pacman -S --noconfirm "$pkg"
    elif command -v dnf &>/dev/null; then
        run_root dnf install -y "$pkg"
    else
        err "Missing dependency: ${pkg}. Install it and re-run."
        exit 1
    fi
}

ensure_docker() {
    if docker info &>/dev/null 2>&1; then
        return 0
    fi
    if run_root docker info &>/dev/null 2>&1; then
        log "Docker works with sudo — setup will use sudo for compose commands."
        return 0
    fi
    err "Docker is not running or not installed. On CasaOS, open Settings and ensure Docker is enabled."
    exit 1
}

repair_env_file() {
    local env="${INSTALL_DIR}/.env"
    [[ -f "$env" ]] || return 0
    if grep -q $'\x1b' "$env" 2>/dev/null; then
        log "Repairing corrupted .env (removing log lines written by older setup.sh)..."
        LC_ALL=C grep -v $'\x1b' "$env" >"${env}.repair"
        mv "${env}.repair" "$env"
        chmod 600 "$env"
    fi
}

apply_casaos_compose_fixes() {
    local compose="${INSTALL_DIR}/docker-compose.yml"
    [[ -f "$compose" ]] || return 0

    log "Exposing service ports on LAN (CasaOS)..."
    sed -i 's/127\.0\.0\.1:/0.0.0.0:/g' "$compose"

    local override="${INSTALL_DIR}/docker-compose.override.yml"
    if [[ -f "$override" ]] && grep -q 'privileged: true' "$override" 2>/dev/null; then
        return 0
    fi
    if [[ -f "$override" ]]; then
        cat >>"$override" <<'EOF'

  decypharr:
    privileged: true
EOF
    else
        cat >"$override" <<'EOF'
# Auto-generated: CasaOS FUSE compatibility
services:
  decypharr:
    privileged: true
EOF
    fi
}

verify_install() {
    local ok=true

    if [[ ! -f "${INSTALL_DIR}/.setup_complete" ]]; then
        err "Setup did not finish — missing ${INSTALL_DIR}/.setup_complete"
        ok=false
    fi
    if [[ ! -f "${INSTALL_DIR}/manage.sh" ]]; then
        err "Missing ${INSTALL_DIR}/manage.sh"
        ok=false
    fi

    local running
    running="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -cE '^(decypharr|radarr|sonarr|seerr|prowlarr|plex|jellyfin)$' || true)"
    if [[ "$running" -lt 3 ]]; then
        err "Expected Docker containers to be running, but only found ${running} core service(s)."
        err "Check logs: cd ${INSTALL_DIR} && ./manage.sh logs"
        ok=false
    fi

    if [[ "$ok" != "true" ]]; then
        return 1
    fi
    return 0
}

print_success() {
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    echo ""
    log "Install verified. Open these URLs in your browser:"
    echo "  Seerr (start here):  http://${ip:-localhost}:5055"
    echo "  Plex:                http://${ip:-localhost}:32400/web"
    echo "  Jellyfin:            http://${ip:-localhost}:8096"
    echo "  Radarr:              http://${ip:-localhost}:7878"
    echo "  Sonarr:              http://${ip:-localhost}:8989"
    echo ""
    echo "  Install directory:   ${INSTALL_DIR}"
    echo "  Manage services:     cd ${INSTALL_DIR} && ./manage.sh status"
    echo ""
    echo "  Note: containers run via Docker Compose — they won't show as CasaOS app tiles."
}

# ── Preflight ─────────────────────────────────────────────────────
if [[ -z "${TORBOX_API_KEY:-}" ]]; then
    err "TORBOX_API_KEY is required for CasaOS install."
    echo "  curl -fsSL https://raw.githubusercontent.com/killamfkr/TorBox-Media-Server/main/install-casaos.sh | TORBOX_API_KEY=\"your-key\" bash"
    exit 1
fi

if [[ $EUID -eq 0 && -z "${PUID:-}" ]]; then
    export PUID=1000 PGID=1000
    log "Running as root — using PUID=1000 PGID=1000 for container file ownership."
fi

log "Checking dependencies..."
for pkg in git fuse3 jq curl openssl; do
    ensure_pkg "$pkg"
done
ensure_docker

# ── Clone / update source repo ────────────────────────────────────
log "Preparing directories..."
run_root mkdir -p "$(dirname "$REPO_DIR")" "$(dirname "$INSTALL_DIR")" "${TORBOX_MOUNT_DIR}"

if [[ -d "${REPO_DIR}/.git" ]]; then
    log "Updating existing repo at ${REPO_DIR}..."
    git -C "${REPO_DIR}" pull --ff-only
else
    log "Cloning ${REPO_URL} → ${REPO_DIR}..."
    git clone "${REPO_URL}" "${REPO_DIR}"
fi

# ── Run setup ─────────────────────────────────────────────────────
export TORBOX_INSTALL_DIR="${INSTALL_DIR}"
cd "${REPO_DIR}"
chmod +x setup.sh

log "Running setup (this downloads ~5–8 GB of Docker images on first run)..."
if ! ./setup.sh --yes "$@"; then
    err "setup.sh failed. See output above."
    exit 1
fi

apply_casaos_compose_fixes
repair_env_file

if [[ -x "${INSTALL_DIR}/manage.sh" ]]; then
    log "Restarting services with CasaOS network settings..."
    (cd "${INSTALL_DIR}" && ./manage.sh restart) || true
fi

if verify_install; then
    print_success
else
    err "Install incomplete. Try re-running:"
    echo "  cd ${REPO_DIR} && TORBOX_INSTALL_DIR=${INSTALL_DIR} TORBOX_CASAOS=true ./setup.sh --yes"
    echo "  cd ${INSTALL_DIR} && ./manage.sh start"
    exit 1
fi
