#!/usr/bin/env bash
## Per-service install functions.
## Each function renders its compose template into a folder under DATA_DIR
## and brings the stack up. All idempotent — safe to re-run.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "services.sh is a library and should be sourced, not executed."
    exit 1
fi


# ---- defaults (env vars override) ----
: "${DATA_DIR:=/opt/server-stack}"
: "${DOCKER_NETWORK_NAME:=proxyNetwork}"

# image tags. user can override any of these via env before running tui.sh.
: "${PORTAINER_VERSION:=latest}"
: "${NPM_VERSION:=latest}"
: "${N8N_VERSION:=latest}"
: "${UPTIME_KUMA_VERSION:=2}"
: "${VAULTWARDEN_VERSION:=latest}"
: "${PIHOLE_VERSION:=latest}"
: "${ADGUARD_VERSION:=latest}"
: "${WG_EASY_VERSION:=latest}"
: "${WATCHTOWER_VERSION:=latest}"
: "${FORGEJO_VERSION:=14}"
: "${HOMEPAGE_VERSION:=latest}"
: "${DOCKGE_VERSION:=latest}"
: "${MEMOS_VERSION:=stable}"
: "${CLOUDFLARED_VERSION:=latest}"


# ---- shared docker network ----
ensure_docker_network(){
    if ! docker network inspect "${DOCKER_NETWORK_NAME}" &>/dev/null; then
        log "Creating docker network '${DOCKER_NETWORK_NAME}'..."
        docker network create "${DOCKER_NETWORK_NAME}" >/dev/null
    fi
}


# ---- generic render + up ----
# render a template into a service folder and bring it up.
_render_and_up(){
    local service_name="$1"
    local template="$2"
    local target_dir="${DATA_DIR}/${service_name}"

    if ! command -v docker &>/dev/null; then
        err "Docker is not installed. Cannot bring up ${service_name}."
        exit 1
    fi

    mkdir -p "${target_dir}"
    envsubst < "${SCRIPT_DIR}/templates/${template}" \
        > "${target_dir}/docker-compose.yaml"

    if ! ( cd "${target_dir}" && docker compose up -d ); then
        err "Failed to start ${service_name}. Check docker logs for details."
        exit 1
    fi
}


# ---- Portainer ----
install_portainer(){
    spacer
    log "Installing Portainer..."
    spacer

    export PORTAINER_VERSION
    export PORTAINER_PORT="${CONTAINER_CONFIG[Portainer.port]:-9000}"
    export DOCKER_NETWORK_NAME

    ensure_docker_network
    _render_and_up "portainer" "portainer.compose.yaml"

    fine "Portainer up at http://$(server_ip):${PORTAINER_PORT}"
}


# ---- Nginx Proxy Manager ----
install_npm(){
    spacer
    log "Installing Nginx Proxy Manager..."
    spacer

    export NPM_VERSION
    export NPM_HTTP_PORT="${CONTAINER_CONFIG[NPM.http_port]:-80}"
    export NPM_HTTPS_PORT="${CONTAINER_CONFIG[NPM.https_port]:-443}"
    export NPM_ADMIN_PORT="${CONTAINER_CONFIG[NPM.admin_port]:-81}"
    export DOCKER_NETWORK_NAME

    ensure_docker_network
    _render_and_up "nginx-proxy-manager" "npm.compose.yaml"

    fine "NPM admin at http://$(server_ip):${NPM_ADMIN_PORT}"
    fine "Default credentials: admin@example.com / changeme"
}


# ---- n8n ----
install_n8n(){
    spacer
    log "Installing n8n..."
    spacer

    export N8N_VERSION
    export N8N_PORT="${CONTAINER_CONFIG[n8n.port]:-5678}"
    export N8N_TIMEZONE="${CONTAINER_CONFIG[n8n.timezone]:-${HARDEN_TIMEZONE:-UTC}}"
    export N8N_ENCRYPTION_KEY="${CONTAINER_CONFIG[n8n.encryption_key]:-$(openssl rand -hex 16)}"
    export DOCKER_NETWORK_NAME

    ensure_docker_network
    _render_and_up "n8n" "n8n.compose.yaml"

    fine "n8n up at http://$(server_ip):${N8N_PORT}"
}


# ---- Uptime Kuma ----
install_uptime_kuma(){
    spacer
    log "Installing Uptime Kuma..."
    spacer

    export UPTIME_KUMA_VERSION
    export UPTIME_KUMA_PORT="${CONTAINER_CONFIG[UptimeKuma.port]:-3001}"
    export DOCKER_NETWORK_NAME

    ensure_docker_network
    _render_and_up "uptime-kuma" "uptime-kuma.compose.yaml"

    fine "Uptime Kuma up at http://$(server_ip):${UPTIME_KUMA_PORT}"
}


