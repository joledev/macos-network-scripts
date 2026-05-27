#!/usr/bin/env bash
# Pull a UniFi Network Application (a.k.a. UniFi Controller) inventory:
# sites, devices (APs, switches, gateways), clients, WLAN configs and
# health stats. Read-only.
#
# Auth: username + password (HTTP cookie/session) over HTTPS to the
# controller. Works with both the classic ``/api/login`` (older
# self-hosted controllers, port 8443) and the UniFi OS ``/api/auth/login``
# flow (newer Cloud Key / UDM Pro / Dream Machine, port 443).
#
# Secrets come from environment or .env — never on the command line.
# Required: NETKIT_UNIFI_HOST, NETKIT_UNIFI_USER, NETKIT_UNIFI_PASS.
#
# Usage:
#   set -x NETKIT_UNIFI_HOST  https://192.168.1.1
#   set -x NETKIT_UNIFI_USER  netaudit
#   set -x NETKIT_UNIFI_PASS  '...'
#   ./bin/netkit unifi [--site default] [--insecure] [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
SITE="default"
INSECURE=0

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --site)
      [[ -n "${2:-}" ]] || die_usage "--site requires a value"
      SITE="$2"; shift 2 ;;
    --insecure) INSECURE=1; shift ;;
    --yes) export NETKIT_YES=1; shift ;;
    --allow-raw) export NETKIT_ALLOW_RAW=1; shift ;;
    --dry-run) export NETKIT_DRY_RUN=1; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) die_usage "Unknown flag: $1" ;;
  esac
done

[[ "$SITE" =~ ^[A-Za-z0-9_-]+$ ]] || die_usage "--site invalid"

# Required env vars.
: "${NETKIT_UNIFI_HOST:?NETKIT_UNIFI_HOST is required (e.g. https://192.168.1.1)}"
: "${NETKIT_UNIFI_USER:?NETKIT_UNIFI_USER is required}"
: "${NETKIT_UNIFI_PASS:?NETKIT_UNIFI_PASS is required}"

guard_no_sudo

if dry_run; then
  log_dry "unifi would:"
  log_dry "  target   : ${NETKIT_UNIFI_HOST}"
  log_dry "  site     : ${SITE}"
  log_dry "  user     : ${NETKIT_UNIFI_USER}"
  log_dry "  insecure : ${INSECURE} (skip TLS verify; common for self-signed UDM/CK)"
  log_dry "  queries  :"
  log_dry "    POST /api/auth/login (UniFi OS) or /api/login (legacy)"
  log_dry "    GET  /proxy/network/api/self/sites           (or /api/self/sites)"
  log_dry "    GET  /proxy/network/api/s/<site>/stat/sysinfo"
  log_dry "    GET  /proxy/network/api/s/<site>/stat/device  (APs/switches/gateways)"
  log_dry "    GET  /proxy/network/api/s/<site>/stat/sta     (associated clients)"
  log_dry "    GET  /proxy/network/api/s/<site>/rest/wlanconf (SSID configs)"
  log_dry "    GET  /proxy/network/api/s/<site>/stat/health"
  log_dry "no traffic sent."
  exit 0
fi

export NETKIT_FMT="$FORMAT" NETKIT_UNIFI_SITE="$SITE" NETKIT_INSECURE="$INSECURE"

python3 - <<'PY'
import json
import os
import ssl
import sys
import urllib.error
import urllib.request
from typing import Any

HOST     = os.environ["NETKIT_UNIFI_HOST"].rstrip("/")
USER     = os.environ["NETKIT_UNIFI_USER"]
PASS     = os.environ["NETKIT_UNIFI_PASS"]
SITE     = os.environ["NETKIT_UNIFI_SITE"]
FMT      = os.environ["NETKIT_FMT"]
INSECURE = os.environ["NETKIT_INSECURE"] == "1"

