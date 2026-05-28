#!/usr/bin/env bash
# LLDP / CDP capture — the ONLY source of real physical topology on a LAN:
# which switch/AP a link terminates on, the remote port, and the VLAN.
#
# Switches, managed APs (incl. TP-Link/Omada, Aruba, Cisco) and many printers
# emit an LLDP frame (and Cisco gear a CDP frame) roughly every 30 s. We sniff
# them with tcpdump for one cycle and decode the TLVs: chassis/system name,
# port id/description, capabilities, management address and port VLAN.
#
# Capture needs raw frames (BPF) → sudo. Gated behind --allow-raw, matching the
# rest of the toolkit's raw-packet contract. Nothing is transmitted; this is a
# passive listen.
#
# Output: JSON / md / text.
#
# Usage: lldp.sh [--interface en7] [--duration 35] [--allow-raw] [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
IFACE=""
DURATION=35

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

[[ "$DURATION" =~ ^[0-9]+$ ]] && (( DURATION >= 5 && DURATION <= 120 )) \
  || die_usage "--duration must be 5..120 (LLDP/CDP cycle is ~30s)"

guard_no_sudo
[[ -z "$IFACE" ]] && IFACE=$(pick_interface || echo "")
[[ -z "$IFACE" ]] && die "Could not pick an interface. Pass --interface."

FILTER='ether proto 0x88cc or ether dst 01:00:0c:cc:cc:cc'

if dry_run; then
  log_dry "lldp would:"
  log_dry "  capture : sudo tcpdump -i ${IFACE} -s0 -G ${DURATION} -W1 -w <tmp> '${FILTER}'"
  log_dry "  parse   : LLDP (0x88cc) + CDP (01:00:0c:cc:cc:cc) TLVs (stdlib)"
  log_dry "  note    : passive listen — nothing transmitted"
  log_dry "no capture run."
  exit 0
fi

require_cmd tcpdump
# tcpdump needs raw-frame access (sudo) → explicit opt-in.
guard_raw_packet "LLDP/CDP capture (passive tcpdump via sudo)"

PCAP="$(mktemp -t netkit-lldp.XXXXXX.pcap)"
trap 'rm -f "$PCAP"' EXIT

log_info "Listening ${DURATION}s for LLDP/CDP on ${IFACE} (one advertise cycle ~30s)..."
# -G N -W 1 makes tcpdump exit after N seconds with a single file.
if ! sudo -n tcpdump -i "$IFACE" -s 0 -G "$DURATION" -W 1 -w "$PCAP" "$FILTER" >/dev/null 2>&1; then
  log_warn "passwordless sudo unavailable; run 'sudo -v' first, then re-run with --allow-raw."
  die "tcpdump capture failed (needs sudo)."
fi

export NETKIT_FMT="$FORMAT" NETKIT_PCAP="$PCAP" NETKIT_ROOT NETKIT_IFACE="$IFACE"

python3 - <<'PY'
import json, os, sys

sys.path.insert(0, os.path.join(os.environ["NETKIT_ROOT"], "scripts/utils"))
import lldp_parse

fmt = os.environ["NETKIT_FMT"]
try:
    with open(os.environ["NETKIT_PCAP"], "rb") as f:
        data = f.read()
except OSError:
    data = b""

res = lldp_parse.analyze(data)
lldp, cdp = res["lldp"], res["cdp"]

if fmt == "json":
    print(json.dumps({"interface": os.environ.get("NETKIT_IFACE", ""),
                      "lldp_count": len(lldp), "cdp_count": len(cdp),
                      "lldp": lldp, "cdp": cdp}, indent=2))
    sys.exit(0)

if fmt == "md":
    print(f"# LLDP / CDP neighbors (LLDP={len(lldp)}, CDP={len(cdp)})\n")
    if not lldp and not cdp:
        print("_no LLDP/CDP frames in the capture window. The link partner may "
              "not advertise, or needs a longer --duration._")
        sys.exit(0)
    if lldp:
        print("## LLDP\n")
        print("| System | Port | Port desc | Mgmt IP | VLAN | Capabilities |")
        print("| --- | --- | --- | --- | --- | --- |")
        for r in lldp:
            print(f"| {r.get('system_name','') or r.get('chassis_id','')} | "
                  f"{r.get('port_id','')} | {r.get('port_desc','')} | "
                  f"{r.get('mgmt_address','')} | {r.get('pvid','')} | "
                  f"{', '.join(r.get('capabilities',[]))} |")
    if cdp:
        print("\n## CDP\n")
        print("| Device | Port | Platform | Version | Native VLAN |")
        print("| --- | --- | --- | --- | --- |")
        for r in cdp:
            print(f"| {r.get('device_id','')} | {r.get('port_id','')} | "
                  f"{r.get('platform','')} | {(r.get('software_version','') or '')[:40]} | "
                  f"{r.get('native_vlan','')} |")
    sys.exit(0)

print(f"LLDP/CDP — {len(lldp)} LLDP, {len(cdp)} CDP neighbor(s) on {os.environ.get('NETKIT_IFACE','')}\n")
if not lldp and not cdp:
    print("(no LLDP/CDP frames captured — link partner may not advertise, or")
    print(" try a longer --duration; some switches advertise every 30-60s)")
    sys.exit(0)
for r in lldp:
    print(f"LLDP  {r.get('system_name','') or r.get('chassis_id','')}")
    for k in ("chassis_id", "port_id", "port_desc", "mgmt_address", "pvid"):
        if r.get(k):
            print(f"    {k:<12}: {r[k]}")
    if r.get("capabilities"):
        print(f"    {'caps':<12}: {', '.join(r['capabilities'])}")
    if r.get("system_desc"):
        print(f"    {'system_desc':<12}: {r['system_desc'][:70]}")
    print()
for r in cdp:
    print(f"CDP   {r.get('device_id','')}")
    for k in ("port_id", "platform", "native_vlan"):
        if r.get(k):
            print(f"    {k:<12}: {r[k]}")
    if r.get("software_version"):
        print(f"    {'version':<12}: {r['software_version'][:70]}")
    print()
PY
