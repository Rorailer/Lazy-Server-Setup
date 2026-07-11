#!/usr/bin/env bash

## This is a Server Setup Script for Ubuntu and Debian based systems.
## This will Update the server , install docker , install nginx proxy manager , portainer and cloudflared


# this will stop the script if anything in this script fails. (nothing will go unnoticed)
set -euo pipefail


# --- Variable setup (change in .env file and not here) ----

# this is just to make sure the right file is always selected.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=.env
    source "$ENV_FILE"
fi


# --PORTS--
NPM_HTTP_PORT="${NPM_HTTP_PORT:-80}"
NPM_HTTPS_PORT="${NPM_HTTPS_PORT:-443}"
NPM_ADMIN_PORT="${NPM_ADMIN_PORT:-81}"
PORTAINER_PORT="${PORTAINER_PORT:-9000}"
CLOUDFLARED_TOKEN="${CLOUDFLARED_TOKEN:-}"
# .env.example uses DOCKER_NETWORK; accept both names
DOCKER_NETWORK_NAME="${DOCKER_NETWORK_NAME:-${DOCKER_NETWORK:-proxyNetwork}}"
DATA_DIR="${DATA_DIR:-/opt/server-data}"


# ---- COLORS ----
BOLD='\033[1m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
NC='\033[0m'

log(){
    echo -e "${BLUE}[INFO]${NC} $*" ;
}

ok(){
    echo -e "${GREEN} [ OK]${NC} $*" ;
}

err(){
    echo -e "${RED}[FAILED]${NC} $*" ;
}

warn(){
    echo -e "${YELLOW}[WARN]${NC} $*" ;
}


banner(){
    echo -e "${CYAN}${BOLD}";
    echo "╔══════════════════════════════════════════════════════════════╗";
    echo "║                     Server Setup Script                      ║";
    echo "║                                                              ║";
    echo "║     Setting Up: Docker , NPM , Portainer and Cloudflared     ║";
    echo "╚══════════════════════════════════════════════════════════════╝";
    echo -e "${NC}";
}


spacer(){
    echo -e "${CYAN}--------------------------------------------------------------${NC}";
}


check_root(){
    if [[ $EUID -ne 0 ]]; then
        err "Run this script with sudo.";
        exit 1;
    fi
}

confirm(){
    local msg="$1"
    local choice
    read -rp "$(echo -e "${YELLOW}[??]${NC} $msg [y/N]: ")" choice
    [[ "$choice" == "y" || "$choice" == "Y" ]]
}



# Step 1/5 system update
update_system(){
    spacer
    log "STEP 1/5: Updating & Upgrading the system..."
    spacer
    
    apt-get update
    apt-get upgrade -y
    apt-get install -y \
        curl \
        wget \
        gnupg \
        lsb-release \
        ca-certificates \
        apt-transport-https \
        software-properties-common \
        ufw
    
    ok "Update Successful!"
}


# Step 2/5 docker install
install_docker(){
    spacer
    log "STEP 2/5: Installing Docker..."
    spacer

    local distro
    distro=$(. /etc/os-release && echo "$ID")

    if [[ "$distro" != "ubuntu" && "$distro" != "debian" ]]; then
        err "Unsupported distro for this script: ${distro}. Only Ubuntu and Debian are supported."
        exit 1
    fi

    if command -v docker &> /dev/null; then
        warn "Docker is already installed: $(docker --version)"
        if ! confirm "Reinstall Docker? (only needed if 'docker compose' is missing)"; then
            ok "Keeping existing Docker install."
            # still make sure the shared network exists for the services below
            docker network create "${DOCKER_NETWORK_NAME}" 2>/dev/null || true
            return
        fi
    fi


    # Clean up old stuff
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Adding offical repo
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${distro}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
        echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
        https://download.docker.com/linux/${distro} \
        $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    #installing docker
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin



    #enabling and starting docker now.
    systemctl enable docker
    systemctl start docker

    #docker network setup
    docker network create "${DOCKER_NETWORK_NAME}" 2>/dev/null || true

    ok "Docker Installed: $(docker --version)"
    ok "Docker Compose Installed: $(docker compose version)"


}




# Now time for Portainer

setup_portainer(){
    spacer
    log " STEP 3/5: Setting up Portainer..."
    spacer

    local portainer_dir="${DATA_DIR}/portainer"
    mkdir -p "${portainer_dir}/data"

    docker stop portainer 2>/dev/null || true
    docker rm portainer 2>/dev/null || true

    docker run -d \
        --name=portainer \
        --restart=always \
        -p "${PORTAINER_PORT}:9000" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "${portainer_dir}/data:/data" \
        --network "${DOCKER_NETWORK_NAME}" \
        portainer/portainer-ce:latest
    
    ok "Portainer setup at http://localhost:${PORTAINER_PORT} or http://<server-ip>:${PORTAINER_PORT}"
}

# Nginx Proxy Manager

