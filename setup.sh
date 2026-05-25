#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
#  TorBox Media Server - All-in-One Setup Script
#  Automated setup for a debrid-powered media server using Docker
#
#  Components: Prowlarr, Byparr, Decypharr, Seerr,
#              Radarr, Sonarr, rclone/FUSE mount, Plex or Jellyfin
#
#  Supports all major Linux distributions (Arch, Debian/Ubuntu, Fedora/RHEL,
#  openSUSE, and derivatives). Requires Docker 24+ and Docker Compose v2.
# ============================================================================

VERSION="1.0.0"
DRY_RUN=false
SERVICES_STARTED=false

trap 'cleanup_on_interrupt' INT TERM

cleanup_on_interrupt() {
    echo ""
    log_warn "Setup interrupted. Cleaning up partial installation..."
    if [[ "$SERVICES_STARTED" == "true" ]]; then
        # Stop containers if they were started
        if [[ -n "${INSTALL_DIR:-}" && -d "${INSTALL_DIR:-}" ]]; then
            compose_cmd down --remove-orphans 2>/dev/null || true
        fi
    fi
    # Remove partially created install dir only if install never completed
    if [[ -n "${INSTALL_DIR:-}" && -d "${INSTALL_DIR:-}" && ! -f "${INSTALL_DIR}/.torbox-installed" ]]; then
        rm -rf "${INSTALL_DIR}" 2>/dev/null || true
    fi
    log_info "Cleanup complete. Re-run setup.sh when ready."
    exit 130
}

# Shared test utility helpers (used by tests/test_setup_functions.sh)
generate_api_key() {
    local key=""
    local out=""
    # Prefer openssl for cryptographically strong randomness
    if command -v openssl &>/dev/null; then
        # Try each generator, capturing only on success
        if out="$(openssl rand -hex 16 2>/dev/null)"; then
            key="$out"
        fi
    fi
    if [[ -z "$key" ]] && command -v od &>/dev/null; then
        if out="$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"; then
            key="$out"
        fi
    fi
    if [[ -z "$key" ]] && command -v xxd &>/dev/null; then
        if out="$(head -c 16 /dev/urandom 2>/dev/null | xxd -p -c 32 2>/dev/null | tr -d ' \n')"; then
            key="$out"
        fi
    fi
    if [[ -z "$key" ]]; then
        # Last resort: use Python if available
        if command -v python3 &>/dev/null; then
            if out="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(16))
PY
)"; then
                key="$out"
            fi
        fi
    fi
    # Final fallback: if everything failed (extremely unlikely), return empty and let caller handle
    echo "$key"
}
mask_key() { local k="$1"; [[ ${#k} -le 4 ]] && echo "$k" || echo "${k:0:4}...${k: -4}"; }

# ============================================================================
#  Colors / Formatting
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ============================================================================
#  Logging Helpers
# ============================================================================
log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${CYAN}➜${NC} $*"; }
log_section() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}$1${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ============================================================================
#  Banner / Branding
# ============================================================================
show_banner() {
    clear
    echo -e "${CYAN}"
    cat << 'EOF'
  ╔══════════════════════════════════════════════════════════════╗
  ║                 TorBox Media Server Setup                   ║
  ╠══════════════════════════════════════════════════════════════╣
  ║   Prowlarr · Byparr · Decypharr · Seerr ·                  ║
  ║   Radarr · Sonarr · rclone/FUSE · Plex/Jellyfin            ║
  ╚══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    echo -e "  ${BOLD}Version:${NC} ${VERSION}"
    echo -e "  ${BOLD}GitHub:${NC}  https://github.com/nordicnode/TorBox-Media-Server"
    echo ""
}

# ============================================================================
#  Arguments / Flags
# ============================================================================
NON_INTERACTIVE=false
USE_EXISTING_ENV=false
for arg in "$@"; do
    case "$arg" in
        --yes|-y|--non-interactive) NON_INTERACTIVE=true ;;
        --use-existing-env) USE_EXISTING_ENV=true ;;
        --dry-run) DRY_RUN=true ;;
        --help|-h)
            cat << EOF
Usage: $0 [options]

Options:
  -y, --yes, --non-interactive   Run without prompts (requires TORBOX_API_KEY env var)
      --use-existing-env         Reuse values from existing .env when present
      --dry-run                  Print actions without executing them
  -h, --help                     Show this help

