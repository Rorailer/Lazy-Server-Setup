# Server Setup TUI

A bash + `gum` TUI that bootstraps a fresh Ubuntu or Debian server. Hardens it (sudo user, SSH lockdown, swap, timezone, NTP, UFW, Fail2ban), then installs whichever Docker services you pick from a list of 13. One script, one interactive flow, no `.env` editing.

If you'd rather understand each piece manually, follow the [legacy linear script](./setup.sh). The TUI is just the lazy way.

---

## What it does

In order, when you run `sudo ./tui.sh`:

1. **Pre-flight** — checks you're on Ubuntu/Debian, that you have root, and installs `gum` if missing.
2. **Pick categories** — Server Hardening, Docker, Cloudflared (any combo).
3. **Hardening checklist** — 9 toggleable steps, all checked by default. Untick the ones you don't want.
4. **Per-step config** — username, SSH key paste, swap size, timezone, full Fail2ban tuning.
5. **Docker container picker** — type-to-search across 13 containers.
6. **Per-container config** — ports, passwords, paths, domains.
7. **Cloudflared token** — paste from the Zero Trust dashboard.
8. **UFW dynamic port list** — auto-built from your selections, with `[recommended]` tags pre-checked.
9. **Conflict check** — flags Pi-hole vs AdGuard collisions and duplicate ports before letting you install.
10. **Review screen** — full summary, one button to proceed or cancel.
11. **Install** — runs everything in the right order, tees a transcript to `/tmp/setup-result.log`.
12. **Quick Reference** — the URLs, credentials, and "verify SSH before you log out" warning.

---

## Quick start

```bash
git clone https://github.com/Rorailer/Server-Setup-TUI.git
cd Server-Setup-TUI
chmod +x tui.sh
sudo ./tui.sh
```

That's it. `gum` will be installed for you on first run.

Press **Enter** to accept any default. **Space** toggles checkboxes. **Tab** or arrows for confirm dialogs. Type to filter the container picker.

---

## What you can install

### Server hardening (9 toggleable steps)

| Step | What it does | Configurable |
|---|---|---|
| Create / update sudo user | Adds a new sudo user (or promotes an existing one) | Username, mode (new / update) |
| Add SSH public key | Drops your key into `~/.ssh/authorized_keys` | Paste the key |
| Disable SSH password auth | Sets `PasswordAuthentication no` | — |
| Deny SSH root login | Sets `PermitRootLogin no` | — |
| Setup UFW | Resets, opens SSH + selected service ports, enables | Dynamic port list |
| Setup Fail2ban | Installs, configures `jail.local`, enables sshd jail | maxretry, bantime, findtime, repeat-offender escalation |
| Create swap file | Allocates a swap file at `/swapfile` | Size (default = RAM, capped at 4GB) |
| Set timezone | `timedatectl set-timezone <tz>` | Timezone (default `Asia/Singapore`) |
| Install NTP | Enables `systemd-timesyncd` | — |

### Docker containers (13 to pick from)

| Container | What it is | Default port |
|---|---|---|
| **Portainer** | Docker management UI | 9000 |
| **Nginx Proxy Manager** | Reverse proxy + Let's Encrypt | 80 / 443 / 81 (admin) |
| **n8n** | Workflow automation | 5678 |
| **Uptime Kuma** | Self-hosted uptime monitoring | 3001 |
| **Vaultwarden** | Bitwarden-compatible password manager | 8222 |
| **Pi-hole** | DNS-level ad blocking | 53 + 8053 (web) |
| **AdGuard Home** | DNS-level ad blocking (Pi-hole alternative) | 53 + 8054 (web) |
| **Wg-easy** | Wireguard VPN with web UI | 51820/udp + 51821 (web) |
| **Watchtower** | Auto-updates other Docker containers | — |
| **Forgejo** | Self-hosted Git server (Gitea fork) | 3123 |
| **Homepage** | Service dashboard | 3010 |
| **Dockge** | Compose-stack-focused Portainer alternative | 5001 |
| **Memos** | Lightweight note-taking | 5230 |

