# Minimal 3x-ui — VLESS + WebSocket (security=none) one-click

One-shot installer for **xy l Minimal node mode**:

- Latest **MHSanaei 3x-ui** panel (full stack: systemd service, SQLite, xray managed by panel)
- **Single inbound only**: VLESS + WebSocket, `security=none`, listen **443**, path `/`
- Random panel port + `webBasePath` + strong panel user/password
- Module01-style **BBR + FQ + 64MB** TCP buffers — **only when the running kernel supports them** (live-verified; otherwise skipped, install continues)
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
- OS auto-detected from `/etc/os-release` (legacy CentOS: `/etc/centos-release`): **Ubuntu / Debian / CentOS (incl. 7) / Alma / Rocky / RHEL / Fedora / Amazon Linux**
- Outbound HTTPS to **GitHub** (install script + release assets) and package mirrors
- Port **443** free (script exits with a clear fix hint if busy)
- Cloud security group / provider firewall must allow **443** and the printed panel port

**No distro flag.** The same one-liner detects distro **and** version, picks `apt` / `dnf` / `yum`, and keeps existing Ubuntu/Debian behavior.

## One-command usage

```bash
curl -fsSL https://raw.githubusercontent.com/xyl0061-pixel/install-minimal-vless-ws/main/install-minimal-vless-ws.sh | bash
```

Or copy the script to the VPS:

```bash
scp -P <ssh_port> install-minimal-vless-ws.sh root@SERVER:/root/
ssh -p <ssh_port> root@SERVER 'bash /root/install-minimal-vless-ws.sh'
```

## Node alias (REMARK)

When the installer reaches **creating the VLESS inbound** (after the panel is up):

| Situation | Behavior |
|-----------|----------|
| `REMARK` env already set | Use it (no prompt). Good for automation / `REMARK=foo curl\|bash`. |
| Interactive TTY, `REMARK` unset | Prompt in Chinese: 请输入节点别名…; empty input → hostname default (and say so). |
| Non-TTY / pipe (`curl\|bash`), `REMARK` unset | Hostname default — **does not hang** waiting for input. Prints a one-line hint to set `REMARK=别名`. |

## Optional environment overrides

| Env | Meaning |
|-----|---------|
| `REMARK` | Inbound remark / `#fragment` in vless link. If unset: interactive prompt on TTY, else hostname. |
| `PANEL_PORT` | Fixed panel port (default: random 20000–62000) |
| `PANEL_USER` / `PANEL_PASS` | Fixed panel credentials (default: random) |
| `WEB_BASE_PATH` | Panel path without required slashes (default: random 16 hex) |
| `UUID` | Client UUID (default: `uuidgen` / python) |
| `SKIP_SYSCTL=1` | Skip BBR/FQ/buffer tuning |
| `FORCE=1` | Reinstall / reconfigure over an existing x-ui install |
| `XUI_ENABLE_FAIL2BAN=false` | Default in script; set `true` to let official installer set up fail2ban |

Examples:

```bash
bash install-minimal-vless-ws.sh
REMARK=zuno2 FORCE=1 bash install-minimal-vless-ws.sh
REMARK=zuno2 curl -fsSL https://raw.githubusercontent.com/xyl0061-pixel/install-minimal-vless-ws/main/install-minimal-vless-ws.sh | bash
```

## Robustness notes