Environment variables for non-interactive use:
  TORBOX_API_KEY            Required. Your TorBox API key.
  TORBOX_MEDIA_SERVER       Optional. 'plex' or 'jellyfin' (default: plex)
  TORBOX_MOUNT_DIR          Optional. Default: /mnt/torbox
  TORBOX_INSTALL_DIR        Optional. Default: ./torbox-media-server
  TORBOX_DATA_DIR           Optional. Default: <install_dir>/data
  TORBOX_CONFIG_DIR         Optional. Default: <install_dir>/config
  TORBOX_TZ                 Optional. Default: system timezone or UTC
  TORBOX_PUID               Optional. Default: current user id
  TORBOX_PGID               Optional. Default: current group id
  TORBOX_HW_ACCEL           Optional. 'intel', 'nvidia', or 'none' (auto-detect if unset)
  TORBOX_ENABLE_AUTOSTART   Optional. 'true' or 'false' (default: true)
  PLEX_CLAIM                Optional. Plex claim token if using Plex
EOF
            exit 0
            ;;
    esac
done

run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] $*"
    else
        "$@"
    fi
}

# ============================================================================
#  Safe command wrappers and compose detection
# ============================================================================
COMPOSE_CMD=()
DOCKER_CMD=()
detect_compose_cmd() {
    if docker info &>/dev/null; then
        COMPOSE_CMD=(docker compose)
        DOCKER_CMD=(docker)
    else
        COMPOSE_CMD=(sudo docker compose)
        DOCKER_CMD=(sudo docker)
    fi
}

