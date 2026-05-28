#!/usr/bin/env bash
# Reachable-segment discovery — map every network this Mac can reach, so a
# building/multi-VLAN scan knows WHICH ranges to sweep.
#
# Reads the routing table (netstat -rn, v4+v6) and interface subnets and splits
# them into:
#   * directly-connected subnets  → on-link, immediately scannable
#   * routed networks (via a gateway) → other segments/VLANs reachable through
#     a router (candidate scan targets if routing allows)
#   * default route + per-interface gateways
#
# Pure read of local routing state — no probes. With --trace it also traceroutes
# a target to reveal the L3 hops between segments.
#
# Output: JSON / md / text.
#
# Usage: routes.sh [--trace HOST] [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
TRACE_HOST=""

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --trace)
      [[ -n "${2:-}" ]] || die_usage "--trace requires a host/IP"
      TRACE_HOST="$2"; shift 2 ;;
    --yes) export NETKIT_YES=1; shift ;;
    --allow-raw) export NETKIT_ALLOW_RAW=1; shift ;;
    --dry-run) export NETKIT_DRY_RUN=1; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) die_usage "Unknown flag: $1" ;;
  esac
done

if [[ -n "$TRACE_HOST" ]]; then
  [[ "$TRACE_HOST" =~ ^[A-Za-z0-9._-]+$ ]] || die_usage "--trace host has invalid characters"
fi

guard_no_sudo

if dry_run; then
  log_dry "routes would:"
  log_dry "  read   : netstat -rn (IPv4 + IPv6 routing tables)"
  log_dry "  read   : interface subnets (directly-connected)"
  [[ -n "$TRACE_HOST" ]] && log_dry "  trace  : traceroute -w1 -q1 -m15 ${TRACE_HOST}"
  log_dry "no probes (unless --trace)."
  exit 0
fi

RT4="$(netstat -rn -f inet 2>/dev/null || true)"
RT6="$(netstat -rn -f inet6 2>/dev/null || true)"
TRACE_OUT=""
if [[ -n "$TRACE_HOST" ]]; then
  log_info "traceroute to ${TRACE_HOST}..."
  TRACE_OUT="$(traceroute -n -w 1 -q 1 -m 15 "$TRACE_HOST" 2>/dev/null || true)"
fi

export NETKIT_FMT="$FORMAT" NETKIT_RT4="$RT4" NETKIT_RT6="$RT6" \
       NETKIT_TRACE_HOST="$TRACE_HOST" NETKIT_TRACE_OUT="$TRACE_OUT" NETKIT_ROOT

python3 - <<'PY'
import ipaddress, json, os, re, subprocess, sys

fmt = os.environ["NETKIT_FMT"]
rt4 = os.environ.get("NETKIT_RT4", "")


def sh(cmd):
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.DEVNULL)
    except Exception:
        return ""


# Directly-connected subnets, from each active interface's ip + mask.
ifaces = {}
cur = None
for ln in sh(["ifconfig"]).splitlines():
    if ln and not ln[0].isspace():
        cur = ln.split(":", 1)[0]
    elif cur and "inet " in ln and "127.0.0.1" not in ln:
        parts = ln.split()
        ip = parts[1]
        mask_hex = parts[parts.index("netmask") + 1] if "netmask" in parts else ""
        try:
            bits = bin(int(mask_hex, 16)).count("1") if mask_hex.startswith("0x") else 24
            net = ipaddress.ip_network(f"{ip}/{bits}", strict=False)
            if net.is_link_local:        # skip 169.254/16 APIPA — not a real segment
                continue
            ifaces.setdefault(cur, []).append({"ip": ip, "cidr": str(net)})
        except ValueError:
            pass

connected, routed = [], []
default_gw = default_if = ""

# Parse the IPv4 routing table.
for ln in rt4.splitlines():
    parts = ln.split()
    if len(parts) < 4 or parts[0] in ("Routing", "Internet:", "Destination"):
        continue
    dest, gw, flags, netif = parts[0], parts[1], parts[2], parts[3]
    if dest == "default":
        default_gw, default_if = gw, netif
        continue
    # Normalize abbreviated macOS destinations ("192.168.1" → 192.168.1.0/24).
    d = dest
    if "/" not in d and re.match(r"^\d+(\.\d+){0,3}$", d):
        octets = d.split(".")
        prefix = len(octets) * 8
        d = ".".join(octets + ["0"] * (4 - len(octets))) + f"/{prefix}"
    try:
        net = ipaddress.ip_network(d, strict=False)
    except ValueError:
        continue
    if net.prefixlen == 32 or net.is_loopback or net.is_multicast or net.is_link_local:
        continue
    entry = {"network": str(net), "via": gw, "iface": netif}
    if gw.startswith("link#") or re.match(r"^[0-9a-f]{1,2}(:[0-9a-f]{1,2})+$", gw, re.I):
        connected.append(entry)
    elif re.match(r"^\d+\.\d+\.\d+\.\d+$", gw):
        routed.append(entry)

# De-dup connected against interface subnets (prefer the iface view).
iface_cidrs = {c["cidr"] for v in ifaces.values() for c in v}
scannable = sorted(iface_cidrs | {c["network"] for c in connected})

result = {
    "default_gateway": default_gw, "default_interface": default_if,
    "interfaces": ifaces,
    "directly_connected": scannable,
    "routed_networks": routed,
}

if os.environ.get("NETKIT_TRACE_OUT"):
    hops = []
    for ln in os.environ["NETKIT_TRACE_OUT"].splitlines():
        m = re.match(r"\s*(\d+)\s+(\S+)", ln)
        if m and m.group(2) != "traceroute":
            hops.append({"hop": int(m.group(1)), "host": m.group(2)})
    result["traceroute"] = {"target": os.environ.get("NETKIT_TRACE_HOST", ""), "hops": hops}

if fmt == "json":
    print(json.dumps(result, indent=2))
    sys.exit(0)

if fmt == "md":
    print("# Reachable network segments\n")
    print(f"- **Default route:** via `{default_gw}` on `{default_if}`\n")
    print("## Directly-connected (scannable now)\n")
    for c in scannable:
        print(f"- `{c}`")
    if routed:
        print("\n## Routed networks (other segments/VLANs)\n")
        print("| network | via gateway | iface |")
        print("| --- | --- | --- |")
        for r in routed:
            print(f"| {r['network']} | {r['via']} | {r['iface']} |")
    sys.exit(0)

print(f"Default route : via {default_gw} on {default_if}\n")
print("Directly-connected subnets (scannable now):")
for c in scannable:
    print(f"  {c}")
if routed:
    print("\nRouted networks (other segments/VLANs reachable via a gateway):")
    for r in routed:
        print(f"  {r['network']:<22} via {r['via']} ({r['iface']})")
else:
    print("\n(no extra routed networks — this Mac only sees its directly-connected subnets;")
    print(" other building VLANs would need a route here, a run from each VLAN, or SNMP)")
if result.get("traceroute"):
    print(f"\nPath to {result['traceroute']['target']}:")
    for h in result["traceroute"]["hops"]:
        print(f"  {h['hop']:>2}  {h['host']}")
PY
