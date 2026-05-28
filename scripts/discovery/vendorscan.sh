#!/usr/bin/env bash
# Vendor-specific discovery — speak proprietary LAN discovery protocols to pull
# the EXACT make/model that generic HTTP/TLS fingerprinting can't.
#
# Probes (all UDP broadcast, no sudo):
#   * TP-Link Kasa      UDP 9999  — XOR-autokey "get_sysinfo" (plugs, bulbs,
#                                   older cams): alias, model, hw/sw, mac.
#   * TP-Link Tapo/TDP  UDP 20002 — TDP probe; reply carries device_model + mac
#                                   even when the rest is encrypted.
#   * MikroTik MNDP     UDP 5678  — unencrypted TLVs: identity, version,
#                                   platform, board, software-id, uptime.
#
# Output: JSON / md / text.
#
# Usage: vendorscan.sh [--duration N] [--json|--md|--text]

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
  log_dry "vendorscan would broadcast (UDP, ${DURATION}s):"
  log_dry "  TP-Link Kasa     : 255.255.255.255:9999  (XOR get_sysinfo)"
  log_dry "  TP-Link Tapo/TDP : 255.255.255.255:20002 (TDP probe)"
  log_dry "  MikroTik MNDP    : 255.255.255.255:5678   (TLV)"
  log_dry "no traffic sent."
  exit 0
fi

log_info "vendorscan: Kasa/Tapo/MNDP broadcast probes (${DURATION}s)..."

export NETKIT_FMT="$FORMAT" NETKIT_DURATION="$DURATION" NETKIT_ROOT

python3 - <<'PY'
import json, os, socket, struct, sys, time

sys.path.insert(0, os.path.join(os.environ["NETKIT_ROOT"], "scripts/utils"))
try:
    import oui
except ImportError:
    oui = None

fmt      = os.environ["NETKIT_FMT"]
duration = int(os.environ["NETKIT_DURATION"])


def bcast_socket():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.bind(("", 0))
    s.settimeout(0.5)
    return s


# ---- TP-Link Kasa (UDP 9999, XOR autokey, init key 0xAB) ----
def kasa_crypt(data: bytes, decrypt: bool) -> bytes:
    key = 0xAB
    out = bytearray()
    for b in data:
        c = b ^ key
        out.append(c)
        key = b if decrypt else c
    return bytes(out)


def kasa_scan(deadline):
    s = bcast_socket()
    payload = kasa_crypt(b'{"system":{"get_sysinfo":{}}}', decrypt=False)
    try:
        s.sendto(payload, ("255.255.255.255", 9999))
    except OSError:
        s.close(); return {}
    found = {}
    while time.time() < deadline:
        try:
            data, addr = s.recvfrom(4096)
        except socket.timeout:
            continue
        try:
            info = json.loads(kasa_crypt(data, decrypt=True).decode(errors="replace"))
            sysinfo = info.get("system", {}).get("get_sysinfo", {})
        except Exception:
            continue
        if sysinfo:
            found[addr[0]] = {
                "ip": addr[0], "protocol": "kasa",
                "model": sysinfo.get("model", ""),
                "name": sysinfo.get("alias", "") or sysinfo.get("dev_name", ""),
                "mac": (sysinfo.get("mac") or sysinfo.get("mic_mac") or "").lower(),
                "hw_ver": sysinfo.get("hw_ver", ""), "sw_ver": sysinfo.get("sw_ver", ""),
                "type": sysinfo.get("mic_type") or sysinfo.get("type", ""),
            }
    s.close()
    return found


