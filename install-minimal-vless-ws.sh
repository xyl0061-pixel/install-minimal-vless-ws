#!/usr/bin/env bash
# Minimal 3x-ui node: panel + single VLESS-WS (security=none) on :443
# Fixed: valid JSON settings with decryption=none for current xray-core.
# + firewall + Module01 BBR/FQ/64MB. Designed for fresh Ubuntu/Debian/CentOS-ish VPS.
#
# Usage (root):
#   curl -fsSL <url> | bash
#   # or
#   bash install-minimal-vless-ws.sh
#
# Optional env: REMARK PANEL_PORT PANEL_USER PANEL_PASS WEB_BASE_PATH UUID
#               SKIP_SYSCTL=1 FORCE=1 XUI_ENABLE_FAIL2BAN=false
# REMARK: if unset and stdin is a TTY, prompt when creating the VLESS inbound;
#         if unset and non-TTY (e.g. curl|bash), default to hostname (no hang).
set -euo pipefail

readonly SCRIPT_NAME="install-minimal-vless-ws"
readonly CRED_FILE="/root/minimal-vless-ws-install.txt"
readonly SYSCTL_FILE="/etc/sysctl.d/99-vps-opt.conf"
readonly XUI_DB="/etc/x-ui/x-ui.db"
readonly XUI_BIN="/usr/local/x-ui/x-ui"
readonly INBOUND_PORT=443
readonly WS_PATH="/"
readonly INSTALL_SH_URL="https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh"

red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; blue='\033[0;34m'; plain='\033[0m'

log()  { echo -e "${green}[${SCRIPT_NAME}]${plain} $*"; }
warn() { echo -e "${yellow}[${SCRIPT_NAME}] WARN:${plain} $*" >&2; }
err()  { echo -e "${red}[${SCRIPT_NAME}] ERROR:${plain} $*" >&2; }
die()  { err "$*"; exit 1; }

# ---------- helpers ----------
gen_alnum() {
  local n="${1:-16}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 $((n * 2)) 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c "$n"
  else
    tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "$n"
  fi
}

gen_hex() {
  local n="${1:-16}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex $(( (n + 1) / 2 )) 2>/dev/null | head -c "$n"
  else
    tr -dc 'a-f0-9' </dev/urandom | head -c "$n"
  fi
}

gen_uuid() {
  if [[ -n "${UUID:-}" ]]; then
    printf '%s' "$UUID"
    return
  fi
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import uuid; print(uuid.uuid4())'
    return
  fi
  # RFC4122-ish fallback
  local h
  h=$(gen_hex 32)
  printf '%s-%s-%s-%s-%s\n' "${h:0:8}" "${h:8:4}" "4${h:13:3}" "$(printf '%x' $((0x8 + RANDOM % 4)))${h:17:3}" "${h:20:12}"
}

now_ms() {
  # Prefer millisecond epoch; fall back to seconds*1000
  if date +%s%3N 2>/dev/null | grep -Eq '^[0-9]+$'; then
    date +%s%3N
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

detect_public_ip() {
  local ip="" url
  local urls=(
    "https://api4.ipify.org"
    "https://ipv4.icanhazip.com"
    "https://v4.api.ipinfo.io/ip"
    "https://4.ident.me"
  )
  for url in "${urls[@]}"; do
    ip=$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]"' || true)
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s' "$ip"
      return 0
    fi
  done
  # Local interface fallback (may be private)
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
  printf '%s' "${ip:-}"
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {found=1} END{exit !found}'
    return
  fi
  if command -v netstat >/dev/null 2>&1; then
    netstat -lnt 2>/dev/null | awk -v p=":${port} " '$4 ~ p {found=1} END{exit !found}'
    return
  fi
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    return
  fi
  return 1
}

who_holds_port() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -lntp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" || $4 ~ p" " {print; found=1} END{exit !found}' || true
  elif command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true
  else
    echo "(install ss/lsof to see process)"
  fi
}

pkg_retry() {
  # pkg_retry <desc> -- cmd...
  local desc="$1"; shift
  local attempt=1 max=3
  while true; do
    if "$@"; then
      return 0
    fi
    if (( attempt >= max )); then
      die "Failed after ${max} attempts: ${desc}"
    fi
    warn "${desc} failed (attempt ${attempt}/${max}); retrying in 3s..."
    sleep 3
    attempt=$((attempt + 1))
  done
}

# ---------- preflight ----------
require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Must run as root. Try: sudo bash $0"
}

detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-}"
    OS_VER="${VERSION_ID:-}"
    OS_LIKE="${ID_LIKE:-}"
  elif [[ -f /usr/lib/os-release ]]; then
    # shellcheck disable=SC1091
    source /usr/lib/os-release
    OS_ID="${ID:-}"
    OS_VER="${VERSION_ID:-}"
    OS_LIKE="${ID_LIKE:-}"
  else
    die "Unsupported OS: cannot read /etc/os-release. Need Ubuntu/Debian/CentOS/Alma/Rocky/RHEL."
  fi

  case "${OS_ID}" in
    ubuntu|debian|armbian)
      PKG_FAM="apt"
      ;;
    centos|rhel|almalinux|rocky|ol|fedora|amzn|virtuozzo)
      if command -v dnf >/dev/null 2>&1; then
        PKG_FAM="dnf"
      else
        PKG_FAM="yum"
      fi
      ;;
    *)
      # Tolerate ID_LIKE
      if [[ "${OS_LIKE}" == *debian* || "${OS_LIKE}" == *ubuntu* ]]; then
        PKG_FAM="apt"
      elif [[ "${OS_LIKE}" == *rhel* || "${OS_LIKE}" == *centos* || "${OS_LIKE}" == *fedora* ]]; then
        if command -v dnf >/dev/null 2>&1; then PKG_FAM="dnf"; else PKG_FAM="yum"; fi
      else
        die "Unsupported OS '${OS_ID}'. Supported: Ubuntu/Debian/CentOS/Alma/Rocky/RHEL/Fedora/Amazon Linux."
      fi
      ;;
  esac
  log "OS detected: ${OS_ID} ${OS_VER} (pkg=${PKG_FAM})"
}

