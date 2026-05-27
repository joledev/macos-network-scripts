#!/usr/bin/env bash
# Detect macOS network interfaces with IPs, kind, status and link speed.
# Output formats: text (default), json, md.
#
# Usage: interfaces.sh [--json|--md]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
case "${1:-}" in
  --json) FORMAT="json" ;;
  --md)   FORMAT="md" ;;
  --text|"") FORMAT="text" ;;
  -h|--help)
    awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
    exit 0 ;;
  *) die "Unknown flag: $1" ;;
esac

# Build list of (device, hwport) pairs
mapfile -t DEVICES < <(networksetup -listallhardwareports 2>/dev/null \
  | awk '
      /^Hardware Port:/ { hp = substr($0, index($0,$3)) }
      /^Device:/        { print $2 "\t" hp }
    ')

# Add a default-route marker
DEFAULT_IFACE=$(default_route_iface || true)
DEFAULT_GW=$(default_gateway || true)

# Get link speed via networksetup -getMedia (if supported by the adapter)
iface_media() {
  local iface="$1"
  networksetup -getMedia "$iface" 2>/dev/null \
    | awk -F': ' '/^Active:/ {print $2; exit}'
}

# Get up/down status from ifconfig
iface_status() {
  local iface="$1"
  ifconfig "$iface" 2>/dev/null | awk '/status:/ {print $2; exit}'
}

# Build JSON via python to keep escaping correct
emit_json() {
  python3 - <<'PY'
import json, os, subprocess, sys

def sh(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        return ""

# Parse hardware ports
hp_map = {}
current_hp = None
for line in sh("networksetup -listallhardwareports").splitlines():
    if line.startswith("Hardware Port:"):
        current_hp = line.split(":", 1)[1].strip()
    elif line.startswith("Device:"):
        dev = line.split(":", 1)[1].strip()
        if dev and current_hp:
            hp_map[dev] = current_hp

default_iface = sh("route -n get default | awk '/interface:/ {print $2}'")
default_gw    = sh("route -n get default | awk '/gateway:/ {print $2}'")

def iface_ipv4(dev):
    out = sh(f"ifconfig {dev}")
    for ln in out.splitlines():
        ln = ln.strip()
        if ln.startswith("inet ") and "127.0.0.1" not in ln:
            return ln.split()[1]
    return ""

def iface_netmask_hex(dev):
    out = sh(f"ifconfig {dev}")
    for ln in out.splitlines():
        ln = ln.strip()
        if ln.startswith("inet ") and "127.0.0.1" not in ln:
            parts = ln.split()
            if "netmask" in parts:
                return parts[parts.index("netmask") + 1]
    return ""

def hex_to_cidr(h):
    if not h.startswith("0x"):
        return ""
    bits = bin(int(h, 16)).count("1")
    return str(bits)

def iface_status(dev):
    out = sh(f"ifconfig {dev}")
    for ln in out.splitlines():
        ln = ln.strip()
        if ln.startswith("status:"):
            return ln.split(":", 1)[1].strip()
    return ""

def iface_mac(dev):
    out = sh(f"ifconfig {dev}")
    for ln in out.splitlines():
        ln = ln.strip()
        if ln.startswith("ether "):
            return ln.split()[1]
    return ""

def iface_media(dev):
    out = sh(f"networksetup -getMedia {dev}")
    for ln in out.splitlines():
        if ln.startswith("Active:"):
            return ln.split(":", 1)[1].strip()
    return ""

def classify(hwport):
    hp = hwport.lower()
    if "wi-fi" in hp or "airport" in hp: return "wifi"
    if "ethernet" in hp or "lan" in hp or ("usb" in hp and "lan" in hp): return "ethernet"
    if "thunderbolt" in hp: return "thunderbolt"
    if not hp: return "virtual"
    return "other"

rows = []
for dev, hwport in hp_map.items():
    ip = iface_ipv4(dev)
    rows.append({
        "device": dev,
        "hardware_port": hwport,
        "kind": classify(hwport),
        "mac": iface_mac(dev),
        "ipv4": ip,
        "netmask_cidr": hex_to_cidr(iface_netmask_hex(dev)) if ip else "",
        "status": iface_status(dev),
        "media": iface_media(dev),
        "is_default_route": dev == default_iface,
    })

print(json.dumps({
    "default_interface": default_iface,
    "default_gateway": default_gw,
    "interfaces": rows,
}, indent=2))
PY
}

emit_md() {
  local tmp; tmp=$(mktemp -t netkit-iface.XXXXXX)
  trap 'rm -f "$tmp"' RETURN
  emit_json > "$tmp"
  IFACE_JSON_FILE="$tmp" python3 - <<'PY'
import json, os
data = json.load(open(os.environ["IFACE_JSON_FILE"]))
print(f"# Network interfaces\n")
print(f"- **Default route via:** `{data['default_interface']}` → `{data['default_gateway']}`\n")
cols = ["device","kind","ipv4","netmask_cidr","status","media","mac","hardware_port"]
print("| " + " | ".join(cols) + " | default |")
print("| " + " | ".join("---" for _ in cols) + " | --- |")
for r in data["interfaces"]:
    row = [str(r.get(c, "") or "") for c in cols]
    row.append("yes" if r.get("is_default_route") else "")
    print("| " + " | ".join(s.replace("|", "\\|") for s in row) + " |")
PY
}

emit_text() {
  local tmp; tmp=$(mktemp -t netkit-iface.XXXXXX)
  trap 'rm -f "$tmp"' RETURN
  emit_json > "$tmp"
  IFACE_JSON_FILE="$tmp" python3 - <<'PY'
import json, os
data = json.load(open(os.environ["IFACE_JSON_FILE"]))
print(f"Default route : {data['default_interface']} -> {data['default_gateway']}")
print()
fmt = "{:<8} {:<11} {:<16} {:<6} {:<10} {:<24} {}"
print(fmt.format("device", "kind", "ipv4", "cidr", "status", "media", "hardware_port"))
print("-" * 120)
for r in data["interfaces"]:
    print(fmt.format(
        r.get("device","") or "",
        r.get("kind","") or "",
        r.get("ipv4","") or "",
        r.get("netmask_cidr","") or "",
        r.get("status","") or "",
        (r.get("media","") or "")[:23],
        r.get("hardware_port","") or "",
    ))
PY
}

case "$FORMAT" in
  json) emit_json ;;
  md)   emit_md ;;
  text) emit_text ;;
esac
