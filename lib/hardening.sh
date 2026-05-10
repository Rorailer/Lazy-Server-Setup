#!/usr/bin/env bash
## Server hardening functions.
## All the user / SSH / firewall / swap / timezone / NTP setup lives here.
## Adapted from the standard "harden a fresh VPS" recipe everyone has copy-pasted at least once.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "hardening.sh is a library and should be sourced, not executed."
    exit 1
fi


# ---- User account ----
# create a brand new sudo user. asks for a password interactively (adduser handles that).
add_user_account(){
    local username="$1"

    if id "$username" &>/dev/null; then
        warn "User '$username' already exists. Switching to update mode."
        update_user_account "$username"
        return
    fi

    log "Creating user '$username'..."
    adduser --disabled-password --gecos "" "$username"

    # set a password if provided non-interactively, otherwise leave locked (SSH key only)
    log "User created. Adding to sudo group..."
    usermod -aG sudo "$username"
    fine "User '$username' created and granted sudo."
}

# add an existing user to the sudo group. no-op if already a member.
update_user_account(){
    local username="$1"

    if ! id "$username" &>/dev/null; then
        err "User '$username' does not exist. Cannot update."
        exit 1
    fi

    if id -nG "$username" | grep -qw sudo; then
        fine "User '$username' is already in the sudo group."
        return
    fi

    log "Adding '$username' to sudo group..."
    usermod -aG sudo "$username"
    fine "User '$username' added to sudo."
}


# ---- Sudoers temporary NOPASSWD ----
# while the script runs we don't want to be prompted for the user's
# password every time we sudo. backup sudoers, add a temp NOPASSWD line.
# the cleanup trap will revert this on exit.
SUDOERS_BACKUP="/etc/sudoers.bak"

disable_sudo_password(){
    local username="$1"

    if [[ -f "$SUDOERS_BACKUP" ]]; then
        return
    fi

    cp /etc/sudoers "$SUDOERS_BACKUP"
    echo "${username} ALL=(ALL:ALL) NOPASSWD: ALL" >> /etc/sudoers
}

revert_sudoers(){
    if [[ -f "$SUDOERS_BACKUP" ]]; then
        mv "$SUDOERS_BACKUP" /etc/sudoers
    fi
}


# ---- SSH key ----
add_ssh_key(){
    local username="$1"
    local key="$2"
    local home="/home/$username"
    local sshdir="$home/.ssh"
    local authfile="$sshdir/authorized_keys"

    mkdir -p "$sshdir"
    chmod 700 "$sshdir"

    # only append if the key isn't already there
    if [[ -f "$authfile" ]] && grep -qF "$key" "$authfile"; then
        fine "SSH key already present for '$username'."
    else
        echo "$key" >> "$authfile"
        fine "SSH key added for '$username'."
    fi

    chmod 600 "$authfile"
    chown -R "${username}:${username}" "$sshdir"
}


# ---- SSH config ----
# disable password auth and root login. idempotent — safe to re-run.
change_ssh_config(){
    local cfg="/etc/ssh/sshd_config"
    local backup="/etc/ssh/sshd_config.bak.$(date +%s)"

    cp "$cfg" "$backup"
    log "Backed up sshd_config to $backup"

    # password auth off
    if grep -qE '^[#[:space:]]*PasswordAuthentication' "$cfg"; then
        sed -i 's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' "$cfg"
    else
        echo "PasswordAuthentication no" >> "$cfg"
    fi

    # root login off
    if grep -qE '^[#[:space:]]*PermitRootLogin' "$cfg"; then
        sed -i 's/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin no/' "$cfg"
    else
        echo "PermitRootLogin no" >> "$cfg"
    fi

    fine "sshd_config updated."
}


# ---- UFW base lockdown ----
# resets UFW to a known state, opens SSH only.
# additional service ports are added later by add_ufw_port().
setup_ufw(){
    log "Setting up UFW base lockdown..."
    if ! command -v ufw &>/dev/null; then
        apt-get install -y ufw >/dev/null 2>&1
    fi

    ufw --force reset >/dev/null
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow "${SSH_PORT:-22}/tcp" comment 'SSH' >/dev/null
    fine "UFW base rules applied (SSH on ${SSH_PORT:-22}/tcp)."
}

