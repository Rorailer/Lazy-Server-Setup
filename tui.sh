#!/usr/bin/env bash
## Server Setup Script — TUI mode
## A gum-based, accordion-style flow for hardening + Docker service install
## on Ubuntu / Debian. The lazy way to bootstrap a fresh server.
##
## Companion legacy version: setup.sh (kept for non-interactive use).

# fail loud, fail fast. nothing silent.
set -euo pipefail


# ---- locate ourselves ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# ---- source libs ----
# shellcheck source=lib/helpers.sh
source "${SCRIPT_DIR}/lib/helpers.sh"
# shellcheck source=lib/render.sh
source "${SCRIPT_DIR}/lib/render.sh"
# shellcheck source=lib/hardening.sh
source "${SCRIPT_DIR}/lib/hardening.sh"
# shellcheck source=lib/services.sh
source "${SCRIPT_DIR}/lib/services.sh"


# ---- state ----
# kept as globals on purpose. simpler than passing dicts around in bash.
declare -a SELECTED_CATEGORIES=()
declare -A HARDENING=()
declare HARDEN_USERNAME=""
declare HARDEN_USER_MODE="new"
declare HARDEN_SSH_KEY=""
declare HARDEN_SWAP_SIZE=""
declare HARDEN_TIMEZONE="Asia/Singapore"
declare HARDEN_F2B_MAXRETRY="5"
declare HARDEN_F2B_BANTIME="1h"
declare HARDEN_F2B_FINDTIME="10m"
declare HARDEN_F2B_INCREMENT="true"
declare HARDEN_F2B_FACTOR="2"
declare HARDEN_F2B_MAXTIME="1w"
declare -a SELECTED_CONTAINERS=()
declare -A CONTAINER_CONFIG=()
declare CLOUDFLARED_TOKEN=""
declare -a UFW_PORTS=()
declare -i SSH_PORT=22


# ---- cleanup trap ----
# revert any sudoers changes if we exit unexpectedly.
trap 'revert_sudoers' EXIT SIGHUP SIGINT SIGTERM


# ---- transcript log ----
# everything gets tee'd to /tmp/setup-result.log so the user can grep credentials
# or replay the install later. defensive: if we can't write the default (e.g.
# leftover from a previous run with different ownership) we fall back to an
# auto-generated path under /tmp.
mkdir -p "$(dirname "$SETUP_LOG")" 2>/dev/null || true
if ! ( : > "$SETUP_LOG" ) 2>/dev/null; then
    SETUP_LOG="$(mktemp -t setup-result.XXXXXX.log)"
fi
chmod 600 "$SETUP_LOG" 2>/dev/null || true


# ──────────────────────────────────────────────────────────────────────────────
#  Step counter (» step N of M · Phase  ▰▰▰▱▱▱▱)
# ──────────────────────────────────────────────────────────────────────────────
# called between phases so the user always knows where they are.
step_counter(){
    local current="$1"  # current phase name
    local n="$2"        # current step number
    local total="$3"    # total steps

    # progress bar: ▰ for done, ▱ for remaining
    local filled=$((n * 24 / total))
    local empty=$((24 - filled))
    local bar=""
    local i
    for ((i=0; i<filled; i++)); do bar+="▰"; done
    for ((i=0; i<empty; i++));  do bar+="▱"; done

    echo
    printf '%b» step %d of %d · %s%b   %b%s%b\n' \
        "$MAGENTA" "$n" "$total" "$current" "$NC" \
        "$DIM" "$bar" "$NC"
    echo
}


# ──────────────────────────────────────────────────────────────────────────────
#  Conflict detection (Pi-hole vs AdGuard, port collisions)
# ──────────────────────────────────────────────────────────────────────────────
# returns 0 if conflicts exist, populates global CONFLICT_LINES array.
declare -a CONFLICT_LINES=()
declare CONFLICT_HAS_ERROR=0

