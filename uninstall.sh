#!/usr/bin/env bash
# ============================================================================
#  Uninstall Script — Removes all services deployed by setup.sh
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
BOLD='\033[1m'

log()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[  OK]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[FAIL]${NC}  $*"; }

# pick up the same .env used by setup.sh so paths/names match
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/.env" ]]; then
    # shellcheck source=.env
    source "${SCRIPT_DIR}/.env"
fi

DATA_DIR="${DATA_DIR:-/opt/server-data}"
DOCKER_NETWORK="${DOCKER_NETWORK_NAME:-${DOCKER_NETWORK:-proxyNetwork}}"

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (use sudo)"
    exit 1
fi

echo -e "${RED}${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║            ⚠  SERVER SERVICES UNINSTALL  ⚠                 ║"
echo "║                                                            ║"
echo "║  This will remove: Portainer, NPM, Cloudflared             ║"
echo "║  Optionally: Docker Engine, service data                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

read -rp "$(echo -e "${RED}[?]${NC} Are you sure you want to proceed? [y/N]: ")" confirm
[[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "Cancelled."; exit 0; }

# Stop and remove containers
log "Stopping and removing containers..."
docker stop cloudflared npm portainer 2>/dev/null || true
docker rm cloudflared npm portainer 2>/dev/null || true

# Remove NPM compose stack
if [[ -f "${DATA_DIR}/nginx-proxy-manager/docker-compose.yml" ]]; then
    cd "${DATA_DIR}/nginx-proxy-manager"
    docker compose down 2>/dev/null || true
fi

ok "Containers removed"

# Remove Docker network
docker network rm "$DOCKER_NETWORK" 2>/dev/null || true
ok "Docker network '${DOCKER_NETWORK}' removed"

# Ask about data
read -rp "$(echo -e "${YELLOW}[?]${NC} Remove all service data at ${DATA_DIR}? [y/N]: ")" rm_data
if [[ "$rm_data" =~ ^[Yy]$ ]]; then
    rm -rf "$DATA_DIR"
    ok "Service data removed"
else
    warn "Service data preserved at ${DATA_DIR}"
fi

# Ask about Docker
read -rp "$(echo -e "${YELLOW}[?]${NC} Uninstall Docker Engine? [y/N]: ")" rm_docker
if [[ "$rm_docker" =~ ^[Yy]$ ]]; then
    apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null || true
    apt-get autoremove -y
    rm -rf /var/lib/docker /var/lib/containerd
    rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.asc
    ok "Docker uninstalled"
else
    warn "Docker preserved"
fi

echo ""
ok "Uninstall complete."