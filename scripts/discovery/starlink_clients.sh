#!/usr/bin/env bash
# starlink-clients — enumerate EVERY device the Starlink router knows about.
#
# The Starlink router (not the dish) exposes a gRPC API on :9000. Its
# get_status reply carries the full client list — anonymously, no auth — which
# is far more complete than an ARP/ping sweep: it includes devices that ignore
# ICMP, sleep, roam, or use a randomized MAC, plus the router's own knowledge
# of each client:
#   * name              the hostname the device announced (often the model)
#   * iface / band      ETH / RF_2GHZ / RF_5GHZ  (wired vs 2.4 vs 5 GHz)
#   * signalStrength    per-client RSSI (dBm) and SNR
#   * upstreamMacAddress which node it associates with — the REAL mesh topology
#   * hopsFromController 0=router, 1=direct client, 2=behind a mesh node
#   * dhcp lease + up/download counters
#
# Read-only: a single get_status query to YOUR own router. Needs grpcurl.
#
# Output: JSON / md / text.
#
# Usage: starlink_clients.sh [--host 192.168.1.1] [--port 9000] [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
HOST=""
PORT=9000

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --host)
      [[ -n "${2:-}" ]] || die_usage "--host requires an IP"
      HOST="$2"; shift 2 ;;
    --port)
      [[ -n "${2:-}" ]] || die_usage "--port requires a number"
      PORT="$2"; shift 2 ;;
    --yes) export NETKIT_YES=1; shift ;;
    --dry-run) export NETKIT_DRY_RUN=1; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) die_usage "Unknown flag: $1" ;;
  esac
done

[[ -n "$HOST" ]] || HOST="$(default_gateway 2>/dev/null || echo 192.168.1.1)"
[[ "$HOST" =~ ^[0-9.]+$ ]] || die_usage "--host must be an IPv4 address"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die_usage "--port must be 1..65535"

guard_no_sudo

if dry_run; then
  log_dry "starlink-clients would:"
  log_dry "  grpcurl -plaintext -d '{\"get_status\":{}}' ${HOST}:${PORT} SpaceX.API.Device.Device.Handle"
  log_dry "  parse  : clients[] (name/ip/mac/band/signal/upstream/hops)"
  log_dry "no other traffic sent."
  exit 0
fi

if ! soft_require grpcurl; then
  # Emit empty-but-valid output so recon and other callers don't choke.
  if [[ "$FORMAT" == "json" ]]; then echo '{"count":0,"clients":[],"error":"grpcurl not installed"}'; fi
  exit 0
fi

RAW="$(grpcurl -plaintext -max-time 8 -d '{"get_status":{}}' \
        "${HOST}:${PORT}" SpaceX.API.Device.Device.Handle 2>/dev/null || true)"

if [[ -z "$RAW" ]]; then
  log_warn "No response from Starlink router gRPC at ${HOST}:${PORT} (not a Starlink router, or API closed)."
  if [[ "$FORMAT" == "json" ]]; then echo '{"count":0,"clients":[],"error":"no grpc response"}'; fi
  exit 0
fi

SL_TMP="$(mktemp -t netkit-sl.XXXXXX)"
trap 'rm -f "$SL_TMP"' EXIT
printf '%s' "$RAW" > "$SL_TMP"
export NETKIT_FMT="$FORMAT" NETKIT_SL_JSON="$SL_TMP" NETKIT_ROOT
python3 - <<'PY'
import json, os, sys

sys.path.insert(0, os.path.join(os.environ["NETKIT_ROOT"], "scripts/utils"))
import starlink_parse

fmt = os.environ["NETKIT_FMT"]
try:
    with open(os.environ["NETKIT_SL_JSON"]) as f:
        data = json.load(f)
except (OSError, json.JSONDecodeError):
    print('{"count":0,"clients":[]}' if fmt == "json" else "no parseable response")
    sys.exit(0)

clients = starlink_parse.parse_clients(data)
out = {"count": len(clients), "clients": clients}

if fmt == "json":
    print(json.dumps(out, indent=2))
    sys.exit(0)

if fmt == "md":
    print(f"# Starlink router clients ({len(clients)})\n")
    print("| name | ip | mac | band | signal | hops | upstream |")
    print("| --- | --- | --- | --- | --- | --- | --- |")
    for c in clients:
        print(f"| {c['name'] or '?'} | {c['ip'] or '-'} | {c['mac']} | {c['band']} | "
              f"{c['signal_dbm'] if c['signal_dbm'] is not None else ''} | {c['hops']} | {c['upstream_mac']} |")
    sys.exit(0)

print(f"Starlink router clients — {len(clients)}\n")
print(f"{'name':<16}{'ip':<16}{'band':<10}{'signal':<8}{'hops':<5}upstream")
print("-" * 78)
for c in clients:
    sig = f"{c['signal_dbm']}" if c["signal_dbm"] is not None else ""
    print(f"{(c['name'] or '?')[:15]:<16}{(c['ip'] or '-'):<16}{c['band']:<10}{sig:<8}"
          f"{str(c['hops']) if c['hops'] is not None else '':<5}{c['upstream_mac']}")
PY
