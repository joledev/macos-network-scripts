#!/usr/bin/env bash
# scripts/utils/common.sh — shared helpers for netkit scripts.
# Source this file; do not execute it directly.

# shellcheck shell=bash

if [[ -n "${_NETKIT_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_NETKIT_COMMON_LOADED=1

set -uo pipefail

# ---- Paths ----
NETKIT_ROOT="${NETKIT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export NETKIT_ROOT

# ---- Load .env if present ----
if [[ -f "${NETKIT_ROOT}/.env" ]]; then
  # shellcheck disable=SC1090,SC1091
  set -a; source "${NETKIT_ROOT}/.env"; set +a
fi

# ---- Defaults ----
: "${NETKIT_OUTPUT_DIR:=${NETKIT_ROOT}/output}"
: "${NETKIT_MAX_HOSTS:=256}"
: "${NETKIT_PING_TARGETS:=1.1.1.1,8.8.8.8}"
: "${NETKIT_DNS_DOMAIN:=github.com}"
: "${NETKIT_STRICT:=1}"
: "${NETKIT_YES:=0}"
: "${NETKIT_ALLOW_RAW:=0}"
: "${NETKIT_DRY_RUN:=0}"
export NETKIT_OUTPUT_DIR NETKIT_MAX_HOSTS NETKIT_PING_TARGETS NETKIT_DNS_DOMAIN
export NETKIT_STRICT NETKIT_YES NETKIT_ALLOW_RAW NETKIT_DRY_RUN

# ---- Color & logging ----
if [[ -t 2 ]] && [[ "${NO_COLOR:-}" == "" ]]; then
  C_RESET=$'\e[0m'; C_DIM=$'\e[2m'; C_RED=$'\e[31m'; C_YEL=$'\e[33m'; C_GRN=$'\e[32m'; C_CYA=$'\e[36m'
else
  C_RESET=""; C_DIM=""; C_RED=""; C_YEL=""; C_GRN=""; C_CYA=""
fi

log_info() { printf "%s[netkit]%s %s\n" "${C_CYA}" "${C_RESET}" "$*" >&2; }
log_ok()   { printf "%s[ ok  ]%s %s\n" "${C_GRN}" "${C_RESET}" "$*" >&2; }
log_warn() { printf "%s[warn ]%s %s\n" "${C_YEL}" "${C_RESET}" "$*" >&2; }
log_err()  { printf "%s[error]%s %s\n" "${C_RED}" "${C_RESET}" "$*" >&2; }
log_dim()  { printf "%s%s%s\n" "${C_DIM}" "$*" "${C_RESET}" >&2; }
log_dry()  { printf "%s[dry-run]%s %s\n" "${C_YEL}" "${C_RESET}" "$*" >&2; }

# True when --dry-run / NETKIT_DRY_RUN=1 is active.
dry_run() { [[ "${NETKIT_DRY_RUN:-0}" == "1" ]]; }

die() { log_err "$*"; exit 1; }

# die_usage: same as die but signals a CLI usage error (exit 2). Use this
# for invalid flag values, missing required args, unknown flags — anything
# the user could fix by re-typing the command. Scripts used to redeclare
# this locally; centralized so the convention stays uniform.
die_usage() { log_err "$*"; exit 2; }

# ---- Tool detection ----
has_cmd() { command -v "$1" >/dev/null 2>&1; }

require_cmd() {
  has_cmd "$1" || die "Required command '$1' not found. Install it (see requirements/brew.txt)."
}

soft_require() {
  if ! has_cmd "$1"; then
    log_warn "'$1' not installed — skipping the section that needs it."
    return 1
  fi
  return 0
}

# ---- Output helpers ----
timestamp() { date +%Y%m%d-%H%M%S; }

ensure_output_dir() {
  mkdir -p "${NETKIT_OUTPUT_DIR}"
}

# JSON-escape an arbitrary string via python (always available on macOS)
json_str() {
  python3 -c 'import json,sys;print(json.dumps(sys.stdin.read().rstrip("\n")))'
}

# ---- Interface detection ----
# Returns the device name of the default-route interface (e.g. en7).
default_route_iface() {
  route -n get default 2>/dev/null | awk '/interface:/ {print $2; exit}'
}

# Returns the default gateway IPv4.
default_gateway() {
  route -n get default 2>/dev/null | awk '/gateway:/ {print $2; exit}'
}

# Returns the IPv4 address of the given interface, or empty.
iface_ipv4() {
  local iface="$1"
  ifconfig "$iface" 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}'
}

# Returns every IPv4 address assigned to any local interface, one per line.
# Used by host discovery to filter "self" entries from the ARP cache —
# a Mac with both Wi-Fi and Ethernet active has two IPs on the same LAN.
all_local_ipv4() {
  ifconfig 2>/dev/null | awk '
    /^[a-z]/ { iface = $1; sub(/:$/, "", iface) }
    /inet / && $2 != "127.0.0.1" { print $2 }
  '
}

# Returns the IPv4 netmask of the given interface in dotted form (e.g. 255.255.255.0).
iface_netmask() {
  local iface="$1"
  local hex
  hex=$(ifconfig "$iface" 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $4; exit}')
  [[ -z "$hex" ]] && return 1
  python3 -c "
import sys
h = sys.argv[1]
if h.startswith('0x'): h = h[2:]
print('.'.join(str(int(h[i:i+2], 16)) for i in (0, 2, 4, 6)))
" "$hex"
}

# Returns the human-readable hardware port label (e.g. "USB 10/100/1G/2.5G LAN").
iface_hwport() {
  local iface="$1"
  networksetup -listallhardwareports 2>/dev/null | awk -v dev="$iface" '
    /^Hardware Port:/ { hp = substr($0, index($0,$3)) }
    /^Device:/ { if ($2 == dev) { print hp; exit } }
  '
}

# Classify an interface as one of: ethernet, wifi, thunderbolt, virtual, other.
# Order matters: more specific patterns first so they're not shadowed.
iface_kind() {
  local iface="$1"
  local hp; hp=$(iface_hwport "$iface")
  local hp_lower; hp_lower=$(printf '%s' "$hp" | tr '[:upper:]' '[:lower:]')
  case "$hp_lower" in
    *wi-fi*|*airport*)        echo "wifi" ;;
    *usb*ethernet*)           echo "ethernet" ;;
    *ethernet*|*lan*)         echo "ethernet" ;;
    *thunderbolt*)            echo "thunderbolt" ;;
    "")                       echo "virtual" ;;
    *)                        echo "other" ;;
  esac
}

