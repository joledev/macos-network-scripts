#!/usr/bin/env bash
# LAN throughput measurement via iperf3.
#
# Two modes:
#   - Client (default): connect to an iperf3 server and measure bandwidth.
#       throughput.sh --server <host> [--port 5201] [--duration 10] [--udp] [--reverse]
#   - Listen: run as iperf3 server for another machine to connect to.
#       throughput.sh --listen [--port 5201]
#
# Use a peer on the SAME LAN to validate cabling / switch / NIC actual speed
# (vs link negotiation). For Internet throughput, see `netkit speedtest`.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
SERVER=""
PORT=5201
DURATION=10
UDP=0
REVERSE=0
LISTEN=0
LISTEN_TIMEOUT=300   # seconds; server auto-exits after this


while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --server)
      [[ -n "${2:-}" ]] || die_usage "--server requires a host"
      SERVER="$2"; shift 2 ;;
    --port)
      [[ -n "${2:-}" ]] || die_usage "--port requires a number"
      PORT="$2"; shift 2 ;;
    --duration)
      [[ -n "${2:-}" ]] || die_usage "--duration requires seconds"
      DURATION="$2"; shift 2 ;;
    --listen-timeout)
      [[ -n "${2:-}" ]] || die_usage "--listen-timeout requires seconds"
      LISTEN_TIMEOUT="$2"; shift 2 ;;
    --udp) UDP=1; shift ;;
    --reverse) REVERSE=1; shift ;;
    --listen) LISTEN=1; shift ;;
    --yes) export NETKIT_YES=1; shift ;;
    --allow-raw) export NETKIT_ALLOW_RAW=1; shift ;;
    --dry-run) export NETKIT_DRY_RUN=1; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) die_usage "Unknown flag: $1" ;;
  esac
done

[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) \
  || die_usage "--port must be 1..65535"
[[ "$DURATION" =~ ^[0-9]+$ ]] && (( DURATION >= 1 && DURATION <= 300 )) \
  || die_usage "--duration must be 1..300 seconds"
[[ "$LISTEN_TIMEOUT" =~ ^[0-9]+$ ]] && (( LISTEN_TIMEOUT >= 10 && LISTEN_TIMEOUT <= 3600 )) \
  || die_usage "--listen-timeout must be 10..3600 seconds"
[[ -n "$SERVER" || $LISTEN -eq 1 ]] \
  || die_usage "either --server <host> or --listen is required"

guard_no_sudo
require_cmd iperf3

if dry_run; then
  log_dry "throughput would:"
  if (( LISTEN )); then
    log_dry "  mode    : server (listen, --one-off)"
    log_dry "  cmd     : iperf3 -s -p $PORT --one-off"
    log_dry "  watchdog: kill server after ${LISTEN_TIMEOUT}s if no client connects"
  else
    extra=""
    (( UDP ))     && extra="${extra} -u -b 0"
    (( REVERSE )) && extra="${extra} -R"
    log_dry "  mode  : client"
    log_dry "  target: $SERVER:$PORT"
    log_dry "  cmd   : iperf3 -c $SERVER -p $PORT -t $DURATION${extra}"
  fi
  log_dry "no traffic sent."
  exit 0
fi

if (( LISTEN )); then
  log_info "iperf3 server on :$PORT (--one-off; auto-exit after ${LISTEN_TIMEOUT}s if no client)"
  # --one-off makes iperf3 exit after the first client disconnects.
  # The watchdog then kills the server even if no client ever connects.
  iperf3 -s -p "$PORT" --one-off &
  IPERF_PID=$!
  (
    sleep "$LISTEN_TIMEOUT"
    if kill -0 "$IPERF_PID" 2>/dev/null; then
      log_warn "iperf3 server hit ${LISTEN_TIMEOUT}s timeout with no client; terminating."
      kill "$IPERF_PID" 2>/dev/null || true
    fi
  ) &
  WATCHDOG_PID=$!
  trap 'kill "$IPERF_PID" "$WATCHDOG_PID" 2>/dev/null || true' EXIT INT TERM
  wait "$IPERF_PID" 2>/dev/null || true
  kill "$WATCHDOG_PID" 2>/dev/null || true
  exit 0
