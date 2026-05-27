#!/usr/bin/env bash
# Discover hosts on the LAN.
#
# Strategy:
#   1. Always read the ARP cache (passive, instant).
#   2. If --active, also probe each address in the subnet via ping (small sweep).
#   3. If nmap is present, use `nmap -sn` for richer results.
#   4. If arp-scan is present and the user passes --arpscan, use it (needs sudo).
#
# Output: JSON list of {ip, mac, vendor, name, source}
#
# Usage:
#   hosts.sh [--active] [--arpscan] [--interface en7] [--subnet 192.168.1.0/24] [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
ACTIVE=0
USE_ARPSCAN=0
FORCE=0
IFACE=""
SUBNET=""

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md) FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --active) ACTIVE=1; shift ;;
    --arpscan) USE_ARPSCAN=1; shift ;;
    --interface) IFACE="$2"; shift 2 ;;
    --subnet) SUBNET="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --yes) export NETKIT_YES=1; shift ;;
    --allow-raw) export NETKIT_ALLOW_RAW=1; shift ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

guard_no_sudo

# Resolve interface and subnet
[[ -z "$IFACE" ]] && IFACE=$(pick_interface || true)
[[ -z "$IFACE" ]] && die "Could not pick a network interface. Set NETKIT_INTERFACE or pass --interface."

if [[ -z "$SUBNET" ]]; then
  SUBNET=$(iface_subnet_cidr "$IFACE" || true)
fi
[[ -z "$SUBNET" ]] && die "Could not derive subnet for $IFACE. Pass --subnet 192.168.x.0/24."

guard_subnet_size "$SUBNET" "$FORCE"

if (( ACTIVE )); then
  guard_active "$SUBNET"
fi
if (( USE_ARPSCAN )); then
  guard_raw_packet "arp-scan (raw ARP probe via sudo)"
fi

log_info "Interface: $IFACE   Subnet: $SUBNET   Active probe: $ACTIVE   arp-scan: $USE_ARPSCAN"

# Step 1: passive ARP cache
ARP_TMP="$(mktemp -t netkit-arp.XXXXXX)"
ARPSCAN_TMP="$(mktemp -t netkit-arpscan.XXXXXX)"
trap 'rm -f "$ARP_TMP" "$ARPSCAN_TMP"' EXIT

arp -an 2>/dev/null > "$ARP_TMP" || true

# Step 2: active probe
if (( ACTIVE )); then
  log_info "Pinging subnet to populate ARP cache..."
  if has_cmd nmap; then
    nmap -sn -e "$IFACE" "$SUBNET" >/dev/null 2>&1 || log_warn "nmap -sn returned non-zero; continuing with ARP only"
  else
    export NETKIT_SUBNET="$SUBNET"
    python3 - <<'PY' 2>/dev/null || true