compose_cmd() {
    if [[ ${#COMPOSE_CMD[@]} -eq 0 ]]; then
        detect_compose_cmd
    fi
    # CD into directory so Docker auto-discovers both docker-compose.yml and docker-compose.override.yml
    (cd "${INSTALL_DIR}" && "${COMPOSE_CMD[@]}" --env-file "${ENV_FILE}" "$@")
}

docker_cmd() {
    if [[ ${#DOCKER_CMD[@]} -eq 0 ]]; then
        detect_compose_cmd
    fi
    "${DOCKER_CMD[@]}" "$@"
}

# ============================================================================
#  Dependency & Environment Checks
# ============================================================================
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "Do not run this script as root. Run as a normal user with sudo access."
        exit 1
    fi
}

check_linux() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        log_error "This setup currently supports Linux only."
        exit 1
    fi
}

check_dependencies() {
    log_section "Checking System Dependencies"

    local missing=()

    if ! command -v curl &>/dev/null; then
        missing+=("curl")
    fi

    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi

    if ! command -v openssl &>/dev/null && ! command -v od &>/dev/null && ! command -v xxd &>/dev/null && ! command -v python3 &>/dev/null; then
        # We need at least one secure/random generator path for API keys
        missing+=("openssl")
    fi

    if ! command -v docker &>/dev/null; then
        missing+=("docker")
    fi

    if ! docker compose version &>/dev/null; then
        missing+=("docker-compose")
    fi

    if ! command -v timedatectl &>/dev/null; then
        missing+=("timedatectl")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing dependencies: ${missing[*]}"
        echo ""
        local install_deps="y"
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "Install missing dependencies automatically? [Y/n]: " install_deps
        fi
        if [[ "${install_deps,,}" != "n" ]]; then
            install_dependencies "${missing[@]}"
        else
            log_error "Cannot continue without: ${missing[*]}"
            exit 1
        fi
    else
        log_info "All dependencies satisfied."
    fi

    # Ensure docker daemon is running (distinguish permission errors from daemon-down)
    if ! docker info &>/dev/null; then
        if systemctl is-active --quiet docker 2>/dev/null; then
            log_warn "Docker is running but current user lacks permission."
        else
            log_warn "Docker daemon is not running. Starting it..."
            sudo systemctl start docker 2>/dev/null || true
            sudo systemctl enable docker 2>/dev/null || true
            # Wait for Docker daemon to be ready (up to 15 seconds)
            local docker_wait=0
            local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
            while [[ $docker_wait -lt 15 ]]; do
                if sudo docker info &>/dev/null; then
                    printf "\r  %-50s\r" ""
                    break
                fi
                printf "\r  %s Waiting for Docker daemon... %ds/15s" "${spin_chars:docker_wait%${#spin_chars}:1}" "$docker_wait"
                sleep 1
                docker_wait=$((docker_wait + 1))
            done
            printf "\r  %-50s\r" ""
        fi
        if ! sudo docker info &>/dev/null; then
            log_error "Failed to connect to Docker. Please start Docker manually and re-run."
            exit 1
        fi
    fi

    # Ensure current user is in docker group (skip if running as root)
    if [[ $EUID -ne 0 ]] && ! groups | grep -qw docker; then
        log_warn "Current user is not in the 'docker' group."
        sudo usermod -aG docker "$USER"
        log_warn "Added $USER to docker group. You may need to log out and back in."
        log_warn "For now, commands will use sudo as needed."
    fi

    # Check FUSE support
    if [[ ! -e /dev/fuse ]]; then
        log_warn "/dev/fuse not found. Loading fuse module..."
        sudo modprobe fuse 2>/dev/null || true
        if [[ ! -e /dev/fuse ]]; then
            log_error "/dev/fuse still not available. Please install FUSE for your distro:"
            echo "  Arch Linux:   sudo pacman -S fuse3"
            echo "  Debian/Ubuntu: sudo apt-get install fuse3"
            echo "  Fedora/RHEL:   sudo dnf install fuse3"
            echo "  openSUSE:      sudo zypper install fuse3"
            echo "  Amazon Linux:  sudo yum install fuse"
            exit 1
        fi
    fi
    log_info "FUSE support available."
}

check_ports() {
    log_section "Checking Ports"
    local required_ports=(8282 9696 8191 7878 8989 5055)
    local conflicts=()

    # Add media server port(s) depending on selection if already known
    if [[ "${MEDIA_SERVER:-}" == "plex" ]]; then
        required_ports+=(32400)
    elif [[ "${MEDIA_SERVER:-}" == "jellyfin" ]]; then
        required_ports+=(8096 8920)
    fi

    for port in "${required_ports[@]}"; do
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[:.])${port}$"; then
            conflicts+=("$port")
        fi
    done

    if [[ ${#conflicts[@]} -gt 0 ]]; then
        log_warn "The following localhost ports are already in use: ${conflicts[*]}"
        echo "  The stack binds services to 127.0.0.1 only for safety."
        echo "  Stop the conflicting services or edit the generated compose file later."
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            log_warn "Non-interactive mode: continuing despite port conflicts."
        else
            read -rp "Continue anyway? [Y/n]: " continue_anyway
            if [[ "${continue_anyway,,}" == "n" ]]; then
                log_error "Setup cancelled. Free the conflicting ports and re-run."
                exit 1
            fi
        fi
    fi
}

install_dependencies() {
    local deps=("$@")
    log_step "Installing: ${deps[*]}"

    # Detect package manager and install using the appropriate method
    if command -v pacman &>/dev/null; then
        # Arch Linux and derivatives (Manjaro, EndeavourOS, CachyOS, etc.)
        for dep in "${deps[@]}"; do
            case "$dep" in
                docker)
                    sudo pacman -S --noconfirm docker docker-compose-plugin
                    sudo systemctl enable --now docker
                    sudo usermod -aG docker "$USER"
                    ;;
                docker-compose) sudo pacman -S --noconfirm docker-compose-plugin ;;
                curl)           sudo pacman -S --noconfirm curl ;;
                jq)             sudo pacman -S --noconfirm jq ;;
                openssl)        sudo pacman -S --noconfirm openssl ;;
                timedatectl)    sudo pacman -S --noconfirm systemd ;;
            esac
        done

    elif command -v apt-get &>/dev/null; then
        # Debian, Ubuntu, Linux Mint, Pop!_OS, Raspberry Pi OS, and derivatives
        sudo apt-get update -qq
        for dep in "${deps[@]}"; do
            case "$dep" in
                docker)
                    # Prefer the official Docker CE repo over the older distro-provided docker.io
                    if apt-cache show docker-ce &>/dev/null 2>&1; then
                        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
                    else
                        # Fall back to distro package if official repo is not configured
                        sudo apt-get install -y docker.io docker-compose-plugin
                    fi
                    sudo systemctl enable --now docker
                    sudo usermod -aG docker "$USER"
                    ;;
                docker-compose) sudo apt-get install -y docker-compose-plugin ;;
                curl)           sudo apt-get install -y curl ;;
                jq)             sudo apt-get install -y jq ;;
                openssl)        sudo apt-get install -y openssl ;;
                timedatectl)    sudo apt-get install -y systemd ;;
            esac
        done

    elif command -v dnf &>/dev/null; then
        # Fedora, RHEL, CentOS Stream, AlmaLinux, Rocky Linux, and derivatives
        # dnf5 (Fedora 41+) is compatible with dnf flags used here
        for dep in "${deps[@]}"; do
            case "$dep" in
                docker)
                    # moby-engine is the community-maintained Docker in Fedora repos;
                    # docker-ce is available if the user has added the official Docker repo.
                    if dnf list available docker-ce &>/dev/null 2>&1; then
                        sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
                    else
                        sudo dnf install -y moby-engine docker-compose-plugin
                    fi
                    sudo systemctl enable --now docker
                    sudo usermod -aG docker "$USER"
                    ;;
                docker-compose) sudo dnf install -y docker-compose-plugin 2>/dev/null || sudo dnf install -y docker-compose ;;
                curl)           sudo dnf install -y curl ;;
                jq)             sudo dnf install -y jq ;;
                openssl)        sudo dnf install -y openssl ;;
                timedatectl)    sudo dnf install -y systemd-udev ;;
            esac
        done

    elif command -v zypper &>/dev/null; then
        # openSUSE Leap and Tumbleweed
        sudo zypper --non-interactive refresh
        for dep in "${deps[@]}"; do
            case "$dep" in
                docker)
                    sudo zypper --non-interactive install docker docker-compose
                    sudo systemctl enable --now docker
                    sudo usermod -aG docker "$USER"
                    ;;
                docker-compose) sudo zypper --non-interactive install docker-compose ;;
                curl)           sudo zypper --non-interactive install curl ;;
                jq)             sudo zypper --non-interactive install jq ;;
                openssl)        sudo zypper --non-interactive install openssl ;;
                timedatectl)    sudo zypper --non-interactive install systemd ;;
            esac
        done

    elif command -v yum &>/dev/null; then
        # Amazon Linux 2, older RHEL/CentOS, and yum-based systems
        for dep in "${deps[@]}"; do
            case "$dep" in
                docker)
                    sudo yum install -y docker
                    sudo systemctl enable --now docker
                    sudo usermod -aG docker "$USER"
                    ;;
                docker-compose)
                    # docker-compose-plugin may not exist; fall back to standalone binary
                    if ! sudo yum install -y docker-compose-plugin 2>/dev/null; then
                        log_warn "docker-compose-plugin not found in yum repos."
                        log_warn "Install Docker Compose manually: https://docs.docker.com/compose/install/"
                    fi
                    ;;
                curl)    sudo yum install -y curl ;;
                jq)      sudo yum install -y jq ;;
                openssl) sudo yum install -y openssl ;;
                timedatectl) sudo yum install -y systemd ;;
            esac
        done

    else
        log_error "No supported package manager found (tried: pacman, apt-get, dnf, zypper, yum)."
        log_error "Please install the following dependencies manually and re-run:"
        for dep in "${deps[@]}"; do
            echo "    - $dep"
        done
        log_error "See https://docs.docker.com/engine/install/ for Docker installation."
        exit 1
    fi

    log_info "Dependencies installed."
}