# ---- TP-Link Tapo / TDP (UDP 20002) ----
def tapo_scan(deadline):
    s = bcast_socket()
    probe = bytes.fromhex("020000010000000000000000463cb5d3")
    try:
        s.sendto(probe, ("255.255.255.255", 20002))
    except OSError:
        s.close(); return {}
    found = {}
    while time.time() < deadline:
        try:
            data, addr = s.recvfrom(4096)
        except socket.timeout:
            continue
        # The JSON result trails a 16-byte header; some fields stay readable.
        start = data.find(b"{")
        if start < 0:
            continue
        try:
            obj = json.loads(data[start:].decode(errors="replace"))
            res = obj.get("result", obj)
        except Exception:
            continue
        model = res.get("device_model") or res.get("model") or ""
        if model or res.get("mac"):
            found[addr[0]] = {
                "ip": addr[0], "protocol": "tapo/tdp", "model": model,
                "name": res.get("device_name", "") or res.get("nickname", ""),
                "mac": (res.get("mac") or "").lower().replace("-", ":"),
                "type": res.get("device_type", ""),
                "fw": res.get("fw_ver", ""),
            }
    s.close()
    return found


# ---- MikroTik MNDP (UDP 5678, unencrypted TLVs) ----
MNDP_TLV = {1: "mac", 5: "identity", 7: "version", 8: "platform",
            10: "uptime", 11: "software_id", 12: "board", 15: "ipv6",
            16: "interface"}


def mndp_scan(deadline):
    s = bcast_socket()
    try:
        s.sendto(b"\x00\x00\x00\x00", ("255.255.255.255", 5678))
    except OSError:
        s.close(); return {}
    found = {}
    while time.time() < deadline:
        try:
            data, addr = s.recvfrom(4096)
        except socket.timeout:
            continue
        rec = {"ip": addr[0], "protocol": "mndp"}
        i = 4  # skip the 2-byte header + 2-byte seq
        while i + 4 <= len(data):
            t, ln = struct.unpack(">HH", data[i:i+4])
            v = data[i+4:i+4+ln]
            i += 4 + ln
            key = MNDP_TLV.get(t)
            if not key:
                continue
            if key == "mac" and len(v) == 6:
                rec["mac"] = ":".join(f"{b:02x}" for b in v)
            elif key == "uptime" and len(v) == 4:
                rec["uptime_s"] = struct.unpack("<I", v)[0]
            else:
                rec[key] = v.decode(errors="replace").strip("\x00")
        if len(rec) > 2:
            found[addr[0]] = rec
    s.close()
    return found


deadline = time.time() + duration
merged = {}
for scan in (kasa_scan, tapo_scan, mndp_scan):
    for ip, rec in scan(deadline).items():
        if ip in merged:
            merged[ip].update({k: v for k, v in rec.items() if v})
        else:
            merged[ip] = rec

for rec in merged.values():
    if rec.get("mac") and oui is not None and not rec.get("vendor"):
        rec["vendor"] = oui.lookup(rec["mac"])

records = sorted(merged.values(),
                 key=lambda r: tuple(int(x) for x in r["ip"].split(".")))

if fmt == "json":
    print(json.dumps({"count": len(records), "devices": records}, indent=2))
elif fmt == "md":
    print(f"# Vendor-protocol devices ({len(records)})\n")
    if not records:
        print("_no device answered Kasa/Tapo/MNDP (none present on this LAN)._"); sys.exit(0)
    print("| IP | Protocol | Model | Name | MAC | Version |")
    print("| --- | --- | --- | --- | --- | --- |")
    for r in records:
        print(f"| {r['ip']} | {r.get('protocol','')} | {r.get('model','')} | "
              f"{r.get('name','') or r.get('identity','')} | {r.get('mac','')} | "
              f"{r.get('sw_ver','') or r.get('version','') or r.get('fw','')} |")
else:
    print(f"vendorscan — {len(records)} device(s) answered a vendor probe\n")
    if not records:
        print("(no device answered Kasa/Tapo/MNDP — none present on this LAN)")
        sys.exit(0)
    for r in records:
        print(f"{r['ip']:<15} [{r.get('protocol','')}] {r.get('model','')} "
              f"{r.get('name','') or r.get('identity','')}")
        for k in ("mac", "hw_ver", "sw_ver", "version", "platform", "board", "fw", "uptime_s"):
            if r.get(k):
                print(f"    {k:<9}: {r[k]}")
PY