# Cookie jar manually managed (CookiePolicy from stdlib gets in the way of
# UniFi's "X-CSRF-Token" auth).
cookies: dict[str, str] = {}
csrf_token: str = ""

ctx = ssl.create_default_context()
if INSECURE:
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE


def _build_cookie_header() -> str:
    return "; ".join(f"{k}={v}" for k, v in cookies.items())


def _request(method: str, path: str, body: dict | None = None) -> dict:
    url = f"{HOST}{path}"
    data: bytes | None = None
    headers = {
        "Accept":       "application/json",
        "Content-Type": "application/json",
    }
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    if cookies:
        headers["Cookie"] = _build_cookie_header()
    if csrf_token:
        headers["X-CSRF-Token"] = csrf_token

    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=8) as resp:
            for header, value in resp.headers.items():
                if header.lower() == "set-cookie":
                    # Parse `name=value; attr=...; attr...`
                    parts = value.split(";", 1)[0].split("=", 1)
                    if len(parts) == 2:
                        cookies[parts[0].strip()] = parts[1].strip()
                elif header.lower() == "x-csrf-token":
                    globals()["csrf_token"] = value
            raw = resp.read().decode("utf-8", errors="replace")
            return {"status": resp.status, "body": raw}
    except urllib.error.HTTPError as e:
        return {"status": e.code, "body": e.read().decode("utf-8", errors="replace"),
                "error": str(e)}
    except (urllib.error.URLError, OSError) as e:
        return {"status": 0, "body": "", "error": str(e)}


def _json(resp: dict) -> Any:
    try:
        return json.loads(resp.get("body", ""))
    except json.JSONDecodeError:
        return None


# ---- Detect UniFi OS vs legacy controller ----
# UniFi OS exposes /api/auth/login + proxies the Network app under
# /proxy/network. Legacy controller uses /api/login + endpoints at /api/.
def _login() -> tuple[bool, str]:
    """Try UniFi OS auth first; fall back to legacy."""
    # UniFi OS
    r = _request("POST", "/api/auth/login",
                 {"username": USER, "password": PASS, "rememberMe": False})
    if r["status"] == 200:
        return True, "unifi-os"
    # Legacy
    r = _request("POST", "/api/login", {"username": USER, "password": PASS})
    if r["status"] == 200:
        return True, "legacy"
    err = r.get("error", "") or r.get("body", "")[:200]
    return False, f"login failed (status={r['status']}): {err}"


def _api_prefix(flavor: str) -> str:
    return "/proxy/network/api" if flavor == "unifi-os" else "/api"


# ---- Execute ----
ok, flavor = _login()
if not ok:
    err_payload = {
        "host": HOST, "site": SITE, "logged_in": False, "error": flavor,
    }
    if FMT == "json":
        print(json.dumps(err_payload, indent=2))
    else:
        print(f"UniFi {HOST}: {flavor}", file=sys.stderr)
    sys.exit(1)

api = _api_prefix(flavor)


def get_data(path: str) -> list[dict]:
    r = _request("GET", f"{api}{path}")
    d = _json(r) or {}
    if isinstance(d, dict):
        return d.get("data", []) or []
    return d if isinstance(d, list) else []


sites    = get_data("/self/sites")
sysinfo  = get_data(f"/s/{SITE}/stat/sysinfo")
devices  = get_data(f"/s/{SITE}/stat/device")
clients  = get_data(f"/s/{SITE}/stat/sta")
wlans    = get_data(f"/s/{SITE}/rest/wlanconf")
health   = get_data(f"/s/{SITE}/stat/health")