- Detects OS family **and version**; installs deps via `apt` / `dnf` / `yum` with retries
- **CentOS 7 EOL yum**: if `mirrorlist.centos.org` is still referenced, switches base repos to official **`vault.centos.org`** (backed up under `/etc/yum.repos.d/bak-minimal-vless-ws/`)
- Pre-downloads the 3x-ui release tarball with **exponential backoff** (handles transient GitHub **HTTP 504**); injects a curl shim into the official `install.sh` so a prefetched archive is reused — **no third-party mirrors, no insecure TLS**
- Root + internet + `curl`/`tar`/`openssl` required; clear errors otherwise
- If `:443` is busy, prints the holder (`ss`/`lsof`) and exits non-zero
- If x-ui already installed: exits with instructions unless `FORCE=1`
- Uses official `install.sh` non-interactive env: `XUI_NONINTERACTIVE`, `XUI_USERNAME`, `XUI_PASSWORD`, `XUI_PANEL_PORT`, `XUI_WEB_BASE_PATH`, `XUI_SSL_MODE=none`, `XUI_DB_TYPE=sqlite`
- Creates inbound properly in panel DB, then restarts x-ui and verifies listeners + local panel HTTP
- Writes valid VLESS settings JSON including required `"decryption":"none"`

## BBR / FQ / 64MB (kernel capability ≠ distro ID)

| Layer | What the script does |
|-------|----------------------|
| OS detection | `/etc/os-release` (+ legacy CentOS release files) → package manager |
| Kernel probe | `modprobe tcp_bbr` / `sch_fq`, read `tcp_available_congestion_control` |
| Apply | Writes `/etc/sysctl.d/99-vps-opt.conf`, applies **key-by-key**; unsupported keys (e.g. `tcp_notsent_lowat` on 3.10) are skipped and **do not abort** |
| Report | Logs **BBR/FQ enabled only after live `sysctl -n` verification** |

- Stock **CentOS 7 / kernel 3.10**: usually **no `tcp_bbr`** — BBR skipped; FQ/64MB applied when the kernel accepts them
- Some CentOS 7 hosts ship a **custom newer kernel** with BBR — script enables it only if live verification succeeds
- **Never** auto-upgrades the kernel or reboots

## CentOS 7 / binary compatibility (verified artifacts)

Checked against **3x-ui v3.11.0** release `x-ui-linux-amd64.tar.gz`:

- Panel binary `x-ui` and bundled `xray-linux-amd64` are **statically linked** (`ldd`: not a dynamic executable) → **not blocked by CentOS 7 glibc 2.17**
- Host still needs working **CA certificates** and outbound TLS to GitHub (script best-effort `yum update ca-certificates`)
- Immediate failure mode seen in the field: GitHub release CDN **HTTP 504** while fetching the tarball (openssl already installed; version resolve succeeded). This installer retries/prefetches that download.

**Limits:** CentOS 7 is EOL. If package mirrors / vault / GitHub remain unreachable from the VPS, install cannot proceed without fixing network. This repo does **not** ship alternative binary mirrors.

## If download still fails (504)

1. Confirm the VPS can reach GitHub: `curl -I https://github.com` and `curl -IL https://github.com/MHSanaei/3x-ui/releases/latest`
2. Re-run (partial installs): `FORCE=1 bash install-minimal-vless-ws.sh`
3. If GitHub is blocked on the VPS network path, fix routing/DNS/proxy on the **server** (client Clash does not help a VPS install)

## Tests

Mock tests (no live package/service mutation):

```bash
bash tests/run-tests.sh
```

Coverage includes Ubuntu vs CentOS 7 detection expectations, BBR present/absent mocks, transient download 504→success, exhausted retries, and unsupported sysctl skip.

`bash -n install-minimal-vless-ws.sh` is expected clean. **No full CentOS 7 VM install was executed in CI/box** for this change — validate on a real CentOS 7 VPS after merge.

## Caveats

- Provider **security groups** are outside the guest OS; open 443 + panel port there too
- Panel is **HTTP** (no TLS) by design for Minimal mode — treat credentials as sensitive
- `FORCE=1` backs up `/etc/x-ui/x-ui.db` then re-runs official installer + rewrites Minimal inbound
- Do not run against a production Full-mode node unless you intend to replace it

## Files

- `install-minimal-vless-ws.sh` — installer (executable)
- `README.md` — this file
- `tests/run-tests.sh` — mock unit tests