setup_npm(){
    spacer
    log "STEP 4/5: Setting up Nginx Proxy Manager..."
    spacer


    local npm_dir="${DATA_DIR}/nginx-proxy-manager"
    mkdir -p "${npm_dir}/data" "${npm_dir}/letsencrypt"


    cat > "${npm_dir}/docker-compose.yml" <<EOF
services:
    npm:
        image: jc21/nginx-proxy-manager:latest
        container_name: npm
        restart: always
        networks:
            - ${DOCKER_NETWORK_NAME}
        ports:
            - "${NPM_HTTP_PORT}:80"
            - "${NPM_HTTPS_PORT}:443"
            - "${NPM_ADMIN_PORT}:81"
        volumes:
            - ./data:/data
            - ./letsencrypt:/etc/letsencrypt
networks:
    ${DOCKER_NETWORK_NAME}:
        external: true
EOF



    #deployement
    cd "${npm_dir}"
    docker compose down 2>/dev/null || true
    docker compose up -d 

    ok "Nginx Proxy Manager is up and running"
    ok "Admin Panel: http://<server-ip>:${NPM_ADMIN_PORT}"
    ok "Default Credentials: admin@example.com / changeme"
}

# STEP 5/5 Cloudflared

setup_cloudflared(){
    spacer
    log "STEP 5/5: Setup Cloudflared..."
    spacer

    if [[ -z "$CLOUDFLARED_TOKEN" ]]; then
        warn "No CLOUDFLARED_TOKEN provided."
        echo ""
        echo "  To set up a Cloudflare Tunnel, you need a tunnel token from"
        echo "  the Cloudflare Zero Trust dashboard:"
        echo "    https://one.dash.cloudflare.com → Networks → Tunnels → Create"
        echo ""
        read -rp "$(echo -e "${YELLOW}[?]${NC} Enter your Cloudflare Tunnel token (or press Enter to skip): ")" CLOUDFLARED_TOKEN || true

        if [[ -z "$CLOUDFLARED_TOKEN" ]]; then
            warn "Skipping Cloudflared setup."
            return
        fi

    fi

    # initial cleanup
    docker stop cloudflared 2>/dev/null || true
    docker rm cloudflared 2>/dev/null || true

    docker run -d \
        --name=cloudflared \
        --restart=always \
        --network="${DOCKER_NETWORK_NAME}" \
        cloudflare/cloudflared:latest \
        tunnel --no-autoupdate run --token "${CLOUDFLARED_TOKEN}"

    ok "Cloudflared tunnel is setup."
}


# UFW SETUP

configure_firewall(){
    spacer
    log "Setting up UFW"
    spacer

    # Ask for SSH port
    echo ""
    echo -e "  ${BOLD}What SSH port is your server using?${NC}"
    echo -e "  ${YELLOW}Press Enter if you don't know (default: 22)${NC}"
    echo ""
    read -rp "$(echo -e "${CYAN}[?]${NC} SSH port [22]: ")" SSH_PORT || true
    SSH_PORT="${SSH_PORT:-22}"


    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
        err "Invalid SSH port. Using default port 22."
        SSH_PORT=22
    fi

    log "Using SSH port: ${SSH_PORT}"
 
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
 
    # SSH
    ufw allow "${SSH_PORT}/tcp" comment 'SSH'
 
    # Nginx Proxy Manager
    ufw allow "${NPM_HTTP_PORT}/tcp"  comment 'HTTP'
    ufw allow "${NPM_HTTPS_PORT}/tcp" comment 'HTTPS'
    ufw allow "${NPM_ADMIN_PORT}/tcp" comment 'NPM Admin'
 
    # Portainer
    ufw allow "${PORTAINER_PORT}/tcp" comment 'Portainer'
 
    ufw --force enable
    ok "Firewall configured and enabled"
}


# ──────────────────────────────────────────────────────────────────────────────
#  Summary
# ──────────────────────────────────────────────────────────────────────────────
print_summary() {
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')
 
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    Setup Complete!                          ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo -e "${GREEN}${BOLD}Services Running:${NC}"
    echo ""
    echo -e "  ${BOLD}Portainer${NC}          http://${server_ip}:${PORTAINER_PORT}"
    echo -e "  ${BOLD}NPM Admin${NC}          http://${server_ip}:${NPM_ADMIN_PORT}"
    echo -e "                     Login: admin@example.com / changeme"
    echo -e "  ${BOLD}HTTP${NC}               http://${server_ip}:${NPM_HTTP_PORT}"
    echo -e "  ${BOLD}HTTPS${NC}              https://${server_ip}:${NPM_HTTPS_PORT}"
    echo ""
 
    if docker ps --format '{{.Names}}' | grep -q cloudflared; then
        echo -e "  ${BOLD}Cloudflared${NC}        Running ✓"
    else
        echo -e "  ${BOLD}Cloudflared${NC}        ${YELLOW}Not configured${NC}"
    fi
 
    echo ""
    echo -e "${YELLOW}${BOLD}Next Steps:${NC}"
    echo "  1. Access Portainer and set your admin password"
    echo "  2. Log into NPM and change the default credentials"
    echo "  3. Configure your Cloudflare Tunnel routes (if applicable)"
    echo "  4. Set up your proxy hosts in NPM"
    echo ""
}
 
# ──────────────────────────────────────────────────────────────────────────────
#  Main
# ──────────────────────────────────────────────────────────────────────────────
main() {
    banner
    check_root
 
    log "Starting server setup..."
    log "Data directory: ${DATA_DIR}"
    echo ""
 
    if ! confirm "Proceed with full server setup?"; then
        warn "Setup cancelled."
        exit 0
    fi
 
    update_system
    install_docker
    setup_portainer
    setup_npm
    setup_cloudflared
    configure_firewall
    print_summary
}
 
main "$@"
 