#!/usr/bin/env bash
# Read-only SNMP audit of a managed switch / router / AP.
#
# Pulls:
#   - System info (sysDescr / sysName / sysContact / sysLocation / sysUpTime)
#   - Interface table (per-port name, type, speed, admin/oper status,
#     in/out octets, in/out errors, in/out discards)
#   - ARP / IP-to-MAC table (ipNetToMediaTable)
#   - Optional: bridge MAC-forwarding table (BRIDGE-MIB; switch port → MAC)
#
# Requires: `net-snmp` (brew install net-snmp). Falls back gracefully
# with an install hint if missing.
#
# Strictly READ-ONLY. Uses snmpget / snmpwalk / snmpbulkwalk with the
# configured community string. Default community 'public' (read-only on
# most managed switches by default — change with --community).
#
# Usage:
#   snmp.sh --host 192.168.1.1 [--community public] [--version 2c]
#           [--port 161] [--timeout 3] [--retries 1]
#           [--bridge]                  # also walk BRIDGE-MIB MAC-port map
#           [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
HOST=""
COMMUNITY="public"
VERSION="2c"
SNMP_PORT=161
SNMP_TIMEOUT=3
SNMP_RETRIES=1
WITH_BRIDGE=0

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --host)
      [[ -n "${2:-}" ]] || die_usage "--host requires a hostname or IP"
      HOST="$2"; shift 2 ;;
    --community)
      [[ -n "${2:-}" ]] || die_usage "--community requires a value"
      COMMUNITY="$2"; shift 2 ;;
    --version)
      [[ -n "${2:-}" ]] || die_usage "--version requires 1|2c"
      VERSION="$2"; shift 2 ;;
    --port)
      [[ -n "${2:-}" ]] || die_usage "--port requires a number"
      SNMP_PORT="$2"; shift 2 ;;
    --timeout)
      [[ -n "${2:-}" ]] || die_usage "--timeout requires seconds"
      SNMP_TIMEOUT="$2"; shift 2 ;;
    --retries)
      [[ -n "${2:-}" ]] || die_usage "--retries requires a count"
      SNMP_RETRIES="$2"; shift 2 ;;
    --bridge) WITH_BRIDGE=1; shift ;;
    --yes) export NETKIT_YES=1; shift ;;
    --allow-raw) export NETKIT_ALLOW_RAW=1; shift ;;
    --dry-run) export NETKIT_DRY_RUN=1; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) die_usage "Unknown flag: $1" ;;
  esac
done

[[ -n "$HOST" ]] || die_usage "--host is required"
[[ "$HOST" =~ ^[A-Za-z0-9._:-]+$ ]] || die_usage "--host invalid"
[[ "$VERSION" =~ ^(1|2c)$ ]] || die_usage "--version must be 1 or 2c"
[[ "$COMMUNITY" =~ ^[[:print:]]+$ ]] || die_usage "--community contains invalid chars"
[[ "$SNMP_PORT" =~ ^[0-9]+$ ]] && (( SNMP_PORT >= 1 && SNMP_PORT <= 65535 )) \
  || die_usage "--port must be 1..65535"
[[ "$SNMP_TIMEOUT" =~ ^[0-9]+$ ]] && (( SNMP_TIMEOUT >= 1 && SNMP_TIMEOUT <= 60 )) \
  || die_usage "--timeout must be 1..60 seconds"
[[ "$SNMP_RETRIES" =~ ^[0-9]+$ ]] && (( SNMP_RETRIES >= 0 && SNMP_RETRIES <= 5 )) \
  || die_usage "--retries must be 0..5"

guard_no_sudo

if dry_run; then
  log_dry "snmp would:"
  log_dry "  target    : ${HOST}:${SNMP_PORT}"
  log_dry "  version   : v${VERSION}"
  log_dry "  community : ${COMMUNITY} (read-only)"
  log_dry "  snmpget   : sysDescr / sysName / sysContact / sysLocation / sysUpTime"
  log_dry "  snmpwalk  : ifTable (per-port stats), ipNetToMediaTable (ARP-like)"
  if (( WITH_BRIDGE )); then
    log_dry "  --bridge  : also walk BRIDGE-MIB MAC-forwarding table"
  fi
  log_dry "no traffic sent."
  exit 0
fi

if ! has_cmd snmpget || ! has_cmd snmpwalk; then
  die "net-snmp not installed. Install with:  brew install net-snmp"
fi