detect_conflicts(){
    CONFLICT_LINES=()
    CONFLICT_HAS_ERROR=0

    # Pi-hole + AdGuard mutex (both want port 53)
    local has_pihole=0 has_adguard=0
    local svc
    for svc in "${SELECTED_CONTAINERS[@]:-}"; do
        [[ "$svc" == "Pi-hole" ]]      && has_pihole=1
        [[ "$svc" == "AdGuard Home" ]] && has_adguard=1
    done
    if (( has_pihole == 1 && has_adguard == 1 )); then
        CONFLICT_LINES+=("✗ Pi-hole and AdGuard Home both bind port 53")
        CONFLICT_LINES+=("   Only one DNS resolver can hold port 53. Pick one.")
        CONFLICT_HAS_ERROR=1
    fi

    # duplicate port detection across selected containers
    declare -A port_to_svc=()
    for svc in "${SELECTED_CONTAINERS[@]:-}"; do
        local port=""
        case "$svc" in
            "Portainer")            port="${CONTAINER_CONFIG[Portainer.port]:-9000}" ;;
            "n8n")                  port="${CONTAINER_CONFIG[n8n.port]:-5678}" ;;
            "Uptime Kuma")          port="${CONTAINER_CONFIG[UptimeKuma.port]:-3001}" ;;
            "Vaultwarden")          port="${CONTAINER_CONFIG[Vaultwarden.port]:-8222}" ;;
            "Pi-hole")              port="${CONTAINER_CONFIG[Pihole.web_port]:-8053}" ;;
            "AdGuard Home")         port="${CONTAINER_CONFIG[AdGuard.web_port]:-8054}" ;;
            "Forgejo")              port="${CONTAINER_CONFIG[Forgejo.port]:-3123}" ;;
            "Homepage")             port="${CONTAINER_CONFIG[Homepage.port]:-3010}" ;;
            "Dockge")               port="${CONTAINER_CONFIG[Dockge.port]:-5001}" ;;
            "Memos")                port="${CONTAINER_CONFIG[Memos.port]:-5230}" ;;
        esac
        [[ -z "$port" ]] && continue
        if [[ -n "${port_to_svc[$port]:-}" ]]; then
            CONFLICT_LINES+=("! Port ${port}/tcp wanted by ${port_to_svc[$port]} and ${svc}")
            CONFLICT_LINES+=("   Both containers want :${port}. Change one.")
        else
            port_to_svc[$port]="$svc"
        fi
    done

    [[ ${#CONFLICT_LINES[@]} -gt 0 ]] && return 0 || return 1
}

render_conflict_alert(){
    [[ ${#CONFLICT_LINES[@]} -eq 0 ]] && return

    local body=""
    local line
    for line in "${CONFLICT_LINES[@]}"; do
        body+="${line}"$'\n'
    done

    gum style \
        --border rounded \
        --border-foreground "${ACCENT_YELLOW}" \
        --foreground "${ACCENT_YELLOW}" \
        --padding "0 1" \
        --margin "0 0 1 0" \
        --bold \
        "⚠  Conflicts detected"
    gum style \
        --border rounded \
        --border-foreground "${ACCENT_YELLOW}" \
        --width 88 \
        --padding "1 2" \
        --margin "0 0 1 0" \
        "${body%$'\n'}"
}


# ──────────────────────────────────────────────────────────────────────────────
#  Step functions
# ──────────────────────────────────────────────────────────────────────────────

# pick top-level categories
step_categories(){
    redraw_state
    local picks
    picks=$(gum choose --no-limit --header "What do you want to set up?" \
        "Server Hardening" \
        "Docker" \
        "Cloudflared")

    # convert newline-separated picks to array
    SELECTED_CATEGORIES=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && SELECTED_CATEGORIES+=("$line")
    done <<< "$picks"

    if [[ ${#SELECTED_CATEGORIES[@]} -eq 0 ]]; then
        err "Nothing selected. Exiting."
        exit 0
    fi
}

# was a given category selected?
_picked(){
    local target="$1"
    local cat
    for cat in "${SELECTED_CATEGORIES[@]}"; do
        [[ "$cat" == "$target" ]] && return 0
    done
    return 1
}


# ---- Hardening sub-flow ----
step_hardening_picks(){
    redraw_state
    local picks
    picks=$(gum choose --no-limit --header "Hardening steps to run:" \
        --selected "Create / update sudo user,Add SSH public key,Disable SSH password auth,Deny SSH root login,Setup UFW,Setup Fail2ban,Create swap file,Set timezone,Install NTP" \
        "Create / update sudo user" \
        "Add SSH public key" \
        "Disable SSH password auth" \
        "Deny SSH root login" \
        "Setup UFW" \
        "Setup Fail2ban" \
        "Create swap file" \
        "Set timezone" \
        "Install NTP")

    HARDENING=()
    while IFS= read -r line; do
        case "$line" in
            "Create / update sudo user")    HARDENING[create_user]=1 ;;
            "Add SSH public key")           HARDENING[ssh_key]=1 ;;
            "Disable SSH password auth")    HARDENING[disable_pw]=1 ;;
            "Deny SSH root login")          HARDENING[deny_root]=1 ;;
            "Setup UFW")                    HARDENING[setup_ufw]=1 ;;
            "Setup Fail2ban")               HARDENING[setup_fail2ban]=1 ;;
            "Create swap file")             HARDENING[create_swap]=1 ;;
            "Set timezone")                 HARDENING[set_timezone]=1 ;;
            "Install NTP")                  HARDENING[install_ntp]=1 ;;
        esac
    done <<< "$picks"
}

step_hardening_user(){
    [[ "${HARDENING[create_user]:-}" == "1" ]] || return 0

    redraw_state
    HARDEN_USERNAME=$(gum input --header "Sudo user name" --placeholder "myuser")
    if [[ -z "$HARDEN_USERNAME" ]]; then
        err "Username can't be empty."
        exit 1
    fi

    HARDEN_USER_MODE=$(gum choose --header "Create new or update existing?" "new" "update")
}

