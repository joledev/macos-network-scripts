#!/usr/bin/env bash
# Wi-Fi diagnostics: current SSID, RSSI, channel, security, supported PHY,
# plus a scan of nearby APs (SSID, channel, security).
#
# Two data sources:
#   - system_profiler SPAirPortDataType   (no sudo, default)
#   - wdutil info                          (richer, needs --allow-raw + sudo)
#
# Usage: wifi.sh [--survey] [--json|--md|--text]
#   --survey   passive RF site survey of ALL nearby APs: per-band / per-channel
#              / per-security tallies + least-congested 2.4GHz channel

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
SURVEY=0

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --survey) SURVEY=1; shift ;;
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

USE_WDUTIL=0
if [[ "${NETKIT_ALLOW_RAW:-0}" == "1" ]] && has_cmd wdutil && sudo -n true 2>/dev/null; then
  USE_WDUTIL=1
fi

if dry_run; then
  log_dry "wifi would:"
  log_dry "  source : system_profiler SPAirPortDataType (no sudo)"
  if (( USE_WDUTIL )); then
    log_dry "         : + sudo wdutil info (richer data)"
  else
    log_dry "  hint   : --allow-raw + 'sudo -v' for richer wdutil data"
  fi
  log_dry "no probes sent."
  exit 0
fi

export NETKIT_FMT="$FORMAT" NETKIT_WITH_WDUTIL="$USE_WDUTIL" NETKIT_SURVEY="$SURVEY"

python3 - <<'PY'
import json, os, re, subprocess, sys

sys.path.insert(0, os.path.join(os.environ["NETKIT_ROOT"], "scripts/utils"))
import wifi_parser

fmt = os.environ["NETKIT_FMT"]
use_wdutil = os.environ["NETKIT_WITH_WDUTIL"] == "1"
want_survey = os.environ.get("NETKIT_SURVEY") == "1"

def sh(cmd, timeout=10):
    try:
        return subprocess.check_output(cmd, text=True,
                                       stderr=subprocess.DEVNULL, timeout=timeout)
    except Exception:
        return ""

# ---- system_profiler — parsing extracted to scripts/utils/wifi_parser.py ----
sp = sh(["system_profiler", "SPAirPortDataType"])
result = wifi_parser.parse(sp)
result["wdutil_used"] = False


# ---- wdutil (optional, sudo) ----
if use_wdutil:
    wd = sh(["sudo", "-n", "wdutil", "info"])
    if wd:
        result["wdutil_used"] = True
        # Extract a couple of useful fields wdutil gives that system_profiler
        # doesn't: RSSI in real time, link rate, noise, channel bandwidth.
        for ln in wd.splitlines():
            s = ln.strip()
            if s.startswith("RSSI"):
                m = re.search(r"(-?\d+)\s*dBm", s)
                if m:
                    result["current"]["signal_dbm"] = int(m.group(1))
            elif s.startswith("Noise"):
                m = re.search(r"(-?\d+)\s*dBm", s)
                if m:
                    result["current"]["noise_dbm"] = int(m.group(1))
            elif s.startswith("Tx Rate"):
                m = re.search(r"(\d+(?:\.\d+)?)", s)
                if m:
                    result["current"]["tx_rate_mbps"] = float(m.group(1))

# Co-channel summary (interference indicator).
result["co_channel_count"] = wifi_parser.co_channel_count(result)
# Passive site survey (always computed; surfaced in text/md only with --survey).
result["survey"] = wifi_parser.survey(result)

if fmt == "json":
    print(json.dumps(result, indent=2))
elif fmt == "md":
    cur = result["current"]
    print(f"# Wi-Fi diagnostics ({result['interface']})\n")
    print(f"- **Connected to:** `{cur['ssid'] or '(not connected)'}`")
    print(f"- **PHY / Channel:** {cur['phy_mode']} / {cur['channel']}")
    print(f"- **Security:** {cur['security']}")
    print(f"- **Signal / Noise:** {cur['signal_dbm']} dBm / {cur['noise_dbm']} dBm")
    print(f"- **Tx rate:** {cur['tx_rate_mbps']} Mbps")
    if result.get("co_channel_count") is not None:
        print(f"- **Same-channel APs nearby:** {result['co_channel_count']}")
    print(f"- **Source:** system_profiler{' + wdutil' if result['wdutil_used'] else ''}\n")
    print(f"## Nearby APs ({len(result['nearby_aps'])})\n")
    if result["nearby_aps"]:
        print("| SSID | PHY | Channel | Security |")
        print("| --- | --- | --- | --- |")
        for a in result["nearby_aps"]:
            print(f"| {a['ssid']} | {a['phy_mode']} | {a['channel']} | {a['security']} |")
else:
    cur = result["current"]
    print(f"Interface: {result['interface']}   MAC: {result['mac']}   Country: {result['country_code']}")
    print(f"PHY modes supported: {result['phy_modes']}")
    print()
    print(f"Connected to: {cur['ssid'] or '(not connected)'}")
    print(f"  PHY         : {cur['phy_mode']}")
    print(f"  Channel     : {cur['channel']}")
    print(f"  Security    : {cur['security']}")
    print(f"  Signal      : {cur['signal_dbm']} dBm")
    print(f"  Noise       : {cur['noise_dbm']} dBm")
    print(f"  Tx rate     : {cur['tx_rate_mbps']} Mbps")
    if result.get("co_channel_count") is not None:
        print(f"  Co-channel  : {result['co_channel_count']} nearby APs")
    print()
    print(f"Nearby APs ({len(result['nearby_aps'])}):")
    if result["nearby_aps"]:
        print(f"  {'SSID':<32} {'PHY':<22} {'Channel':<22} Security")
        print("  " + "-" * 100)
        for a in result["nearby_aps"]:
            print(f"  {a['ssid'][:32]:<32} {a['phy_mode'][:22]:<22} {a['channel'][:22]:<22} {a['security']}")

if want_survey and fmt in ("text", "md"):
    s = result["survey"]
    print()
    print("## Site survey (passive)\n" if fmt == "md" else "Site survey (passive RF):")
    print(f"  APs seen     : {s['ap_count']}")
    print(f"  Bands        : " + ", ".join(f"{k}={v}" for k, v in s["bands"].items()))
    print(f"  Channels     : " + ", ".join(f"ch{k}:{v}" for k, v in s["channels"].items()))
    print(f"  Security     : " + ", ".join(f"{k}={v}" for k, v in s["security"].items()))
    if s.get("recommend_2ghz_channel"):
        print(f"  Best 2.4GHz  : channel {s['recommend_2ghz_channel']} (least crowded of 1/6/11)")
    if s.get("weak_security_ssids"):
        print(f"  Weak security: {', '.join(s['weak_security_ssids'])}")
    if s.get("by_signal"):
        print("  Strongest APs:")
        for a in s["by_signal"][:10]:
            print(f"    {a.get('signal_dbm')} dBm  ch {a.get('channel','')}  "
                  f"{a.get('security','')}  {a.get('ssid','')}")
PY
