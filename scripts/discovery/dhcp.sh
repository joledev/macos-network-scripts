#!/usr/bin/env bash
# DHCP fingerprinting — sniff DHCP DISCOVER/REQUEST traffic and extract each
# client's hostname (option 12), vendor class (option 60) and parameter-request
# list (option 55). That option-55 list is the Fingerbank "fingerprint" that
# identifies the OS/device; the hostname often names the device outright.
#
# DHCP is sporadic (devices only speak it on join / lease renewal, typically
# every few hours), so a capture window may catch nothing — bounce a device's
# Wi-Fi or wait for the renewal, or run with a longer --duration.
#
# Capture needs raw frames (BPF) → sudo. Gated behind --allow-raw. Passive only.
#
# Output: JSON / md / text.
#
# Usage: dhcp.sh [--interface en7] [--duration 60] [--allow-raw] [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
IFACE=""
DURATION=60

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --interface)
      [[ -n "${2:-}" ]] || die_usage "--interface requires a value"
      IFACE="$2"; shift 2 ;;
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

[[ "$DURATION" =~ ^[0-9]+$ ]] && (( DURATION >= 5 && DURATION <= 600 )) \
  || die_usage "--duration must be 5..600"

guard_no_sudo
[[ -z "$IFACE" ]] && IFACE=$(pick_interface || echo "")
[[ -z "$IFACE" ]] && die "Could not pick an interface. Pass --interface."

FILTER='udp port 67 or udp port 68'

if dry_run; then
  log_dry "dhcp would:"
  log_dry "  capture : sudo tcpdump -i ${IFACE} -s0 -G ${DURATION} -W1 -w <tmp> '${FILTER}'"
  log_dry "  parse   : DHCP options 12 (hostname), 55 (fingerprint), 60 (vendor)"
  log_dry "  note    : passive; DHCP is sporadic — may catch nothing in the window"
  log_dry "no capture run."
  exit 0
fi

require_cmd tcpdump
guard_raw_packet "DHCP capture (passive tcpdump via sudo)"

PCAP="$(mktemp -t netkit-dhcp.XXXXXX.pcap)"
trap 'rm -f "$PCAP"' EXIT

log_info "Sniffing DHCP on ${IFACE} for ${DURATION}s (sporadic — join a device to trigger)..."
if ! sudo -n tcpdump -i "$IFACE" -s 0 -G "$DURATION" -W 1 -w "$PCAP" "$FILTER" >/dev/null 2>&1; then
  log_warn "passwordless sudo unavailable; run 'sudo -v' first, then re-run with --allow-raw."
  die "tcpdump capture failed (needs sudo)."
fi

export NETKIT_FMT="$FORMAT" NETKIT_PCAP="$PCAP" NETKIT_ROOT

python3 - <<'PY'
import json, os, sys

sys.path.insert(0, os.path.join(os.environ["NETKIT_ROOT"], "scripts/utils"))
import dhcp_parse
try:
    import oui
except ImportError:
    oui = None

fmt = os.environ["NETKIT_FMT"]
try:
    with open(os.environ["NETKIT_PCAP"], "rb") as f:
        data = f.read()
except OSError:
    data = b""

recs = dhcp_parse.analyze(data)
for r in recs:
    if r.get("mac") and oui is not None:
        r["vendor"] = oui.lookup(r["mac"])
        kind = oui.mac_kind(r["mac"])
        if kind == "random/local":
            r["mac_kind"] = kind
recs.sort(key=lambda r: r.get("hostname", "") or r.get("mac", ""))

if fmt == "json":
    print(json.dumps({"count": len(recs), "clients": recs}, indent=2))
    sys.exit(0)

if fmt == "md":
    print(f"# DHCP fingerprints ({len(recs)})\n")
    if not recs:
        print("_no DHCP traffic captured in the window (it's sporadic — try a "
              "longer --duration or reconnect a device)._")
        sys.exit(0)
    print("| MAC | Vendor | OS guess | Hostname | Vendor class | Msg | Fingerprint (opt 55) |")
    print("| --- | --- | --- | --- | --- | --- | --- |")
    for r in recs:
        print(f"| {r.get('mac','')} | {r.get('vendor','')} | {r.get('os_guess','')} | "
              f"{r.get('hostname','')} | {r.get('vendor_class','')} | {r.get('msg_type','')} | "
              f"`{r.get('fingerprint','')}` |")
    sys.exit(0)

print(f"DHCP fingerprinting — {len(recs)} client(s)\n")
if not recs:
    print("(no DHCP traffic captured — it's sporadic; try a longer --duration")
    print(" or reconnect a device to force a DISCOVER/REQUEST)")
    sys.exit(0)
for r in recs:
    print(f"{r.get('mac',''):<19} {r.get('hostname','') or '(no hostname)'}")
    if r.get("mac_kind") == "random/local":
        print(f"    {'mac':<13}: randomized / locally-administered (privacy MAC)")
    for k in ("vendor", "os_guess", "vendor_class", "msg_type", "requested_ip"):
        if r.get(k):
            print(f"    {k:<13}: {r[k]}")
    if r.get("fingerprint"):
        print(f"    {'fingerprint':<13}: {r['fingerprint']}  (look up on fingerbank.org)")
    print()
PY
