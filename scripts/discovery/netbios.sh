#!/usr/bin/env bash
# NetBIOS name discovery — pull hostnames, workgroup/domain and the adapter MAC
# from any host running the NetBIOS Name Service (Windows PCs, NAS/Samba boxes,
# printers). Sends a UDP/137 NBSTAT "node status" query and parses the reply.
#
# This fills the rows ARP leaves blank: a Windows laptop or a NAS that exposes
# nothing over mDNS/SSDP will still answer NBSTAT with its name and workgroup.
#
# No sudo, no raw packets — a normal UDP datagram per host.
#
# Output: JSON / md / text.
#
# Usage: netbios.sh [--hosts ip1,ip2,...] [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
HOSTS_CSV=""

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --hosts)
      [[ -n "${2:-}" ]] || die_usage "--hosts requires a comma-separated IP list"
      HOSTS_CSV="$2"; shift 2 ;;
    --yes) export NETKIT_YES=1; shift ;;
    --allow-raw) export NETKIT_ALLOW_RAW=1; shift ;;
    --dry-run) export NETKIT_DRY_RUN=1; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) die_usage "Unknown flag: $1" ;;
  esac
done

if [[ -n "$HOSTS_CSV" ]]; then
  IFS=',' read -r -a _HOST_ARR <<< "$HOSTS_CSV"
  for _h in "${_HOST_ARR[@]}"; do
    _h="${_h// /}"; [[ -z "$_h" ]] && continue
    [[ "$_h" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
      || die_usage "--hosts contains invalid token: '${_h}' (expected IPv4)"
  done
fi

guard_no_sudo

if [[ -z "$HOSTS_CSV" ]]; then
  _self_ips="$(all_local_ipv4 2>/dev/null | paste -sd'|' -)"
  HOSTS_CSV="$(arp -an 2>/dev/null \
    | grep -v incomplete \
    | awk '/\(/ {gsub(/[()]/, "", $2); print $2}' \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
    | grep -vE '^(22[4-9]|23[0-9])\.' | grep -vE '^255\.255\.255\.255$' \
    | { if [[ -n "$_self_ips" ]]; then grep -vE "^(${_self_ips})$"; else cat; fi; } \
    | sort -u | paste -sd, -)"
fi
[[ -z "$HOSTS_CSV" ]] && die "No hosts. Run 'netkit discover --active' first or pass --hosts."

HOST_COUNT=$(printf '%s' "$HOSTS_CSV" | tr ',' '\n' | grep -c .)

if dry_run; then
  log_dry "netbios would:"
  log_dry "  query  : UDP/137 NBSTAT node-status to ${HOST_COUNT} host(s)"
  log_dry "  hosts  : ${HOSTS_CSV}"
  log_dry "no traffic sent."
  exit 0
fi

log_info "NBSTAT querying ${HOST_COUNT} host(s) on UDP/137..."

export NETKIT_FMT="$FORMAT" NETKIT_HOSTS_CSV="$HOSTS_CSV" NETKIT_ROOT

python3 - <<'PY'
import concurrent.futures, json, os, random, re, socket, struct, sys

sys.path.insert(0, os.path.join(os.environ["NETKIT_ROOT"], "scripts/utils"))
try:
    import oui
except ImportError:
    oui = None

fmt   = os.environ["NETKIT_FMT"]
hosts = [h.strip() for h in os.environ["NETKIT_HOSTS_CSV"].split(",") if h.strip()]

# NetBIOS suffixes that name a useful service/role.
SUFFIX_ROLE = {
    0x00: "workstation", 0x20: "file-server", 0x1B: "domain-master",
    0x1C: "domain-controller", 0x1D: "master-browser", 0x1E: "browser",
    0x03: "messenger", 0x06: "ras-server", 0x21: "ras-client",
}


def build_query():
    txid = random.randint(0, 0xFFFF)
    header = struct.pack(">HHHHHH", txid, 0x0000, 1, 0, 0, 0)
    # First-level encode the wildcard name "*" (padded to 16 bytes with NULs).
    name = b"*" + b"\x00" * 15
    enc = bytearray()
    for b in name:
        enc.append((b >> 4) + 0x41)
        enc.append((b & 0x0F) + 0x41)
    question = bytes([0x20]) + bytes(enc) + b"\x00" + struct.pack(">HH", 0x0021, 0x0001)
    return header + question, txid


def _skip_name(buf, off):
    while off < len(buf):
        ln = buf[off]
        if ln == 0:
            return off + 1
        if ln & 0xC0 == 0xC0:        # compression pointer (2 bytes)
            return off + 2
        off += 1 + ln
    return off


def query(ip):
    pkt, _ = build_query()
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(1.2)
        s.sendto(pkt, (ip, 137))
        data, _ = s.recvfrom(2048)
        s.close()
    except (OSError, socket.timeout):
        return None
    if len(data) < 12:
        return None
    off = 12
    off = _skip_name(data, off)        # question name
    off += 4                            # question type+class
    off = _skip_name(data, off)        # answer name
    if off + 10 > len(data):
        return None
    _typ, _cls, _ttl, rdlen = struct.unpack(">HHIH", data[off:off+10])
    off += 10
    rdata = data[off:off+rdlen]
    if not rdata:
        return None
    num = rdata[0]
    p = 1
    names = []
    for _ in range(num):
        if p + 18 > len(rdata):
            break
        nm = rdata[p:p+15].decode("ascii", "replace").rstrip()
        suffix = rdata[p+15]
        flags = struct.unpack(">H", rdata[p+16:p+18])[0]
        group = bool(flags & 0x8000)
        names.append({"name": nm, "suffix": suffix, "group": group,
                      "role": SUFFIX_ROLE.get(suffix, f"0x{suffix:02x}")})
        p += 18
    mac = ""
    if p + 6 <= len(rdata):
        mac = ":".join(f"{b:02x}" for b in rdata[p:p+6])
        if mac == "00:00:00:00:00:00":
            mac = ""

    hostname = workgroup = ""
    services = []
    for n in names:
        if n["suffix"] == 0x00 and not n["group"] and not hostname:
            hostname = n["name"]
        elif n["suffix"] == 0x00 and n["group"] and not workgroup:
            workgroup = n["name"]
        if n["suffix"] in (0x20, 0x1B, 0x1C, 0x1D):
            services.append(n["role"])
    rec = {"ip": ip, "hostname": hostname, "workgroup": workgroup,
           "services": sorted(set(services)), "names": names}
    if mac:
        rec["mac"] = mac
        if oui is not None:
            rec["vendor"] = oui.lookup(mac)
    return rec


results = []
with concurrent.futures.ThreadPoolExecutor(max_workers=min(32, max(1, len(hosts)))) as ex:
    for r in ex.map(query, hosts):
        if r and (r.get("hostname") or r.get("names")):
            results.append(r)
results.sort(key=lambda r: tuple(int(x) for x in r["ip"].split(".")))

if fmt == "json":
    print(json.dumps({"count": len(results), "hosts": results}, indent=2))
elif fmt == "md":
    print(f"# NetBIOS hosts ({len(results)})\n")
    if not results:
        print("_no host answered NBSTAT (no NetBIOS/SMB on this LAN)._"); sys.exit(0)
    print("| IP | Hostname | Workgroup | Services | MAC | Vendor |")
    print("| --- | --- | --- | --- | --- | --- |")
    for r in results:
        print(f"| {r['ip']} | {r.get('hostname','')} | {r.get('workgroup','')} | "
              f"{', '.join(r.get('services',[]))} | {r.get('mac','')} | {r.get('vendor','')} |")
else:
    print(f"NetBIOS / NBNS — {len(results)} host(s) answered\n")
    if not results:
        print("(no host answered NBSTAT — no NetBIOS/SMB on this LAN)")
        sys.exit(0)
    print(f"{'IP':<15} {'hostname':<18} {'workgroup':<16} {'services'}")
    print("-" * 90)
    for r in results:
        print(f"{r['ip']:<15} {r.get('hostname',''):<18} {r.get('workgroup',''):<16} "
              f"{', '.join(r.get('services',[]))}")
PY