# Pick a preferred interface. Order of precedence:
#   1. --interface flag (caller sets NETKIT_INTERFACE)
#   2. NETKIT_INTERFACE from env / .env
#   3. The default-route interface if it has IPv4 (already macOS service order — Ethernet wins by default)
#   4. First Ethernet-class interface with an IPv4
#   5. Wi-Fi (en0) if it has IPv4
#   6. Empty string (caller must handle)
pick_interface() {
  if [[ -n "${NETKIT_INTERFACE:-}" ]]; then
    if [[ -n "$(iface_ipv4 "${NETKIT_INTERFACE}")" ]]; then
      echo "${NETKIT_INTERFACE}"; return 0
    fi
    log_warn "NETKIT_INTERFACE='${NETKIT_INTERFACE}' has no IPv4; falling back."
  fi

  local d; d=$(default_route_iface)
  if [[ -n "$d" ]] && [[ -n "$(iface_ipv4 "$d")" ]]; then
    echo "$d"; return 0
  fi

  # Search for any Ethernet-class interface with an IPv4 address
  local iface
  while IFS= read -r iface; do
    [[ -z "$iface" ]] && continue
    if [[ -n "$(iface_ipv4 "$iface")" ]] && [[ "$(iface_kind "$iface")" == "ethernet" ]]; then
      echo "$iface"; return 0
    fi
  done < <(networksetup -listallhardwareports 2>/dev/null | awk '/^Device:/ {print $2}')

  # Fallback: Wi-Fi
  if [[ -n "$(iface_ipv4 en0)" ]]; then
    echo "en0"; return 0
  fi
  return 1
}