# Project devices into a compact shape.
def _device_compact(d: dict) -> dict:
    return {
        "mac":        d.get("mac"),
        "model":      d.get("model") or d.get("model_in_lts") or "",
        "model_name": d.get("model_in_eol_str") or d.get("name") or "",
        "type":       d.get("type"),
        "name":       d.get("name") or d.get("hostname") or "",
        "ip":         d.get("ip"),
        "version":    d.get("version"),
        "adopted":    d.get("adopted"),
        "state":      d.get("state"),    # 0=disconnected,1=connected,...
        "uptime_s":   d.get("uptime"),
        "site_id":    d.get("site_id"),
        "num_ports":  d.get("num_port") or len(d.get("port_table") or []),
        "num_sta":    d.get("num_sta"),
        "cpu_pct":    (d.get("system-stats") or {}).get("cpu"),
        "mem_pct":    (d.get("system-stats") or {}).get("mem"),
        "uplink_speed_mbps": (d.get("uplink") or {}).get("speed"),
        "uplink_full_duplex": (d.get("uplink") or {}).get("full_duplex"),
        "lan_ip":     d.get("lan_ip"),
        "is_gateway": d.get("type") == "ugw" or d.get("type") == "udm",
        "is_switch":  d.get("type") == "usw",
        "is_ap":      d.get("type") == "uap",
    }


def _client_compact(c: dict) -> dict:
    return {
        "mac":        c.get("mac"),
        "hostname":   c.get("hostname"),
        "name":       c.get("name"),
        "ip":         c.get("ip"),
        "essid":      c.get("essid"),
        "ap_mac":     c.get("ap_mac"),
        "sw_mac":     c.get("sw_mac"),
        "sw_port":    c.get("sw_port"),
        "uptime_s":   c.get("uptime"),
        "rx_bytes":   c.get("rx_bytes"),
        "tx_bytes":   c.get("tx_bytes"),
        "signal_dbm": c.get("signal"),
        "noise_dbm":  c.get("noise"),
        "channel":    c.get("channel"),
        "radio":      c.get("radio_proto") or c.get("radio"),
        "is_wired":   c.get("is_wired"),
        "is_guest":   c.get("is_guest"),
    }


def _wlan_compact(w: dict) -> dict:
    return {
        "name":     w.get("name"),
        "enabled":  w.get("enabled"),
        "security": w.get("security"),
        "wpa_mode": w.get("wpa_mode"),
        "is_guest": w.get("is_guest"),
        "hide_ssid": w.get("hide_ssid"),
        "vlan":     w.get("vlan"),
        "vlan_enabled": w.get("vlan_enabled"),
        "radius":   w.get("radius_enabled") or False,
        "passphrase_known": bool(w.get("x_passphrase")),
    }


# Health is a list of subsystem dicts; flatten.
health_map = {h.get("subsystem"): h for h in health if isinstance(h, dict)}

result = {
    "host":      HOST,
    "flavor":    flavor,
    "site":      SITE,
    "logged_in": True,
    "controller_sysinfo": sysinfo[0] if sysinfo else {},
    "sites":     [{"name": s.get("name"), "desc": s.get("desc"),
                    "site_id": s.get("_id")} for s in sites],
    "devices":   [_device_compact(d) for d in devices],
    "clients":   [_client_compact(c) for c in clients],
    "wlans":     [_wlan_compact(w) for w in wlans],
    "health":    {k: {"status": v.get("status"), "num_user": v.get("num_user"),
                      "num_disconnected": v.get("num_disconnected")}
                  for k, v in health_map.items()},
    "counts": {
        "sites":   len(sites),
        "devices": len(devices),
        "clients": len(clients),
        "wlans":   len(wlans),
        "aps":      sum(1 for d in devices if d.get("type") == "uap"),
        "switches": sum(1 for d in devices if d.get("type") == "usw"),
        "gateways": sum(1 for d in devices if d.get("type") in {"ugw", "udm"}),
    },
}


# Try to log out cleanly.
_request("POST", "/api/auth/logout" if flavor == "unifi-os" else "/api/logout")


if FMT == "json":
    print(json.dumps(result, indent=2, default=str))