# ---- Vaultwarden ----
install_vaultwarden(){
    spacer
    log "Installing Vaultwarden..."
    spacer

    export VAULTWARDEN_VERSION
    export VAULTWARDEN_PORT="${CONTAINER_CONFIG[Vaultwarden.port]:-8222}"
    export VAULTWARDEN_DOMAIN="${CONTAINER_CONFIG[Vaultwarden.domain]:-http://$(server_ip):${VAULTWARDEN_PORT}}"
    export VAULTWARDEN_ADMIN_TOKEN="${CONTAINER_CONFIG[Vaultwarden.admin_token]:-$(openssl rand -hex 32)}"
    export DOCKER_NETWORK_NAME

    ensure_docker_network
    _render_and_up "vaultwarden" "vaultwarden.compose.yaml"

    fine "Vaultwarden up at ${VAULTWARDEN_DOMAIN}"
    fine "Admin panel: ${VAULTWARDEN_DOMAIN}/admin"
    fine "Admin token (save this): ${VAULTWARDEN_ADMIN_TOKEN}"
}


# ---- Pi-hole ----
install_pihole(){
    spacer
    log "Installing Pi-hole..."
    spacer

    export PIHOLE_VERSION
    export PIHOLE_WEB_PORT="${CONTAINER_CONFIG[Pihole.web_port]:-8053}"
    export PIHOLE_TIMEZONE="${CONTAINER_CONFIG[Pihole.timezone]:-${HARDEN_TIMEZONE:-UTC}}"
    export PIHOLE_PASSWORD="${CONTAINER_CONFIG[Pihole.password]:-$(openssl rand -hex 12)}"
    export DOCKER_NETWORK_NAME

    ensure_docker_network
    _render_and_up "pihole" "pihole.compose.yaml"

    fine "Pi-hole up at http://$(server_ip):${PIHOLE_WEB_PORT}/admin"
    fine "Web password (save this): ${PIHOLE_PASSWORD}"
    fine "DNS server: $(server_ip):53 — point your devices here for ad blocking."
}


# ---- AdGuard Home ----
install_adguardhome(){
    spacer
    log "Installing AdGuard Home..."
    spacer

    export ADGUARD_VERSION
    export ADGUARD_SETUP_PORT="${CONTAINER_CONFIG[AdGuard.setup_port]:-3030}"
    export ADGUARD_WEB_PORT="${CONTAINER_CONFIG[AdGuard.web_port]:-8054}"
    export DOCKER_NETWORK_NAME

    ensure_docker_network
    _render_and_up "adguardhome" "adguardhome.compose.yaml"

    fine "AdGuard Home initial setup at http://$(server_ip):${ADGUARD_SETUP_PORT}"
    fine "After first-run wizard, web UI moves to http://$(server_ip):${ADGUARD_WEB_PORT}"
    fine "DNS server: $(server_ip):53 — point your devices here for ad blocking."
}


# ---- Wg-easy ----
install_wg_easy(){
    spacer
    log "Installing Wg-easy..."
    spacer

    export WG_EASY_VERSION
    export WG_EASY_HOST="${CONTAINER_CONFIG[WgEasy.host]:-$(server_ip)}"
    export WG_EASY_VPN_PORT="${CONTAINER_CONFIG[WgEasy.vpn_port]:-51820}"
    export WG_EASY_WEB_PORT="${CONTAINER_CONFIG[WgEasy.web_port]:-51821}"
    local plain_password="${CONTAINER_CONFIG[WgEasy.password]:-}"

    if [[ -z "$plain_password" ]]; then
        plain_password="$(openssl rand -hex 16)"
        log "Generated wg-easy password: ${plain_password}"
    fi

    # generate bcrypt hash with the wg-easy image itself (it has the helper baked in).
    # need to escape $ in the hash for envsubst since we don't want it expanded.
    local raw_hash
    raw_hash="$(docker run --rm "ghcr.io/wg-easy/wg-easy:${WG_EASY_VERSION}" wgpw "${plain_password}" 2>/dev/null \
        | sed -n "s/^PASSWORD_HASH='\(.*\)'$/\1/p")"

    if [[ -z "$raw_hash" ]]; then
        warn "Could not generate password hash automatically. Setting plain PASSWORD instead."
        export WG_EASY_PASSWORD_HASH=""
        # we'll handle this case by patching the rendered compose below
    fi

    export WG_EASY_PASSWORD_HASH="${raw_hash//\$/\$\$}"
    export DOCKER_NETWORK_NAME

    ensure_docker_network
    _render_and_up "wg-easy" "wg-easy.compose.yaml"

    fine "Wg-easy web UI at http://$(server_ip):${WG_EASY_WEB_PORT}"
    fine "Web password (save this): ${plain_password}"
    fine "VPN endpoint: ${WG_EASY_HOST}:${WG_EASY_VPN_PORT}/udp"
}