# ============================================================================
#  User Configuration
# ============================================================================

gather_config() {
    log_section "Configuration"

    # TorBox API Key
    echo -e "${BOLD}TorBox API Key${NC}"
    echo "  Get your API key from: https://torbox.app/settings"
    echo ""
    if [[ -n "${TORBOX_API_KEY:-}" ]]; then
        # Non-interactive: use env var
        log_info "Using TorBox API key from TORBOX_API_KEY env var."
    elif [[ -n "${EXISTING_TORBOX_API_KEY:-}" ]]; then
        echo -e "  ${GREEN}Previous API key found.${NC} Press Enter to keep it, or paste a new one."
        read -rsp "  TorBox API key [keep existing]: " new_torbox_key
        echo ""
        if [[ -n "$new_torbox_key" ]]; then
            TORBOX_API_KEY="$new_torbox_key"
        else
            TORBOX_API_KEY="$EXISTING_TORBOX_API_KEY"
        fi
    else
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            log_error "TORBOX_API_KEY env var is required in non-interactive mode."
            exit 1
        fi
        while true; do
            read -rsp "  Enter TorBox API key: " TORBOX_API_KEY
            echo ""
            if [[ -n "$TORBOX_API_KEY" ]]; then
                break
            fi
            log_warn "API key cannot be empty."
        done
    fi

    # Media server selection
    echo ""
    echo -e "${BOLD}Choose Media Server${NC}"
    if [[ -n "${TORBOX_MEDIA_SERVER:-}" ]]; then
        MEDIA_SERVER="${TORBOX_MEDIA_SERVER,,}"
        log_info "Using media server from env: ${MEDIA_SERVER}"
    elif [[ -n "${EXISTING_MEDIA_SERVER:-}" ]]; then
        MEDIA_SERVER="$EXISTING_MEDIA_SERVER"
        log_info "Using previous media server: ${MEDIA_SERVER}"
    elif [[ "$NON_INTERACTIVE" == "true" ]]; then
        MEDIA_SERVER="plex"
        log_info "Non-interactive: defaulting to Plex."
    else
        echo "  1) Plex"
        echo "  2) Jellyfin"
        while true; do
            read -rp "Select [1-2] (default 1): " media_choice
            case "${media_choice:-1}" in
                1) MEDIA_SERVER="plex"; break ;;
                2) MEDIA_SERVER="jellyfin"; break ;;
                *) log_warn "Please choose 1 or 2." ;;
            esac
        done
    fi

    # Install dir and derived dirs
    INSTALL_DIR="${TORBOX_INSTALL_DIR:-${PWD}/torbox-media-server}"
    DATA_DIR="${TORBOX_DATA_DIR:-${INSTALL_DIR}/data}"
    CONFIG_DIR="${TORBOX_CONFIG_DIR:-${INSTALL_DIR}/config}"
    MOUNT_DIR="${TORBOX_MOUNT_DIR:-/mnt/torbox}"
    ENV_FILE="${INSTALL_DIR}/.env"
    COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"

    # Existing values if reusing env
    if [[ "$USE_EXISTING_ENV" == "true" && -f "$ENV_FILE" ]]; then
        EXISTING_TORBOX_API_KEY="$(env_val TORBOX_API_KEY || true)"
        EXISTING_MEDIA_SERVER="$(env_val COMPOSE_PROFILES || true)"
    fi

    # PUID/PGID/TZ
    PUID="${TORBOX_PUID:-$(id -u)}"
    PGID="${TORBOX_PGID:-$(id -g)}"
    TZ="${TORBOX_TZ:-$(timedatectl show -p Timezone --value 2>/dev/null || true)}"
    if [[ -z "$TZ" ]]; then TZ="UTC"; fi

    # Optional Plex claim
    PLEX_CLAIM="${PLEX_CLAIM:-}"

    # Hardware Acceleration — auto-detect, then prompt only if ambiguous
    HW_ACCEL="${TORBOX_HW_ACCEL:-}"
    if [[ -z "$HW_ACCEL" ]]; then
        local detected_intel=false detected_nvidia=false
        if [[ -d /dev/dri ]]; then
            detected_intel=true
        fi
        if command -v nvidia-smi &>/dev/null || [[ -d /proc/driver/nvidia ]]; then
            detected_nvidia=true
        fi

        if [[ "$detected_intel" == "true" && "$detected_nvidia" == "false" ]]; then
            HW_ACCEL="intel"
            log_info "Auto-detected Intel QuickSync (/dev/dri)."
        elif [[ "$detected_nvidia" == "true" && "$detected_intel" == "false" ]]; then
            HW_ACCEL="nvidia"
            log_info "Auto-detected NVIDIA GPU."
        elif [[ "$detected_intel" == "true" && "$detected_nvidia" == "true" ]]; then
            if [[ "$NON_INTERACTIVE" == "true" ]]; then
                HW_ACCEL="intel"
                log_info "Both GPUs detected. Non-interactive: defaulting to Intel QuickSync."
            else
                echo "  Both Intel and NVIDIA GPUs detected."
                echo "  1) Intel QuickSync"
                echo "  2) NVIDIA"
                echo "  3) Software only"
                while true; do
                    read -rp "Select hardware acceleration [1-3] (default 1): " hw_choice
                    case "${hw_choice:-1}" in
                        1) HW_ACCEL="intel"; break ;;
                        2) HW_ACCEL="nvidia"; break ;;
                        3) HW_ACCEL="none"; break ;;
                        *) log_warn "Please choose 1, 2, or 3." ;;
                    esac
                done
            fi
        else
            HW_ACCEL="none"
            if [[ "$NON_INTERACTIVE" == "true" ]]; then
                log_info "No GPU detected. Non-interactive: using software transcoding."
            else
                echo "  No GPU detected."
                echo "  Continuing with software transcoding."
            fi
        fi
    fi

    # Verify nvidia-container-toolkit is installed if NVIDIA is selected
    if [[ "${HW_ACCEL}" == "nvidia" ]]; then
        if ! command -v nvidia-container-runtime &>/dev/null && \
           ! command -v nvidia-ctk &>/dev/null; then
            log_error "NVIDIA GPU detected but nvidia-container-toolkit is not installed."
            log_error "Docker cannot use NVIDIA GPUs without the container toolkit."
            echo ""
            echo "  Install it with:"
            echo "    Arch Linux:   sudo pacman -S nvidia-container-toolkit"
            echo "    Debian/Ubuntu: sudo apt-get install nvidia-container-toolkit"
            echo "    Fedora/RHEL:   sudo dnf install nvidia-container-toolkit"
            echo "    openSUSE:      sudo zypper install nvidia-container-toolkit"
            echo "  Official guide: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
            echo ""
            log_info "Falling back to software transcoding."
            HW_ACCEL="none"
        else
            log_info "nvidia-container-toolkit is installed."
        fi
    fi

    echo ""
    log_info "Configuration complete."
    log_info "Generated API keys for Radarr, Sonarr, and Prowlarr."

    # Show confirmation summary
    log_section "Configuration Summary"
    echo -e "  ${BOLD}TorBox API Key:${NC}    ...${TORBOX_API_KEY: -4}"
    echo -e "  ${BOLD}Media Server:${NC}      ${MEDIA_SERVER}"
    echo -e "  ${BOLD}Mount Directory:${NC}   ${MOUNT_DIR}"
    echo -e "  ${BOLD}PUID/PGID:${NC}         ${PUID}:${PGID}"
    echo -e "  ${BOLD}Timezone:${NC}          ${TZ}"
    echo -e "  ${BOLD}HW Acceleration:${NC}   ${HW_ACCEL}"
    echo ""
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -rp "Proceed with these settings? [Y/n]: " confirm_config
        if [[ "${confirm_config,,}" == "n" ]]; then
            log_info "Setup cancelled."
            exit 0
        fi
    fi
}