import concurrent.futures, ipaddress, os, subprocess
hosts = list(ipaddress.IPv4Network(os.environ["NETKIT_SUBNET"], strict=False).hosts())
def ping(h):
    subprocess.run(["ping","-c","1","-W","300","-q",str(h)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
with concurrent.futures.ThreadPoolExecutor(max_workers=64) as ex:
    list(ex.map(ping, hosts))
PY
  fi
  arp -an 2>/dev/null > "$ARP_TMP" || true
fi

# Step 3: arp-scan if requested
if (( USE_ARPSCAN )); then
  if ! has_cmd arp-scan; then
    log_warn "arp-scan not installed; skipping (brew install arp-scan)"
  else
    log_info "Running arp-scan (requires sudo)..."
    if sudo -n arp-scan --interface="$IFACE" --localnet 2>/dev/null > "$ARPSCAN_TMP"; then :
    else
      log_warn "arp-scan needs passwordless sudo — skipping. Try: 'sudo -v' first."
      : > "$ARPSCAN_TMP"
    fi
  fi
fi

# Best-effort mDNS warmup (fills ARP entries for AppleTV, printers, etc.).
# macOS does not ship GNU `timeout`; prefer gtimeout if installed, else
# spawn dns-sd in background and kill it after 2 s.
if has_cmd dns-sd; then
  if has_cmd gtimeout; then
    gtimeout 2 dns-sd -B _services._dns-sd._udp local. >/dev/null 2>&1 || true
  elif has_cmd timeout; then
    timeout 2 dns-sd -B _services._dns-sd._udp local. >/dev/null 2>&1 || true
  else
    dns-sd -B _services._dns-sd._udp local. >/dev/null 2>&1 &
    _mdns_pid=$!
    ( sleep 2; kill "$_mdns_pid" >/dev/null 2>&1 ) >/dev/null 2>&1 &
    wait "$_mdns_pid" 2>/dev/null || true
  fi
fi

export NETKIT_ROOT NETKIT_FMT="$FORMAT" NETKIT_IFACE="$IFACE" NETKIT_SUBNET="$SUBNET"
export NETKIT_ARP_FILE="$ARP_TMP" NETKIT_ARPSCAN_FILE="$ARPSCAN_TMP"

python3 - <<'PY'
import concurrent.futures, json, os, re, socket, sys
sys.path.insert(0, os.path.join(os.environ["NETKIT_ROOT"], "scripts/utils"))
import oui

arp_text = ""
try:
    with open(os.environ["NETKIT_ARP_FILE"]) as f:
        arp_text = f.read()
except OSError:
    pass

arpscan_text = ""
try:
    with open(os.environ["NETKIT_ARPSCAN_FILE"]) as f:
        arpscan_text = f.read()
except OSError:
    pass

hosts = {}

arp_re = re.compile(r"\(([\d.]+)\)\s+at\s+([0-9a-f:]+)", re.I)
for line in arp_text.splitlines():
    m = arp_re.search(line)
    if not m: continue
    ip, mac = m.group(1), m.group(2).lower()
    if mac == "(incomplete)":
        continue
    mac_full = ":".join(p.zfill(2) for p in mac.split(":"))
    hosts.setdefault(ip, {
        "ip": ip, "mac": mac_full, "vendor": oui.lookup(mac_full),
        "name": "", "source": "arp",
    })

for line in arpscan_text.splitlines():
    if "\t" not in line:
        continue
    parts = line.split("\t")
    if len(parts) < 2:
        continue
    ip = parts[0].strip()
    mac = parts[1].strip().lower()
    if not re.match(r"^\d+\.\d+\.\d+\.\d+$", ip):
        continue
    vendor = parts[2].strip() if len(parts) > 2 else oui.lookup(mac)
    rec = hosts.setdefault(ip, {
        "ip": ip, "mac": mac, "vendor": vendor, "name": "", "source": "arp-scan",
    })
    rec["vendor"] = vendor or rec["vendor"]
    rec["source"] = "arp-scan"

def rdns(ip):
    try:
        socket.setdefaulttimeout(0.4)
        return ip, socket.gethostbyaddr(ip)[0]
    except Exception:
        return ip, ""

ips = list(hosts.keys())
with concurrent.futures.ThreadPoolExecutor(max_workers=32) as ex:
    for ip, name in ex.map(rdns, ips):
        if name:
            hosts[ip]["name"] = name

rows = sorted(hosts.values(),
              key=lambda r: tuple(int(x) for x in r["ip"].split(".")))

result = {
    "interface": os.environ["NETKIT_IFACE"],
    "subnet": os.environ["NETKIT_SUBNET"],
    "count": len(rows),
    "hosts": rows,
}

fmt = os.environ["NETKIT_FMT"]
if fmt == "json":
    print(json.dumps(result, indent=2))
elif fmt == "md":
    print(f"# Hosts on {result['subnet']} via {result['interface']} ({result['count']})\n")
    if not rows:
        print("_no hosts found (try --active)_\n")
        sys.exit(0)
    cols = ["ip", "mac", "vendor", "name", "source"]
    print("| " + " | ".join(cols) + " |")
    print("| " + " | ".join("---" for _ in cols) + " |")
    for r in rows:
        print("| " + " | ".join(str(r.get(c, "")).replace("|", r"\|") for c in cols) + " |")
else:
    print(f"Interface: {result['interface']}   Subnet: {result['subnet']}   Hosts: {result['count']}")
    print()
    print(f"{'IP':<16} {'MAC':<19} {'Vendor':<18} {'Name':<32} {'Source'}")
    print("-" * 100)
    for r in rows:
        print(f"{r['ip']:<16} {r['mac']:<19} {(r['vendor'] or '')[:18]:<18} {(r['name'] or '')[:32]:<32} {r['source']}")
PY