step_hardening_ssh_key(){
    [[ "${HARDENING[ssh_key]:-}" == "1" ]] || return 0

    redraw_state
    HARDEN_SSH_KEY=$(gum input --header "Paste your SSH public key" --width 100 \
        --placeholder "ssh-ed25519 AAAA...")

    # quick sanity check
    if [[ ! "$HARDEN_SSH_KEY" =~ ^(ssh-(rsa|ed25519|ecdsa)|ecdsa-sha2-) ]]; then
        warn "That doesn't look like a public key. Continuing anyway."
    fi
}

step_hardening_swap(){
    [[ "${HARDENING[create_swap]:-}" == "1" ]] || return 0

    redraw_state
    local default_size
    default_size="$(detect_ram_gb)G"
    HARDEN_SWAP_SIZE=$(gum input --header "Swap size (e.g. 2G, 4G)" \
        --value "$default_size" --placeholder "$default_size")
    HARDEN_SWAP_SIZE="${HARDEN_SWAP_SIZE:-$default_size}"
}

step_hardening_timezone(){
    [[ "${HARDENING[set_timezone]:-}" == "1" ]] || return 0

    redraw_state
    HARDEN_TIMEZONE=$(gum input --header "Timezone" \
        --value "Asia/Singapore" --placeholder "Asia/Singapore")
    HARDEN_TIMEZONE="${HARDEN_TIMEZONE:-Asia/Singapore}"
}

# fail2ban tuning. all fields have sensible defaults — press enter to accept.
step_hardening_fail2ban(){
    [[ "${HARDENING[setup_fail2ban]:-}" == "1" ]] || return 0

    redraw_state

    HARDEN_F2B_MAXRETRY=$(gum input \
        --header "Fail2ban: failed attempts before ban" \
        --value "5" --placeholder "5")
    HARDEN_F2B_MAXRETRY="${HARDEN_F2B_MAXRETRY:-5}"

    HARDEN_F2B_BANTIME=$(gum input \
        --header "Fail2ban: initial ban duration (e.g. 10m, 1h, 1d)" \
        --value "1h" --placeholder "1h")
    HARDEN_F2B_BANTIME="${HARDEN_F2B_BANTIME:-1h}"

    HARDEN_F2B_FINDTIME=$(gum input \
        --header "Fail2ban: window for counting failures (e.g. 5m, 10m, 1h)" \
        --value "10m" --placeholder "10m")
    HARDEN_F2B_FINDTIME="${HARDEN_F2B_FINDTIME:-10m}"

    HARDEN_F2B_INCREMENT=$(gum choose \
        --header "Fail2ban: progressively increase ban time for repeat offenders?" \
        "true" "false")
    HARDEN_F2B_INCREMENT="${HARDEN_F2B_INCREMENT:-true}"

    if [[ "$HARDEN_F2B_INCREMENT" == "true" ]]; then
        HARDEN_F2B_FACTOR=$(gum input \
            --header "Fail2ban: multiplier per repeat (2 = doubles each time)" \
            --value "2" --placeholder "2")
        HARDEN_F2B_FACTOR="${HARDEN_F2B_FACTOR:-2}"

        HARDEN_F2B_MAXTIME=$(gum input \
            --header "Fail2ban: cap on ban duration (e.g. 1d, 1w, 30d)" \
            --value "1w" --placeholder "1w")
        HARDEN_F2B_MAXTIME="${HARDEN_F2B_MAXTIME:-1w}"
    fi
}


# ---- Docker container sub-flow ----
step_pick_containers(){
    _picked "Docker" || return 0

    redraw_state
    local picks
    picks=$(gum choose --no-limit --header "Pick Docker containers to install:" \
        "Portainer" \
        "Nginx Proxy Manager" \
        "n8n" \
        "Uptime Kuma" \
        "Vaultwarden" \
        "Pi-hole" \
        "AdGuard Home" \
        "Wg-easy" \
        "Watchtower" \
        "Forgejo" \
        "Homepage" \
        "Dockge" \
        "Memos")

    SELECTED_CONTAINERS=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && SELECTED_CONTAINERS+=("$line")
    done <<< "$picks"
}

# helper: ask for a single port with a default
_ask_port(){
    local svc="$1"
    local key="$2"
    local label="$3"
    local default="$4"
    local v
    v=$(gum input --header "${svc}: ${label}" --value "$default" --placeholder "$default")
    CONTAINER_CONFIG[$key]="${v:-$default}"
}

