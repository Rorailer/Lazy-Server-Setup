#!/usr/bin/env bash
## Stacked-box rendering for the TUI.
## Each step's prior selections are re-printed as styled gum boxes so the
## user can always see the full state above the current prompt.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "render.sh is a library and should be sourced, not executed."
    exit 1
fi


# ---- gum style wrappers ----
# all boxes look consistent: rounded border, padded.
_box(){
    local title="$1"
    shift
    # body comes from stdin
    # chip title — small box above the content box (matches Charm design)
    gum style \
        --border rounded \
        --border-foreground "${ACCENT_212:-212}" \
        --foreground "${ACCENT_212:-212}" \
        --padding "0 1" \
        --margin "0 0 1 0" \
        --bold \
        "${title}"
    # content box — 88 wide, neutral grey border
    gum style \
        --border rounded \
        --border-foreground "${ACCENT_240:-240}" \
        --width 88 \
        --padding "1 2" \
        --margin "0 0 1 0" \
        "$@"
}


# ---- Categories box ----
render_categories(){
    if [[ ${#SELECTED_CATEGORIES[@]} -eq 0 ]]; then
        return
    fi
    local lines=""
    local cat
    for cat in "${SELECTED_CATEGORIES[@]}"; do
        lines+="✓ ${cat}"$'\n'
    done
    _box "Categories" "${lines%$'\n'}"
}


# ---- Hardening selections box ----
render_hardening(){
    if [[ ${#HARDENING[@]} -eq 0 ]]; then
        return
    fi
    local lines=""
    [[ "${HARDENING[create_user]:-}" == "1" ]]    && lines+="✓ Create / update sudo user"$'\n'
    [[ "${HARDENING[ssh_key]:-}" == "1" ]]        && lines+="✓ Add SSH public key"$'\n'
    [[ "${HARDENING[disable_pw]:-}" == "1" ]]     && lines+="✓ Disable SSH password auth"$'\n'
    [[ "${HARDENING[deny_root]:-}" == "1" ]]      && lines+="✓ Deny SSH root login"$'\n'
    [[ "${HARDENING[setup_ufw]:-}" == "1" ]]      && lines+="✓ Setup UFW"$'\n'
    [[ "${HARDENING[setup_fail2ban]:-}" == "1" ]] && lines+="✓ Setup Fail2ban"$'\n'
    [[ "${HARDENING[create_swap]:-}" == "1" ]]    && lines+="✓ Create swap file"$'\n'
    [[ "${HARDENING[set_timezone]:-}" == "1" ]]   && lines+="✓ Set timezone"$'\n'
    [[ "${HARDENING[install_ntp]:-}" == "1" ]]    && lines+="✓ Install NTP"$'\n'
    if [[ -n "$lines" ]]; then
        _box "Server Hardening" "${lines%$'\n'}"
    fi
}


# ---- Hardening config details box ----
render_hardening_config(){
    local lines=""
    [[ -n "${HARDEN_USERNAME:-}" ]]   && lines+="User:     ${HARDEN_USERNAME} (${HARDEN_USER_MODE})"$'\n'
    [[ -n "${HARDEN_SSH_KEY:-}" ]]    && lines+="SSH key:  $(echo "${HARDEN_SSH_KEY}" | cut -c1-30)..."$'\n'
    [[ -n "${HARDEN_SWAP_SIZE:-}" ]]  && lines+="Swap:     ${HARDEN_SWAP_SIZE}"$'\n'
    [[ -n "${HARDEN_TIMEZONE:-}" ]]   && lines+="Timezone: ${HARDEN_TIMEZONE}"$'\n'
    if [[ "${HARDENING[setup_fail2ban]:-}" == "1" ]]; then
        lines+="Fail2ban: maxretry=${HARDEN_F2B_MAXRETRY:-5}, bantime=${HARDEN_F2B_BANTIME:-1h}, findtime=${HARDEN_F2B_FINDTIME:-10m}"$'\n'
        if [[ "${HARDEN_F2B_INCREMENT:-true}" == "true" ]]; then
            lines+="          repeat: x${HARDEN_F2B_FACTOR:-2}, max ${HARDEN_F2B_MAXTIME:-1w}"$'\n'
        fi
    fi
    if [[ -n "$lines" ]]; then
        _box "Hardening Config" "${lines%$'\n'}"
    fi
}


# ---- Docker container selections box ----
render_containers(){
    if [[ ${#SELECTED_CONTAINERS[@]} -eq 0 ]]; then
        return
    fi
    local lines=""
    local c
    for c in "${SELECTED_CONTAINERS[@]}"; do
        lines+="✓ ${c}"$'\n'
    done
    _box "Docker Containers" "${lines%$'\n'}"
}


# ---- Per-container config box ----
render_container_config(){
    local name="$1"
    local lines=""
    local k
    for k in "${!CONTAINER_CONFIG[@]}"; do
        if [[ "$k" == "${name}."* ]]; then
            local field="${k#${name}.}"
            local value="${CONTAINER_CONFIG[$k]}"
            # mask password fields
            if [[ "$field" == *"password"* || "$field" == *"key"* ]]; then
                value="••••••••"
            fi
            lines+="${field}: ${value}"$'\n'
        fi
    done
    if [[ -n "$lines" ]]; then
        _box "${name} Config" "${lines%$'\n'}"
    fi
}


# ---- Cloudflared box ----
render_cloudflared(){
    if [[ -z "${CLOUDFLARED_TOKEN:-}" ]]; then
        return
    fi
    _box "Cloudflared" "Tunnel token: ••••••••"
}


# ---- UFW ports box ----
render_ufw(){
    if [[ ${#UFW_PORTS[@]} -eq 0 ]]; then
        return
    fi
    local lines=""
    local p
    for p in "${UFW_PORTS[@]}"; do
        lines+="${p}"$'\n'
    done
    _box "UFW Allowed Ports" "${lines%$'\n'}"
}


# ---- redraw_state: clear and redraw all collected boxes ----
# called between steps so the user always sees the full picture above
# the next prompt.
redraw_state(){
    clear
    banner
    render_categories
    render_hardening
    render_hardening_config
    render_containers
    local c
    for c in "${SELECTED_CONTAINERS[@]:-}"; do
        [[ -n "$c" ]] && render_container_config "$c"
    done
    render_cloudflared
    render_ufw
}
