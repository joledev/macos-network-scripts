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
    # Schema (subject to change across firmware versions):
    # status.dishGetStatus.{uptimeS, downlinkThroughputBps, uplinkThroughputBps,
    #                       pingDropRate, popPingLatencyMs, state,
    #                       deviceInfo:{id, hardwareVersion, softwareVersion, countryCode},
    #                       alerts:{}, obstructionStats:{fractionObstructed,
    #                       avgProlongedObstructionDurationS}}
    ds = (status.get("dishGetStatus") or {})
    result["uptime_s"]    = ds.get("uptimeS")
    dl = ds.get("downlinkThroughputBps", 0)
    ul = ds.get("uplinkThroughputBps", 0)
    if dl: result["downlink_mbps"] = round(dl / 1e6, 2)
    if ul: result["uplink_mbps"]   = round(ul / 1e6, 2)
    result["ping_drop_rate"] = ds.get("pingDropRate")
    result["ping_latency_ms"] = ds.get("popPingLatencyMs")
    result["state"] = ds.get("state", "")
    info = ds.get("deviceInfo", {}) or {}
    result["device_id"]    = info.get("id", "")
    result["hardware"]     = info.get("hardwareVersion", "")
    result["software"]     = info.get("softwareVersion", "")
    result["country_code"] = info.get("countryCode", "")
    obs = ds.get("obstructionStats", {}) or {}
    result["obstruction_fraction"]            = obs.get("fractionObstructed")
    result["obstruction_avg_prolonged_s"]     = obs.get("avgProlongedObstructionDurationS")
    # alerts is a dict of {name: bool}; collect the True ones.
    al = ds.get("alerts", {}) or {}
    result["alerts"] = [k for k, v in al.items() if v]

if fmt == "json":
    print(json.dumps(result, indent=2, default=str))
elif fmt == "md":
    r = result
    print(f"# Starlink dish — {r['host']}\n")
    print(f"- **State:** {r.get('state','?')}")
    print(f"- **Uptime:** {r.get('uptime_s','?')} s")
    print(f"- **Down / Up:** {r.get('downlink_mbps','?')} / {r.get('uplink_mbps','?')} Mbps")
    print(f"- **Pop ping:** {r.get('ping_latency_ms','?')} ms")
    print(f"- **Ping drop:** {r.get('ping_drop_rate','?')}")
    if r.get("obstruction_fraction") is not None:
        pct = r["obstruction_fraction"] * 100 if r["obstruction_fraction"] else 0
        print(f"- **Obstruction:** {pct:.3f}% of view; avg prolonged {r.get('obstruction_avg_prolonged_s','?')} s")
    print(f"- **Hardware:** {r.get('hardware','?')}")
    print(f"- **Software:** {r.get('software','?')}")
    print(f"- **Country:** {r.get('country_code','?')}")
    if r["alerts"]:
        print(f"- **Active alerts:** {', '.join(r['alerts'])}")
else:
    r = result
    print(f"Starlink dish @ {r['host']}:{r['port']}")
    print(f"  state         : {r.get('state','?')}")
    print(f"  uptime        : {r.get('uptime_s','?')} s")
    print(f"  download      : {r.get('downlink_mbps','?')} Mbps")
    print(f"  upload        : {r.get('uplink_mbps','?')} Mbps")
    print(f"  pop ping      : {r.get('ping_latency_ms','?')} ms")
    print(f"  ping drop     : {r.get('ping_drop_rate','?')}")
    if r.get('obstruction_fraction') is not None:
        pct = r["obstruction_fraction"] * 100 if r["obstruction_fraction"] else 0
        print(f"  obstruction   : {pct:.3f}%")
    print(f"  hardware      : {r.get('hardware','?')}")
    print(f"  software      : {r.get('software','?')}")
    if r["alerts"]:
        print(f"  alerts        : {', '.join(r['alerts'])}")
PY