# Convert dotted-decimal netmask to CIDR prefix length
netmask_to_cidr() {
  local mask="$1"
  python3 -c "import ipaddress,sys;print(ipaddress.IPv4Network('0.0.0.0/'+sys.argv[1]).prefixlen)" "$mask" 2>/dev/null
}

# Derive the CIDR network for the given interface (e.g. 192.168.1.0/24)
iface_subnet_cidr() {
  local iface="$1"
  local ip mask
  ip=$(iface_ipv4 "$iface")
  mask=$(iface_netmask "$iface")
  [[ -z "$ip" || -z "$mask" ]] && return 1
  python3 -c "
import ipaddress, sys
ip = sys.argv[1]; mask = sys.argv[2]
net = ipaddress.IPv4Network(f'{ip}/{mask}', strict=False)
print(net.with_prefixlen)
" "$ip" "$mask"
}

# Count hosts in a CIDR for safety checks
cidr_host_count() {
  python3 -c "import ipaddress,sys;print(ipaddress.IPv4Network(sys.argv[1], strict=False).num_addresses)" "$1"
}

# ---- Safety guards ----
confirm() {
  local prompt="${1:-Continue?}"
  if [[ "${NETKIT_YES:-0}" == "1" ]]; then
    log_dim "Auto-confirmed (NETKIT_YES=1): $prompt"
    return 0
  fi
  read -r -p "${prompt} [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# Enforce the subnet host-count cap. Returns 0 if safe, exits otherwise.
guard_subnet_size() {
  local cidr="$1" force="${2:-0}"
  local count; count=$(cidr_host_count "$cidr")
  if (( count > NETKIT_MAX_HOSTS )) && [[ "$force" != "1" ]]; then
    die "Subnet ${cidr} has ${count} hosts (> NETKIT_MAX_HOSTS=${NETKIT_MAX_HOSTS}). Re-run with --force to override."
  fi
}

# Refuse to run if the toolkit is in strict mode and the operation needs root.
guard_no_sudo() {
  if [[ "$NETKIT_STRICT" == "1" ]] && [[ "$(id -u)" == "0" ]]; then
    die "Refusing to run as root in strict mode. Set NETKIT_STRICT=0 to override (not recommended)."
  fi
}

# Refuse raw-packet operations (arp-scan, future tcpdump opt-ins) unless
# the caller has explicitly opted in. Honors NETKIT_ALLOW_RAW=1, the
# --allow-raw flag (forwarded as NETKIT_ALLOW_RAW), or interactive
# confirmation. In strict mode, declining confirmation aborts.
guard_raw_packet() {
  local label="${1:-raw-packet operation}"
  if [[ "$NETKIT_ALLOW_RAW" == "1" ]]; then
    return 0
  fi
  if [[ "$NETKIT_STRICT" == "1" ]]; then
    if ! confirm "About to perform a ${label} (requires sudo / raw frames). Proceed?"; then
      die "${label} declined. Re-run with --allow-raw or NETKIT_ALLOW_RAW=1 to skip this prompt."
    fi
  else
    # Strict off: warn and continue without prompting.
    log_warn "Allowing ${label} because NETKIT_STRICT=0."
  fi
}

# Confirm an active sweep (sends one packet per host in the subnet).
guard_active() {
  local subnet="${1:-?}"
  local hosts="?"
  if [[ "$subnet" != "?" ]]; then
    hosts=$(cidr_host_count "$subnet" 2>/dev/null || echo "?")
  fi
  if ! confirm "Active sweep will ping ${hosts} hosts in ${subnet}. Continue?"; then
    die "Active sweep declined."
  fi
}

# ---- Output writer ----
write_json() {
  local path="$1"
  ensure_output_dir
  cat > "$path"
  log_ok "Wrote ${path/#$NETKIT_ROOT\//}"
}

write_text() {
  local path="$1"
  ensure_output_dir
  cat > "$path"
  log_ok "Wrote ${path/#$NETKIT_ROOT\//}"
}
