#!/usr/bin/env bash
# TP-Link Omada / EAP discovery — detect Omada-managed access points, switches
# and gateways that broadcast on UDP 29810, and (when a key is supplied) decode
# the AES-128 body to reveal model / firmware / MAC / device name.
#
# Omada EAPs broadcast a discovery datagram to 255.255.255.255:29810 (the same
# port the controller listens on). We bind that port, listen, and also send a
# probe. The header (version/opcode/length) is plaintext; the JSON body is
# AES-128-ECB encrypted with a firmware-baked key. There is no public decoder,
# so by default we DETECT the device + dump the header/body hex; if you supply
# NETKIT_OMADA_KEY (32 hex chars) we decrypt via openssl and parse the JSON.
#
# No sudo (UDP listen/broadcast on a high port).
#
# Output: JSON / md / text.
#
# Usage: omada.sh [--duration N] [--json|--md|--text]
#   NETKIT_OMADA_KEY=<32-hex>   AES-128-ECB key to decrypt the body (optional)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
DURATION=12

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

[[ "$DURATION" =~ ^[0-9]+$ ]] && (( DURATION >= 5 && DURATION <= 60 )) \
  || die_usage "--duration must be 5..60 (EAP broadcast cycle ~10s)"

guard_no_sudo

if dry_run; then
  log_dry "omada would:"
  log_dry "  listen : bind UDP 0.0.0.0:29810, capture EAP discovery broadcasts (${DURATION}s)"
  log_dry "  probe  : send discovery datagram to 255.255.255.255:29810"
  log_dry "  decode : header plaintext; body AES-128-ECB (needs NETKIT_OMADA_KEY)"
  log_dry "no traffic sent."
  exit 0
fi

log_info "Omada discovery: listening on UDP 29810 for ${DURATION}s..."
[[ -n "${NETKIT_OMADA_KEY:-}" ]] && log_info "  will attempt AES-128-ECB decode with NETKIT_OMADA_KEY"

SELF_IPS="$(all_local_ipv4 2>/dev/null | paste -sd, -)"
export NETKIT_FMT="$FORMAT" NETKIT_DURATION="$DURATION" NETKIT_ROOT \
       NETKIT_OMADA_KEY="${NETKIT_OMADA_KEY:-}" NETKIT_SELF_IPS="$SELF_IPS"

python3 - <<'PY'
import json, os, socket, struct, subprocess, sys, time

sys.path.insert(0, os.path.join(os.environ["NETKIT_ROOT"], "scripts/utils"))
try:
    import oui
except ImportError:
    oui = None

fmt      = os.environ["NETKIT_FMT"]
duration = int(os.environ["NETKIT_DURATION"])
key_hex  = (os.environ.get("NETKIT_OMADA_KEY") or "").strip()
self_ips = {ip.strip() for ip in os.environ.get("NETKIT_SELF_IPS", "").split(",") if ip.strip()}

PORT = 29810


def try_decrypt(body: bytes):
    """AES-128-ECB decrypt via openssl (no Python crypto dep). Returns text or None."""
    if not key_hex or len(key_hex) != 32 or len(body) % 16 != 0 or not body:
        return None
    try:
        p = subprocess.run(
            ["openssl", "enc", "-d", "-aes-128-ecb", "-K", key_hex, "-nopad"],
            input=body, capture_output=True, timeout=4)
        out = p.stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    txt = out.decode(errors="replace")
    return txt if "{" in txt else None


def parse_json_fields(txt: str) -> dict:
    start = txt.find("{")
    if start < 0:
        return {}
    try:
        obj = json.loads(txt[start:txt.rfind("}") + 1])
    except Exception:
        return {}
    out = {}
    for k_src, k_dst in (("model", "model"), ("firmwareVer", "firmware"),
                         ("hwVer", "hw_ver"), ("mac", "mac"), ("ip", "ip"),
                         ("deviceName", "name"), ("uptime", "uptime")):
        if isinstance(obj, dict) and obj.get(k_src):
            out[k_dst] = obj[k_src]
    return out


def listen():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        s.bind(("", PORT))
    except OSError as e:
        print(f"warn: cannot bind UDP {PORT}: {e}", file=sys.stderr)
        s.close()
        return []
    # Best-effort probe (header-only; the controller's exact probe is undocumented).
    try:
        s.sendto(b"\x01\x00\x00\x00", ("255.255.255.255", PORT))
    except OSError:
        pass
    s.settimeout(0.5)
    end = time.time() + duration
    found = {}
    while time.time() < end:
        try:
            data, addr = s.recvfrom(8192)
        except socket.timeout:
            continue
        ip = addr[0]
        if ip in self_ips or ip in found:
            continue  # skip our own echoed probe
        rec = {"ip": ip, "bytes": len(data)}
        if len(data) >= 4:
            rec["version"] = data[0]
            rec["opcode"] = data[1]
            rec["header_len"] = struct.unpack(">H", data[2:4])[0]
        body = data[4:]
        rec["body_hex_preview"] = body[:32].hex()
        dec = try_decrypt(body)
        if dec:
            fields = parse_json_fields(dec)
            if fields:
                rec.update(fields)
                rec["decoded"] = True
        found[ip] = rec
    s.close()
    return list(found.values())


records = listen()
for r in records:
    if r.get("mac") and oui is not None:
        r["vendor"] = oui.lookup(str(r["mac"]).replace("-", ":"))
records.sort(key=lambda r: r.get("ip", ""))

if fmt == "json":
    print(json.dumps({"count": len(records), "key_supplied": bool(key_hex),
                      "devices": records}, indent=2))
    sys.exit(0)

if fmt == "md":
    print(f"# Omada / EAP devices ({len(records)})\n")
    if not records:
        print("_no Omada broadcasts on UDP 29810. The APs may be in standalone/"
              "router mode (not Omada SDN), or simply not advertising._")
        sys.exit(0)
    print("| IP | Model | Firmware | MAC | Decoded |")
    print("| --- | --- | --- | --- | --- |")
    for r in records:
        print(f"| {r['ip']} | {r.get('model','?')} | {r.get('firmware','')} | "
              f"{r.get('mac','')} | {'yes' if r.get('decoded') else 'encrypted'} |")
    sys.exit(0)

print(f"Omada / EAP discovery — {len(records)} device(s) on UDP 29810\n")
if not records:
    print("(no Omada broadcasts captured. Your TP-Link APs are likely in")
    print(" standalone/router mode, not Omada SDN — so they don't advertise here.)")
    sys.exit(0)
for r in records:
    print(f"{r['ip']:<15} {'(decoded)' if r.get('decoded') else '(encrypted body)'}")
    for k in ("model", "firmware", "hw_ver", "mac", "name", "uptime"):
        if r.get(k):
            print(f"    {k:<10}: {r[k]}")
    print(f"    header    : version={r.get('version')} opcode={r.get('opcode')} len={r.get('header_len')}")
    print(f"    body[0:32] : {r.get('body_hex_preview','')}")
    if not r.get("decoded"):
        print("    (set NETKIT_OMADA_KEY=<32-hex> to attempt AES-128-ECB decode)")
    print()
PY