# add a port to ufw. accepts either "8080" (defaults to tcp) or "53/udp".
add_ufw_port(){
    local portproto="$1"
    local comment="${2:-}"

    # default to tcp if no protocol given
    if [[ "$portproto" != */* ]]; then
        portproto="${portproto}/tcp"
    fi

    if [[ -n "$comment" ]]; then
        ufw allow "${portproto}" comment "$comment" >/dev/null
    else
        ufw allow "${portproto}" >/dev/null
    fi
}

# enable ufw at the end. uses --force so it doesn't prompt.
enable_ufw(){
    ufw --force enable >/dev/null
    fine "UFW enabled."
}


# ---- Swap ----
# create a swap file sized to whatever HARDEN_SWAP_SIZE says (e.g. "2G").
# skips if a /swapfile already exists.
create_swap(){
    local size="${1:-2G}"

    if swapon --show | grep -q '/swapfile'; then
        fine "/swapfile already active. Skipping swap creation."
        return
    fi

    log "Creating ${size} swap file at /swapfile..."
    fallocate -l "$size" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$(swap_size_mb "$size")
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile

    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    fine "Swap file created and mounted."
}

# helper to convert "2G" -> 2048 (MB), used as fallback when fallocate fails
swap_size_mb(){
    local s="$1"
    local n="${s%[GgMm]}"
    local unit="${s: -1}"
    case "$unit" in
        G|g) echo $((n * 1024)) ;;
        M|m) echo "$n" ;;
        *)   echo $((s * 1024)) ;;
    esac
}

# tune swap behavior so it isn't aggressive
tune_swap(){
    local swappiness="${1:-10}"
    local cache_pressure="${2:-50}"

    sysctl -q -w vm.swappiness="$swappiness"
    sysctl -q -w vm.vfs_cache_pressure="$cache_pressure"

    # persist
    if ! grep -q '^vm.swappiness' /etc/sysctl.conf; then
        echo "vm.swappiness=${swappiness}" >> /etc/sysctl.conf
    fi
    if ! grep -q '^vm.vfs_cache_pressure' /etc/sysctl.conf; then
        echo "vm.vfs_cache_pressure=${cache_pressure}" >> /etc/sysctl.conf
    fi
    fine "Swap tuned (swappiness=${swappiness}, vfs_cache_pressure=${cache_pressure})."
}


# ---- Timezone ----
set_timezone(){
    local tz="$1"
    if ! timedatectl list-timezones | grep -qx "$tz"; then
        warn "Unknown timezone '$tz'. Defaulting to UTC."
        tz="UTC"
    fi
    timedatectl set-timezone "$tz"
    fine "Timezone set to $(cat /etc/timezone 2>/dev/null || echo "$tz")."
}


# ---- NTP ----
# uses systemd-timesyncd (default on modern Ubuntu/Debian).
configure_ntp(){
    log "Enabling NTP via systemd-timesyncd..."
    apt-get install -y systemd-timesyncd >/dev/null 2>&1 || true
    systemctl enable systemd-timesyncd >/dev/null 2>&1
    systemctl start systemd-timesyncd >/dev/null 2>&1
    timedatectl set-ntp true >/dev/null
    fine "NTP enabled."
}


# ---- Fail2ban ----
# installs fail2ban, writes a jail.local with custom limits, enables the sshd jail.
# repeat-offender escalation uses bantime.increment with a multiplier.
setup_fail2ban(){
    local maxretry="${1:-5}"
    local bantime="${2:-1h}"
    local findtime="${3:-10m}"
    local increment="${4:-true}"
    local factor="${5:-2}"
    local maxtime="${6:-1w}"

    log "Installing fail2ban..."
    apt-get install -y fail2ban >/dev/null 2>&1

    log "Writing /etc/fail2ban/jail.local..."
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
# how many failures within findtime trigger a ban
maxretry = ${maxretry}
# initial ban duration
bantime  = ${bantime}
# rolling window of time during which failures are counted
findtime = ${findtime}

# repeat offenders get progressively longer bans
bantime.increment = ${increment}
bantime.factor    = ${factor}
bantime.maxtime   = ${maxtime}

# default backend (systemd works on modern Ubuntu/Debian)
backend = systemd

# always allow loopback
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = ${SSH_PORT:-22}
EOF

    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban
    fine "Fail2ban configured. SSH jail active (maxretry=${maxretry}, bantime=${bantime})."
}
