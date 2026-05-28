#!/usr/bin/env bash
# Query a Starlink dish via its gRPC API at 192.168.100.1:9200.
#
# Reports: device state, uptime, alerts, signal-quality, throughput,
# obstruction stats, GPS, software version, hardware revision.
#
# Requires `grpcurl` (brew install grpcurl). Without it the script does a
# TCP reachability probe only and tells you what to install.
#
# Usage: starlink.sh [--host 192.168.100.1] [--port 9200] [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
HOST="192.168.100.1"
PORT=9200


while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --host)
      [[ -n "${2:-}" ]] || die_usage "--host requires a value"
      HOST="$2"; shift 2 ;;
    --port)
      [[ -n "${2:-}" ]] || die_usage "--port requires a number"
      PORT="$2"; shift 2 ;;
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

# Validate --host (hostname / IPv4) and --port (1..65535).
[[ "$HOST" =~ ^[A-Za-z0-9._:-]+$ ]] || die_usage "--host invalid (allowed: A-Z a-z 0-9 . _ : -)"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) \
  || die_usage "--port must be 1..65535"

if dry_run; then
  log_dry "starlink would:"
  log_dry "  reach    : TCP $HOST:$PORT"
  log_dry "  grpcurl  : grpcurl -plaintext -d '{\"get_status\":{}}' $HOST:$PORT SpaceX.API.Device.Device/Handle"
  log_dry "  hint     : brew install grpcurl  (if missing)"
  log_dry "no traffic sent."
  exit 0
fi

export NETKIT_FMT="$FORMAT" NETKIT_HOST="$HOST" NETKIT_PORT="$PORT"

python3 - <<'PY'
import json, os, socket, subprocess, sys

fmt  = os.environ["NETKIT_FMT"]
host = os.environ["NETKIT_HOST"]
port = int(os.environ["NETKIT_PORT"])

result = {
    "host":         host,
    "port":         port,
    "tcp_reachable": False,
    "grpc_available": False,
    "uptime_s":     None,
    "downlink_mbps": None,
    "uplink_mbps":   None,
    "ping_drop_rate": None,
    "ping_latency_ms": None,
    "obstruction_fraction": None,
    "obstruction_avg_prolonged_s": None,
    "state":        "",
    "alerts":       [],
    "device_id":    "",
    "hardware":     "",
    "software":     "",
    "country_code": "",
    "raw":          None,
    "error":        "",
}

# 1) TCP reachability.
try:
    with socket.create_connection((host, port), timeout=2):
        result["tcp_reachable"] = True
except OSError as e:
    result["error"] = f"not reachable: {e}"
    if fmt == "json":
        print(json.dumps(result, indent=2))
    else:
        print(f"Starlink dish at {host}:{port} not reachable.")
        print(f"  reason: {e}")
        print("  hint: on a Starlink LAN the dish answers at 192.168.100.1.")
        print("        If you're behind a router that NATs the dish, set up a")
        print("        static route from your laptop's subnet to 192.168.100.0/24.")
    sys.exit(1)

# 2) grpcurl.
import shutil
if not shutil.which("grpcurl"):
    result["error"] = "grpcurl not installed (brew install grpcurl)"
    if fmt == "json":
        print(json.dumps(result, indent=2))
    else:
        print(f"Dish reachable at {host}:{port}, but grpcurl is not installed.")
        print(f"  install: brew install grpcurl")
        print(f"  manual : grpcurl -plaintext -d '{{\"get_status\":{{}}}}' "
              f"{host}:{port} SpaceX.API.Device.Device/Handle")
    sys.exit(1)
result["grpc_available"] = True

# 3) get_status — main telemetry call.
def grpc_call(payload: str) -> dict:
    try:
        proc = subprocess.run(
            ["grpcurl", "-plaintext", "-d", payload,
             f"{host}:{port}", "SpaceX.API.Device.Device/Handle"],
            capture_output=True, text=True, timeout=8,
        )
        if proc.returncode != 0:
            return {"_error": proc.stderr.strip()[:300]}
        return json.loads(proc.stdout) if proc.stdout.strip() else {}
    except (subprocess.TimeoutExpired, json.JSONDecodeError) as e:
        return {"_error": str(e)}

status = grpc_call('{"get_status":{}}')
result["raw"] = status

if "_error" in status:
    result["error"] = status["_error"]
