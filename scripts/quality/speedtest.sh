#!/usr/bin/env bash
# Measure ISP throughput + ping using whichever speedtest CLI is installed.
#
# Order of preference:
#   1. Ookla `speedtest` (brew install speedtest, recommended)
#   2. `cloudflare-speed-cli` (already on this Mac per dotfiles)
#   3. Plain curl timing against a Cloudflare endpoint (degraded fallback)
#
# Output: { download_mbps, upload_mbps, ping_ms, jitter_ms, server, isp }
#
# Usage: speedtest.sh [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
die_usage() { log_err "$*"; exit 2; }

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
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

# Pick the best available speedtest tool.
TOOL=""
if has_cmd speedtest && speedtest --version 2>&1 | grep -qi "ookla"; then
  TOOL="ookla"
elif has_cmd cloudflare-speed-cli; then
  TOOL="cloudflare"
elif has_cmd curl; then
  TOOL="curl"
else
  die "no speedtest tool found. Install one: brew install speedtest"
fi

if dry_run; then
  log_dry "speedtest would:"
  log_dry "  tool : ${TOOL}"
  case "$TOOL" in
    ookla) log_dry "  cmd  : speedtest --accept-license --accept-gdpr --format=json" ;;
    cloudflare) log_dry "  cmd  : cloudflare-speed-cli --json" ;;
    curl) log_dry "  cmd  : curl-based download/upload to speed.cloudflare.com (degraded)" ;;
  esac
  log_dry "no traffic sent."
  exit 0
fi

log_info "Running speedtest via ${TOOL}..."

export NETKIT_FMT="$FORMAT" NETKIT_TOOL="$TOOL"

python3 - <<'PY'
import json, os, re, subprocess, sys

fmt  = os.environ["NETKIT_FMT"]
tool = os.environ["NETKIT_TOOL"]

def sh(cmd, timeout=120):
    try:
        return subprocess.check_output(cmd, shell=False, text=True,
                                       stderr=subprocess.DEVNULL, timeout=timeout)
    except Exception as e:
        return f"__error__: {e}"

result = {
    "tool": tool,
    "download_mbps": None,
    "upload_mbps":   None,
    "ping_ms":       None,
    "jitter_ms":     None,
    "packet_loss":   None,
    "server":        "",
    "isp":           "",
    "raw":           None,
}

if tool == "ookla":
    out = sh(["speedtest", "--accept-license", "--accept-gdpr", "--format=json"])
    if out.startswith("__error__"):
        result["error"] = out; print(json.dumps(result, indent=2) if fmt == "json" else out); sys.exit(1)
    d = json.loads(out)
    # bandwidth fields are bytes/sec; convert to Mbps (×8 / 1e6)
    dl = d.get("download", {}).get("bandwidth", 0) * 8 / 1e6
    ul = d.get("upload", {}).get("bandwidth", 0) * 8 / 1e6
    result.update({
        "download_mbps": round(dl, 2),
        "upload_mbps":   round(ul, 2),
        "ping_ms":       d.get("ping", {}).get("latency"),
        "jitter_ms":     d.get("ping", {}).get("jitter"),
        "packet_loss":   d.get("packetLoss"),
        "server":        f'{d.get("server",{}).get("name","")} ({d.get("server",{}).get("location","")})',
        "isp":           d.get("isp", ""),
        "raw":           d,
    })

elif tool == "cloudflare":
    out = sh(["cloudflare-speed-cli", "--json"])
    if out.startswith("__error__"):
        result["error"] = out; print(json.dumps(result, indent=2) if fmt == "json" else out); sys.exit(1)
    try:
        d = json.loads(out)
    except json.JSONDecodeError:
        # cloudflare-speed-cli may emit non-JSON if --json isn't supported.
        result["error"] = "cloudflare-speed-cli did not return JSON; raw:"
        result["raw"] = out[:500]
    else:
        result.update({
            "download_mbps": d.get("downloadMbps") or d.get("download_mbps") or d.get("download"),
            "upload_mbps":   d.get("uploadMbps")   or d.get("upload_mbps")   or d.get("upload"),
            "ping_ms":       d.get("latencyMs")    or d.get("latency_ms")    or d.get("latency"),
            "jitter_ms":     d.get("jitterMs")     or d.get("jitter_ms"),
            "server":        d.get("server", "Cloudflare"),
            "raw":           d,
        })

else:  # curl fallback — coarse, no upload
    # Download a 10 MB blob from speed.cloudflare.com and measure time_total.
    out = sh(["curl", "-sS", "-o", "/dev/null", "-w",
              "%{speed_download} %{time_total} %{time_connect}\n",
              "https://speed.cloudflare.com/__down?bytes=10000000"],
             timeout=60)
    if out and not out.startswith("__error__"):
        parts = out.strip().split()
        if len(parts) >= 3:
            bps = float(parts[0])
            result["download_mbps"] = round(bps * 8 / 1e6, 2)
            result["ping_ms"] = round(float(parts[2]) * 1000, 2)
            result["server"] = "speed.cloudflare.com"

# Output
if fmt == "json":
    print(json.dumps(result, indent=2, default=str))
elif fmt == "md":
    print(f"# Speedtest ({tool})\n")
    print(f"- **Download:** {result['download_mbps']} Mbps")
    print(f"- **Upload:** {result['upload_mbps']} Mbps")
    print(f"- **Ping:** {result['ping_ms']} ms")
    print(f"- **Jitter:** {result['jitter_ms']} ms")
    print(f"- **Packet loss:** {result.get('packet_loss')}")
    print(f"- **Server:** {result['server']}")
    print(f"- **ISP:** {result['isp']}")
else:
    print(f"speedtest via {tool}")
    print()
    print(f"  Download  : {result['download_mbps']:>8} Mbps" if result['download_mbps'] else "  Download  : -")
    print(f"  Upload    : {result['upload_mbps']:>8} Mbps"   if result['upload_mbps']   else "  Upload    : -")
    print(f"  Ping      : {result['ping_ms']:>8} ms"          if result['ping_ms']       else "  Ping      : -")
    if result['jitter_ms']:
        print(f"  Jitter    : {result['jitter_ms']:>8} ms")
    if result.get('packet_loss') is not None:
        print(f"  Loss      : {result['packet_loss']}%")
    if result.get('server'): print(f"  Server    : {result['server']}")
    if result.get('isp'):    print(f"  ISP       : {result['isp']}")
PY
