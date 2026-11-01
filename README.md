# Minimal 3x-ui — VLESS + WebSocket (security=none) one-click

One-shot installer for **xy l Minimal node mode** (same product as `64.81.26.148`):

- Latest **MHSanaei 3x-ui** panel (full stack: systemd service, SQLite, xray managed by panel)
- **Single inbound only**: VLESS + WebSocket, `security=none`, listen **443**, path `/`
- Random panel port + `webBasePath` + strong panel user/password
- Module01-style **BBR + FQ + 64MB** TCP buffers (if no `tcp_bbr`, still applies FQ + 64MB and continues)
- Opens firewall for **443** + panel port (ufw / firewalld / iptables; continues if none)
- **No domain, no TLS/REALITY/HY2, no nginx, no subscription :2096**

After success it prints:

1. Panel URL — `http://IP:PORT/basepath/`
2. Panel username
3. Panel password
4. One `vless://` link

Credentials are also saved to `/root/minimal-vless-ws-install.txt` (mode `600`).

## Requirements

- Root on a **fresh** (or partially prepared) VPS
- OS: Ubuntu / Debian / CentOS / Alma / Rocky / RHEL / Fedora / Amazon Linux
- Outbound HTTPS (GitHub + package mirrors)
- Port **443** free (script exits with a clear fix hint if busy)
- Cloud security group / provider firewall must allow **443** and the printed panel port

## One-command usage

Copy the script to the VPS, then:

```bash
# From your laptop (example)
scp -P <ssh_port> install-minimal-vless-ws.sh root@SERVER:/root/
ssh -p <ssh_port> root@SERVER 'bash /root/install-minimal-vless-ws.sh'
```

Or pipe from a URL you host:

```bash
curl -fsSL https://YOUR_HOST/install-minimal-vless-ws.sh | bash
```

`/workspace/tools/install-minimal-vless-ws.sh`

## Optional environment overrides

| Env | Meaning |
|-----|---------|
| `REMARK` | Inbound remark / `#fragment` in vless link (default: short hostname or IP tag) |
| `PANEL_PORT` | Fixed panel port (default: random 20000–62000) |
| `PANEL_USER` / `PANEL_PASS` | Fixed panel credentials (default: random) |
| `WEB_BASE_PATH` | Panel path without required slashes (default: random 16 hex) |
| `UUID` | Client UUID (default: `uuidgen` / python) |
| `SKIP_SYSCTL=1` | Skip BBR/FQ/buffer tuning |
| `FORCE=1` | Reinstall / reconfigure over an existing x-ui install |
| `XUI_ENABLE_FAIL2BAN=false` | Default in script; set `true` to let official installer set up fail2ban |

Example:

```bash
REMARK=zuno2 FORCE=1 bash install-minimal-vless-ws.sh
```

## What the final banner looks like

```
════════════════════════════════════════════════════════════
  Minimal 3x-ui 安装完成 / Install complete
════════════════════════════════════════════════════════════
Panel URL:      http://203.0.113.10:49987/cbad217368f7a5fd/
Username:       0d797407b5
Password:       y8FPZDHFMQRlwO
VLESS link:     vless://d8cd11ee-3f16-44c8-b22d-df29bf6f6f18@203.0.113.10:443?encryption=none&security=none&type=ws&path=%2F#zuno2
────────────────────────────────────────────────────────────
Saved (mode 600): /root/minimal-vless-ws-install.txt
Inbound: VLESS + WS security=none  path=/  port=443
Sysctl:  /etc/sysctl.d/99-vps-opt.conf (BBR if kernel supports; else FQ+64MB only)
云安全组 / Security group: allow TCP 443 + 49987
════════════════════════════════════════════════════════════
```

## Robustness notes

- Detects OS family and installs deps via `apt` / `dnf` / `yum` with retries
- Root + internet + `curl`/`tar`/`openssl` required; clear errors otherwise
- If `:443` is busy, prints the holder (`ss`/`lsof`) and exits non-zero — does not silently break
- If x-ui already installed: exits with instructions unless `FORCE=1`
- Uses official `install.sh` non-interactive env: `XUI_NONINTERACTIVE`, `XUI_USERNAME`, `XUI_PASSWORD`, `XUI_PANEL_PORT`, `XUI_WEB_BASE_PATH`, `XUI_SSL_MODE=none`, `XUI_DB_TYPE=sqlite`
- Creates inbound properly in panel DB (`inbounds` + `clients` + `client_inbounds` + `client_traffics`), then restarts x-ui and verifies listeners + local panel HTTP

## Caveats

- **CentOS 7 / kernel 3.10**: often no `tcp_bbr` — script skips BBR, still sets FQ + 64MB; does **not** abort
- Provider **security groups** are outside the guest OS; open 443 + panel port there too
- Panel is **HTTP** (no TLS) by design for Minimal mode — treat credentials as sensitive; prefer SSH tunnel or rotate often
- `FORCE=1` backs up `/etc/x-ui/x-ui.db` then re-runs official installer + rewrites Minimal inbound
- Do not run against a production Full-mode node unless you intend to replace it

## Files

- `install-minimal-vless-ws.sh` — installer (executable)
- `install-minimal-vless-ws.README.md` — this file