fi

log_info "Measuring throughput to $SERVER:$PORT for ${DURATION}s..."

# Build command and capture JSON output.
CMD=(iperf3 -c "$SERVER" -p "$PORT" -t "$DURATION" -J)
(( UDP ))     && CMD+=(-u -b 0)
(( REVERSE )) && CMD+=(-R)

set +e
RAW=$("${CMD[@]}" 2>&1)
RC=$?
set -e

export NETKIT_FMT="$FORMAT" NETKIT_RAW="$RAW" NETKIT_RC="$RC" \
       NETKIT_SERVER="$SERVER" NETKIT_PORT="$PORT" \
       NETKIT_UDP="$UDP" NETKIT_REVERSE="$REVERSE"

python3 - <<'PY'
import json, os, sys

raw  = os.environ["NETKIT_RAW"]
rc   = int(os.environ["NETKIT_RC"])
fmt  = os.environ["NETKIT_FMT"]
udp  = os.environ["NETKIT_UDP"] == "1"
rev  = os.environ["NETKIT_REVERSE"] == "1"

# iperf3 -J emits a JSON object. Parse it.
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print({"error": "iperf3 did not return JSON", "rc": rc, "raw": raw[:500]} if fmt == "json"
          else f"iperf3 failed (rc={rc}):\n{raw[:500]}", file=sys.stderr)
    sys.exit(rc or 1)

# Summarized fields. iperf3 puts the totals in "end".
end = data.get("end", {})
sum_sent = end.get("sum_sent", {}) or end.get("sum_received", {})
sum_recv = end.get("sum_received", {})
result = {
    "server":     os.environ["NETKIT_SERVER"],
    "port":       int(os.environ["NETKIT_PORT"]),
    "udp":        udp,
    "reverse":    rev,
    "duration_s": sum_sent.get("seconds"),
    "sent_bytes": sum_sent.get("bytes"),
    "sent_mbps":  round((sum_sent.get("bits_per_second") or 0) / 1e6, 2),
    "recv_mbps":  round((sum_recv.get("bits_per_second") or 0) / 1e6, 2),
    "retransmits": sum_sent.get("retransmits"),
}
if udp:
    # UDP report carries jitter/loss differently.
    streams = end.get("streams", [])
    if streams:
        s = streams[0].get("udp", {})
        result["jitter_ms"] = s.get("jitter_ms")
        result["lost_packets"] = s.get("lost_packets")
        result["packet_loss"] = s.get("lost_percent")

if fmt == "json":
    print(json.dumps(result, indent=2))
elif fmt == "md":
    print(f"# iperf3 throughput — {result['server']}:{result['port']}\n")
    print(f"- **Duration:** {result['duration_s']} s")
    print(f"- **Sent:** {result['sent_mbps']} Mbps")
    print(f"- **Received:** {result['recv_mbps']} Mbps")
    if result.get("retransmits") is not None:
        print(f"- **TCP retransmits:** {result['retransmits']}")
    if result.get("jitter_ms") is not None:
        print(f"- **Jitter (UDP):** {result['jitter_ms']} ms")
        print(f"- **Loss (UDP):** {result['packet_loss']}%")
else:
    print(f"iperf3 → {result['server']}:{result['port']}  ({result['duration_s']}s)")
    print()
    print(f"  Sent     : {result['sent_mbps']:>8} Mbps")
    print(f"  Received : {result['recv_mbps']:>8} Mbps")
    if result.get("retransmits") is not None:
        print(f"  Retrans  : {result['retransmits']}")
    if udp:
        print(f"  Jitter   : {result.get('jitter_ms', '-')} ms")
        print(f"  Loss     : {result.get('packet_loss', '-')}%")
PY