export NETKIT_FMT="$FORMAT" NETKIT_HOST="$HOST" NETKIT_COMMUNITY="$COMMUNITY" \
       NETKIT_VERSION="$VERSION" NETKIT_SNMP_PORT="$SNMP_PORT" \
       NETKIT_TIMEOUT="$SNMP_TIMEOUT" NETKIT_RETRIES="$SNMP_RETRIES" \
       NETKIT_BRIDGE="$WITH_BRIDGE"

python3 - <<'PY'
import json, os, re, subprocess, sys
from typing import Any

HOST    = os.environ["NETKIT_HOST"]
COMM    = os.environ["NETKIT_COMMUNITY"]
VERSION = os.environ["NETKIT_VERSION"]
PORT    = os.environ["NETKIT_SNMP_PORT"]
TIMEOUT = os.environ["NETKIT_TIMEOUT"]
RETRIES = os.environ["NETKIT_RETRIES"]
FMT     = os.environ["NETKIT_FMT"]
BRIDGE  = os.environ["NETKIT_BRIDGE"] == "1"

# Common args to every snmp* invocation. -Oqv = quick + value-only; -t
# timeout, -r retries.
_BASE = ["-v", VERSION, "-c", COMM, "-t", TIMEOUT, "-r", RETRIES,
         "-Oqv", "-Pe", f"{HOST}:{PORT}"]


def _run(tool: str, *oid_args: str) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            [tool, "-v", VERSION, "-c", COMM, "-t", TIMEOUT, "-r", RETRIES,
             "-Pe", f"{HOST}:{PORT}", *oid_args],
            capture_output=True, text=True, timeout=int(TIMEOUT) * 6 + 10,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "subprocess timeout"


def get_single(oid: str) -> str:
    rc, out, _ = _run("snmpget", "-Oqv", oid)
    if rc != 0:
        return ""
    return out.strip().strip('"')


def walk_table(oid: str, output_format: str = "v") -> list[str]:
    """Return raw lines from snmpwalk. ``output_format`` controls -O: 'v'
    for value-only, 'n' for numeric-OID + value, '' for default."""
    args = ["-O" + output_format, oid] if output_format else [oid]
    rc, out, _ = _run("snmpwalk", *args)
    if rc != 0:
        return []
    return [ln for ln in out.splitlines() if ln.strip()]


# ---- 1. system group ----
system: dict[str, str] = {}
SYS_OIDS = {
    "sysDescr":    "1.3.6.1.2.1.1.1.0",
    "sysObjectID": "1.3.6.1.2.1.1.2.0",
    "sysUpTime":   "1.3.6.1.2.1.1.3.0",
    "sysContact":  "1.3.6.1.2.1.1.4.0",
    "sysName":     "1.3.6.1.2.1.1.5.0",
    "sysLocation": "1.3.6.1.2.1.1.6.0",
    "sysServices": "1.3.6.1.2.1.1.7.0",
}
for name, oid in SYS_OIDS.items():
    system[name] = get_single(oid)

reachable = bool(system.get("sysDescr"))

# Bail early if the device didn't respond at all.
if not reachable:
    error = "SNMP target not reachable or community string rejected"
    payload = {
        "host": HOST, "port": int(PORT), "version": f"v{VERSION}",
        "reachable": False, "error": error, "system": system,
        "interfaces": [], "arp": [], "bridge_fdb": [],
    }
    print(json.dumps(payload, indent=2) if FMT == "json"
          else f"SNMP {HOST}:{PORT} — {error}", file=(sys.stdout if FMT == "json" else sys.stderr))
    sys.exit(2)


# ---- 2. interface table ----
def walk_indexed(oid: str) -> dict[str, str]:
    """snmpwalk that returns {index_suffix: value} by parsing the OID tail."""
    rc, out, _ = _run("snmpwalk", "-Oqn", oid)
    if rc != 0:
        return {}
    result: dict[str, str] = {}
    base = oid.lstrip(".")
    for ln in out.splitlines():
        ln = ln.strip()
        if not ln:
            continue
        m = re.match(r"^\.?(\S+)\s+(.*)$", ln)
        if not m:
            continue
        full_oid, val = m.group(1), m.group(2).strip().strip('"')
        if full_oid.startswith(base):
            idx = full_oid[len(base):].lstrip(".")
            result[idx] = val
    return result


