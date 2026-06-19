#!/usr/bin/env bash
# CasaOS / Ubuntu one-liner bootstrap for TorBox Media Server.
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/nordicnode/TorBox-Media-Server/main/install-casaos.sh | bash
#   curl -fsSL .../install-casaos.sh | TORBOX_API_KEY="your-key" bash
set -euo pipefail

REPO_URL="${TORBOX_REPO_URL:-https://github.com/nordicnode/TorBox-Media-Server.git}"
CLONE_DIR="${TORBOX_CASAOS_DIR:-/DATA/AppData/torbox-media-server}"
export TORBOX_MOUNT_DIR="${TORBOX_MOUNT_DIR:-/DATA/Media/torbox-media}"

if [[ ! -d /DATA ]]; then
    CLONE_DIR="${HOME}/torbox-media-server"
    export TORBOX_MOUNT_DIR="${TORBOX_MOUNT_DIR:-/mnt/torbox-media}"
fi

ensure_pkg() {
    local pkg="$1"
    if command -v "$pkg" &>/dev/null; then
        return 0
    fi
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -qq
        sudo apt-get install -y "$pkg"
    elif command -v pacman &>/dev/null; then
        sudo pacman -S --noconfirm "$pkg"
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y "$pkg"
    else
        echo "Missing dependency: $pkg. Install it and re-run." >&2
        exit 1
    fi
}

ensure_pkg git
ensure_pkg fuse3

mkdir -p "$(dirname "$CLONE_DIR")"
if [[ -d "${CLONE_DIR}/.git" ]]; then
    git -C "${CLONE_DIR}" pull --ff-only
else
    git clone "${REPO_URL}" "${CLONE_DIR}"
fi

cd "${CLONE_DIR}"
chmod +x setup.sh

if [[ $# -eq 0 && -n "${TORBOX_API_KEY:-}" ]]; then
    exec ./setup.sh --yes
fi

exec ./setup.sh "$@"