check_internet() {
  local ok=0
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --connect-timeout 5 --max-time 10 -o /dev/null https://github.com >/dev/null 2>&1 && ok=1
    [[ $ok -eq 0 ]] && curl -fsS --connect-timeout 5 --max-time 10 -o /dev/null https://1.1.1.1 >/dev/null 2>&1 && ok=1
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=10 --spider https://github.com >/dev/null 2>&1 && ok=1
  else
    # Will install curl shortly; try raw TCP
    if (echo >/dev/tcp/1.1.1.1/443) >/dev/null 2>&1; then ok=1; fi
  fi
  [[ $ok -eq 1 ]] || die "No internet connectivity (need GitHub + package mirrors). Fix network/DNS and retry."
}

install_deps() {
  log "Installing dependencies (curl wget tar unzip socat openssl ca-certificates jq sqlite3 uuid-runtime)..."
  export DEBIAN_FRONTEND=noninteractive
  case "$PKG_FAM" in
    apt)
      pkg_retry "apt-get update" apt-get update -y
      pkg_retry "apt-get install" apt-get install -y -q \
        curl wget tar unzip socat openssl ca-certificates \
        jq sqlite3 uuid-runtime cron tzdata iproute2 \
        || pkg_retry "apt-get install (minimal)" apt-get install -y -q \
          curl wget tar unzip socat openssl ca-certificates jq sqlite3
      # uuid-runtime optional on some
      apt-get install -y -q uuid-runtime >/dev/null 2>&1 || true
      ;;
    dnf)
      pkg_retry "dnf makecache" dnf makecache -y
      pkg_retry "dnf install" dnf install -y -q \
        curl wget tar unzip socat openssl ca-certificates \
        jq sqlite cronie tzdata iproute \
        || pkg_retry "dnf install (minimal)" dnf install -y -q \
          curl wget tar unzip socat openssl ca-certificates
      dnf install -y -q util-linux >/dev/null 2>&1 || true
      # sqlite package name varies
      dnf install -y -q sqlite >/dev/null 2>&1 || dnf install -y -q sqlite3 >/dev/null 2>&1 || true
      ;;
    yum)
      pkg_retry "yum makecache" yum makecache -y
      pkg_retry "yum install" yum install -y \
        curl wget tar unzip socat openssl ca-certificates \
        cronie tzdata iproute
      yum install -y jq >/dev/null 2>&1 || true
      yum install -y sqlite >/dev/null 2>&1 || yum install -y sqlite3 >/dev/null 2>&1 || true
      yum install -y util-linux >/dev/null 2>&1 || true
      ;;
  esac

  command -v curl >/dev/null 2>&1 || die "curl missing after package install"
  command -v tar >/dev/null 2>&1 || die "tar missing after package install"
  command -v openssl >/dev/null 2>&1 || die "openssl missing after package install"
  if ! command -v sqlite3 >/dev/null 2>&1; then
    warn "sqlite3 CLI not found; will try python3 for DB writes"
    command -v python3 >/dev/null 2>&1 || die "Need sqlite3 or python3 to create inbound in 3x-ui DB"
  fi
}

check_port_443() {
  if port_in_use "$INBOUND_PORT"; then
    err "Port ${INBOUND_PORT} is already in use. Minimal mode requires free :${INBOUND_PORT}."
    err "Holder:"
    who_holds_port "$INBOUND_PORT" >&2 || true
    err "Fix: stop/remove whatever listens on ${INBOUND_PORT} (nginx/caddy/apache/old xray), then re-run."
    err "  ss -lntp | grep ':${INBOUND_PORT}'"
    exit 1
  fi
  log "Port ${INBOUND_PORT} is free"
}

# ---------- existing x-ui ----------
xui_installed() {
  [[ -x "$XUI_BIN" ]] || [[ -d /usr/local/x-ui ]] || systemctl list-unit-files 2>/dev/null | grep -q '^x-ui.service' \
    || [[ -f /etc/systemd/system/x-ui.service ]]
}

