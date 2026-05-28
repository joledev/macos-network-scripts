#!/usr/bin/env bash
# IPv6 neighbor discovery — list hosts visible over IPv6 (NDP), which ARP/IPv4
# discovery misses entirely. Pings the all-nodes multicast group (ff02::1) to
# populate the neighbor cache, then reads it via `ndp -an`, attaching the OUI
# vendor for each link-layer address.
#
# Modern devices (Apple, IoT, Windows) are often reachable over link-local
# IPv6 even when their IPv4 is quiet — so this surfaces hosts nothing else sees.
# No sudo: pinging multicast and reading the neighbor cache need no privileges.
#
# Output: JSON / md / text.
#
# Usage: ndp.sh [--interface en7] [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
IFACE=""

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --interface)
      [[ -n "${2:-}" ]] || die_usage "--interface requires a value"
      IFACE="$2"; shift 2 ;;
    --yes) export NETKIT_YES=1; shift ;;
    --allow-raw) export NETKIT_ALLOW_RAW=1; shift ;;
    --dry-run) export NETKIT_DRY_RUN=1; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) die_usage "Unknown flag: $1" ;;
  esac
done

guard_no_sudo
[[ -z "$IFACE" ]] && IFACE=$(pick_interface || echo "")

if dry_run; then
  log_dry "ndp would:"
  log_dry "  seed   : ping6 -c 2 ff02::1%${IFACE:-<iface>} (all-nodes multicast)"
  log_dry "  read   : ndp -an  (IPv6 neighbor cache)"
  log_dry "no privileged ops."
  exit 0
fi

# Seed the neighbor cache: ping the all-nodes multicast group. Best effort.
if [[ -n "$IFACE" ]] && has_cmd ping6; then
  log_info "Seeding IPv6 neighbor cache via ff02::1%${IFACE}..."
  ping6 -c 2 -i 0.3 "ff02::1%${IFACE}" >/dev/null 2>&1 || true
fi

# Our own interface MACs, so we don't list this Mac as a neighbor.
SELF_MACS="$(ifconfig 2>/dev/null | awk '/[ \t]ether /{print tolower($2)}' | paste -sd, -)"
export NETKIT_FMT="$FORMAT" NETKIT_ROOT NETKIT_IFACE="$IFACE" NETKIT_SELF_MACS="$SELF_MACS"

python3 - <<'PY'
import json, os, re, subprocess, sys

sys.path.insert(0, os.path.join(os.environ["NETKIT_ROOT"], "scripts/utils"))
try:
    import oui
except ImportError:
    oui = None

fmt = os.environ["NETKIT_FMT"]
want_iface = os.environ.get("NETKIT_IFACE", "")
self_macs = {m.strip() for m in os.environ.get("NETKIT_SELF_MACS", "").split(",") if m.strip()}

try:
    out = subprocess.run(["ndp", "-an"], capture_output=True, text=True, timeout=10).stdout
except (OSError, subprocess.TimeoutExpired):
    out = ""

# ndp -an columns: Neighbor  Linklayer-Address  Netif  Expire  St  Flgs  Prbs
rows = {}
for ln in out.splitlines():
    parts = ln.split()
    if len(parts) < 3:
        continue
    addr = parts[0]
    mac = parts[1]
    netif = parts[2]
    if not re.match(r"^[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}$", mac):
        continue  # header / "(incomplete)" rows
    if mac.lower() in self_macs:
        continue  # this Mac's own interfaces
    addr_only = addr.split("%")[0]
    scope = addr.split("%")[1] if "%" in addr else netif
    # Skip our own and multicast/anycast-ish entries.
    if addr_only.startswith("ff") or addr_only in ("::", "::1"):
        continue
    rec = rows.setdefault((addr_only, scope), {
        "address": addr_only, "interface": scope, "mac": mac.lower(),
        "link_local": addr_only.lower().startswith("fe80"),
    })
    if oui is not None:
        rec["vendor"] = oui.lookup(mac.lower())

records = list(rows.values())
if want_iface:
    # Prefer the active interface but keep all if the filter empties the list.
    filt = [r for r in records if r["interface"] == want_iface]
    if filt:
        records = filt
records.sort(key=lambda r: (not r["link_local"], r["address"]))

if fmt == "json":
    print(json.dumps({"count": len(records), "neighbors": records}, indent=2))
elif fmt == "md":
    print(f"# IPv6 neighbors ({len(records)})\n")
    if not records:
        print("_no IPv6 neighbors in the cache._"); sys.exit(0)
    print("| IPv6 | MAC | Vendor | Iface | Scope |")
    print("| --- | --- | --- | --- | --- |")
    for r in records:
        scope = "link-local" if r["link_local"] else "global"
        print(f"| {r['address']} | {r['mac']} | {r.get('vendor','')} | {r['interface']} | {scope} |")
else:
    print(f"IPv6 neighbors — {len(records)}\n")
    if not records:
        print("(no IPv6 neighbors in the cache)")
        sys.exit(0)
    print(f"{'IPv6':<28} {'MAC':<19} {'vendor':<22} iface")
    print("-" * 90)
    for r in records:
        print(f"{r['address'][:28]:<28} {r['mac']:<19} {(r.get('vendor','') or '')[:22]:<22} {r['interface']}")
PY
