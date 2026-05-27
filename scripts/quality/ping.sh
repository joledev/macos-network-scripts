#!/usr/bin/env bash
# Quality test: latency, jitter and packet loss to gateway + configured targets.
#
# Usage:
#   ping.sh [--interface en7] [--count 30] [--json|--md|--text]
#   ping.sh --targets 1.1.1.1,8.8.8.8,github.com

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
COUNT=20
IFACE=""
TARGETS=""

die_usage() { log_err "$*"; exit 2; }

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md) FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --count)
      [[ -n "${2:-}" ]] || die_usage "--count requires an integer 1..1000"
      COUNT="$2"; shift 2 ;;
    --interface) IFACE="$2"; shift 2 ;;
    --targets) TARGETS="$2"; shift 2 ;;
    --yes) export NETKIT_YES=1; shift ;;
    --allow-raw) export NETKIT_ALLOW_RAW=1; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) die_usage "Unknown flag: $1" ;;
  esac
done

# Validate --count: bounded positive integer (cap at 1000 — anything bigger
# is a runaway and ping would hammer the link for minutes).
[[ "$COUNT" =~ ^[0-9]+$ ]] || die_usage "--count must be an integer (got: ${COUNT})"
(( COUNT >= 1 && COUNT <= 1000 )) || die_usage "--count must be between 1 and 1000 (got: ${COUNT})"

# Validate --targets if provided. Each comma-separated token must match a
# safe character class (host/IP/domain). Rejects shell metachars, quotes,
# whitespace — also makes the heredoc interpolation in this script safe.
if [[ -n "$TARGETS" ]]; then
  IFS=',' read -r -a _TGT_ARR <<< "$TARGETS"
  for _t in "${_TGT_ARR[@]}"; do
    _t="${_t// /}"
    [[ -z "$_t" ]] && continue
    [[ "$_t" =~ ^[A-Za-z0-9._:-]+$ ]] || die_usage "--targets contains invalid token: '${_t}' (allowed chars: A-Z a-z 0-9 . _ : -)"
  done
fi

guard_no_sudo
[[ -z "$IFACE" ]] && IFACE=$(pick_interface || true)
[[ -z "$IFACE" ]] && die "Could not pick a network interface."

GW=$(default_gateway || true)

# Build target list: gateway first, then user targets, then defaults
if [[ -z "$TARGETS" ]]; then
  TARGETS="$NETKIT_PING_TARGETS"
fi
ALL=("$GW")
IFS=',' read -r -a USR <<< "$TARGETS"
for t in "${USR[@]}"; do
  t="${t// /}"
  [[ -n "$t" ]] && ALL+=("$t")
done

log_info "Pinging via $IFACE: ${ALL[*]} (count=$COUNT)"

# Run pings and capture per-target output
RESULTS_FILE="$(mktemp -t netkit-ping.XXXXXX)"
trap 'rm -f "$RESULTS_FILE"' EXIT

echo "[" > "$RESULTS_FILE"
FIRST=1
for tgt in "${ALL[@]}"; do
  [[ -z "$tgt" ]] && continue
  out=$(ping -b "$IFACE" -c "$COUNT" -i 0.2 -q "$tgt" 2>&1 || true)
  # Pull stats. macOS ping output:
  #   X packets transmitted, Y packets received, Z.Z% packet loss
  #   round-trip min/avg/max/stddev = a/b/c/d ms
  loss=$(printf '%s' "$out" | awk -F'[ %]' '/packet loss/ {for(i=1;i<=NF;i++) if($i=="loss"){print $(i-2); exit}}')
  stats=$(printf '%s' "$out" | awk -F'= ' '/min\/avg\/max/ {print $2; exit}' | awk '{print $1}')
  mn=""; av=""; mx=""; sd=""
  if [[ -n "$stats" ]]; then
    IFS='/' read -r mn av mx sd <<< "$stats"
  fi
  sent=$(printf '%s' "$out" | awk -F'[ ,]+' '/packets transmitted/ {print $1; exit}')
  recv=$(printf '%s' "$out" | awk -F'[ ,]+' '/packets received/ {for(i=1;i<NF;i++) if($i=="packets" && $(i+1)=="received") {print $(i-1); exit}}')

  (( FIRST )) || echo "," >> "$RESULTS_FILE"
  FIRST=0
  python3 - >>"$RESULTS_FILE" <<PY
import json
print(json.dumps({
    "target": "$tgt",
    "sent": int("$sent" or 0),
    "received": int("$recv" or 0),
    "loss_pct": float("$loss" or 0),
    "rtt_min_ms": float("$mn" or 0),
    "rtt_avg_ms": float("$av" or 0),
    "rtt_max_ms": float("$mx" or 0),
    "rtt_stddev_ms": float("$sd" or 0),
}, indent=2))
PY
done
echo "]" >> "$RESULTS_FILE"

# DNS lookup timing
DNS_TIME_MS=""
if has_cmd dig; then
  DNS_RAW=$(dig +stats +noall +answer "$NETKIT_DNS_DOMAIN" 2>/dev/null || true)
  # dig prints Query time elsewhere; do a second pass
  Q=$(dig "$NETKIT_DNS_DOMAIN" 2>/dev/null | awk '/Query time:/ {print $4; exit}')
  DNS_TIME_MS="${Q:-}"
fi

python3 - <<PY
import json, sys
with open("${RESULTS_FILE}") as f:
    rows = json.load(f)
result = {
    "interface": "${IFACE}",
    "gateway": "${GW}",
    "dns_domain": "${NETKIT_DNS_DOMAIN}",
    "dns_query_ms": float("${DNS_TIME_MS}" or 0) if "${DNS_TIME_MS}" else None,
    "targets": rows,
}

fmt = "${FORMAT}"
if fmt == "json":
    print(json.dumps(result, indent=2))
elif fmt == "md":
    print(f"# Network quality — via {result['interface']}\n")
    if result["dns_query_ms"] is not None:
        print(f"- **DNS lookup ({result['dns_domain']}):** {result['dns_query_ms']} ms\n")
    print("| target | sent | recv | loss % | min ms | avg ms | max ms | stddev (jitter) ms |")
    print("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for r in rows:
        print(f"| {r['target']} | {r['sent']} | {r['received']} | {r['loss_pct']:.1f} | {r['rtt_min_ms']:.2f} | {r['rtt_avg_ms']:.2f} | {r['rtt_max_ms']:.2f} | {r['rtt_stddev_ms']:.2f} |")
else:
    print(f"Interface : {result['interface']}")
    print(f"Gateway   : {result['gateway']}")
    if result['dns_query_ms'] is not None:
        print(f"DNS       : {result['dns_query_ms']} ms ({result['dns_domain']})")
    print()
    fmt_row = "{:<22} {:>5} {:>5} {:>7} {:>8} {:>8} {:>8} {:>10}"
    print(fmt_row.format("target","sent","recv","loss%","min","avg","max","stddev"))
    print("-" * 88)
    for r in rows:
        print(fmt_row.format(r["target"], r["sent"], r["received"],
                              f"{r['loss_pct']:.1f}",
                              f"{r['rtt_min_ms']:.2f}", f"{r['rtt_avg_ms']:.2f}",
                              f"{r['rtt_max_ms']:.2f}", f"{r['rtt_stddev_ms']:.2f}"))
PY