# per-container config screens
step_configure_container(){
    local name="$1"
    redraw_state

    case "$name" in
        "Portainer")
            _ask_port "Portainer" "Portainer.port" "external port" "9000"
            ;;

        "Nginx Proxy Manager")
            _ask_port "NPM" "NPM.http_port"  "HTTP port"  "80"
            _ask_port "NPM" "NPM.https_port" "HTTPS port" "443"
            _ask_port "NPM" "NPM.admin_port" "Admin port" "81"
            ;;

        "n8n")
            _ask_port "n8n" "n8n.port" "external port" "5678"
            local tz
            tz=$(gum input --header "n8n: timezone" \
                --value "${HARDEN_TIMEZONE:-UTC}" \
                --placeholder "${HARDEN_TIMEZONE:-UTC}")
            CONTAINER_CONFIG[n8n.timezone]="${tz:-${HARDEN_TIMEZONE:-UTC}}"
            ;;

        "Uptime Kuma")
            _ask_port "Uptime Kuma" "UptimeKuma.port" "external port" "3001"
            ;;

        "Vaultwarden")
            _ask_port "Vaultwarden" "Vaultwarden.port" "external port" "8222"
            local domain
            domain=$(gum input --header "Vaultwarden: public DOMAIN URL (https://vault.example.com or http://ip:port)" \
                --placeholder "http://$(server_ip):8222")
            CONTAINER_CONFIG[Vaultwarden.domain]="${domain:-http://$(server_ip):8222}"
            local token
            token=$(gum input --header "Vaultwarden: ADMIN_TOKEN (blank to autogenerate)" --password)
            CONTAINER_CONFIG[Vaultwarden.admin_token]="${token:-$(openssl rand -hex 32)}"
            ;;

        "Pi-hole")
            _ask_port "Pi-hole" "Pihole.web_port" "web UI port" "8053"
            local tz
            tz=$(gum input --header "Pi-hole: timezone" \
                --value "${HARDEN_TIMEZONE:-UTC}" \
                --placeholder "${HARDEN_TIMEZONE:-UTC}")
            CONTAINER_CONFIG[Pihole.timezone]="${tz:-${HARDEN_TIMEZONE:-UTC}}"
            local pw
            pw=$(gum input --header "Pi-hole: web password (blank to autogenerate)" --password)
            CONTAINER_CONFIG[Pihole.password]="${pw:-$(openssl rand -hex 12)}"
            ;;

        "AdGuard Home")
            _ask_port "AdGuard Home" "AdGuard.setup_port" "initial setup port" "3030"
            _ask_port "AdGuard Home" "AdGuard.web_port" "post-setup web port" "8054"
            ;;

        "Wg-easy")
            local host
            host=$(gum input --header "Wg-easy: WG_HOST (public IP or domain clients connect to)" \
                --value "$(server_ip)" --placeholder "$(server_ip)")
            CONTAINER_CONFIG[WgEasy.host]="${host:-$(server_ip)}"
            _ask_port "Wg-easy" "WgEasy.vpn_port" "VPN port (UDP)" "51820"
            _ask_port "Wg-easy" "WgEasy.web_port" "web UI port (TCP)" "51821"
            local pw
            pw=$(gum input --header "Wg-easy: web password (blank to autogenerate)" --password)
            CONTAINER_CONFIG[WgEasy.password]="${pw:-}"
            ;;

        "Watchtower")
            local interval
            interval=$(gum input --header "Watchtower: poll interval (seconds)" \
                --value "86400" --placeholder "86400 = once per day")
            CONTAINER_CONFIG[Watchtower.poll_interval]="${interval:-86400}"
            local cleanup
            cleanup=$(gum choose --header "Watchtower: remove old images after update?" "true" "false")
            CONTAINER_CONFIG[Watchtower.cleanup]="${cleanup:-true}"
            ;;

        "Forgejo")
            _ask_port "Forgejo" "Forgejo.port" "external port" "3123"
            ;;

        "Homepage")
            _ask_port "Homepage" "Homepage.port" "external port" "3010"
            local hosts
            hosts=$(gum input --header "Homepage: HOMEPAGE_ALLOWED_HOSTS (comma-separated, blank = auto)" \
                --placeholder "localhost,$(server_ip):3010")
            CONTAINER_CONFIG[Homepage.allowed_hosts]="${hosts:-$(server_ip):3010}"
            ;;

        "Dockge")
            _ask_port "Dockge" "Dockge.port" "external port" "5001"
            local stacks
            stacks=$(gum input --header "Dockge: stacks directory" \
                --value "/opt/stacks" --placeholder "/opt/stacks")
            CONTAINER_CONFIG[Dockge.stacks_dir]="${stacks:-/opt/stacks}"
            ;;

        "Memos")
            _ask_port "Memos" "Memos.port" "external port" "5230"
            ;;
    esac
}


# ---- Cloudflared sub-flow ----
step_cloudflared(){
    _picked "Cloudflared" || return 0

    redraw_state
    CLOUDFLARED_TOKEN=$(gum input \
        --header "Cloudflare Tunnel token" \
        --password \
        --placeholder "paste from Zero Trust dashboard")
}


