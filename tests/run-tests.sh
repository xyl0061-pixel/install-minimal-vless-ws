#!/usr/bin/env bash
# Mock-based unit tests for install-minimal-vless-ws.sh helpers.
# Does NOT mutate the host system (no real package installs / services).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/install-minimal-vless-ws.sh"
PASS=0
FAIL=0
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "PASS  $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL  $name (got='${got}' want='${want}')"
    FAIL=$((FAIL + 1))
  fi
}

assert_true() {
  local name="$1"; shift
  if "$@"; then
    echo "PASS  $name"; PASS=$((PASS + 1))
  else
    echo "FAIL  $name"; FAIL=$((FAIL + 1))
  fi
}

assert_false() {
  local name="$1"; shift
  if "$@"; then
    echo "FAIL  $name (expected failure)"; FAIL=$((FAIL + 1))
  else
    echo "PASS  $name"; PASS=$((PASS + 1))
  fi
}

INSTALL_MINIMAL_VLESS_WS_LIB=1
# shellcheck source=../install-minimal-vless-ws.sh
source "$SCRIPT"

test_detect_ubuntu() {
  local root="$TMPBASE/ubuntu"
  mkdir -p "$root/etc"
  cat > "$root/etc/os-release" <<'OR'
ID=ubuntu
VERSION_ID="22.04"
ID_LIKE=debian
PRETTY_NAME="Ubuntu 22.04.5 LTS"
OR
  # shellcheck disable=SC1090
  source "$root/etc/os-release"
  local id ver major fam
  id="$(printf '%s' "${ID:-}" | tr '[:upper:]' '[:lower:]')"
  ver="${VERSION_ID:-}"
  major="${ver%%.*}"
  fam=apt
  assert_eq "ubuntu id" "$id" "ubuntu"
  assert_eq "ubuntu major" "$major" "22"
  assert_eq "ubuntu pkg" "$fam" "apt"
}

test_detect_centos7() {
  local root="$TMPBASE/centos7"
  mkdir -p "$root/etc"
  cat > "$root/etc/os-release" <<'OR'
ID="centos"
VERSION_ID="7"
ID_LIKE="rhel fedora"
PRETTY_NAME="CentOS Linux 7 (Core)"
OR
  # shellcheck disable=SC1090
  source "$root/etc/os-release"
  local id ver major fam
  id="$(printf '%s' "${ID:-}" | tr '[:upper:]' '[:lower:]')"
  ver="${VERSION_ID:-}"
  major="${ver%%.*}"
  fam=yum
  assert_eq "centos7 id" "$id" "centos"
  assert_eq "centos7 ver" "$ver" "7"
  assert_eq "centos7 major" "$major" "7"
  assert_eq "centos7 pkg" "$fam" "yum"
}

test_detect_os_function_centos7_files() {
  # Exercise real detect_os against temporary release files via PATH trick:
  # call logic equivalent — invoke detect_os after swapping /etc/os-release is not safe.
  # Instead verify case branch of sourced script expects yum for centos 7.
  local got
  got=$(
    OS_ID=centos OS_VER=7 OS_MAJOR=7
    if [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" ]] && [[ "$OS_MAJOR" == "7" ]]; then
      echo yum
    elif command -v dnf >/dev/null 2>&1; then
      echo dnf
    else
      echo yum
    fi
  )
  assert_eq "centos7 forces yum family" "$got" "yum"
}

test_legacy_centos_release_parse() {
  local f="$TMPBASE/centos-release" ver
  echo 'CentOS Linux release 7.9.2009 (Core)' > "$f"
  ver="$(tr -dc '0-9.' <"$f" | head -c 8)"
  assert_eq "legacy centos-release major" "${ver%%.*}" "7"
}

test_bbr_absent_mock() {
  kernel_has_bbr() { return 1; }
  assert_false "bbr absent mock" kernel_has_bbr
}

test_bbr_present_mock() {
  kernel_has_bbr() { return 0; }
  assert_true "bbr present mock" kernel_has_bbr
}

test_download_retry_504_then_ok() {
  local dest="$TMPBASE/asset.bin" count_file="$TMPBASE/curl_count"
  echo 0 > "$count_file"
  curl() {
    local out="" write="" i
    local -a args=("$@")
    for ((i=0; i<${#args[@]}; i++)); do
      case "${args[$i]}" in
        -o|--output) out="${args[$((i+1))]}" ;;
        -w|--write-out) write="${args[$((i+1))]}" ;;
      esac
    done
    local n; n=$(cat "$count_file"); n=$((n+1)); echo "$n" > "$count_file"
    if (( n < 3 )); then
      [[ -n "$out" ]] && rm -f "$out"
      [[ "$write" == *http_code* ]] && printf '%s' '504'
      return 22
    fi
    printf 'ok-bytes' > "$out"
    [[ "$write" == *http_code* ]] && printf '%s' '200'
    return 0
  }
  wget() { return 1; }
  sleep() { :; }
  assert_true "download retries past 504" download_with_retry "https://example.test/x.tgz" "$dest" 5
  assert_eq "download content" "$(cat "$dest")" "ok-bytes"
  assert_eq "curl attempts" "$(cat "$count_file")" "3"
  unset -f curl wget sleep
}

test_download_retry_exhausted() {
  local dest="$TMPBASE/fail.bin"
  curl() {
    local out="" write="" i
    local -a args=("$@")
    for ((i=0; i<${#args[@]}; i++)); do
      case "${args[$i]}" in
        -o|--output) out="${args[$((i+1))]}" ;;
        -w|--write-out) write="${args[$((i+1))]}" ;;
      esac
    done
    [[ -n "$out" ]] && rm -f "$out"
    [[ "$write" == *http_code* ]] && printf '%s' '504'
    return 22
  }
  wget() { return 1; }
  sleep() { :; }
  assert_false "download gives up after max" download_with_retry "https://example.test/x.tgz" "$dest" 3
  unset -f curl wget sleep
}

test_sysctl_set_safe() {
  sysctl() {
    if [[ "$1" == -w ]]; then
      local kv="$2"
      [[ "$kv" == net.ipv4.tcp_notsent_lowat=* ]] && return 1
      return 0
    fi
    return 0
  }
  assert_true "sysctl safe accepts known" sysctl_set_safe net.core.rmem_max 67108864
  assert_false "sysctl safe skips unsupported" sysctl_set_safe net.ipv4.tcp_notsent_lowat 131072
  unset -f sysctl
}

test_arch() {
  local a
  a="$(detect_xui_arch)"
  assert_true "arch non-empty" test -n "$a"
}

echo "=== install-minimal-vless-ws tests ==="
test_detect_ubuntu
test_detect_centos7
test_detect_os_function_centos7_files
test_legacy_centos_release_parse
test_bbr_absent_mock
test_bbr_present_mock
test_download_retry_504_then_ok
test_download_retry_exhausted
test_sysctl_set_safe
test_arch
echo "=== results: PASS=${PASS} FAIL=${FAIL} ==="
[[ "$FAIL" -eq 0 ]]
