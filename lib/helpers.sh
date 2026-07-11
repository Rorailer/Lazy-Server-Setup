#!/usr/bin/env bash
## Shared helpers for tui.sh
## Logging, banner, OS check, gum/docker bootstrap, and basic prompts.

# this file is meant to be sourced, not run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "helpers.sh is a library and should be sourced, not executed."
    exit 1
fi


# ---- COLORS ----
# loosely matches the Charm theme from the design: magenta accent, cyan info,
# green ok, yellow warn, red err. ANSI 256 codes are used by gum below for the
# box borders and chip titles.
BOLD='\033[1m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
MAGENTA='\033[38;5;212m'
DIM='\033[38;5;245m'
NC='\033[0m'

# gum --border-foreground accent codes (used by lib/render.sh)
ACCENT_212="212"   # Charm magenta — for chip titles, active prompts
ACCENT_240="240"   # neutral grey — for content boxes
ACCENT_GREEN="114"
ACCENT_RED="203"
ACCENT_YELLOW="222"

# where the install transcript gets saved
SETUP_LOG="${SETUP_LOG:-/tmp/setup-result.log}"


# ---- Logging helpers ----
# same prefixes as the rest of the user's scripts. consistency matters.
log(){
    echo -e "${BLUE}[INFO]${NC} $*" ;
}

fine(){
    echo -e "${GREEN}[ OK]${NC} $*" ;
}

err(){
    echo -e "${RED}[FAILED]${NC} $*" ;
}

warn(){
    echo -e "${YELLOW}[WARN]${NC} $*" ;
}

# 88-col banner with title + subtitle, double-line border.
# matches the design's Charm-direction banner (cyan border, magenta title).
# inner width is 86 chars so the box is exactly 88 wide including the borders.
banner(){
    local title="Server Setup Script (TUI)"
    local subtitle="Hardening + Docker services in one flow"
    # center 86-wide
    local title_pad title_padR
    title_pad=$(( (86 - ${#title}) / 2 ))
    title_padR=$(( 86 - ${#title} - title_pad ))
    local sub_pad sub_padR
    sub_pad=$(( (86 - ${#subtitle}) / 2 ))
    sub_padR=$(( 86 - ${#subtitle} - sub_pad ))

    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════════════════════════╗${NC}"
    printf '%b║%*s%b%s%b%*s║%b\n' "$CYAN" "$title_pad" "" "${MAGENTA}${BOLD}" "$title" "${NC}${CYAN}" "$title_padR" "" "$NC"
    echo -e "${CYAN}║                                                                                      ║${NC}"
    printf '%b║%*s%s%*s║%b\n' "$CYAN" "$sub_pad" "" "$subtitle" "$sub_padR" "" "$NC"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo
}

spacer(){
    echo -e "${CYAN}--------------------------------------------------------------${NC}";
}


# ---- Basic prompts (used before gum is available) ----
# input asks a question with a default. press enter to take the default.
input(){
    local question="$1"
    local default="$2"
    local answer
    read -rp "$(echo -e "${CYAN}[?]${NC} ${question} [${default}]: ")" answer
    echo "${answer:-$default}"
}

# yes/no prompt with a default. press enter = take the default
approve(){
    local msg="$1"
    local default="${2:-N}"
    read -rp "$(echo -e "${YELLOW}[??]${NC} ${msg} [y/N]: ")" choice
    choice="${choice:-$default}"
    [[ "$choice" == "y" || "$choice" == "Y" ]] && return 0 || return 1
}


# ---- Pre-flight checks ----

# bail if not Ubuntu/Debian
whichOS(){
    if [[ ! -f /etc/os-release ]]; then
        err "Cannot tell what OS this is (no /etc/os-release). Aborting."
        exit 1
    fi

    . /etc/os-release
    case "$ID" in
        ubuntu|debian)
            fine "Detected supported OS: $PRETTY_NAME"
            ;;
        *)
            err "Unsupported OS: $ID. Only Ubuntu and Debian are supported."
            exit 1
            ;;
    esac
}

# must run as root for hardening + docker install
require_root(){
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run with sudo (root privileges required)."
        exit 1
    fi
}


# ---- gum bootstrap ----
# install charm.sh's gum if not already on the system.
# uses the official charm apt repo so updates flow naturally.
ensure_gum(){
    if command -v gum &> /dev/null; then
        fine "gum is already installed: $(gum --version | head -n1)"
        return
    fi

    warn "gum (charm.sh TUI) is not installed."
    if ! approve "Install gum now? (uses the official charm.sh apt repo)"; then
        err "gum is required for the TUI. Aborting."
        exit 1
    fi

    log "Installing gum..."
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    chmod a+r /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
        > /etc/apt/sources.list.d/charm.list
    apt-get update -qq
    apt-get install -y gum

    fine "gum installed: $(gum --version | head -n1)"
}


# ---- Docker bootstrap ----
# only needed if user picked any docker containers
docker_exist(){
    if command -v docker &> /dev/null; then
        fine "Docker is already installed: $(docker --version)"
        return 0
    fi

    warn "Docker is not installed."
    if command -v gum &> /dev/null; then
        if ! gum confirm "Install Docker now? (uses the official get.docker.com script)"; then
            err "Docker is required to run the selected services. Aborting."
            exit 1
        fi
    elif ! approve "Install Docker now? (uses the official get.docker.com one-liner)" "Y"; then
        err "Docker is required to run the selected services. Aborting."
        exit 1
    fi

    log "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
    fine "Docker installed: $(docker --version)"
}


# ---- Misc ----
# get the first non-loopback IP, used in summary
server_ip(){
    hostname -I | awk '{print $1}'
}

# auto-detect total RAM in GB, capped at 4 (for swap default)
detect_ram_gb(){
    local mem_kb
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    local mem_gb=$(( (mem_kb + 1048575) / 1048576 ))
    if (( mem_gb > 4 )); then
        mem_gb=4
    fi
    if (( mem_gb < 1 )); then
        mem_gb=1
    fi
    echo "${mem_gb}"
}