# Interface table columns we care about.
IF_OIDS = {
    "ifDescr":         "1.3.6.1.2.1.2.2.1.2",
    "ifType":          "1.3.6.1.2.1.2.2.1.3",
    "ifMtu":           "1.3.6.1.2.1.2.2.1.4",
    "ifSpeed":         "1.3.6.1.2.1.2.2.1.5",
    "ifPhysAddress":   "1.3.6.1.2.1.2.2.1.6",
    "ifAdminStatus":   "1.3.6.1.2.1.2.2.1.7",
    "ifOperStatus":    "1.3.6.1.2.1.2.2.1.8",
    "ifInOctets":      "1.3.6.1.2.1.2.2.1.10",
    "ifInErrors":      "1.3.6.1.2.1.2.2.1.14",
    "ifOutOctets":     "1.3.6.1.2.1.2.2.1.16",
    "ifOutErrors":     "1.3.6.1.2.1.2.2.1.20",
    # Newer high-counter / name columns from IF-MIB.
    "ifName":          "1.3.6.1.2.1.31.1.1.1.1",
    "ifAlias":         "1.3.6.1.2.1.31.1.1.1.18",
    "ifHighSpeed":     "1.3.6.1.2.1.31.1.1.1.15",  # in Mbps
}
col_data = {col: walk_indexed(oid) for col, oid in IF_OIDS.items()}
indexes = sorted(col_data["ifDescr"].keys(), key=lambda x: int(x) if x.isdigit() else x)

STATUS_MAP = {"1": "up", "2": "down", "3": "testing", "4": "unknown",
              "5": "dormant", "6": "notPresent", "7": "lowerLayerDown"}

interfaces: list[dict[str, Any]] = []
for idx in indexes:
    speed_bps   = col_data["ifSpeed"].get(idx, "")
    speed_mbps  = col_data["ifHighSpeed"].get(idx, "")
    try:
        speed_human = (f"{int(speed_mbps)} Mbps" if speed_mbps
                       else f"{int(int(speed_bps)/1_000_000)} Mbps" if speed_bps and speed_bps.isdigit()
                       else speed_bps)
    except ValueError:
        speed_human = speed_bps
    interfaces.append({
        "ifIndex":      idx,
        "name":         col_data["ifName"].get(idx, "") or col_data["ifDescr"].get(idx, ""),
        "descr":        col_data["ifDescr"].get(idx, ""),
        "alias":        col_data["ifAlias"].get(idx, ""),
        "type":         col_data["ifType"].get(idx, ""),
        "mtu":          col_data["ifMtu"].get(idx, ""),
        "speed":        speed_human,
        "phys_address": col_data["ifPhysAddress"].get(idx, ""),
        "admin_status": STATUS_MAP.get(col_data["ifAdminStatus"].get(idx, ""),
                                        col_data["ifAdminStatus"].get(idx, "")),
        "oper_status":  STATUS_MAP.get(col_data["ifOperStatus"].get(idx, ""),
                                        col_data["ifOperStatus"].get(idx, "")),
        "in_octets":    col_data["ifInOctets"].get(idx, ""),
        "out_octets":   col_data["ifOutOctets"].get(idx, ""),
        "in_errors":    col_data["ifInErrors"].get(idx, ""),
        "out_errors":   col_data["ifOutErrors"].get(idx, ""),
    })


# ---- 3. ARP / ipNetToMediaTable ----
# 1.3.6.1.2.1.4.22.1.2 = ipNetToMediaPhysAddress
arp: list[dict[str, str]] = []
rc, out, _ = _run("snmpwalk", "-Ofq", "1.3.6.1.2.1.4.22.1.2")
if rc == 0:
    for ln in out.splitlines():
        ln = ln.strip()
        if not ln:
            continue
        # Format: ".iso....22.1.2.<ifIndex>.<ip>  <hex mac>"
        m = re.match(r"\S+\.(\d+)\.((?:\d+\.){3}\d+)\s+(.+)$", ln)
        if m:
            arp.append({
                "ifIndex": m.group(1),
                "ip":      m.group(2),
                "mac":     m.group(3).strip().strip('"').lower(),
            })