# ---- UFW dynamic ports ----
# Build the port list based on selections, mark "[recommended]" the ones
# that need to be exposed externally to function (DNS, VPN UDP, NPM 80/443, SSH).
# Pre-check only the recommended ones; everything else is shown but unchecked
# so the user can opt in (e.g. if they're not using NPM as a reverse proxy).
step_ufw_ports(){
    [[ "${HARDENING[setup_ufw]:-}" == "1" ]] || return 0

    redraw_state

    # ask for SSH port first so its label is accurate
    SSH_PORT=$(gum input --header "What SSH port is this server using?" \
        --value "22" --placeholder "22")
    SSH_PORT="${SSH_PORT:-22}"

    # we build two parallel arrays: options (labels) and recommended (which to pre-check)
    local options=()
    local recommended=()

    # helper to format a "recommended" tag — green ansi, gum passes through
    local rec_tag
    rec_tag=$'\033[38;5;114m[recommended]\033[0m'

    # SSH is always recommended
    local ssh_label="SSH (${SSH_PORT}/tcp) ${rec_tag}"
    options+=("$ssh_label")
    recommended+=("$ssh_label")

    local svc
    for svc in "${SELECTED_CONTAINERS[@]}"; do
        case "$svc" in
            "Portainer")
                options+=("Portainer (${CONTAINER_CONFIG[Portainer.port]:-9000}/tcp)")
                ;;
            "Nginx Proxy Manager")
                # HTTP + HTTPS are recommended (NPM needs to be reachable for it to be useful)
                local http="${CONTAINER_CONFIG[NPM.http_port]:-80}"
                local https="${CONTAINER_CONFIG[NPM.https_port]:-443}"
                local adm="${CONTAINER_CONFIG[NPM.admin_port]:-81}"
                local npm_http_label="NPM HTTP (${http}/tcp) ${rec_tag}"
                local npm_https_label="NPM HTTPS (${https}/tcp) ${rec_tag}"
                options+=("$npm_http_label");  recommended+=("$npm_http_label")
                options+=("$npm_https_label"); recommended+=("$npm_https_label")
                # admin port is not recommended for public exposure
                options+=("NPM Admin (${adm}/tcp)")
                ;;
            "n8n")
                options+=("n8n (${CONTAINER_CONFIG[n8n.port]:-5678}/tcp)")
                ;;
            "Uptime Kuma")
                options+=("Uptime Kuma (${CONTAINER_CONFIG[UptimeKuma.port]:-3001}/tcp)")
                ;;
            "Vaultwarden")
                options+=("Vaultwarden (${CONTAINER_CONFIG[Vaultwarden.port]:-8222}/tcp)")
                ;;
            "Pi-hole")
                local ph_t="Pi-hole DNS (53/tcp) ${rec_tag}"
                local ph_u="Pi-hole DNS (53/udp) ${rec_tag}"
                options+=("$ph_t"); recommended+=("$ph_t")
                options+=("$ph_u"); recommended+=("$ph_u")
                options+=("Pi-hole Web (${CONTAINER_CONFIG[Pihole.web_port]:-8053}/tcp)")
                ;;
            "AdGuard Home")
                local ag_t="AdGuard DNS (53/tcp) ${rec_tag}"
                local ag_u="AdGuard DNS (53/udp) ${rec_tag}"
                options+=("$ag_t"); recommended+=("$ag_t")
                options+=("$ag_u"); recommended+=("$ag_u")
                options+=("AdGuard Setup (${CONTAINER_CONFIG[AdGuard.setup_port]:-3030}/tcp)")
                options+=("AdGuard Web (${CONTAINER_CONFIG[AdGuard.web_port]:-8054}/tcp)")
                ;;
            "Wg-easy")
                local wgvpn="${CONTAINER_CONFIG[WgEasy.vpn_port]:-51820}"
                local wg_label="Wg-easy VPN (${wgvpn}/udp) ${rec_tag}"
                options+=("$wg_label"); recommended+=("$wg_label")
                options+=("Wg-easy Web (${CONTAINER_CONFIG[WgEasy.web_port]:-51821}/tcp)")
                ;;
            "Forgejo")
                options+=("Forgejo (${CONTAINER_CONFIG[Forgejo.port]:-3123}/tcp)")
                ;;
            "Homepage")
                options+=("Homepage (${CONTAINER_CONFIG[Homepage.port]:-3010}/tcp)")
                ;;
            "Dockge")
                options+=("Dockge (${CONTAINER_CONFIG[Dockge.port]:-5001}/tcp)")
                ;;
            "Memos")
                options+=("Memos (${CONTAINER_CONFIG[Memos.port]:-5230}/tcp)")
                ;;
        esac
    done

    # join recommended into csv for gum --selected
    local selected_csv
    selected_csv=$(IFS=,; echo "${recommended[*]}")

    local picks
    picks=$(gum choose --no-limit \
        --header "Ports to allow through UFW. [recommended] = needs to be public to work. Others sit behind a reverse proxy / VPN — open only if you're not using one." \
        --selected "$selected_csv" \
        "${options[@]}")

    UFW_PORTS=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # extract the "NNNN/proto" bit from "Label (NNNN/proto)..."
        local portproto="${line##*\(}"
        portproto="${portproto%%\)*}"
        UFW_PORTS+=("${line}|${portproto}")
    done <<< "$picks"
}


