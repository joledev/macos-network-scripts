#!/usr/bin/env bash
# UPnP / SSDP discovery — enumerate devices that announce themselves over
# Simple Service Discovery Protocol.
#
# How it works:
#   1. Send an M-SEARCH multicast to 239.255.255.250:1900 (ssdp:all).
#   2. Collect unicast responses: ST, USN, SERVER, LOCATION headers.
#   3. Fetch each LOCATION device-description XML and parse
#      friendlyName / manufacturer / modelName / modelNumber / deviceType /
#      serialNumber / presentationURL.
#
# This surfaces smart TVs, media servers (DLNA/Plex), routers/gateways
# (InternetGatewayDevice — often exposes the WAN IP + port mappings),
# printers, NAS boxes, repeaters and consoles. No sudo, no raw packets —
# just one multicast query plus HTTP GETs to the URLs devices advertise.
#
# Output: JSON / md / text.
#
# Usage: ssdp.sh [--duration N] [--st <search-target>] [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
DURATION=4
SEARCH_TARGET="ssdp:all"

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --duration)
      [[ -n "${2:-}" ]] || die_usage "--duration requires seconds"
      DURATION="$2"; shift 2 ;;
    --st)
      [[ -n "${2:-}" ]] || die_usage "--st requires a search target"
      SEARCH_TARGET="$2"; shift 2 ;;
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
  log_dry "ssdp would:"
  log_dry "  m-search   : UDP multicast 239.255.255.250:1900 ST=${SEARCH_TARGET} (${DURATION}s)"
  log_dry "  fetch      : HTTP GET each advertised LOCATION (device description XML)"
  log_dry "no traffic sent."
  exit 0
fi

log_info "SSDP M-SEARCH (ST=${SEARCH_TARGET}, ${DURATION}s window)..."

export NETKIT_FMT="$FORMAT" NETKIT_DURATION="$DURATION" NETKIT_ST="$SEARCH_TARGET"

python3 - <<'PY'
import concurrent.futures, json, os, re, socket, sys, time
import urllib.request

fmt      = os.environ["NETKIT_FMT"]
duration = int(os.environ["NETKIT_DURATION"])
st       = os.environ["NETKIT_ST"]

MCAST = ("239.255.255.250", 1900)
MSEARCH = (
    "M-SEARCH * HTTP/1.1\r\n"
    "HOST: 239.255.255.250:1900\r\n"
    'MAN: "ssdp:discover"\r\n'
    f"MX: 2\r\n"
    f"ST: {st}\r\n"
    "USER-AGENT: netkit/0.2 UPnP/1.1\r\n\r\n"
).encode()


def discover():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    sock.settimeout(0.5)
    # Send twice — SSDP responses are best-effort UDP.
    sock.sendto(MSEARCH, MCAST)
    sock.sendto(MSEARCH, MCAST)
    end = time.time() + duration
    seen = {}
    while time.time() < end:
        try:
            data, addr = sock.recvfrom(8192)
        except socket.timeout:
            continue
        text = data.decode(errors="replace")
        hdr = {}
        for ln in text.splitlines()[1:]:
            if ":" in ln:
                k, v = ln.split(":", 1)
                hdr[k.strip().upper()] = v.strip()
        ip = addr[0]
        loc = hdr.get("LOCATION", "")
        # One row per distinct device description (LOCATION). Devices re-announce
        # the same endpoint many times; collapse them and merge the STs.
        key = (ip, loc) if loc else (ip, hdr.get("USN", "") or hdr.get("ST", ""))
        rec = seen.setdefault(key, {
            "ip": ip, "server": hdr.get("SERVER", ""),
            "st": hdr.get("ST", ""), "usn": hdr.get("USN", ""),
            "location": loc, "targets": [],
        })
        if hdr.get("ST") and hdr["ST"] not in rec["targets"]:
            rec["targets"].append(hdr["ST"])
    sock.close()
    return list(seen.values())


XML_FIELDS = {
    "friendlyName": "friendly_name",
    "manufacturer": "manufacturer",
    "modelName": "model_name",
    "modelNumber": "model_number",
    "modelDescription": "model_description",
    "deviceType": "device_type",
    "serialNumber": "serial",
    "presentationURL": "presentation_url",
}


def fetch_desc(loc):
    if not loc:
        return {}
    try:
        req = urllib.request.Request(loc, headers={"User-Agent": "netkit/0.2"})
        with urllib.request.urlopen(req, timeout=3) as r:
            body = r.read(65536).decode(errors="replace")
    except Exception:
        return {}
    out = {}
    for tag, key in XML_FIELDS.items():
        m = re.search(rf"<{tag}>([^<]+)</{tag}>", body)
        if m and key not in out:
            out[key] = m.group(1).strip()
    return out


records = discover()

# Enrich each unique LOCATION with its device-description XML (in parallel).
locs = {r["location"] for r in records if r.get("location")}
desc_by_loc = {}
if locs:
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(12, len(locs))) as ex:
        for loc, d in zip(locs, ex.map(fetch_desc, locs)):
            desc_by_loc[loc] = d
for r in records:
    d = desc_by_loc.get(r.get("location"), {})
    r.update(d)

# Collapse to one row per (ip, friendly_name|usn) for readability.
records.sort(key=lambda r: (tuple(int(x) for x in r["ip"].split(".")) if re.match(r"^\d+\.\d+\.\d+\.\d+$", r["ip"]) else (0,), r.get("friendly_name", "")))

if fmt == "json":
    print(json.dumps({"count": len(records), "devices": records}, indent=2))
    sys.exit(0)

if fmt == "md":
    print(f"# UPnP / SSDP devices ({len(records)})\n")
    if not records:
        print("_no UPnP devices responded._"); sys.exit(0)
    print("| IP | Friendly name | Manufacturer | Model | Device type | Server |")
    print("| --- | --- | --- | --- | --- | --- |")
    for r in records:
        cells = [r["ip"], r.get("friendly_name", ""), r.get("manufacturer", ""),
                 " ".join(x for x in (r.get("model_name", ""), r.get("model_number", "")) if x),
                 r.get("device_type", "").split(":")[-2] if r.get("device_type") else "",
                 r.get("server", "")]
        print("| " + " | ".join(str(c).replace("|", r"\|") for c in cells) + " |")
    sys.exit(0)

# text
print(f"UPnP / SSDP discovery — {len(records)} announcement(s)\n")
if not records:
    print("(no UPnP devices responded — some networks isolate SSDP per-client)")
    sys.exit(0)
for r in records:
    name = r.get("friendly_name") or r.get("server") or r.get("st") or "?"
    print(f"{r['ip']:<15} {name}")
    if r.get("manufacturer") or r.get("model_name"):
        print(f"    device   : {r.get('manufacturer','')} {r.get('model_name','')} {r.get('model_number','')}".rstrip())
    if r.get("device_type"):
        print(f"    type     : {r['device_type']}")
    if r.get("serial"):
        print(f"    serial   : {r['serial']}")
    if r.get("server"):
        print(f"    server   : {r['server']}")
    if r.get("location"):
        print(f"    location : {r['location']}")
    print()
PY