handle_existing() {
  if ! xui_installed; then
    return 0
  fi
  if [[ "${FORCE:-0}" != "1" ]]; then
    err "3x-ui / x-ui already present on this host."
    err "  - To wipe panel settings and reconfigure Minimal mode: FORCE=1 bash $0"
    err "  - Or uninstall first: x-ui uninstall   (then re-run this script)"
    err "Refusing to overwrite without FORCE=1."
    exit 1
  fi
  warn "FORCE=1 set: stopping x-ui and preparing reinstall/reconfigure..."
  systemctl stop x-ui 2>/dev/null || true
  pkill -f '/usr/local/x-ui/bin/xray-linux' 2>/dev/null || true
  # Backup DB if present
  if [[ -f "$XUI_DB" ]]; then
    local bak="${XUI_DB}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$XUI_DB" "$bak" 2>/dev/null || true
    warn "Backed up DB to ${bak}"
  fi
  # Drop leftover :443 inbound from a half-failed prior run
  if [[ -f "$XUI_DB" ]] && command -v sqlite3 >/dev/null 2>&1; then
    local old_ids oid
    old_ids=$(sqlite3 "$XUI_DB" "SELECT id FROM inbounds WHERE port=${INBOUND_PORT};" 2>/dev/null || true)
    for oid in $old_ids; do
      sqlite3 "$XUI_DB" "DELETE FROM client_inbounds WHERE inbound_id=${oid};" 2>/dev/null || true
      sqlite3 "$XUI_DB" "DELETE FROM client_traffics WHERE inbound_id=${oid};" 2>/dev/null || true
      sqlite3 "$XUI_DB" "DELETE FROM inbounds WHERE id=${oid};" 2>/dev/null || true
    done
    [[ -n "${old_ids:-}" ]] && warn "Removed leftover inbound(s) on :${INBOUND_PORT} (ids: ${old_ids})"
  fi
  # Strip broken VLESS from generated config so xray is not crash-looping during reinstall
  if [[ -f /usr/local/x-ui/bin/config.json ]]; then
    python3 - <<'PY' 2>/dev/null || true
import json
p = "/usr/local/x-ui/bin/config.json"
try:
    with open(p, encoding="utf-8") as f:
        c = json.load(f)
except Exception:
    raise SystemExit
c["inbounds"] = [
    ib for ib in (c.get("inbounds") or [])
    if ib.get("protocol") == "tunnel" or ib.get("tag") == "api"
]
with open(p, "w", encoding="utf-8") as f:
    json.dump(c, f, indent=2)
    f.write("\n")
PY
  fi
}

# ---------- sysctl Module01 ----------
apply_sysctl() {
  if [[ "${SKIP_SYSCTL:-0}" == "1" ]]; then
    warn "SKIP_SYSCTL=1 — skipping BBR/FQ/buffer tuning"
    return 0
  fi
  log "Applying Module01-style sysctl (FQ + 64MB buffers; BBR if available)..."

  local have_bbr=0
  if [[ -d /sys/module/tcp_bbr ]] || modprobe tcp_bbr 2>/dev/null; then
    have_bbr=1
  elif grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    have_bbr=1
  elif sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    have_bbr=1
  fi

  {
    echo "# Module 01: 64MB stack + BBR + FQ (written by ${SCRIPT_NAME})"
    echo "# Generated: $(date -Iseconds 2>/dev/null || date)"
    echo "net.core.default_qdisc = fq"
    if [[ $have_bbr -eq 1 ]]; then
      echo "net.ipv4.tcp_congestion_control = bbr"
    else
      echo "# net.ipv4.tcp_congestion_control = bbr  # skipped: tcp_bbr not available (old kernel?)"
    fi
    echo
    echo "net.core.rmem_max = 67108864"
    echo "net.core.wmem_max = 67108864"
    echo "net.core.rmem_default = 262144"
    echo "net.core.wmem_default = 262144"
    echo "net.ipv4.tcp_rmem = 4096 87380 67108864"
    echo "net.ipv4.tcp_wmem = 4096 65536 67108864"
    echo
    echo "net.ipv4.tcp_fastopen = 3"
    echo "net.ipv4.tcp_adv_win_scale = 1"
    echo "net.ipv4.tcp_slow_start_after_idle = 0"
    echo "net.ipv4.tcp_notsent_lowat = 131072"
    echo "net.ipv4.tcp_mtu_probing = 1"
    echo
    echo "net.core.somaxconn = 65535"
    echo "net.core.netdev_max_backlog = 131072"
    echo "net.ipv4.tcp_tw_reuse = 1"
    echo "net.ipv4.tcp_fin_timeout = 15"
  } > "$SYSCTL_FILE"

  if [[ $have_bbr -eq 0 ]]; then
    warn "Kernel has no tcp_bbr (common on CentOS 7 / 3.10). FQ + 64MB buffers still applied; BBR skipped (not aborting)."
  else
    log "BBR module available — enabled"
  fi

  sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || warn "sysctl apply returned non-zero; values written to ${SYSCTL_FILE}"

  # Best-effort set fq on default route iface
  if command -v tc >/dev/null 2>&1; then
    local iface
    iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    if [[ -n "${iface:-}" ]]; then
      tc qdisc replace dev "$iface" root fq 2>/dev/null || true
    fi
  fi
}

