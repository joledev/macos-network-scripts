#!/usr/bin/env bash
# Discover IP cameras on the LAN via three complementary techniques:
#
#   1. WS-Discovery / ONVIF probe — UDP multicast to 239.255.255.250:3702.
#      ONVIF-compliant cameras (most modern IP cams) respond with their
#      device service URL (XAddr).
#   2. RTSP banner probe — TCP connect to known IPs (from the ARP cache or
#      from passed --hosts) on port 554, send DESCRIBE, capture the Server:
#      header. Detects most DVR / NVR / camera RTSP daemons.
#   3. HTTP fingerprint — connect to port 80 / 8000 / 8080, capture the
#      Server: response header. Cameras commonly identify themselves as
#      "App-webs/", "Hikvision-Webs", "lighttpd" with realm hints, etc.
#
# Output: JSON list of { ip, source, vendor_hint, ports_open, server,
# onvif_xaddr, rtsp_banner }.
#
# Usage: cameras.sh [--hosts ip1,ip2,...] [--duration N] [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
HOSTS_CSV=""
DURATION=3
ACTIVE=0
USER_AGENT="Mozilla/5.0 (compatible; netkit/0.2)"


while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --active) ACTIVE=1; shift ;;
    --hosts)
      [[ -n "${2:-}" ]] || die_usage "--hosts requires a comma-separated IP list"
      HOSTS_CSV="$2"; shift 2 ;;
    --duration)
      [[ -n "${2:-}" ]] || die_usage "--duration requires seconds"
      DURATION="$2"; shift 2 ;;
    --user-agent)
      [[ -n "${2:-}" ]] || die_usage "--user-agent requires a value"
      USER_AGENT="$2"; shift 2 ;;
    --yes) export NETKIT_YES=1; shift ;;
    --allow-raw) export NETKIT_ALLOW_RAW=1; shift ;;
    --dry-run) export NETKIT_DRY_RUN=1; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) die_usage "Unknown flag: $1" ;;
  esac
done

[[ "$DURATION" =~ ^[0-9]+$ ]] && (( DURATION >= 1 && DURATION <= 30 )) \
  || die_usage "--duration must be 1..30"