# ---- Abort screen (cancel-at-review) ----
# offers Back-to-review or Quit instead of an immediate exit.
abort_screen(){
    while true; do
        clear
        banner
        gum style --foreground "${ACCENT_YELLOW}" --bold "[WARN]    cancelled. nothing has been changed."
        echo

        gum style \
            --border rounded \
            --border-foreground "${ACCENT_YELLOW}" \
            --foreground "${ACCENT_YELLOW}" \
            --padding "0 1" \
            --margin "0 0 1 0" \
            --bold \
            "Now what?"
        gum style \
            --border rounded \
            --border-foreground "${ACCENT_240:-240}" \
            --width 88 \
            --padding "1 2" \
            --margin "0 0 1 0" \
            "$(printf 'we can take you back to review so you can edit picks,\nor quit and you can re-run sudo ./tui.sh whenever.')"

        local choice
        choice=$(gum choose --header "" "Back to review" "Quit")
        case "$choice" in
            "Back to review")  return 0 ;;
            "Quit"|*)
                gum style --foreground "${DIM}" "aborted — nothing changed."
                exit 0
                ;;
        esac
    done
}


# ---- Review screen ----
step_review(){
    redraw_state

    # detect conflicts and surface them above the review box
    detect_conflicts && render_conflict_alert

    local summary=""
    summary+="$(gum style --bold 'Hardening')"$'\n'
    if [[ ${#HARDENING[@]} -eq 0 ]]; then
        summary+="  (none selected)"$'\n'
    else
        [[ "${HARDENING[create_user]:-}" == "1" ]]    && summary+="  • User: ${HARDEN_USERNAME} (${HARDEN_USER_MODE}, sudo)"$'\n'
        [[ "${HARDENING[ssh_key]:-}" == "1" ]]        && summary+="  • SSH key: $(echo "$HARDEN_SSH_KEY" | cut -c1-40)..."$'\n'
        [[ "${HARDENING[disable_pw]:-}" == "1" ]]     && summary+="  • Disable SSH password auth"$'\n'
        [[ "${HARDENING[deny_root]:-}" == "1" ]]      && summary+="  • Deny SSH root login"$'\n'
        [[ "${HARDENING[setup_ufw]:-}" == "1" ]]      && summary+="  • UFW: ${#UFW_PORTS[@]} port(s)"$'\n'
        if [[ "${HARDENING[setup_fail2ban]:-}" == "1" ]]; then
            summary+="  • Fail2ban: maxretry=${HARDEN_F2B_MAXRETRY}, bantime=${HARDEN_F2B_BANTIME}, findtime=${HARDEN_F2B_FINDTIME}"$'\n'
            if [[ "$HARDEN_F2B_INCREMENT" == "true" ]]; then
                summary+="    repeat offenders: x${HARDEN_F2B_FACTOR}, max ${HARDEN_F2B_MAXTIME}"$'\n'
            fi
        fi
        [[ "${HARDENING[create_swap]:-}" == "1" ]]    && summary+="  • Swap: ${HARDEN_SWAP_SIZE}"$'\n'
        [[ "${HARDENING[set_timezone]:-}" == "1" ]]   && summary+="  • Timezone: ${HARDEN_TIMEZONE}"$'\n'
        [[ "${HARDENING[install_ntp]:-}" == "1" ]]    && summary+="  • Install NTP"$'\n'
    fi

    summary+=""$'\n'
    summary+="$(gum style --bold 'Docker Containers')"$'\n'
    if [[ ${#SELECTED_CONTAINERS[@]} -eq 0 ]]; then
        summary+="  (none selected)"$'\n'
    else
        local svc
        for svc in "${SELECTED_CONTAINERS[@]}"; do
            summary+="  • ${svc}"$'\n'
        done
    fi

    if [[ -n "${CLOUDFLARED_TOKEN:-}" ]]; then
        summary+=""$'\n'
        summary+="$(gum style --bold 'Cloudflared')"$'\n'
        summary+="  • Tunnel token: ••••••••"$'\n'
    fi

    gum style \
        --border thick \
        --border-foreground 212 \
        --padding "1 2" \
        --margin "1 0" \
        --bold \
        "Review Before Install"
    gum style \
        --border rounded \
        --border-foreground 240 \
        --padding "1 2" \
        --margin "0 0 1 0" \
        "${summary%$'\n'}"

    # if we have an error-severity conflict, force the user back to fix
    if (( CONFLICT_HAS_ERROR == 1 )); then
        gum style --foreground "${ACCENT_RED}" --bold \
            "[FAILED] error-severity conflicts detected. Go back and fix before installing."
        echo
        # offer abort / restart selection
        local choice
        choice=$(gum choose --header "Now what?" "Back to picks" "Quit")
        if [[ "$choice" == "Quit" ]]; then
            gum style --foreground "${DIM}" "aborted — nothing changed."
            exit 0
        fi
        # tell user how to resolve and exit since we don't have full back-step support
        gum style --foreground "${ACCENT_YELLOW}" \
            "Re-run sudo ./tui.sh and unpick one of the conflicting items at the Docker step."
        exit 1
    fi

    if ! gum confirm "Apply changes now?" --affirmative "Install" --negative "Cancel"; then
        # cancel-at-review goes to the abort screen, which can route back to review
        if abort_screen; then
            step_review  # recurse back into review (one level — gum confirm will re-prompt)
        fi
    fi
}


# ──────────────────────────────────────────────────────────────────────────────
#  Install phase
# ──────────────────────────────────────────────────────────────────────────────

run_hardening(){
    _picked "Server Hardening" || return 0

    if [[ "${HARDENING[create_user]:-}" == "1" ]]; then
        if [[ "$HARDEN_USER_MODE" == "new" ]]; then
            add_user_account "$HARDEN_USERNAME"
        else
            update_user_account "$HARDEN_USERNAME"
        fi
        disable_sudo_password "$HARDEN_USERNAME"
    fi

    if [[ "${HARDENING[ssh_key]:-}" == "1" && -n "$HARDEN_SSH_KEY" && -n "$HARDEN_USERNAME" ]]; then
        add_ssh_key "$HARDEN_USERNAME" "$HARDEN_SSH_KEY"
    fi

    if [[ "${HARDENING[disable_pw]:-}" == "1" || "${HARDENING[deny_root]:-}" == "1" ]]; then
        change_ssh_config
    fi

    if [[ "${HARDENING[setup_ufw]:-}" == "1" ]]; then
        setup_ufw
        local entry
        for entry in "${UFW_PORTS[@]}"; do
            local label="${entry%%|*}"
            local portproto="${entry##*|}"
            # SSH was already added by setup_ufw using SSH_PORT
            [[ "$label" == SSH* ]] && continue
            add_ufw_port "$portproto" "$label"
        done
        enable_ufw
    fi

    if [[ "${HARDENING[setup_fail2ban]:-}" == "1" ]]; then
        setup_fail2ban \
            "$HARDEN_F2B_MAXRETRY" \
            "$HARDEN_F2B_BANTIME" \
            "$HARDEN_F2B_FINDTIME" \
            "$HARDEN_F2B_INCREMENT" \
            "$HARDEN_F2B_FACTOR" \
            "$HARDEN_F2B_MAXTIME"
    fi

    if [[ "${HARDENING[create_swap]:-}" == "1" ]]; then
        create_swap "$HARDEN_SWAP_SIZE"
        tune_swap 10 50
    fi

    if [[ "${HARDENING[set_timezone]:-}" == "1" ]]; then
        set_timezone "$HARDEN_TIMEZONE"
    fi

    if [[ "${HARDENING[install_ntp]:-}" == "1" ]]; then
        configure_ntp
    fi

    # restart ssh at the end so all SSH changes take effect together
    if [[ "${HARDENING[disable_pw]:-}" == "1" || "${HARDENING[deny_root]:-}" == "1" ]]; then
        log "Restarting SSH service..."
        systemctl restart ssh 2>/dev/null || systemctl restart sshd
        fine "SSH restarted."
    fi
}

run_docker_install(){
    _picked "Docker" || return 0
    [[ ${#SELECTED_CONTAINERS[@]} -eq 0 ]] && return
    install_selected_services
}

run_cloudflared_only(){
    # cloudflared was selected but Docker wasn't — still need to launch its container
    _picked "Cloudflared" || return 0
    [[ -z "${CLOUDFLARED_TOKEN:-}" ]] && return

    # if Docker is also picked, install_selected_services already handled cloudflared
    _picked "Docker" && return

    install_cloudflared
}

# called during the SELECTION phase, before any output redirection. ensures
# Docker is installed up front so the install phase can run quietly.
ensure_docker_if_needed(){
    local need_docker=0
    if _picked "Docker" && [[ ${#SELECTED_CONTAINERS[@]} -gt 0 ]]; then
        need_docker=1
    fi
    if _picked "Cloudflared" && [[ -n "${CLOUDFLARED_TOKEN:-}" ]]; then
        need_docker=1
    fi
    if [[ $need_docker -eq 1 ]]; then
        docker_exist
    fi
}


# ──────────────────────────────────────────────────────────────────────────────
#  Final summary
# ──────────────────────────────────────────────────────────────────────────────
final_summary(){
    spacer
    log "All done."
    spacer

    echo
    fine "Server is set up."
    echo

    # build the "Quick Reference" box body
    local body=""
    if _picked "Server Hardening" && [[ "${HARDENING[create_user]:-}" == "1" ]]; then
        body+="• New sudo user: ${HARDEN_USERNAME}"$'\n'
        body+="  Login from another terminal:  ssh ${HARDEN_USERNAME}@$(server_ip)"$'\n'
    fi
    local svc
    for svc in "${SELECTED_CONTAINERS[@]:-}"; do
        case "$svc" in
            "Portainer")            body+="• Portainer:    http://$(server_ip):${CONTAINER_CONFIG[Portainer.port]:-9000}"$'\n' ;;
            "Nginx Proxy Manager")  body+="• NPM Admin:    http://$(server_ip):${CONTAINER_CONFIG[NPM.admin_port]:-81}"$'\n'
                                    body+="  Default login: admin@example.com / changeme (CHANGE IT)"$'\n' ;;
            "n8n")                  body+="• n8n:          http://$(server_ip):${CONTAINER_CONFIG[n8n.port]:-5678}"$'\n' ;;
            "Uptime Kuma")          body+="• Uptime Kuma:  http://$(server_ip):${CONTAINER_CONFIG[UptimeKuma.port]:-3001}"$'\n' ;;
            "Vaultwarden")          body+="• Vaultwarden:  ${CONTAINER_CONFIG[Vaultwarden.domain]:-http://$(server_ip):${CONTAINER_CONFIG[Vaultwarden.port]:-8222}}"$'\n' ;;
            "Pi-hole")              body+="• Pi-hole:      http://$(server_ip):${CONTAINER_CONFIG[Pihole.web_port]:-8053}/admin"$'\n' ;;
            "AdGuard Home")         body+="• AdGuard:      http://$(server_ip):${CONTAINER_CONFIG[AdGuard.setup_port]:-3030} (first run)"$'\n'
                                    body+="                http://$(server_ip):${CONTAINER_CONFIG[AdGuard.web_port]:-8054} (after setup)"$'\n' ;;
            "Wg-easy")              body+="• Wg-easy:      http://$(server_ip):${CONTAINER_CONFIG[WgEasy.web_port]:-51821}"$'\n' ;;
            "Watchtower")           body+="• Watchtower:   running (no UI)"$'\n' ;;
            "Forgejo")              body+="• Forgejo:      http://$(server_ip):${CONTAINER_CONFIG[Forgejo.port]:-3123}"$'\n' ;;
            "Homepage")             body+="• Homepage:     http://$(server_ip):${CONTAINER_CONFIG[Homepage.port]:-3010}"$'\n' ;;
            "Dockge")               body+="• Dockge:       http://$(server_ip):${CONTAINER_CONFIG[Dockge.port]:-5001}"$'\n' ;;
            "Memos")                body+="• Memos:        http://$(server_ip):${CONTAINER_CONFIG[Memos.port]:-5230}"$'\n' ;;
        esac
    done

    if [[ -n "${CLOUDFLARED_TOKEN:-}" ]]; then
        body+="• Cloudflared tunnel: running"$'\n'
    fi

    # render Quick Reference box (green accent, matches design)
    gum style \
        --border rounded \
        --border-foreground "${ACCENT_GREEN}" \
        --foreground "${ACCENT_GREEN}" \
        --padding "0 1" \
        --margin "0 0 1 0" \
        --bold \
        "Quick Reference"
    gum style \
        --border rounded \
        --border-foreground "${ACCENT_240:-240}" \
        --width 88 \
        --padding "1 2" \
        --margin "0 0 1 0" \
        "${body%$'\n'}"

    # warn about not closing the existing SSH session yet
    if [[ "${HARDENING[disable_pw]:-}" == "1" || "${HARDENING[deny_root]:-}" == "1" ]]; then
        warn "Don't close this session yet — verify your new SSH user works in a separate terminal first."
    fi
    log "Full transcript + credentials saved to ${SETUP_LOG} (root-only)"
    echo
    return 0
}