# ============================================================================
#  Directory Structure
# ============================================================================

create_directories() {
    log_section "Creating Directory Structure"

    # Directories need more permissive permissions for container access
    local saved_umask
    saved_umask="$(umask)"
    umask 022

    mkdir -p "${INSTALL_DIR}"
    mkdir -p "${DATA_DIR}/media/movies" "${DATA_DIR}/media/tv"
    mkdir -p "${DATA_DIR}/downloads/movies" "${DATA_DIR}/downloads/tv"
    mkdir -p "${CONFIG_DIR}/decypharr" "${CONFIG_DIR}/prowlarr" "${CONFIG_DIR}/radarr" "${CONFIG_DIR}/sonarr" "${CONFIG_DIR}/seerr"
    if [[ "$MEDIA_SERVER" == "plex" ]]; then
        mkdir -p "${CONFIG_DIR}/plex"
    else
        mkdir -p "${CONFIG_DIR}/jellyfin"
    fi

    # Ensure mount directory exists with correct perms
    sudo mkdir -p "${MOUNT_DIR}"
    sudo chown "${PUID}:${PGID}" "${MOUNT_DIR}" || true

    umask "$saved_umask"
    log_info "Directories created under: ${INSTALL_DIR}"
}

# ============================================================================
#  Helpers for env and config generation
# ============================================================================