# Validate --hosts tokens if provided. Each must look like an IPv4 address.
if [[ -n "$HOSTS_CSV" ]]; then
  IFS=',' read -r -a _HOST_ARR <<< "$HOSTS_CSV"
  for _h in "${_HOST_ARR[@]}"; do
    _h="${_h// /}"
    [[ -z "$_h" ]] && continue
    [[ "$_h" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
      || die_usage "--hosts contains invalid token: '${_h}' (expected IPv4)"
  done
fi

guard_no_sudo

# Decide host list to probe via TCP. If --hosts not given, use the ARP
# cache (only IPs we already know about — safer than a full subnet sweep).
if [[ -z "$HOSTS_CSV" ]]; then
  HOSTS_CSV="$(arp -an 2>/dev/null \
    | awk '/\(/ {gsub(/[()]/, "", $2); print $2}' \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
    | sort -u \
    | paste -sd, -)"
fi

if dry_run; then
  log_dry "cameras would:"
  log_dry "  wsdiscovery: UDP multicast 239.255.255.250:3702 (${DURATION}s window)"
  if (( ACTIVE )); then
    log_dry "  rtsp probe : TCP 554 DESCRIBE to each LAN host"
    log_dry "  http probe : TCP 80/8000/8080/8443 GET / to each LAN host"
    log_dry "  hosts      : ${HOSTS_CSV:-(none in arp cache; pass --hosts)}"
  else
    log_dry "  rtsp/http  : SKIPPED — pass --active to TCP-probe each host"
  fi
  log_dry "no traffic sent."
  exit 0
fi

# RTSP + HTTP per-host probes are active traffic. Gate behind --active so
# the contract matches the rest of the toolkit (README: "active probes
# require opt-in"). WS-Discovery is a single UDP multicast probe and runs
# unconditionally — it's how ONVIF was designed to be discovered.
if (( ACTIVE )); then
  # Count probable hosts so the prompt is meaningful.
  HOSTS_FOR_GUARD="${HOSTS_CSV//,/ }"
  HOST_COUNT=$(printf '%s\n' $HOSTS_FOR_GUARD | grep -c .)
  if ! confirm "About to TCP-probe ${HOST_COUNT} host(s) on ports 554/80/8000/8080/8443. Proceed?"; then
    die "Active camera probe declined."
  fi
fi

export NETKIT_FMT="$FORMAT" NETKIT_HOSTS_CSV="$HOSTS_CSV" \
       NETKIT_DURATION="$DURATION" NETKIT_ACTIVE="$ACTIVE" \
       NETKIT_USER_AGENT="$USER_AGENT"

python3 - <<'PY'
import concurrent.futures, json, os, re, socket, sys, time, urllib.parse, uuid

fmt    = os.environ["NETKIT_FMT"]
hosts  = [h for h in os.environ["NETKIT_HOSTS_CSV"].split(",") if h.strip()]
duration = int(os.environ["NETKIT_DURATION"])
active = os.environ["NETKIT_ACTIVE"] == "1"
ua     = os.environ["NETKIT_USER_AGENT"]

# ---- 1) WS-Discovery (ONVIF) probe ----
WSD_ADDR = ("239.255.255.250", 3702)
PROBE_XML = """<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
            xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
            xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"
            xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
  <e:Header>
    <w:MessageID>uuid:{uuid}</w:MessageID>
    <w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
    <w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
  </e:Header>
  <e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></e:Body>
</e:Envelope>"""

def wsdiscovery() -> list[dict]:
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.settimeout(0.5)
    probe = PROBE_XML.format(uuid=str(uuid.uuid4())).encode()
    sock.sendto(probe, WSD_ADDR)
    end = time.time() + duration
    responses = []
    while time.time() < end:
        try:
            data, addr = sock.recvfrom(8192)
        except socket.timeout:
            continue
        body = data.decode(errors="replace")
        xaddrs = []
        for m in re.finditer(r"<d:XAddrs>([^<]+)</d:XAddrs>", body):
            xaddrs.extend(m.group(1).split())
        if not xaddrs:  # fall back: any namespace prefix
            for m in re.finditer(r":XAddrs>([^<]+)<", body):
                xaddrs.extend(m.group(1).split())
        responses.append({"from": addr[0], "xaddrs": xaddrs})
    sock.close()
    return responses

# ---- 2) RTSP DESCRIBE probe ----
def rtsp_probe(ip: str) -> dict:
    try:
        s = socket.create_connection((ip, 554), timeout=1.5)
        req = (f"DESCRIBE rtsp://{ip}/ RTSP/1.0\r\n"
               f"CSeq: 1\r\nUser-Agent: {ua}\r\n\r\n").encode()
        s.send(req)
        s.settimeout(1.5)
        data = s.recv(2048).decode(errors="replace")
        s.close()
    except (OSError, socket.timeout):
        return {}
    server = ""
    realm  = ""
    for ln in data.splitlines():
        ll = ln.lower()
        if ll.startswith("server:"):
            server = ln.split(":", 1)[1].strip()
        elif "www-authenticate:" in ll:
            m = re.search(r'realm="([^"]+)"', ln)
            if m:
                realm = m.group(1)
    return {"server": server, "realm": realm, "raw_first_line": data.splitlines()[0] if data else ""}

# ---- 3) HTTP fingerprint ----
HTTP_PORTS = [80, 8000, 8080, 8443]
def http_probe(ip: str) -> dict:
    """Returns the first responsive port's Server/realm hints."""
    for port in HTTP_PORTS:
        try:
            s = socket.create_connection((ip, port), timeout=1.0)
            req = (f"GET / HTTP/1.0\r\nHost: {ip}\r\nUser-Agent: {ua}\r\n\r\n").encode()
            s.send(req)
            s.settimeout(1.0)
            data = s.recv(2048).decode(errors="replace")
            s.close()
        except (OSError, socket.timeout):
            continue
        server = ""; realm = ""; title = ""
        for ln in data.splitlines():
            ll = ln.lower()
            if ll.startswith("server:"):
                server = ln.split(":", 1)[1].strip()
            elif "www-authenticate:" in ll:
                m = re.search(r'realm="([^"]+)"', ln)
                if m: realm = m.group(1)
        m = re.search(r"<title>([^<]+)</title>", data, re.I)
        if m: title = m.group(1).strip()
        return {"port": port, "server": server, "realm": realm, "title": title}
    return {}

# Vendor heuristics: pattern → vendor hint.
VENDOR_PATTERNS = [
    (r"hikvision|App-webs|webs/", "Hikvision"),
    (r"dahua|webserver/2\.4\.\d+", "Dahua"),
    (r"reolink|netwave", "Reolink"),
    (r"axis", "Axis"),
    (r"amcrest", "Amcrest"),
    (r"foscam", "Foscam"),
    (r"tp[- ]?link.*tapo|tapo c", "TP-Link Tapo"),
    (r"ubnt|ubiquiti", "Ubiquiti"),
    (r"unifi|unifi-protect", "Ubiquiti UniFi"),
    (r"go-?pro", "GoPro"),
    (r"avtech", "AVTech"),
    (r"vivotek", "Vivotek"),
    (r"sony", "Sony"),
    (r"bosch", "Bosch"),
    (r"milesight", "Milesight"),
]
def guess_vendor(text: str) -> str:
    if not text: return ""
    t = text.lower()
    for pat, name in VENDOR_PATTERNS:
        if re.search(pat, t, re.I):
            return name
    return ""

# Run the three techniques concurrently.
findings: dict[str, dict] = {}

# WS-Discovery
for resp in wsdiscovery():
    ip = resp["from"]
    findings.setdefault(ip, {"ip": ip, "sources": []})
    findings[ip]["sources"].append("onvif")
    findings[ip]["onvif_xaddr"] = ", ".join(resp["xaddrs"])
    findings[ip]["vendor_hint"] = findings[ip].get("vendor_hint", "") or guess_vendor(" ".join(resp["xaddrs"]))

# TCP probes per known host (in parallel) — only when --active.
def probe_host(ip: str) -> tuple[str, dict, dict]:
    return ip, rtsp_probe(ip), http_probe(ip)

if hosts and active:
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(16, len(hosts))) as ex:
        for ip, rtsp, http in ex.map(probe_host, hosts):
            if not rtsp and not http:
                continue
            f = findings.setdefault(ip, {"ip": ip, "sources": []})
            if rtsp:
                f["sources"].append("rtsp")
                f["rtsp_server"] = rtsp.get("server", "")
                f["rtsp_realm"]  = rtsp.get("realm", "")
                hint = guess_vendor(rtsp.get("server", "") + " " + rtsp.get("realm", ""))
                if hint: f["vendor_hint"] = hint
            if http:
                f["sources"].append("http")
                f["http_server"] = http.get("server", "")
                f["http_realm"]  = http.get("realm", "")
                f["http_title"]  = http.get("title", "")
                f["http_port"]   = http.get("port")
                hint = guess_vendor(http.get("server","") + " " + http.get("realm","") +
                                    " " + http.get("title",""))
                if hint and not f.get("vendor_hint"):
                    f["vendor_hint"] = hint