### Cloudflared

Paste a tunnel token from the Cloudflare Zero Trust dashboard. The container will run with that token. Done.

---

## How the UFW step works

When you tick "Setup UFW" in the hardening checklist, you'll get a dynamic port list later in the flow. The list is built automatically from the containers you picked.

Ports tagged `[recommended]` are pre-checked because they **need** to be reachable for the service to function:

- **SSH** (always, on whatever port you specified)
- **NPM HTTP / HTTPS** (if NPM picked) — these are how Let's Encrypt and your reverse proxy actually work
- **Pi-hole / AdGuard DNS** (53 tcp + udp, if either picked) — DNS is useless if it can't be reached
- **Wg-easy VPN UDP** (if picked) — the entire point of the tunnel

Everything else (Portainer, Vaultwarden, n8n, the various web UIs) is shown but **unchecked by default**. The assumption is you'll put those behind NPM and only expose 80/443 to the internet. If you're not using a reverse proxy, manually check whichever ones you want exposed directly.

---

## Conflict detection

Before the review screen, the TUI checks for two kinds of conflicts:

1. **Pi-hole + AdGuard Home both picked** — both want to bind port 53. The TUI will block the install and tell you to pick one.
2. **Duplicate container ports** — if two containers want the same external port (e.g. you set Forgejo and Dockge both to 5001), you get a yellow warning. You can still proceed, but stuff will break.

If a hard conflict exists, you can't install until you re-run and fix it. Soft conflicts just warn you.

---

## Image version overrides

By default everything pulls `:latest`. If you want to pin a specific version, set the env var before running:

```bash
sudo IMMICH_VERSION=v1.118.0 N8N_VERSION=1.81.0 ./tui.sh
```

Available overrides:

```
PORTAINER_VERSION       NPM_VERSION             N8N_VERSION
UPTIME_KUMA_VERSION     VAULTWARDEN_VERSION     PIHOLE_VERSION
ADGUARD_VERSION         WG_EASY_VERSION         WATCHTOWER_VERSION
FORGEJO_VERSION         HOMEPAGE_VERSION        DOCKGE_VERSION
MEMOS_VERSION           CLOUDFLARED_VERSION
```

Plus:
- `DATA_DIR` — where service folders get created (default `/opt/server-stack`)
- `DOCKER_NETWORK_NAME` — shared docker network for all services (default `proxyNetwork`)

---

## After install

When the install finishes you'll see a "Quick Reference" box with all the URLs, default credentials, and a callout for the transcript log.

A few things worth doing **before you close your current session**:

1. **Verify SSH access in a new terminal first.** If you disabled password auth or root login and your key isn't working, you'll be locked out of an existing session. Open a second terminal and `ssh newuser@server` to make sure it works *before* you exit the first one.
2. **Open Portainer and set a strong admin password.** First-run password setup expires fast.
3. **Open NPM and change the default credentials** (`admin@example.com` / `changeme`). These are public knowledge.
4. **Set up your Cloudflare tunnel routes** in the Zero Trust dashboard if you used Cloudflared.
5. **Look at `/tmp/setup-result.log`** — full transcript including any auto-generated passwords (Vaultwarden ADMIN_TOKEN, Pi-hole web password, Wg-easy password). Copy them somewhere safe and then delete the file.

---

## Repository layout