# ──────────────────────────────────────────────────────────────────────────────
#  Main
# ──────────────────────────────────────────────────────────────────────────────
main(){
    banner

    # pre-flight log lines (matches design's PreflightAuto)
    log "running pre-flight checks…"
    require_root
    whichOS
    ensure_gum
    fine "ready — let's set this thing up"
    sleep 0.4

    # ---- selection phase ----
    # step counter shown between phases for orientation
    step_counter "Categories" 1 5
    step_categories

    if _picked "Server Hardening"; then
        step_counter "Hardening" 2 5
        step_hardening_picks
        step_hardening_user
        step_hardening_ssh_key
        step_hardening_swap
        step_hardening_timezone
        step_hardening_fail2ban
    fi

    if _picked "Docker"; then
        step_counter "Docker" 3 5
        step_pick_containers
        local svc
        for svc in "${SELECTED_CONTAINERS[@]:-}"; do
            [[ -n "$svc" ]] && step_configure_container "$svc"
        done
    fi

    if _picked "Cloudflared"; then
        step_counter "Cloudflared" 4 5
        step_cloudflared
    fi

    # UFW box only shows if hardening's "Setup UFW" was checked
    step_ufw_ports

    # ---- review + go ----
    step_counter "Review" 5 5
    step_review

    # ensure docker is installed *before* the tee redirection.
    # this way the "Install Docker now?" prompt is visible to the user.
    ensure_docker_if_needed

    # ---- install phase ----
    spacer
    log "Starting install. Hold on tight."
    spacer

    # tee stdout/stderr to the transcript log without breaking set -e
    # (process substitution survives subshell exits cleanly)
    exec > >(tee -a "$SETUP_LOG") 2>&1
    {
        echo "=== install started: $(date) ==="
    } >> "$SETUP_LOG"

    run_hardening
    run_docker_install
    run_cloudflared_only

    final_summary
}

main "$@"
