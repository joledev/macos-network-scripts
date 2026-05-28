#!/usr/bin/env bash
# WS-Discovery (general) — enumerate devices that speak WS-Discovery, not just
# ONVIF cameras. A type-less Probe to 239.255.255.250:3702 makes Windows PCs
# (Function Discovery / WSD), network printers and scanners announce their
# device Types and metadata URL (XAddrs, which carries the IP).
#
# `cameras` sends the same probe but filters for ONVIF video types; this drops
# the filter so everything answers. No sudo — one UDP multicast plus replies.
#
# Output: JSON / md / text.
#
# Usage: wsd.sh [--duration N] [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
DURATION=4

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --duration)
      [[ -n "${2:-}" ]] || die_usage "--duration requires seconds"
      DURATION="$2"; shift 2 ;;
    --yes) export NETKIT_YES=1; shift ;;
    --allow-raw) export NETKIT_ALLOW_RAW=1; shift ;;
    --dry-run) export NETKIT_DRY_RUN=1; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) die_usage "Unknown flag: $1" ;;
  esac
done

[[ "$DURATION" =~ ^[0-9]+$ ]] && (( DURATION >= 1 && DURATION <= 30 )) \
  || die_usage "--duration must be 1..30"

guard_no_sudo

if dry_run; then
  log_dry "wsd would:"
  log_dry "  probe   : UDP multicast 239.255.255.250:3702 (type-less WS-Discovery Probe, ${DURATION}s)"
  log_dry "  parse   : ProbeMatch Types + XAddrs (device class + metadata URL/IP)"
  log_dry "no traffic sent."
  exit 0
fi

log_info "WS-Discovery probe (UDP 3702 multicast, ${DURATION}s window)..."

export NETKIT_FMT="$FORMAT" NETKIT_DURATION="$DURATION"

python3 - <<'PY'
import json, os, re, socket, sys, time, uuid

fmt      = os.environ["NETKIT_FMT"]
duration = int(os.environ["NETKIT_DURATION"])

ADDR = ("239.255.255.250", 3702)
PROBE = """<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
            xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
            xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery">
  <e:Header>
    <w:MessageID>uuid:{u}</w:MessageID>
    <w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
    <w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
  </e:Header>
  <e:Body><d:Probe/></e:Body>
</e:Envelope>"""

# Friendly labels for the common WS-Discovery device types.
TYPE_HINT = [
    (r"PrintDeviceType|PrinterServiceType|wprt:", "printer"),
    (r"ScanDeviceType|wscn:", "scanner"),
    (r"Computer|pub:Computer", "windows computer"),
    (r"NetworkVideoTransmitter|onvif", "camera"),
    (r"MediaServer|MediaRenderer", "media device"),
]


def hint(types: str) -> str:
    for pat, name in TYPE_HINT:
        if re.search(pat, types, re.I):
            return name
    return ""


def discover():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.settimeout(0.5)
    sock.sendto(PROBE.format(u=uuid.uuid4()).encode(), ADDR)
    sock.sendto(PROBE.format(u=uuid.uuid4()).encode(), ADDR)
    end = time.time() + duration
    by_ip = {}
    while time.time() < end:
        try:
            data, addr = sock.recvfrom(8192)
        except socket.timeout:
            continue
        body = data.decode(errors="replace")
        types = " ".join(re.findall(r":Types>([^<]+)<", body))
        xaddrs = []
        for m in re.finditer(r":XAddrs>([^<]+)<", body):
            xaddrs.extend(m.group(1).split())
        ip = addr[0]
        rec = by_ip.setdefault(ip, {"ip": ip, "types": "", "xaddrs": [], "hint": ""})
        if types and not rec["types"]:
            rec["types"] = types.strip()
            rec["hint"] = hint(types)
        for x in xaddrs:
            if x not in rec["xaddrs"]:
                rec["xaddrs"].append(x)
    sock.close()
    return list(by_ip.values())


records = sorted(discover(), key=lambda r: tuple(int(x) for x in r["ip"].split(".")) if re.match(r"^\d+\.\d+\.\d+\.\d+$", r["ip"]) else (0,))

if fmt == "json":
    print(json.dumps({"count": len(records), "devices": records}, indent=2))
elif fmt == "md":
    print(f"# WS-Discovery devices ({len(records)})\n")
    if not records:
        print("_no WS-Discovery responders (no Windows/printer WSD on this LAN)._"); sys.exit(0)
    print("| IP | Kind | Types | Metadata URL |")
    print("| --- | --- | --- | --- |")
    for r in records:
        print(f"| {r['ip']} | {r.get('hint','')} | {r.get('types','')} | "
              f"{', '.join(r.get('xaddrs',[]))} |".replace("\n", " "))
else:
    print(f"WS-Discovery — {len(records)} responder(s)\n")
    if not records:
        print("(no WS-Discovery responders — no Windows/printer WSD on this LAN)")
        sys.exit(0)
    for r in records:
        print(f"{r['ip']:<15} {r.get('hint','') or '?'}")
        if r.get("types"):
            print(f"    types : {r['types']}")
        for x in r.get("xaddrs", []):
            print(f"    url   : {x}")
PY