```
Server-Setup-TUI/
├── tui.sh                    # main TUI entry point
├── setup.sh                  # legacy linear script (no TUI)
├── uninstall.sh              # legacy uninstall
├── lib/
│   ├── helpers.sh            # logging, OS check, gum + docker bootstrap
│   ├── render.sh             # stacked-box rendering helpers
│   ├── hardening.sh          # user/SSH/swap/timezone/NTP/UFW/fail2ban functions
│   └── services.sh           # per-service install functions
├── templates/
│   ├── portainer.compose.yaml
│   ├── npm.compose.yaml
│   ├── n8n.compose.yaml
│   ├── uptime-kuma.compose.yaml
│   ├── vaultwarden.compose.yaml
│   ├── pihole.compose.yaml
│   ├── adguardhome.compose.yaml
│   ├── wg-easy.compose.yaml
│   ├── watchtower.compose.yaml
│   ├── forgejo.compose.yaml
│   ├── homepage.compose.yaml
│   ├── dockge.compose.yaml
│   ├── memos.compose.yaml
│   └── cloudflared.compose.yaml
├── .env.example              # legacy mode config template
├── README.md                 # this file
└── LICENSE                   # MIT
```

Each container gets its own folder under `DATA_DIR` with a generated `docker-compose.yaml`. Backups are easy — just copy that folder.

---

## Troubleshooting

### gum failed to install

The script tries to install `gum` from the official charm.sh apt repo. If your VPS has weird DNS or a flaky connection, that can fail. Manual install:

```bash
mkdir -p /etc/apt/keyrings
curl -fsSL https://repo.charm.sh/apt/gpg.key | gpg --dearmor -o /etc/apt/keyrings/charm.gpg
echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" > /etc/apt/sources.list.d/charm.list
apt-get update && apt-get install -y gum
```

Then re-run `sudo ./tui.sh`.

### "Containers up but UI not reachable"

Check the obvious ones:

```bash
sudo ufw status                # is the port allowed?
docker ps                      # is the container actually up?
docker logs <container_name>   # what's it saying?
```

For NPM: Let's Encrypt won't work unless ports 80 and 443 are open externally. Check your VPS provider's firewall too — UFW only affects the host, not your provider's edge firewall.

### "I just locked myself out of SSH"

This is why we say "verify in a new terminal first". If it happened anyway:

1. Use your VPS provider's web console (Hetzner, DigitalOcean, Linode all have one).
2. Edit `/etc/ssh/sshd_config`, set `PasswordAuthentication yes` and `PermitRootLogin yes` temporarily.
3. `systemctl restart ssh`
4. Reconnect, fix your SSH key situation, lock it down again.

### "Pi-hole and AdGuard both want port 53"

Pick one. The TUI will catch this at the review screen and refuse to install until you re-run with only one selected.

### "I ran it twice and now containers are duplicated"

The TUI is mostly idempotent. If you re-run with the same picks and configs, `docker compose up -d` is a no-op for unchanged services. If you change a port or password, the container restarts with the new config. If something gets weird:

```bash
cd /opt/server-stack/<service>
sudo docker compose down -v
```

then re-run the TUI.

---

## What this does NOT do

- **No HTTPS or domain setup.** Everything runs on `http://your-ip:port` after install. To get clean URLs with HTTPS, set up Nginx Proxy Manager (it's one of the included containers) and add proxy hosts manually through its web UI.
- **No backups.** The `data/` folders inside each service folder under `DATA_DIR` are everything. Back them up however you like (rsync, restic, your favorite cron job).
- **No multi-server orchestration.** This is for bootstrapping a single VPS or homelab box.
- **No Windows or non-systemd Linux support.** Ubuntu/Debian only. The script will exit early on anything else.
- **No automatic updates.** Watchtower (one of the optional containers) handles that for you if you want it.

---

## Legacy mode (`setup.sh`)

If you want zero interactivity (cron-friendly, immutable installs, that kind of thing), the original linear script still works:

```bash
cp .env.example .env
# edit .env values
chmod +x setup.sh
sudo ./setup.sh
```

It runs Docker + Portainer + NPM + Cloudflared + UFW in one shot. No prompts, no flexibility. Just runs.

---

[My Site](https://rorailer.com)

## License

MIT — see [LICENSE](./LICENSE). Use it, fork it, ignore it, whatever.