# ---- Watchtower ----
install_watchtower(){
    spacer
    log "Installing Watchtower..."
    spacer

    export WATCHTOWER_VERSION
    export WATCHTOWER_CLEANUP="${CONTAINER_CONFIG[Watchtower.cleanup]:-true}"
    export WATCHTOWER_POLL_INTERVAL="${CONTAINER_CONFIG[Watchtower.poll_interval]:-86400}"
    export DOCKER_NETWORK_NAME

    ensure_docker_network
    _render_and_up "watchtower" "watchtower.compose.yaml"

    fine "Watchtower running. Polls every ${WATCHTOWER_POLL_INTERVAL}s."
}


# ---- Forgejo ----
install_forgejo(){
    spacer
    log "Installing Forgejo..."
    spacer

    export FORGEJO_VERSION
    export FORGEJO_PORT="${CONTAINER_CONFIG[Forgejo.port]:-3123}"
    export DOCKER_NETWORK_NAME

    ensure_docker_network
    _render_and_up "forgejo" "forgejo.compose.yaml"

    fine "Forgejo up at http://$(server_ip):${FORGEJO_PORT}"
    fine "Scroll to bottom of the setup page and create your admin account."
}


# ---- Homepage ----
install_homepage(){
    spacer
    log "Installing Homepage..."
    spacer

    export HOMEPAGE_VERSION
    export HOMEPAGE_PORT="${CONTAINER_CONFIG[Homepage.port]:-3010}"
    export HOMEPAGE_ALLOWED_HOSTS="${CONTAINER_CONFIG[Homepage.allowed_hosts]:-$(server_ip):${HOMEPAGE_PORT}}"
    export DOCKER_NETWORK_NAME

    ensure_docker_network
    _render_and_up "homepage" "homepage.compose.yaml"

    fine "Homepage up at http://$(server_ip):${HOMEPAGE_PORT}"
}


# ---- Dockge ----
install_dockge(){
    spacer
    log "Installing Dockge..."
    spacer

    export DOCKGE_VERSION
    export DOCKGE_PORT="${CONTAINER_CONFIG[Dockge.port]:-5001}"
    export DOCKGE_STACKS_DIR="${CONTAINER_CONFIG[Dockge.stacks_dir]:-/opt/stacks}"
    export DOCKER_NETWORK_NAME

    mkdir -p "${DOCKGE_STACKS_DIR}"

    ensure_docker_network
    _render_and_up "dockge" "dockge.compose.yaml"

    fine "Dockge up at http://$(server_ip):${DOCKGE_PORT}"
}


# ---- Memos ----
install_memos(){
    spacer
    log "Installing Memos..."
    spacer

    export MEMOS_VERSION
    export MEMOS_PORT="${CONTAINER_CONFIG[Memos.port]:-5230}"
    export DOCKER_NETWORK_NAME

    ensure_docker_network
    _render_and_up "memos" "memos.compose.yaml"

    fine "Memos up at http://$(server_ip):${MEMOS_PORT}"
}


# ---- Cloudflared ----
install_cloudflared(){
    spacer
    log "Setting up Cloudflared tunnel..."
    spacer

    if [[ -z "${CLOUDFLARED_TOKEN:-}" ]]; then
        warn "No Cloudflared token provided. Skipping."
        return
    fi

    export CLOUDFLARED_VERSION
    export CLOUDFLARED_TOKEN
    export DOCKER_NETWORK_NAME

    ensure_docker_network
    _render_and_up "cloudflared" "cloudflared.compose.yaml"

    fine "Cloudflared tunnel running."
}


# ---- dispatcher ----
# called from tui.sh after the user confirms install.
# walks SELECTED_CONTAINERS and runs the matching installer.
install_selected_services(){
    local svc
    for svc in "${SELECTED_CONTAINERS[@]:-}"; do
        case "$svc" in
            "Portainer")              install_portainer ;;
            "Nginx Proxy Manager")    install_npm ;;
            "n8n")                    install_n8n ;;
            "Uptime Kuma")            install_uptime_kuma ;;
            "Vaultwarden")            install_vaultwarden ;;
            "Pi-hole")                install_pihole ;;
            "AdGuard Home")           install_adguardhome ;;
            "Wg-easy")                install_wg_easy ;;
            "Watchtower")             install_watchtower ;;
            "Forgejo")                install_forgejo ;;
            "Homepage")               install_homepage ;;
            "Dockge")                 install_dockge ;;
            "Memos")                  install_memos ;;
            *) warn "Unknown service: $svc — skipping." ;;
        esac
    done

    if [[ -n "${CLOUDFLARED_TOKEN:-}" ]]; then
        install_cloudflared
    fi
}
