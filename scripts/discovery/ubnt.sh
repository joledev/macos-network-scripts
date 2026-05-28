#!/usr/bin/env bash
# Ubiquiti device discovery — find UniFi / airMAX / EdgeMax / AmpliFi gear
# that speaks the UBNT discovery protocol.
#
# How it works:
#   Ubiquiti devices listen on UDP 10001 and answer a small discovery probe
#   with a TLV-encoded packet describing themselves. We broadcast the v1
#   probe (and a v2 probe) to 255.255.255.250 / 255.255.255.255:10001 and
#   parse the replies: MAC, IP, firmware, model (short + full), hostname,
#   ESSID, uptime.
#
# This is how the UniFi mobile app and `ubnt-discover` find access points,
# switches, gateways, antennas and repeaters even before they're adopted.
# No sudo, no raw packets — a broadcast UDP datagram and its replies.
#
# Output: JSON / md / text.
#
# Usage: ubnt.sh [--duration N] [--json|--md|--text]

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
  log_dry "ubnt would:"
  log_dry "  probe      : UDP broadcast 255.255.255.255:10001 (v1 + v2 UBNT discovery, ${DURATION}s)"
  log_dry "  parse      : TLV reply -> mac/ip/firmware/model/hostname/uptime"
  log_dry "no traffic sent."
  exit 0
fi

log_info "Ubiquiti discovery probe (UDP/10001 broadcast, ${DURATION}s window)..."

export NETKIT_FMT="$FORMAT" NETKIT_DURATION="$DURATION"

python3 - <<'PY'
import json, os, socket, struct, sys, time

fmt      = os.environ["NETKIT_FMT"]
duration = int(os.environ["NETKIT_DURATION"])

PORT = 10001
# v1 and v2 discovery probes (the UniFi app sends both).
PROBES = [b"\x01\x00\x00\x00", b"\x02\x08\x00\x00"]
DESTS = ["255.255.255.255", "233.89.188.1"]

# TLV field types in a UBNT discovery reply.
TLV_STR = {
    0x03: "firmware",
    0x0B: "hostname",
    0x0C: "model_short",
    0x0D: "essid",
    0x14: "model",        # full model name, e.g. "UAP-AC-Pro"
    0x15: "model_short2",
    0x16: "seq",
    0x18: "model_full",
}


def parse(data, src_ip):
    rec = {"ip": src_ip, "macs": [], "ips": []}
    if len(data) < 4:
        return None
    # header: version, cmd, payload-length (2 bytes)
    try:
        _ver, _cmd, plen = data[0], data[1], struct.unpack(">H", data[2:4])[0]
    except struct.error:
        return None
    i = 4
    end = min(len(data), 4 + plen) if plen else len(data)
    found_any = False
    while i + 3 <= end:
        t = data[i]
        ln = struct.unpack(">H", data[i+1:i+3])[0]
        v = data[i+3:i+3+ln]
        i += 3 + ln
        if len(v) < ln:
            break
        found_any = True
        if t == 0x01 and ln == 6:                  # MAC only
            rec["macs"].append(v.hex(":"))
        elif t == 0x02 and ln == 10:               # MAC + IP
            rec["macs"].append(v[:6].hex(":"))
            rec["ips"].append(socket.inet_ntoa(v[6:10]))
        elif t == 0x0A and ln == 4:                # uptime (seconds)
            rec["uptime_s"] = struct.unpack(">I", v)[0]
        elif t in TLV_STR:
            rec[TLV_STR[t]] = v.decode(errors="replace").strip("\x00").strip()
        # other TLVs (wmode, sequence, etc.) ignored
    return rec if found_any else None


def discover():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
    sock.bind(("", 0))
    sock.settimeout(0.5)
    for probe in PROBES:
        for dest in DESTS:
            try:
                sock.sendto(probe, (dest, PORT))
            except OSError:
                pass
    end = time.time() + duration
    by_dev = {}
    while time.time() < end:
        try:
            data, addr = sock.recvfrom(8192)
        except socket.timeout:
            continue
        rec = parse(data, addr[0])
        if not rec:
            continue
        key = rec["macs"][0] if rec.get("macs") else addr[0]
        prev = by_dev.get(key)
        if prev:
            prev.update({k: v for k, v in rec.items() if v})
        else:
            by_dev[key] = rec
    sock.close()
    return list(by_dev.values())


records = discover()
records.sort(key=lambda r: r.get("ip", ""))

if fmt == "json":
    print(json.dumps({"count": len(records), "devices": records}, indent=2))
    sys.exit(0)

if fmt == "md":
    print(f"# Ubiquiti devices ({len(records)})\n")
    if not records:
        print("_no Ubiquiti devices answered the discovery probe._"); sys.exit(0)
    print("| IP | Model | Full model | Hostname | Firmware | MAC | Uptime (s) |")
    print("| --- | --- | --- | --- | --- | --- | --- |")
    for r in records:
        cells = [r.get("ip", ""), r.get("model", "") or r.get("model_short", ""),
                 r.get("model_full", ""), r.get("hostname", ""), r.get("firmware", ""),
                 (r.get("macs") or [""])[0], r.get("uptime_s", "")]
        print("| " + " | ".join(str(c).replace("|", r"\|") for c in cells) + " |")
    sys.exit(0)

# text
print(f"Ubiquiti discovery — {len(records)} device(s)\n")
if not records:
    print("(no Ubiquiti devices answered — none present, or discovery is")
    print(" blocked by client/AP isolation on this segment)")
    sys.exit(0)
for r in records:
    print(f"{r.get('ip',''):<15} {r.get('model','') or r.get('model_short','')}  {r.get('hostname','')}")
    if r.get("model_full"):
        print(f"    model    : {r['model_full']}")
    if r.get("firmware"):
        print(f"    firmware : {r['firmware']}")
    if r.get("essid"):
        print(f"    essid    : {r['essid']}")
    if r.get("macs"):
        print(f"    macs     : {', '.join(r['macs'])}")
    if r.get("ips"):
        print(f"    ips      : {', '.join(r['ips'])}")
    if r.get("uptime_s") is not None:
        print(f"    uptime   : {r.get('uptime_s')} s")
    print()
PY