rows = sorted(findings.values(), key=lambda r: tuple(int(x) for x in r["ip"].split(".")))

if fmt == "json":
    print(json.dumps({"count": len(rows), "cameras": rows}, indent=2))
elif fmt == "md":
    print(f"# Camera discovery ({len(rows)} candidates)\n")
    if not rows:
        print("_no camera-shaped devices found._"); sys.exit(0)
    print("| IP | Vendor | Sources | RTSP | HTTP | ONVIF XAddr |")
    print("| --- | --- | --- | --- | --- | --- |")
    for r in rows:
        print(f"| {r['ip']} | {r.get('vendor_hint','')} | "
              f"{','.join(r.get('sources',[]))} | "
              f"{r.get('rtsp_server','')} | "
              f"{r.get('http_server','')} | "
              f"{r.get('onvif_xaddr','')} |")
else:
    print(f"Camera discovery — {len(rows)} candidate(s) on the LAN")
    print()
    if not rows:
        print("(no camera-shaped devices found)")
        print("Try `--hosts <ip1,ip2>` to probe specific candidates directly.")
        sys.exit(0)
    print(f"{'IP':<15} {'vendor':<18} {'sources':<18} {'rtsp':<28} {'http server'}")
    print("-" * 110)
    for r in rows:
        print(f"{r['ip']:<15} {r.get('vendor_hint','')[:18]:<18} "
              f"{','.join(r.get('sources',[]))[:18]:<18} "
              f"{r.get('rtsp_server','')[:28]:<28} "
              f"{r.get('http_server','')[:30]}")
PY