else:
    # Current schema (firmware 2026.x): dishGetStatus with deviceState
    # nesting uptimeS, deviceInfo for hw/sw, top-level boresight + GPS +
    # obstructionStats + alerts. Field names drift between firmwares, so
    # everything is .get()-guarded.
    ds = (status.get("dishGetStatus") or {})

    dev_state = ds.get("deviceState", {}) or {}
    result["uptime_s"] = dev_state.get("uptimeS") or ds.get("uptimeS")

    dl = ds.get("downlinkThroughputBps", 0) or 0
    ul = ds.get("uplinkThroughputBps", 0) or 0
    result["downlink_mbps"] = round(dl / 1e6, 3)
    result["uplink_mbps"]   = round(ul / 1e6, 3)
    result["ping_drop_rate"]  = ds.get("popPingDropRate")
    result["ping_latency_ms"] = ds.get("popPingLatencyMs")

    info = ds.get("deviceInfo", {}) or {}
    result["device_id"]    = info.get("id", "")
    result["hardware"]     = info.get("hardwareVersion", "")
    result["software"]     = info.get("softwareVersion", "")
    result["country_code"] = info.get("countryCode", "")

    # Dish aim — gold for install positioning.
    result["boresight_azimuth_deg"]   = ds.get("boresightAzimuthDeg")
    result["boresight_elevation_deg"] = ds.get("boresightElevationDeg")

    # Signal quality.
    result["snr_above_noise_floor"] = ds.get("isSnrAboveNoiseFloor")
    result["eth_speed_mbps"]        = ds.get("ethSpeedMbps")

    # GPS.
    gps = ds.get("gpsStats", {}) or {}
    result["gps_valid"] = gps.get("gpsValid")
    result["gps_sats"]  = gps.get("gpsSats")

    # Obstruction. New firmware reports validS / patchesValid /
    # avgProlongedObstructionIntervalS instead of a single fraction.
    obs = ds.get("obstructionStats", {}) or {}
    result["obstruction"] = {
        "currently_obstructed":   obs.get("currentlyObstructed"),
        "fraction_obstructed":    obs.get("fractionObstructed"),
        "valid_s":                obs.get("validS"),
        "patches_valid":          obs.get("patchesValid"),
        "avg_prolonged_interval_s": obs.get("avgProlongedObstructionIntervalS"),
        "time_obstructed":        obs.get("timeObstructed"),
    }

    # Bandwidth restriction reasons (if Starlink is throttling).
    result["dl_restricted_reason"] = ds.get("dlBandwidthRestrictedReason")
    result["ul_restricted_reason"] = ds.get("ulBandwidthRestrictedReason")

    # Software update state.
    result["software_update_state"] = ds.get("softwareUpdateState")

    # alerts is a dict of {name: bool}; collect the True ones.
    al = ds.get("alerts", {}) or {}
    result["alerts"] = [k for k, v in al.items() if v]

def _uptime_human(s):
    try:
        s = int(s)
    except (TypeError, ValueError):
        return str(s)
    d, rem = divmod(s, 86400)
    h, rem = divmod(rem, 3600)
    m, _ = divmod(rem, 60)
    return f"{d}d {h}h {m}m"

obs = result.get("obstruction", {}) or {}

if fmt == "json":
    print(json.dumps(result, indent=2, default=str))
elif fmt == "md":
    r = result
    print(f"# Starlink dish — {r['host']}\n")
    print(f"- **Device ID:** `{r.get('device_id','?')}`")
    print(f"- **Hardware / Software:** {r.get('hardware','?')} / {r.get('software','?')}")
    print(f"- **Uptime:** {_uptime_human(r.get('uptime_s'))}")
    print(f"- **Throughput (instant):** ↓ {r.get('downlink_mbps','?')} / ↑ {r.get('uplink_mbps','?')} Mbps")
    print(f"- **Pop ping:** {r.get('ping_latency_ms','?')} ms · drop {r.get('ping_drop_rate','?')}")
    print(f"- **SNR above noise floor:** {r.get('snr_above_noise_floor','?')}")
    print(f"- **Dish aim:** azimuth {r.get('boresight_azimuth_deg','?')}° · elevation {r.get('boresight_elevation_deg','?')}°")
    print(f"- **GPS:** valid={r.get('gps_valid','?')} · sats={r.get('gps_sats','?')}")
    print(f"- **Ethernet:** {r.get('eth_speed_mbps','?')} Mbps")
    print(f"- **Obstruction:** currently={obs.get('currently_obstructed','?')} · "
          f"patches_valid={obs.get('patches_valid','?')} · valid_s={obs.get('valid_s','?')} · "
          f"avg_prolonged_interval_s={obs.get('avg_prolonged_interval_s','?')}")
    if r.get("dl_restricted_reason") or r.get("ul_restricted_reason"):
        print(f"- **Bandwidth restricted:** dl={r.get('dl_restricted_reason')} ul={r.get('ul_restricted_reason')}")
    print(f"- **Active alerts:** {', '.join(r['alerts']) if r['alerts'] else 'none'}")
else:
    r = result
    print(f"Starlink dish @ {r['host']}:{r['port']}")
    print(f"  device id     : {r.get('device_id','?')}")
    print(f"  hardware      : {r.get('hardware','?')}")
    print(f"  software      : {r.get('software','?')}")
    print(f"  uptime        : {_uptime_human(r.get('uptime_s'))}")
    print(f"  throughput    : ↓ {r.get('downlink_mbps','?')} / ↑ {r.get('uplink_mbps','?')} Mbps (instant)")
    print(f"  pop ping      : {r.get('ping_latency_ms','?')} ms  (drop {r.get('ping_drop_rate','?')})")
    print(f"  SNR ok        : {r.get('snr_above_noise_floor','?')}")
    print(f"  dish aim      : az {r.get('boresight_azimuth_deg','?')}°  el {r.get('boresight_elevation_deg','?')}°")
    print(f"  GPS           : valid={r.get('gps_valid','?')} sats={r.get('gps_sats','?')}")
    print(f"  eth speed     : {r.get('eth_speed_mbps','?')} Mbps")
    print(f"  obstruction   : currently={obs.get('currently_obstructed','?')} "
          f"patches_valid={obs.get('patches_valid','?')} valid_s={obs.get('valid_s','?')}")
    if r.get("dl_restricted_reason") or r.get("ul_restricted_reason"):
        print(f"  bw restricted : dl={r.get('dl_restricted_reason')} ul={r.get('ul_restricted_reason')}")
    print(f"  alerts        : {', '.join(r['alerts']) if r['alerts'] else 'none'}")
PY