# ---------- firewall ----------
open_firewall() {
  local panel_port="$1"
  log "Opening firewall for ${INBOUND_PORT}/tcp and ${panel_port}/tcp..."

  local did=0
  if command -v ufw >/dev/null 2>&1; then
    # Only add rules; enable if already active or inactive with care
    ufw allow "${INBOUND_PORT}/tcp" comment 'minimal-vless-ws' >/dev/null 2>&1 || true
    ufw allow "${panel_port}/tcp" comment '3x-ui-panel' >/dev/null 2>&1 || true
    # Keep SSH if we can detect it
    local ssh_port
    # Prefer Status check
    if ufw status 2>/dev/null | grep -qi 'Status: active'; then
      log "ufw active — allowed ${INBOUND_PORT} and ${panel_port}"
    else
      warn "ufw present but inactive — rules added; not forcing ufw enable (avoids SSH lockout)."
    fi
    did=1
  fi

  if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${INBOUND_PORT}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${panel_port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    log "firewalld — allowed ${INBOUND_PORT} and ${panel_port}"
    did=1
  fi

  if [[ $did -eq 0 ]] && command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -p tcp --dport "$INBOUND_PORT" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p tcp --dport "$INBOUND_PORT" -j ACCEPT 2>/dev/null || true
    iptables -C INPUT -p tcp --dport "$panel_port" -j ACCEPT 2>/dev/null \
      || iptables -I INPUT -p tcp --dport "$panel_port" -j ACCEPT 2>/dev/null || true
    # Best-effort persist
    if command -v netfilter-persistent >/dev/null 2>&1; then
      netfilter-persistent save >/dev/null 2>&1 || true
    elif [[ -d /etc/sysconfig ]]; then
      service iptables save >/dev/null 2>&1 || true
    fi
    log "iptables — accepted ${INBOUND_PORT} and ${panel_port}"
    did=1
  fi

  if [[ $did -eq 0 ]]; then
    warn "No ufw/firewalld/iptables found — continuing. Ensure cloud security group allows ${INBOUND_PORT} and ${panel_port}."
  fi
}

# ---------- install 3x-ui ----------
install_3xui() {
  local panel_user="$1" panel_pass="$2" panel_port="$3" web_base="$4" server_ip="$5"

  log "Installing latest MHSanaei 3x-ui (non-interactive)..."
  local tmp
  tmp=$(mktemp)
  if ! curl -fsSL --retry 5 --retry-delay 2 --connect-timeout 15 --max-time 120 \
      -o "$tmp" "$INSTALL_SH_URL"; then
    rm -f "$tmp"
    die "Failed to download 3x-ui install.sh from GitHub. Check outbound HTTPS."
  fi

  # Strip leading/trailing slashes for setting; panel stores with slashes
  local wbp="${web_base#/}"
  wbp="${wbp%/}"

  export XUI_NONINTERACTIVE=1
  export XUI_USERNAME="$panel_user"
  export XUI_PASSWORD="$panel_pass"
  export XUI_PANEL_PORT="$panel_port"
  export XUI_WEB_BASE_PATH="$wbp"
  export XUI_SSL_MODE=none
  export XUI_DB_TYPE=sqlite
  export XUI_SERVER_IP="$server_ip"
  # Fail2ban is nice-to-have; do not abort install if it fails (official is non-fatal anyway)
  export XUI_ENABLE_FAIL2BAN="${XUI_ENABLE_FAIL2BAN:-false}"

  # Official install detects non-TTY; force via env too
  if ! bash "$tmp"; then
    rm -f "$tmp"
    die "3x-ui official install.sh failed. See messages above. Fix and re-run (FORCE=1 if partial)."
  fi
  rm -f "$tmp"

  # Wait for binary + service
  local i
  for i in $(seq 1 30); do
    if [[ -x "$XUI_BIN" ]] && systemctl is-active --quiet x-ui 2>/dev/null; then
      break
    fi
    sleep 1
  done
  [[ -x "$XUI_BIN" ]] || die "x-ui binary missing after install (${XUI_BIN})"
  systemctl enable x-ui >/dev/null 2>&1 || true
  systemctl restart x-ui >/dev/null 2>&1 || true
  sleep 2
  systemctl is-active --quiet x-ui || die "x-ui service failed to start. Check: journalctl -u x-ui -n 50"
  log "3x-ui installed and running"
}


# Guarantee VLESS "decryption":"none" in DB + bin/config.json.
# Current xray-core hard-requires it; missing field → exit 23 / no :443 bind.
ensure_vless_decryption() {
  local cfg="/usr/local/x-ui/bin/config.json"
  [[ -f "$XUI_DB" ]] || return 0

  python3 - "$XUI_DB" <<'PY' || warn "DB decryption repair skipped (python failed)"
import json, sqlite3, sys
db = sys.argv[1]
con = sqlite3.connect(db)
cur = con.cursor()
fixed = 0
for iid, settings in cur.execute("SELECT id, settings FROM inbounds WHERE protocol='vless'"):
    obj = None
    raw_ok = False
    if settings:
        try:
            obj = json.loads(settings)
            raw_ok = True
        except Exception:
            obj = None
    if not isinstance(obj, dict):
        obj = {"clients": [], "decryption": "none", "fallbacks": []}
        raw_ok = False
    if obj.get("decryption") != "none":
        obj["decryption"] = "none"
        raw_ok = False
    if not raw_ok or obj.get("decryption") != "none":
        cur.execute(
            "UPDATE inbounds SET settings=? WHERE id=?",
            (json.dumps(obj, separators=(",", ":")), iid),
        )
        fixed += 1
if fixed:
    con.commit()
    print(f"repaired {fixed} vless inbound settings row(s)")
else:
    print("vless inbound settings OK")
con.close()
PY

  if [[ -f "$cfg" ]]; then
    python3 - "$cfg" <<'PY' || warn "config.json decryption patch skipped"
import json, sys
p = sys.argv[1]
with open(p, encoding="utf-8") as f:
    c = json.load(f)
n = 0
for ib in c.get("inbounds") or []:
    if ib.get("protocol") == "vless":
        st = ib.setdefault("settings", {})
        if st.get("decryption") != "none":
            st["decryption"] = "none"
            n += 1
if n:
    with open(p, "w", encoding="utf-8") as f:
        json.dump(c, f, indent=2)
        f.write("\n")
    print(f"patched decryption on {n} config inbound(s)")
else:
    print("config.json vless decryption OK")
PY
  fi
}

# ---------- REMARK (node alias) ----------
default_remark_from_host() {
  local server_ip="$1" remark
  remark=$(hostname -s 2>/dev/null || true)
  [[ -n "$remark" && "$remark" != "localhost" ]] || remark="node-$(echo "$server_ip" | tr '.' '-')"
  remark=$(printf '%s' "$remark" | tr -cd 'A-Za-z0-9._-' | head -c 32)
  [[ -n "$remark" ]] || remark="vless-ws"
  printf '%s' "$remark"
}

# Strip whitespace/newlines; keep alnum, _-., and CJK; drop URI breakers.
sanitize_remark() {
  local raw="$1" out=""
  if command -v python3 >/dev/null 2>&1; then
    out=$(REMARK_RAW="$raw" python3 - <<'PY'
import os, re
s = os.environ.get("REMARK_RAW", "")
s = re.sub(r"\s+", "", s)
keep = []
for ch in s:
    o = ord(ch)
    if ch.isalnum() or ch in "._-":
        keep.append(ch)
    elif 0x4E00 <= o <= 0x9FFF or 0x3400 <= o <= 0x4DBF:  # CJK
        keep.append(ch)
    # else drop (# ? & % / \\ = + quotes, control, etc.)
print("".join(keep)[:64])
PY
) || out=""
  else
    out=$(printf '%s' "$raw" | tr -d '\r\n\t ' | tr -cd 'A-Za-z0-9._-' | head -c 64)
  fi
  printf '%s' "$out"
}

# Percent-encode fragment for vless://...#remark (safe for Chinese / odd chars).
urlencode_fragment() {
  local s="$1"
  if command -v python3 >/dev/null 2>&1; then
    FRAG_RAW="$s" python3 - <<'PY'
import os, urllib.parse
print(urllib.parse.quote(os.environ.get("FRAG_RAW", ""), safe="-_.~"))
PY
    return
  fi
  printf '%s' "$s"
}

# Resolve REMARK just before creating the VLESS inbound.
# Sets caller's variable via printf -v (arg2, default: remark) so log lines stay on stdout.
# - REMARK env set  -> use it (automation / curl|bash with env)
# - TTY + unset     -> interactive Chinese prompt
# - non-TTY + unset -> hostname default (never hang on pipe)
resolve_remark() {
  local server_ip="$1"
  local __var="${2:-remark}"
  # Use __r (not remark) so printf -v can set caller's local remark via dynamic scope
  local __r="" def
  def=$(default_remark_from_host "$server_ip")

  if [[ -n "${REMARK:-}" ]]; then
    __r=$(sanitize_remark "$REMARK")
    if [[ -z "$__r" ]]; then
      __r="$def"
      warn "REMARK env sanitized to empty; falling back to hostname: ${__r}"
    else
      log "Using REMARK from environment: ${__r}"
    fi
    printf -v "$__var" '%s' "$__r"
    return
  fi

  if [[ -t 0 ]]; then
    echo
    echo -e "${blue}请输入节点别名（remark，将出现在 vless 链接 # 后面）${plain}"
    echo -e "${yellow}直接回车则使用主机名默认: ${def}${plain}"
    printf '%s' "别名: "
    # Prefer /dev/tty so prompt still works if stdin was redirected oddly
    if [[ -r /dev/tty ]]; then
      read -r __r </dev/tty || __r=""
    else
      read -r __r || __r=""
    fi
    __r=$(sanitize_remark "${__r:-}")
    if [[ -z "$__r" ]]; then
      __r="$def"
      log "未输入别名，使用主机名默认: ${__r}"
    else
      log "节点别名 REMARK=${__r}"
    fi
  else
    __r="$def"
    log "非交互安装（stdin 非 TTY），使用主机名作为 REMARK=${__r}"
    log "提示: 可设置 REMARK=别名 覆盖，例如: REMARK=myserver bash install-minimal-vless-ws.sh"
  fi
  printf -v "$__var" '%s' "$__r"
}

# ---------- inbound via SQLite ----------
sql_exec() {
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$XUI_DB" "$@"
  else
    python3 - "$XUI_DB" "$@" <<'PY'
import sqlite3, sys
db = sys.argv[1]
sql = sys.argv[2]
con = sqlite3.connect(db)
try:
    cur = con.execute(sql)
    con.commit()
    rows = cur.fetchall()
    for r in rows:
        print("|".join("" if x is None else str(x) for x in r))
finally:
    con.close()
PY
  fi
}

create_vless_inbound() {
  local uuid="$1" remark="$2" email_tag="$3"
  log "Creating single VLESS + WebSocket inbound (security=none, port ${INBOUND_PORT}, path ${WS_PATH})..."

  [[ -f "$XUI_DB" ]] || die "DB not found: ${XUI_DB}"

  systemctl stop x-ui 2>/dev/null || true
  sleep 1

  local ts sub_id
  ts=$(now_ms)
  sub_id=$(gen_hex 16)

  # Build VLESS settings JSON safely.
  # BUGFIX: previous `printf '%s' "{"clients":...}"` let bash eat every double-quote,
  # storing invalid JSON in SQLite. 3x-ui then regenerated config.json WITHOUT
  # "decryption":"none", and current xray-core aborted with exit status 23.
  local settings stream sniffing
  if command -v jq >/dev/null 2>&1; then
    settings=$(jq -nc \
      --arg id "$uuid" \
      --arg email "$email_tag" \
      --arg sub "$sub_id" \
      --argjson ts "$ts" \
      '{clients:[{id:$id,security:"",email:$email,limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:0,subId:$sub,comment:"",reset:0,resetDay:0,resetWeekday:0,resetMax:0,created_at:$ts,updated_at:$ts}],decryption:"none",fallbacks:[]}')
  else
    settings=$(python3 -c 'import json,sys; u,e,s,t=sys.argv[1:5]; print(json.dumps({"clients":[{"id":u,"security":"","email":e,"limitIp":0,"totalGB":0,"expiryTime":0,"enable":True,"tgId":0,"subId":s,"comment":"","reset":0,"resetDay":0,"resetWeekday":0,"resetMax":0,"created_at":int(t),"updated_at":int(t)}],"decryption":"none","fallbacks":[]},separators=(",",":")))' \
      "$uuid" "$email_tag" "$sub_id" "$ts")
  fi
  if command -v jq >/dev/null 2>&1; then
    echo "$settings" | jq -e '.decryption=="none" and (.clients|type=="array")' >/dev/null \
      || die "Internal error: VLESS settings JSON invalid or missing decryption=none"
  else
    python3 -c 'import json,sys; j=json.loads(sys.argv[1]); assert j.get("decryption")=="none" and isinstance(j.get("clients"),list)' "$settings" \
      || die "Internal error: VLESS settings JSON invalid or missing decryption=none"
  fi
  stream='{"network":"ws","security":"none","externalProxy":[],"wsSettings":{"acceptProxyProtocol":false,"path":"/","host":"","headers":{}}}'
  sniffing='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'

  # Remove any existing :443 vless inbound (FORCE / re-run)
  if command -v sqlite3 >/dev/null 2>&1; then
    # Delete related rows for port 443 inbounds
    local old_ids
    old_ids=$(sqlite3 "$XUI_DB" "SELECT id FROM inbounds WHERE port=${INBOUND_PORT};" 2>/dev/null || true)
    local oid
    for oid in $old_ids; do
      sqlite3 "$XUI_DB" "DELETE FROM client_inbounds WHERE inbound_id=${oid};" 2>/dev/null || true
      sqlite3 "$XUI_DB" "DELETE FROM client_traffics WHERE inbound_id=${oid};" 2>/dev/null || true
      sqlite3 "$XUI_DB" "DELETE FROM inbounds WHERE id=${oid};" 2>/dev/null || true
    done
    # Remove client with same email if present
    local old_cids
    old_cids=$(sqlite3 "$XUI_DB" "SELECT id FROM clients WHERE email='${email_tag}';" 2>/dev/null || true)
    for oid in $old_cids; do
      sqlite3 "$XUI_DB" "DELETE FROM client_inbounds WHERE client_id=${oid};" 2>/dev/null || true
      sqlite3 "$XUI_DB" "DELETE FROM clients WHERE id=${oid};" 2>/dev/null || true
    done
    # Also remove by uuid
    old_cids=$(sqlite3 "$XUI_DB" "SELECT id FROM clients WHERE uuid='${uuid}';" 2>/dev/null || true)
    for oid in $old_cids; do
      sqlite3 "$XUI_DB" "DELETE FROM client_inbounds WHERE client_id=${oid};" 2>/dev/null || true
      sqlite3 "$XUI_DB" "DELETE FROM clients WHERE id=${oid};" 2>/dev/null || true
    done

    # Insert client
    sqlite3 "$XUI_DB" <<SQL
INSERT INTO clients (
  email, sub_id, uuid, password, auth, flow, security, reverse,
  limit_ip, limit_hwid, total_gb, expiry_time, enable, tg_id,
  comment, reset, reset_day, reset_weekday, reset_max,
  traffic_reset, traffic_reset_day, created_at, updated_at, sync_orphaned_at
) VALUES (
  '${email_tag}', '${sub_id}', '${uuid}', '', '', '', '', '',
  0, 0, 0, 0, 1, 0,
  '', 0, 0, 0, 0,
  'never', 1, ${ts}, ${ts}, 0
);
SQL
    local client_id
    client_id=$(sqlite3 "$XUI_DB" "SELECT id FROM clients WHERE email='${email_tag}' ORDER BY id DESC LIMIT 1;")
    [[ -n "$client_id" ]] || die "Failed to insert clients row"

    # Insert inbound — columns match modern 3x-ui (no allocate)
    # Escape single quotes in JSON for SQL
    local settings_sql stream_sql sniffing_sql
    settings_sql=${settings//\'/\'\'}
    stream_sql=${stream//\'/\'\'}
    sniffing_sql=${sniffing//\'/\'\'}

    sqlite3 "$XUI_DB" <<SQL
INSERT INTO inbounds (
  user_id, up, down, total, remark, enable, expiry_time,
  listen, port, protocol, settings, stream_settings, tag, sniffing
) VALUES (
  1, 0, 0, 0, '${remark}', 1, 0,
  '', ${INBOUND_PORT}, 'vless', '${settings_sql}', '${stream_sql}', 'inbound-${INBOUND_PORT}-tcp', '${sniffing_sql}'
);
SQL
    local inbound_id
    inbound_id=$(sqlite3 "$XUI_DB" "SELECT id FROM inbounds WHERE port=${INBOUND_PORT} ORDER BY id DESC LIMIT 1;")
    [[ -n "$inbound_id" ]] || die "Failed to insert inbounds row"

    # Link client <-> inbound
    sqlite3 "$XUI_DB" "INSERT INTO client_inbounds (client_id, inbound_id, flow_override, created_at) VALUES (${client_id}, ${inbound_id}, '', ${ts});" \
      || die "Failed to insert client_inbounds link"

    # client_traffics (required by panel UI / stats)
    sqlite3 "$XUI_DB" <<SQL
INSERT OR REPLACE INTO client_traffics (
  inbound_id, enable, email, up, down, expiry_time, total,
  reset, reset_day, reset_weekday, reset_max, reset_count, last_online, last_sub_fetch
) VALUES (
  ${inbound_id}, 1, '${email_tag}', 0, 0, 0, 0,
  0, 0, 0, 0, 0, 0, 0
);
SQL
  else
    # Python fallback for hosts without sqlite3 CLI
    python3 - "$XUI_DB" "$uuid" "$remark" "$email_tag" "$sub_id" "$ts" "$settings" "$stream" "$sniffing" "$INBOUND_PORT" <<'PY'
import sqlite3, sys
db, uuid, remark, email, sub_id, ts, settings, stream, sniffing, port = sys.argv[1:11]
ts = int(ts); port = int(port)
con = sqlite3.connect(db)
cur = con.cursor()
for row in cur.execute("SELECT id FROM inbounds WHERE port=?", (port,)):
    oid = row[0]
    cur.execute("DELETE FROM client_inbounds WHERE inbound_id=?", (oid,))
    cur.execute("DELETE FROM client_traffics WHERE inbound_id=?", (oid,))
    cur.execute("DELETE FROM inbounds WHERE id=?", (oid,))
for row in list(cur.execute("SELECT id FROM clients WHERE email=? OR uuid=?", (email, uuid))):
    oid = row[0]
    cur.execute("DELETE FROM client_inbounds WHERE client_id=?", (oid,))
    cur.execute("DELETE FROM clients WHERE id=?", (oid,))
cur.execute(
    """INSERT INTO clients (
      email, sub_id, uuid, password, auth, flow, security, reverse,
      limit_ip, limit_hwid, total_gb, expiry_time, enable, tg_id,
      comment, reset, reset_day, reset_weekday, reset_max,
      traffic_reset, traffic_reset_day, created_at, updated_at, sync_orphaned_at
    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
    (email, sub_id, uuid, '', '', '', '', '', 0, 0, 0, 0, 1, 0, '', 0, 0, 0, 0, 'never', 1, ts, ts, 0),
)
client_id = cur.lastrowid
cur.execute(
    """INSERT INTO inbounds (
      user_id, up, down, total, remark, enable, expiry_time,
      listen, port, protocol, settings, stream_settings, tag, sniffing
    ) VALUES (1,0,0,0,?,1,0,'',?,?,?,?,?,?)""",
    (remark, port, 'vless', settings, stream, f'inbound-{port}-tcp', sniffing),
)
inbound_id = cur.lastrowid
cur.execute(
    "INSERT INTO client_inbounds (client_id, inbound_id, flow_override, created_at) VALUES (?,?,?,?)",
    (client_id, inbound_id, '', ts),
)
cur.execute(
    """INSERT OR REPLACE INTO client_traffics (
      inbound_id, enable, email, up, down, expiry_time, total,
      reset, reset_day, reset_weekday, reset_max, reset_count, last_online, last_sub_fetch
    ) VALUES (?,?,?,0,0,0,0,0,0,0,0,0,0,0)""",
    (inbound_id, 1, email),
)
con.commit(); con.close()
print(f"client_id={client_id} inbound_id={inbound_id}")
PY
  fi

  # Ensure DB JSON is valid with decryption before panel rebuilds xray config
  ensure_vless_decryption

  systemctl start x-ui
  sleep 2
  systemctl is-active --quiet x-ui || die "x-ui failed to start after inbound insert"
  # Trigger migrate / reload if available
  "$XUI_BIN" migrate >/dev/null 2>&1 || true
  # migrate/restart may rewrite config.json from DB — reinforce decryption
  ensure_vless_decryption
  systemctl restart x-ui
  sleep 3
  # Final pass in case restart rewrote config again without the field
  ensure_vless_decryption
  if systemctl is-active --quiet x-ui; then
    :
  else
    systemctl restart x-ui
    sleep 2
  fi
  # Only restart again if we actually patched config after last start
  systemctl restart x-ui
  sleep 2
  log "Inbound created (remark=${remark}, uuid=${uuid})"
}


# ---------- verify ----------
verify_listen() {
  local panel_port="$1"
  local ok443=0 okpanel=0 i
  log "Verifying listeners..."
  for i in $(seq 1 20); do
    if port_in_use "$INBOUND_PORT"; then ok443=1; fi
    if port_in_use "$panel_port"; then okpanel=1; fi
    [[ $ok443 -eq 1 && $okpanel -eq 1 ]] && break
    sleep 1
  done
  if [[ $ok443 -ne 1 ]]; then
    err "Port ${INBOUND_PORT} not listening after setup."
    ss -lntp 2>/dev/null | head -40 >&2 || true
    journalctl -u x-ui -n 40 --no-pager >&2 || true
    die "Xray did not bind :${INBOUND_PORT}. Check panel inbound / x-ui logs."
  fi
  if [[ $okpanel -ne 1 ]]; then
    err "Panel port ${panel_port} not listening."
    die "Panel not reachable locally on :${panel_port}"
  fi
  log "Listeners OK (:${INBOUND_PORT} xray, :${panel_port} panel)"

  # Local curl of panel (HTTP)
  local wbp_path="$2"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${panel_port}${wbp_path}" 2>/dev/null || echo "000")
  if [[ "$code" =~ ^[2345][0-9][0-9]$ ]]; then
    log "Panel HTTP check: HTTP ${code}"
  else
    warn "Panel local curl returned '${code}' — service is up but path may need a moment; URL still printed below."
  fi
}

save_and_print() {
  local panel_url="$1" user="$2" pass="$3" vless="$4" panel_port="$5" wbp="$6" uuid="$7" remark="$8" server_ip="$9"

  umask 077
  cat > "$CRED_FILE" <<EOF
# Minimal 3x-ui VLESS-WS install — $(date -Iseconds 2>/dev/null || date)
# mode 600 — keep secret
PANEL_URL=${panel_url}
PANEL_USER=${user}
PANEL_PASS=${pass}
PANEL_PORT=${panel_port}
WEB_BASE_PATH=${wbp}
SERVER_IP=${server_ip}
VLESS_UUID=${uuid}
REMARK=${remark}
VLESS_PORT=${INBOUND_PORT}
VLESS_LINK=${vless}
EOF
  chmod 600 "$CRED_FILE"
  chown root:root "$CRED_FILE" 2>/dev/null || true

  echo
  echo -e "${green}════════════════════════════════════════════════════════════${plain}"
  echo -e "${green}  Minimal 3x-ui 安装完成 / Install complete${plain}"
  echo -e "${green}════════════════════════════════════════════════════════════${plain}"
  echo -e "${blue}Panel URL:${plain}      ${panel_url}"
  echo -e "${blue}Username:${plain}       ${user}"
  echo -e "${blue}Password:${plain}       ${pass}"
  echo -e "${blue}VLESS link:${plain}     ${vless}"
  echo -e "${green}────────────────────────────────────────────────────────────${plain}"
  echo -e "Saved (mode 600): ${CRED_FILE}"
  echo -e "Inbound: VLESS + WS security=none  path=/  port=${INBOUND_PORT}"
  echo -e "Sysctl:  ${SYSCTL_FILE} (BBR if kernel supports; else FQ+64MB only)"
  echo -e "${yellow}云安全组 / Security group: allow TCP ${INBOUND_PORT} + ${panel_port}${plain}"
  echo -e "${green}════════════════════════════════════════════════════════════${plain}"
  echo
}

# ---------- main ----------
main() {
  require_root
  detect_os
  check_internet
  install_deps
  handle_existing
  check_port_443

  local server_ip remark panel_port panel_user panel_pass web_base uuid email_tag wbp_url panel_url vless

  server_ip=$(detect_public_ip)
  [[ -n "$server_ip" ]] || warn "Could not detect public IPv4; panel URL may need manual IP."
  [[ -n "$server_ip" ]] || server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ -n "$server_ip" ]] || server_ip="YOUR_SERVER_IP"

  # REMARK is resolved interactively later, right before creating the VLESS inbound
  remark=""

  panel_port="${PANEL_PORT:-}"
  if [[ -z "$panel_port" ]]; then
    panel_port=$(shuf -i 20000-62000 -n 1 2>/dev/null || echo $((20000 + RANDOM % 40000)))
  fi
  # Ensure panel port free
  local tries=0
  while port_in_use "$panel_port"; do
    tries=$((tries + 1))
    [[ $tries -lt 20 ]] || die "Could not find a free panel port"
    panel_port=$(shuf -i 20000-62000 -n 1 2>/dev/null || echo $((20000 + RANDOM % 40000)))
  done

  panel_user="${PANEL_USER:-$(gen_hex 10)}"
  panel_pass="${PANEL_PASS:-$(gen_alnum 14)}"
  if [[ -n "${WEB_BASE_PATH:-}" ]]; then
    web_base="${WEB_BASE_PATH}"
  else
    web_base="$(gen_hex 16)"
  fi
  # normalize
  web_base="${web_base#/}"; web_base="${web_base%/}"

  apply_sysctl
  install_3xui "$panel_user" "$panel_pass" "$panel_port" "$web_base" "$server_ip"

  # Re-read actual settings from panel (install may normalize path/port)
  local shown_port shown_path
  shown_port=$("$XUI_BIN" setting -show true 2>/dev/null | grep -Eo 'port: .+' | awk '{print $2}' | tr -d '[:space:]' || true)
  shown_path=$("$XUI_BIN" setting -show true 2>/dev/null | grep -Eo 'webBasePath: .+' | awk '{print $2}' | tr -d '[:space:]' || true)
  [[ -n "${shown_port:-}" ]] && panel_port="$shown_port"
  if [[ -n "${shown_path:-}" ]]; then
    web_base="${shown_path#/}"; web_base="${web_base%/}"
  fi

  # Ensure credentials match what we want (in case upgrade path skipped defaults)
  "$XUI_BIN" setting -username "$panel_user" -password "$panel_pass" -port "$panel_port" -webBasePath "$web_base" >/dev/null 2>&1 || true
  systemctl restart x-ui
  sleep 2

  # --- VLESS inbound step: resolve REMARK (interactive if TTY), then UUID ---
  resolve_remark "$server_ip" remark
  [[ -n "$remark" ]] || die "REMARK resolved empty"

  uuid=$(gen_uuid | tr -d '[:space:]')
  [[ "$uuid" =~ ^[0-9a-fA-F-]{36}$ ]] || die "Invalid UUID generated/provided: ${uuid}"

  email_tag="${remark}-ws"
  # email stays ASCII-safe for DB; strip non-ASCII from tag
  if command -v python3 >/dev/null 2>&1; then
    email_tag=$(EMAIL_RAW="$email_tag" python3 -c 'import os,re; s=os.environ["EMAIL_RAW"]; print(re.sub(r"[^A-Za-z0-9._@-]","",s)[:64] or "node-ws")')
  else
    email_tag=$(printf '%s' "$email_tag" | tr -cd 'A-Za-z0-9._@-' | head -c 64)
  fi
  [[ -n "$email_tag" ]] || email_tag="node-ws"

  create_vless_inbound "$uuid" "$remark" "$email_tag"

  wbp_url="/${web_base}/"
  panel_url="http://${server_ip}:${panel_port}${wbp_url}"
  local remark_frag
  remark_frag=$(urlencode_fragment "$remark")
  vless="vless://${uuid}@${server_ip}:${INBOUND_PORT}?encryption=none&security=none&type=ws&path=%2F#${remark_frag}"

  open_firewall "$panel_port"
  verify_listen "$panel_port" "$wbp_url"
  save_and_print "$panel_url" "$panel_user" "$panel_pass" "$vless" "$panel_port" "$wbp_url" "$uuid" "$remark" "$server_ip"
}

main "$@"