env_val() {
    local key="$1"
    grep "^${key}=" "${ENV_FILE}" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' | tr -d '\r'
}

write_env_file() {
    log_section "Writing .env"
    cat > "${ENV_FILE}" << EOF
TORBOX_API_KEY="${TORBOX_API_KEY}"
PUID=${PUID}
PGID=${PGID}
TZ="${TZ}"
INSTALL_DIR="${INSTALL_DIR}"
DATA_DIR="${DATA_DIR}"
CONFIG_DIR="${CONFIG_DIR}"
MOUNT_DIR="${MOUNT_DIR}"
COMPOSE_PROFILES=${MEDIA_SERVER}
PLEX_CLAIM="${PLEX_CLAIM}"
HW_ACCEL=${HW_ACCEL}
EOF
    chmod 600 "${ENV_FILE}"
    log_info "Created ${ENV_FILE}"
}

# ============================================================================
#  Config File Generation
# ============================================================================

write_decypharr_config() {
    log_section "Generating Decypharr Config"

    cat > "${CONFIG_DIR}/decypharr/config.json" << EOF
{
  "debrid": {
    "provider": "torbox",
    "api_key": "${TORBOX_API_KEY}"
  },
  "server": {
    "port": 8282,
    "host": "0.0.0.0"
  },
  "downloaders": {
    "mount_dir": "/mnt/remote",
    "symlink_dir_movies": "/data/media/movies",
    "symlink_dir_tv": "/data/media/tv",
    "downloads_dir_movies": "/data/downloads/movies",
    "downloads_dir_tv": "/data/downloads/tv"
  },
  "torrent": {
    "listen_port": 8282,
    "host": "0.0.0.0"
  }
}
EOF
    chmod 600 "${CONFIG_DIR}/decypharr/config.json"
    log_info "Decypharr config written."
}

radarr_api_key=""
sonarr_api_key=""
prowlarr_api_key=""

write_generated_api_keys() {
    # Generate stable API keys (reuse existing if present when re-running)
    local existing_r existing_s existing_p
    existing_r="${RADARR_API_KEY:-}"
    existing_s="${SONARR_API_KEY:-}"
    existing_p="${PROWLARR_API_KEY:-}"

    if [[ -z "$existing_r" ]]; then existing_r="$(generate_api_key)"; fi
    if [[ -z "$existing_s" ]]; then existing_s="$(generate_api_key)"; fi
    if [[ -z "$existing_p" ]]; then existing_p="$(generate_api_key)"; fi

    if [[ -z "$existing_r" || -z "$existing_s" || -z "$existing_p" ]]; then
        log_error "Failed to generate one or more internal API keys. Ensure openssl, od, xxd, or python3 is available."
        exit 1
    fi

    radarr_api_key="$existing_r"
    sonarr_api_key="$existing_s"
    prowlarr_api_key="$existing_p"
}

apply_sonarr_settings() {
    local settings_file="$1"
    jq \
      --arg apiKey "$sonarr_api_key" \
      '.ApiKey = $apiKey' \
      "$settings_file" > "${settings_file}.tmp" && mv "${settings_file}.tmp" "$settings_file"
}

apply_radarr_settings() {
    local settings_file="$1"
    jq \
      --arg apiKey "$radarr_api_key" \
      '.ApiKey = $apiKey' \
      "$settings_file" > "${settings_file}.tmp" && mv "${settings_file}.tmp" "$settings_file"
}

# ==========================================================================
#  Compose Generation
# ==========================================================================