# ---- 4. (optional) BRIDGE-MIB MAC-forwarding table ----
# dot1dTpFdbPort = 1.3.6.1.2.1.17.4.3.1.2  → maps MAC → bridge port
bridge_fdb: list[dict[str, str]] = []
if BRIDGE:
    # dot1dBasePortIfIndex (1.3.6.1.2.1.17.1.4.1.2): bridge port → ifIndex, so we
    # can resolve each forwarding entry to a human port name (ifName).
    port_ifindex: dict[str, str] = {}
    rc, out, _ = _run("snmpwalk", "-Ofq", "1.3.6.1.2.1.17.1.4.1.2")
    if rc == 0:
        for ln in out.splitlines():
            m = re.match(r".*\.(\d+)\s+(\d+)$", ln.strip())
            if m:
                port_ifindex[m.group(1)] = m.group(2)
    ifname_by_index = {i["ifIndex"]: i["name"] for i in interfaces}

    rc, out, _ = _run("snmpwalk", "-Ofq", "1.3.6.1.2.1.17.4.3.1.2")
    if rc == 0:
        for ln in out.splitlines():
            ln = ln.strip()
            if not ln:
                continue
            # Tail: ".<o1>.<o2>...<o6>" (6 decimal octets) + " port"
            m = re.match(r".*\.(\d+)\.(\d+)\.(\d+)\.(\d+)\.(\d+)\.(\d+)\s+(\d+)$", ln)
            if m:
                mac = ":".join(f"{int(x):02x}" for x in m.groups()[:6])
                port = m.group(7)
                ifidx = port_ifindex.get(port, port)
                bridge_fdb.append({
                    "mac": mac, "port": port, "ifindex": ifidx,
                    "port_name": ifname_by_index.get(ifidx, ""),
                })


# ---- assemble + render ----
result = {
    "host": HOST, "port": int(PORT), "version": f"v{VERSION}",
    "reachable": reachable,
    "system": system,
    "interface_count": len(interfaces),
    "interfaces": interfaces,
    "arp_count": len(arp),
    "arp": arp,
    "bridge_fdb_count": len(bridge_fdb) if BRIDGE else None,
    "bridge_fdb": bridge_fdb,
}

if FMT == "json":
    print(json.dumps(result, indent=2, default=str))
elif FMT == "md":
    print(f"# SNMP audit — `{HOST}:{PORT}` (v{VERSION})\n")
    print("## System\n")
    for k, v in system.items():
        if v:
            print(f"- **{k}**: `{v}`")
    print(f"\n## Interfaces ({len(interfaces)})\n")
    if interfaces:
        print("| idx | name | speed | admin | oper | in octets | in err | out err |")
        print("| --- | --- | --- | --- | --- | --- | --- | --- |")
        for i in interfaces:
            print(f"| {i['ifIndex']} | {i['name']} | {i['speed']} | "
                  f"{i['admin_status']} | {i['oper_status']} | "
                  f"{i['in_octets']} | {i['in_errors']} | {i['out_errors']} |")
    print(f"\n## ARP entries ({len(arp)})\n")
    if arp:
        print("| ifIndex | IP | MAC |")
        print("| --- | --- | --- |")
        for a in arp[:50]:
            print(f"| {a['ifIndex']} | {a['ip']} | {a['mac']} |")
        if len(arp) > 50:
            print(f"\n_{len(arp)-50} more entries (use --json for the full list)._")
    if BRIDGE and bridge_fdb:
        print(f"\n## Bridge MAC forwarding ({len(bridge_fdb)})\n")
        print("| MAC | port |")
        print("| --- | --- |")
        for b in bridge_fdb[:50]:
            print(f"| {b['mac']} | {b['port']} |")
else:
    print(f"SNMP {HOST}:{PORT}  (v{VERSION})")
    print()
    for k, v in system.items():
        if v:
            print(f"  {k:<14} {v[:80]}")
    print()
    print(f"  Interfaces: {len(interfaces)}")
    if interfaces:
        print()
        fmt = "  {:<5} {:<18} {:<10} {:<7} {:<7} {:>14} {:>7} {:>7}"
        print(fmt.format("idx", "name", "speed", "admin", "oper", "in_octets", "in_err", "out_err"))
        print("  " + "-" * 86)
        for i in interfaces:
            print(fmt.format(
                i["ifIndex"][:5], (i["name"] or "")[:18], (i["speed"] or "")[:10],
                (i["admin_status"] or "")[:7], (i["oper_status"] or "")[:7],
                (i["in_octets"] or "0")[:14], (i["in_errors"] or "0")[:7],
                (i["out_errors"] or "0")[:7],
            ))
    print(f"\n  ARP entries: {len(arp)}")
    if arp[:10]:
        for a in arp[:10]:
            print(f"    if{a['ifIndex']:<3} {a['ip']:<15} {a['mac']}")
        if len(arp) > 10:
            print(f"    … ({len(arp)-10} more — use --json or --md)")
    if BRIDGE:
        print(f"\n  Bridge MAC table: {len(bridge_fdb)} entries")
PY