elif FMT == "md":
    c = result["counts"]
    print(f"# UniFi inventory — `{HOST}` (site `{SITE}`)\n")
    print(f"- **Flavor:** {flavor}")
    print(f"- **Devices:** {c['devices']} ({c['aps']} APs, {c['switches']} switches, {c['gateways']} gateways)")
    print(f"- **Active clients:** {c['clients']}")
    print(f"- **WLANs configured:** {c['wlans']}\n")
    print("## Devices\n")
    print("| name | type | model | IP | version | uptime | clients | uplink |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- |")
    for d in result["devices"]:
        print(f"| {d['name']} | {d['type']} | {d['model']} | {d['ip']} | "
              f"{d['version']} | {d['uptime_s']}s | {d['num_sta']} | "
              f"{d['uplink_speed_mbps']} Mbps |")
    print(f"\n## WLANs ({c['wlans']})\n")
    print("| SSID | enabled | security | VLAN | guest |")
    print("| --- | --- | --- | --- | --- |")
    for w in result["wlans"]:
        vlan = w["vlan"] if w["vlan_enabled"] else "—"
        print(f"| {w['name']} | {w['enabled']} | {w['security']}/{w['wpa_mode']} | {vlan} | {w['is_guest']} |")
    print(f"\n## Clients ({c['clients']})\n")
    print("| name | IP | MAC | SSID/sw_port | radio | signal |")
    print("| --- | --- | --- | --- | --- | --- |")
    for cl in result["clients"][:80]:
        loc = cl["essid"] if cl["essid"] else (f"port {cl['sw_port']}" if cl["sw_port"] else "—")
        sig = f"{cl['signal_dbm']} dBm" if cl["signal_dbm"] is not None else "—"
        print(f"| {cl['name'] or cl['hostname'] or ''} | {cl['ip']} | {cl['mac']} | {loc} | {cl['radio'] or '—'} | {sig} |")
    if len(result["clients"]) > 80:
        print(f"\n_{len(result['clients']) - 80} more clients (use --json for the full list)._")
else:
    c = result["counts"]
    print(f"UniFi {flavor} @ {HOST}  site: {SITE}")
    print()
    print(f"  Sites          : {c['sites']}")
    print(f"  Devices        : {c['devices']}  ({c['aps']} APs · {c['switches']} switches · {c['gateways']} gateways)")
    print(f"  Active clients : {c['clients']}")
    print(f"  WLANs          : {c['wlans']}")
    print()
    print(f"  Devices:")
    print(f"    {'name':<24} {'type':<6} {'model':<14} {'ip':<16} {'ver':<14} {'clients':<8}")
    print("    " + "-" * 90)
    for d in result["devices"]:
        print(f"    {(d['name'] or '')[:24]:<24} {(d['type'] or '')[:6]:<6} "
              f"{(d['model'] or '')[:14]:<14} {(d['ip'] or '')[:16]:<16} "
              f"{(d['version'] or '')[:14]:<14} {d['num_sta'] or 0:<8}")
    print(f"\n  WLANs:")
    for w in result["wlans"]:
        flags = []
        if w["enabled"]: flags.append("on")
        if w["is_guest"]: flags.append("guest")
        if w["vlan_enabled"]: flags.append(f"vlan{w['vlan']}")
        print(f"    {(w['name'] or '')[:30]:<30} {w['security'] or '?'}/{w['wpa_mode'] or '?'}  {','.join(flags)}")
    print(f"\n  Clients (first 15):")
    for cl in result["clients"][:15]:
        loc = cl["essid"] or (f"sw:{cl['sw_port']}" if cl["sw_port"] else "?")
        print(f"    {(cl['name'] or cl['hostname'] or '')[:24]:<24} {cl['ip'] or '':<15} "
              f"{cl['mac'] or '':<19} {loc[:20]:<20} {cl['signal_dbm'] or ''}")
    if len(result["clients"]) > 15:
        print(f"    … ({len(result['clients']) - 15} more — use --json)")
PY
