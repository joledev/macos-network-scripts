#!/usr/bin/env bash
# Map the local network: interface -> gateway -> first hop -> internet.
# Combines discovery (interfaces + hosts) and emits:
#   - text summary
#   - JSON
#   - Mermaid graph (graph TD) suitable for Obsidian/GitHub
#
# Usage:
#   map.sh [--interface en7] [--subnet ...] [--json|--md|--mermaid]
#   map.sh --traceroute [--target 1.1.1.1]
#
# By default does NOT probe (uses ARP cache). Add --active to populate.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
ACTIVE=0
DO_TRACE=0
TRACE_TARGET="1.1.1.1"
IFACE=""
SUBNET=""

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md) FORMAT="md"; shift ;;
    --mermaid) FORMAT="mermaid"; shift ;;
    --text) FORMAT="text"; shift ;;
    --active) ACTIVE=1; shift ;;
    --traceroute) DO_TRACE=1; shift ;;
    --target) TRACE_TARGET="$2"; shift 2 ;;
    --interface) IFACE="$2"; shift 2 ;;
    --subnet) SUBNET="$2"; shift 2 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

guard_no_sudo

[[ -z "$IFACE" ]] && IFACE=$(pick_interface || true)
[[ -z "$IFACE" ]] && die "Could not pick a network interface."

if [[ -z "$SUBNET" ]]; then
  SUBNET=$(iface_subnet_cidr "$IFACE" || true)
fi

GATEWAY=$(default_gateway || echo "")
LOCAL_IP=$(iface_ipv4 "$IFACE" || echo "")
HW_PORT=$(iface_hwport "$IFACE" || echo "")
KIND=$(iface_kind "$IFACE" || echo other)

log_info "Mapping via $IFACE ($KIND, $LOCAL_IP) → gateway $GATEWAY"

# Temp files for passing JSON to python
TRACE_FILE="$(mktemp -t netkit-trace.XXXXXX)"
HOSTS_FILE="$(mktemp -t netkit-hosts.XXXXXX)"
trap 'rm -f "$TRACE_FILE" "$HOSTS_FILE"' EXIT

echo "[]" > "$TRACE_FILE"
if (( DO_TRACE )); then
  if has_cmd mtr; then
    log_info "Running mtr to $TRACE_TARGET (10 cycles)..."
    mtr -r -c 10 -j "$TRACE_TARGET" 2>/dev/null > "$TRACE_FILE" || echo "[]" > "$TRACE_FILE"
  else
    log_info "Running traceroute to $TRACE_TARGET..."
    traceroute -n -w 1 -q 1 "$TRACE_TARGET" 2>/dev/null | python3 -c '
import json, re, sys
hops = []
for line in sys.stdin.read().splitlines():
    m = re.match(r"\s*(\d+)\s+(\S+)", line)
    if not m: continue
    hop = int(m.group(1))
    ip = m.group(2)
    if ip == "*": continue
    rtt_m = re.search(r"([\d.]+) ms", line)
    hops.append({"hop": hop, "host": ip, "rtt_ms": float(rtt_m.group(1)) if rtt_m else None})
print(json.dumps(hops))
' > "$TRACE_FILE" || echo "[]" > "$TRACE_FILE"
  fi
fi

# Get hosts (passive ARP cache only by default)
HOSTS_FLAGS=("--json")
(( ACTIVE )) && HOSTS_FLAGS+=("--active")
HOSTS_FLAGS+=("--interface" "$IFACE")
[[ -n "$SUBNET" ]] && HOSTS_FLAGS+=("--subnet" "$SUBNET")
"${SCRIPT_DIR}/../discovery/hosts.sh" "${HOSTS_FLAGS[@]}" > "$HOSTS_FILE" 2>/dev/null || echo '{"hosts":[]}' > "$HOSTS_FILE"

export NETKIT_IFACE="$IFACE"
export NETKIT_HW_PORT="$HW_PORT"
export NETKIT_KIND="$KIND"
export NETKIT_LOCAL_IP="$LOCAL_IP"
export NETKIT_SUBNET="$SUBNET"
export NETKIT_GATEWAY="$GATEWAY"
export NETKIT_FMT="$FORMAT"
export NETKIT_TRACE_FILE="$TRACE_FILE"
export NETKIT_HOSTS_FILE="$HOSTS_FILE"

python3 - <<'PY'
import json, os, sys

hosts = json.load(open(os.environ["NETKIT_HOSTS_FILE"]))
trace = json.load(open(os.environ["NETKIT_TRACE_FILE"]))

result = {
    "interface": os.environ["NETKIT_IFACE"],
    "hardware_port": os.environ["NETKIT_HW_PORT"],
    "kind": os.environ["NETKIT_KIND"],
    "local_ip": os.environ["NETKIT_LOCAL_IP"],
    "subnet": os.environ["NETKIT_SUBNET"],
    "gateway": os.environ["NETKIT_GATEWAY"],
    "hosts": hosts.get("hosts", []),
    "traceroute": trace,
}

fmt = os.environ["NETKIT_FMT"]

if fmt == "json":
    print(json.dumps(result, indent=2))

elif fmt == "mermaid":
    print("graph TD")
    laptop_label = f'MacBook<br/>{result["local_ip"]}<br/><i>{result["hardware_port"]}</i>'
    print(f'    mac["{laptop_label}"] -- {result["kind"]} --> gw["Gateway<br/>{result["gateway"]}"]')
    for i, h in enumerate(result["hosts"]):
        if h["ip"] == result["gateway"]:
            continue
        label = h["ip"]
        if h.get("name"):
            label += f"<br/>{h['name']}"
        if h.get("vendor") and h["vendor"] != "Unknown":
            label += f"<br/><i>{h['vendor']}</i>"
        print(f'    gw --> h{i}["{label}"]')
    if isinstance(trace, list) and trace:
        print("    gw -- WAN --> internet((Internet))")
        prev = "internet"
        for j, hop in enumerate(trace[:6]):
            host = hop.get("host") or hop.get("ip", "?")
            print(f'    {prev} --> i{j}["hop {hop.get("hop","?")}<br/>{host}"]')
            prev = f"i{j}"

elif fmt == "md":
    backtick = "`"
    print(f"# Network topology — {result['interface']}\n")
    print(f"- **Local IP:** {backtick}{result['local_ip']}{backtick} ({result['hardware_port']})")
    print(f"- **Kind:** {result['kind']}")
    print(f"- **Subnet:** {result['subnet']}")
    print(f"- **Gateway:** {backtick}{result['gateway']}{backtick}")
    print(f"- **LAN hosts known:** {len(result['hosts'])}\n")
    if result["hosts"]:
        print("## Hosts\n")
        print("| IP | Name | Vendor |")
        print("| --- | --- | --- |")
        for h in result["hosts"]:
            print(f"| {h['ip']} | {h.get('name','') or ''} | {h.get('vendor','') or ''} |")
    if trace:
        print("\n## Path to internet\n")
        print("```")
        print(json.dumps(trace, indent=2))
        print("```")

else:
    print(f"Interface       : {result['interface']} ({result['kind']})")
    print(f"Hardware port   : {result['hardware_port']}")
    print(f"Local IP/subnet : {result['local_ip']}  /  {result['subnet']}")
    print(f"Gateway         : {result['gateway']}")
    print(f"LAN hosts known : {len(result['hosts'])}")
    if isinstance(trace, list) and trace:
        print()
        print("Traceroute (truncated):")
        for h in trace[:8]:
            rtt = h.get("rtt_ms", "?")
            print(f"  hop {h.get('hop','?'):>2}  {h.get('host','?')}  {rtt} ms")
PY
