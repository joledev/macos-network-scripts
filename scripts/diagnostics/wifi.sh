#!/usr/bin/env bash
# Wi-Fi diagnostics: current SSID, RSSI, channel, security, supported PHY,
# plus a scan of nearby APs (SSID, channel, security).
#
# Two data sources:
#   - system_profiler SPAirPortDataType   (no sudo, default)
#   - wdutil info                          (richer, needs --allow-raw + sudo)
#
# Usage: wifi.sh [--scan] [--json|--md|--text]

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

export NETKIT_FMT="$FORMAT" NETKIT_WITH_WDUTIL="$USE_WDUTIL"

python3 - <<'PY'
import json, os, re, subprocess, sys

fmt = os.environ["NETKIT_FMT"]
use_wdutil = os.environ["NETKIT_WITH_WDUTIL"] == "1"

def sh(cmd, timeout=10):
    try:
        return subprocess.check_output(cmd, text=True,
                                       stderr=subprocess.DEVNULL, timeout=timeout)
    except Exception:
        return ""

# ---- system_profiler ----
sp = sh(["system_profiler", "SPAirPortDataType"])

result = {
    "interface": "",
    "mac": "",
    "country_code": "",
    "phy_modes": "",
    "current": {
        "ssid": "",
        "phy_mode": "",
        "channel": "",
        "band": "",
        "channel_width": "",
        "security": "",
        "signal_dbm": None,
        "noise_dbm": None,
        "tx_rate_mbps": None,
    },
    "nearby_aps": [],
    "wdutil_used": False,
}

# Parse: hierarchical key:value plain text.
def parse_channel(value: str, ap: dict) -> None:
    ap["channel"] = value
    m = re.match(r"(\d+)\s*\(([^,]+)(?:,\s*(\S+))?\)", value)
    if m:
        ap["band"] = m.group(2).strip()
        if m.group(3):
            ap["channel_width"] = m.group(3).strip()

def apply_field(ap: dict, key: str, value: str) -> None:
    if key == "PHY Mode":
        ap["phy_mode"] = value
    elif key == "Channel":
        parse_channel(value, ap)
    elif key == "Security":
        ap["security"] = value
    elif key == "Signal / Noise":
        m = re.search(r"(-?\d+)\s*dBm\s*/\s*(-?\d+)\s*dBm", value)
        if m:
            ap["signal_dbm"] = int(m.group(1))
            ap["noise_dbm"]  = int(m.group(2))
    elif key == "Transmit Rate":
        try:
            ap["tx_rate_mbps"] = int(value)
        except ValueError:
            pass

section = None             # "current" | "nearby" | None
current_target = None      # the dict we're filling right now
ssid_pattern = re.compile(r"^[^:]+:$")  # a bare SSID heading ends with ':'

for line in sp.splitlines():
    stripped = line.strip()
    if not stripped:
        continue
    # Section switches.
    if stripped == "Current Network Information:":
        section = "current"
        current_target = None
        continue
    if stripped == "Other Local Wi-Fi Networks:":
        section = "nearby"
        current_target = None
        continue
    # Always extract these top-level attrs no matter the section.
    if stripped.startswith("MAC Address:"):
        result["mac"] = stripped.split(":", 1)[1].strip()
        continue
    if stripped.startswith("Country Code:") and not result["country_code"]:
        result["country_code"] = stripped.split(":", 1)[1].strip()
        continue
    if stripped.startswith("Supported PHY Modes:"):
        result["phy_modes"] = stripped.split(":", 1)[1].strip()
        continue
    if re.match(r"^en\d+:$", stripped):
        result["interface"] = stripped.rstrip(":")
        continue
    # Section-specific.
    if section == "current":
        if ":" in stripped and not ssid_pattern.match(stripped):
            key, _, val = stripped.partition(":")
            if current_target is None:
                # We haven't seen the SSID heading yet — skip.
                continue
            apply_field(current_target, key.strip(), val.strip())
        elif ssid_pattern.match(stripped):
            result["current"]["ssid"] = stripped.rstrip(":")
            current_target = result["current"]
    elif section == "nearby":
        if ssid_pattern.match(stripped):
            ap = {"ssid": stripped.rstrip(":"),
                  "phy_mode": "", "channel": "", "band": "",
                  "channel_width": "", "security": ""}
            result["nearby_aps"].append(ap)
            current_target = ap
        elif current_target is not None and ":" in stripped:
            key, _, val = stripped.partition(":")
            apply_field(current_target, key.strip(), val.strip())

# Filter out interfaces (awdl0/llw0 etc.) that snuck into "nearby" because
# they appear with a trailing colon in system_profiler.
result["nearby_aps"] = [a for a in result["nearby_aps"]
                        if a.get("channel") or a.get("security")]

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

# Co-channel summary: how many of the nearby APs are on the same channel as
# the current connection (a quick-and-dirty interference indicator).
cur_ch = result["current"]["channel"]
if cur_ch:
    cur_n = re.match(r"(\d+)", cur_ch)
    if cur_n:
        cur_num = cur_n.group(1)
        same = [a for a in result["nearby_aps"]
                if re.match(r"^" + cur_num + r"\b", a.get("channel", ""))]
        result["co_channel_count"] = len(same)

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
PY