write_compose_file() {
    log_section "Generating Docker Compose File"

    cat > "${COMPOSE_FILE}" << 'EOF'
# ============================================================================
#  TorBox Media Server - Docker Compose
#  This file is version-controlled in the repo. Do NOT edit manually.
#  Re-run setup.sh to regenerate after updates.
# ============================================================================

networks:
  media-network:
    driver: bridge

services:
  # ── Decypharr ──────────────────────────────────────────────────
  # Mocks qBittorrent API for Radarr/Sonarr, connects to TorBox,
  # handles WebDAV mounting via built-in rclone, and creates symlinks.
  decypharr:
    image: ghcr.io/sirrobot01/decypharr:v2.0
    container_name: decypharr
    restart: unless-stopped
    networks:
      - media-network
    ports:
      - "127.0.0.1:8282:8282"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - UMASK=002
    volumes:
      - "${CONFIG_DIR}/decypharr/config.json:/app/config.json:ro"
      - "${MOUNT_DIR}:/mnt/remote:rshared"
      - "${DATA_DIR}:/data"
    devices:
      - /dev/fuse:/dev/fuse:rwm
    cap_add:
      - SYS_ADMIN
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8282"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    security_opt:
      # Harmless on systems without AppArmor (e.g. CachyOS)
      - apparmor:unconfined

  # ── Prowlarr ───────────────────────────────────────────────────
  # Indexer manager - feeds search results to Radarr & Sonarr.
  prowlarr:
    image: lscr.io/linuxserver/prowlarr:2.1.3
    container_name: prowlarr
    restart: unless-stopped
    networks:
      - media-network
    ports:
      - "127.0.0.1:9696:9696"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    depends_on:
      byparr:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:9696/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    volumes:
      - "${CONFIG_DIR}/prowlarr:/config"

  # ── Byparr ────────────────────────────────────────────────────
  # Cloudflare bypass proxy (Byparr - drop-in FlareSolverr replacement).
  byparr:
    image: ghcr.io/thephaseless/byparr:v2.1.0
    container_name: byparr
    restart: unless-stopped
    networks:
      - media-network
    ports:
      - "127.0.0.1:8191:8191"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    environment:
      - LOG_LEVEL=info
      - LOG_HTML=false
      - TZ=${TZ}
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8191"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s

  # ── Radarr ─────────────────────────────────────────────────────
  # Movie management - searches, grabs, and organizes movies.
  # Uses Decypharr as its download client (qBittorrent mock).
  radarr:
    image: lscr.io/linuxserver/radarr:5.22.4
    container_name: radarr
    restart: unless-stopped
    networks:
      - media-network
    ports:
      - "127.0.0.1:7878:7878"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    depends_on:
      decypharr:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:7878/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    volumes:
      - "${CONFIG_DIR}/radarr:/config"
      - "${DATA_DIR}:/data"
      - "${MOUNT_DIR}:/mnt/remote:rslave"

  # ── Sonarr ─────────────────────────────────────────────────────
  # TV show management - searches, grabs, and organizes series.
  # Uses Decypharr as its download client (qBittorrent mock).
  sonarr:
    image: lscr.io/linuxserver/sonarr:4.0.14
    container_name: sonarr
    restart: unless-stopped
    networks:
      - media-network
    ports:
      - "127.0.0.1:8989:8989"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    depends_on:
      decypharr:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8989/ping"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    volumes:
      - "${CONFIG_DIR}/sonarr:/config"
      - "${DATA_DIR}:/data"
      - "${MOUNT_DIR}:/mnt/remote:rslave"

  # ── Seerr ───────────────────────────────────────────────────────
  # Media request & discovery frontend.
  seerr:
    image: ghcr.io/seerr-team/seerr:v3.2.0
    container_name: seerr
    user: "${PUID}:${PGID}"
    restart: unless-stopped
    networks:
      - media-network
    ports:
      - "127.0.0.1:5055:5055"
    environment:
      - TZ=${TZ}
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:5055"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    volumes:
      - "${CONFIG_DIR}/seerr:/app/config"

  # ── Plex ───────────────────────────────────────────────────────
  # Media server option 1 - streams your library to any device.
  # Activated via COMPOSE_PROFILES=plex in .env
  plex:
    image: lscr.io/linuxserver/plex:1.41.5
    profiles: ["plex"]
    container_name: plex
    restart: unless-stopped
    networks:
      - media-network
    ports:
      - "127.0.0.1:32400:32400"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - VERSION=docker
      - PLEX_CLAIM=${PLEX_CLAIM:-}
    healthcheck:
      test: ["CMD-SHELL", "wget --spider -q http://localhost:32400/identity || curl -sf http://localhost:32400/identity"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 60s
    volumes:
      - "${CONFIG_DIR}/plex:/config"
      - "${DATA_DIR}:/data"
      - "${MOUNT_DIR}:/mnt/remote:rslave"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  # ── Jellyfin ───────────────────────────────────────────────────
  # Media server option 2 (open-source) - streams your library.
  # Activated via COMPOSE_PROFILES=jellyfin in .env
  jellyfin:
    image: lscr.io/linuxserver/jellyfin:10.10.7
    profiles: ["jellyfin"]
    container_name: jellyfin
    restart: unless-stopped
    networks:
      - media-network
    ports:
      - "127.0.0.1:8096:8096"
      - "127.0.0.1:8920:8920"
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
      - JELLYFIN_PublishedServerUrl=http://localhost:8096
    healthcheck:
      test: ["CMD", "curl", "-sf", "http://localhost:8096/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    volumes:
      - "${CONFIG_DIR}/jellyfin:/config"
      - "${DATA_DIR}:/data"
      - "${MOUNT_DIR}:/mnt/remote:rslave"
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

    log_info "Docker Compose file written to ${COMPOSE_FILE}"
}

# ============================================================================
#  Mount propagation for FUSE visibility across containers
# ============================================================================

ensure_mount_propagation() {
    log_section "Configuring Mount Propagation"

    # Ensure mount point supports shared propagation for rclone FUSE mounts
    sudo mkdir -p "${MOUNT_DIR}"
    sudo mountpoint -q "${MOUNT_DIR}" || sudo mount --bind "${MOUNT_DIR}" "${MOUNT_DIR}"
    sudo mount --make-rshared "${MOUNT_DIR}"

    if findmnt -no PROPAGATION "${MOUNT_DIR}" 2>/dev/null | grep -q shared; then
        log_info "Mount propagation enabled on ${MOUNT_DIR} (shared)."
    else
        log_warn "Mount propagation may not be active. Decypharr's FUSE mounts might not be visible to other containers."
    fi
}

# ============================================================================
#  Optional systemd service
# ============================================================================

create_systemd_service() {
    local service_name="torbox-media-server"
    local service_file="/etc/systemd/system/${service_name}.service"

    if [[ ! -d /run/systemd/system ]] || ! command -v systemctl &>/dev/null; then
        log_warn "systemd not detected. Skipping auto-start service creation."
        return 0
    fi

    if ! docker compose version &>/dev/null; then
        log_warn "Docker Compose v2 not detected. Systemd service may not work."
    fi

    sudo tee "${service_file}" >/dev/null << EOF
[Unit]
Description=TorBox Media Server
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/docker compose --env-file ${ENV_FILE} up -d
ExecStop=/usr/bin/docker compose --env-file ${ENV_FILE} down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable "${service_name}.service" 2>/dev/null \
        && log_info "Enabled systemd service: ${service_name}" \
        || log_warn "Could not enable ${service_name}. You can enable it manually later."
}

# ============================================================================
#  Docker startup and post-setup hints
# ============================================================================

start_stack() {
    log_section "Starting Containers"
    compose_cmd up -d
    SERVICES_STARTED=true
    log_info "Containers started."
}

print_final_notes() {
    log_section "Setup Complete"

    echo -e "${BOLD}Local service URLs:${NC}"
    echo "  Prowlarr: http://localhost:9696"
    echo "  Radarr:   http://localhost:7878"
    echo "  Sonarr:   http://localhost:8989"
    echo "  Seerr:    http://localhost:5055"
    if [[ "$MEDIA_SERVER" == "plex" ]]; then
        echo "  Plex:     http://localhost:32400/web"
    else
        echo "  Jellyfin: http://localhost:8096"
    fi
    echo ""
    echo -e "${BOLD}Install directory:${NC} ${INSTALL_DIR}"
    echo -e "${BOLD}Mount directory:${NC}   ${MOUNT_DIR}"
    echo ""
    echo "Next steps:"
    echo "  1. Open Seerr and complete the initial wizard."
    echo "  2. Connect Seerr to Radarr and Sonarr using the generated API keys."
    echo "  3. Add indexers in Prowlarr."
    echo "  4. Verify Decypharr mount visibility if imports fail."
    echo ""
    echo "Useful commands:"
    echo "  cd ${INSTALL_DIR}"
    echo "  docker compose ps"
    echo "  docker compose logs -f <service>"
    echo ""
}

# ============================================================================
#  Main
# ============================================================================

main() {
    show_banner
    check_root
    check_linux
    gather_config
    check_ports
    check_dependencies
    create_directories
    write_env_file
    write_generated_api_keys
    write_decypharr_config
    write_compose_file
    ensure_mount_propagation

    # Optional auto-start service (default true unless explicitly disabled)
    if [[ "${TORBOX_ENABLE_AUTOSTART:-true}" == "true" ]]; then
        create_systemd_service
    fi

    start_stack
    touch "${INSTALL_DIR}/.torbox-installed"
    print_final_notes
}

main "$@"
