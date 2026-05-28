#!/usr/bin/env bash
# Deep per-host fingerprint — squeeze every detail out of each LAN device.
#
# For every host (ARP cache, or --hosts), gather:
#   - OUI vendor + reverse DNS + known-hosts label/role
#   - Open TCP ports via a connect scan over a curated service list
#     (socket connect only — no raw packets, no sudo)
#   - HTTP / HTTPS banners: Server header, page <title>, redirect Location,
#     WWW-Authenticate realm
#   - TLS certificate subject / issuer (reveals managed-device brands like
#     TP-Link's "CN=TPRI-DEVICE", UniFi, printers, NAS web UIs)
#   - A best-effort role guess (router / ap / switch / camera / printer /
#     nas / media / iot / computer)
#
# Aggressive mode (--aggressive) adds nmap -sV service/version detection when
# nmap is installed (TCP connect scan, still no root). OS detection (nmap -O)
# additionally requires --allow-raw because it needs raw sockets / sudo.
#
# Output: JSON / md / text.
#
# Usage:
#   fingerprint.sh [--hosts ip1,ip2,...] [--ports 22,80,443] [--aggressive]
#                  [--json|--md|--text]
#
# Active probing of each host is the whole point of this tool, so it confirms
# once before probing (honors --yes / NETKIT_YES=1), matching `cameras --active`.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
HOSTS_CSV=""
PORTS_CSV=""
AGGRESSIVE=0

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --aggressive) AGGRESSIVE=1; shift ;;
    --hosts)
      [[ -n "${2:-}" ]] || die_usage "--hosts requires a comma-separated IP list"
      HOSTS_CSV="$2"; shift 2 ;;
    --ports)
      [[ -n "${2:-}" ]] || die_usage "--ports requires a comma-separated port list"
      PORTS_CSV="$2"; shift 2 ;;
    --yes) export NETKIT_YES=1; shift ;;
    --allow-raw) export NETKIT_ALLOW_RAW=1; shift ;;
    --dry-run) export NETKIT_DRY_RUN=1; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) die_usage "Unknown flag: $1" ;;
  esac
done

# Validate --hosts / --ports tokens before doing anything.
if [[ -n "$HOSTS_CSV" ]]; then
  IFS=',' read -r -a _HOST_ARR <<< "$HOSTS_CSV"
  for _h in "${_HOST_ARR[@]}"; do
    _h="${_h// /}"; [[ -z "$_h" ]] && continue
    [[ "$_h" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
      || die_usage "--hosts contains invalid token: '${_h}' (expected IPv4)"
  done
fi
if [[ -n "$PORTS_CSV" ]]; then
  [[ "$PORTS_CSV" =~ ^[0-9,[:space:]]+$ ]] || die_usage "--ports must be a comma-separated port list"
fi

guard_no_sudo

# Default host list: the ARP cache (only IPs we already know — no subnet sweep).
# Drop multicast (224-239.x), the all-ones broadcast and our own interface IPs
# so we fingerprint real LAN peers only (matches discover's host filter).
if [[ -z "$HOSTS_CSV" ]]; then
  _self_ips="$(all_local_ipv4 2>/dev/null | paste -sd'|' -)"
  HOSTS_CSV="$(arp -an 2>/dev/null \
    | awk '/\(/ {gsub(/[()]/, "", $2); print $2}' \
    | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' \
    | grep -vE '^(22[4-9]|23[0-9])\.' \
    | grep -vE '^255\.255\.255\.255$' \
    | { if [[ -n "$_self_ips" ]]; then grep -vE "^(${_self_ips})$"; else cat; fi; } \
    | sort -u | paste -sd, -)"
fi
[[ -z "$HOSTS_CSV" ]] && die "No hosts to fingerprint. Run 'netkit discover --active' first or pass --hosts."

HOST_COUNT=$(printf '%s' "$HOSTS_CSV" | tr ',' '\n' | grep -c .)
USE_NMAP=0
if (( AGGRESSIVE )) && has_cmd nmap; then USE_NMAP=1; fi

if dry_run; then
  log_dry "fingerprint would:"
  log_dry "  hosts      : ${HOST_COUNT} (${HOSTS_CSV})"
  log_dry "  tcp scan   : socket-connect to curated port list per host (no sudo)"
  log_dry "  banners    : HTTP/HTTPS Server+title+redirect, TLS cert subject/issuer"
  if (( AGGRESSIVE )); then
    if (( USE_NMAP )); then
      log_dry "  aggressive : nmap -sT -sV per host (service/version)"
      [[ "$NETKIT_ALLOW_RAW" == "1" ]] && log_dry "  os detect  : nmap -O (raw sockets / sudo)"
    else
      log_dry "  aggressive : requested but nmap not installed — socket scan only"
    fi
  fi
  log_dry "no traffic sent."
  exit 0
fi

# Per-host TCP probing is active traffic — confirm once (honors --yes).
if ! confirm "About to TCP-fingerprint ${HOST_COUNT} host(s) (connect scan + HTTP/TLS banners). Proceed?"; then
  die "Fingerprint declined."
fi
if (( AGGRESSIVE )) && (( ! USE_NMAP )); then
  log_warn "--aggressive requested but nmap not installed; using socket scan only (brew install nmap)."
fi
# OS detection needs raw sockets / sudo → explicit opt-in.
OS_DETECT=0
if (( USE_NMAP )) && [[ "$NETKIT_ALLOW_RAW" == "1" ]]; then
  guard_raw_packet "nmap OS detection (-O, raw sockets via sudo)"
  OS_DETECT=1
fi

log_info "Fingerprinting ${HOST_COUNT} host(s)  aggressive=${AGGRESSIVE} nmap=${USE_NMAP} os_detect=${OS_DETECT}"

NETKIT_GW="$(default_gateway 2>/dev/null || echo "")"
export NETKIT_FMT="$FORMAT" NETKIT_HOSTS_CSV="$HOSTS_CSV" NETKIT_PORTS_CSV="$PORTS_CSV" \
       NETKIT_USE_NMAP="$USE_NMAP" NETKIT_OS_DETECT="$OS_DETECT" NETKIT_ROOT NETKIT_GW

python3 - <<'PY'
import concurrent.futures, json, os, re, socket, ssl, subprocess, sys

sys.path.insert(0, os.path.join(os.environ["NETKIT_ROOT"], "scripts/utils"))
import oui            # noqa: E402
import known_hosts    # noqa: E402

fmt   = os.environ["NETKIT_FMT"]
hosts = [h.strip() for h in os.environ["NETKIT_HOSTS_CSV"].split(",") if h.strip()]
gw    = os.environ.get("NETKIT_GW", "")
use_nmap  = os.environ.get("NETKIT_USE_NMAP") == "1"
os_detect = os.environ.get("NETKIT_OS_DETECT") == "1"

# Curated service ports: routers/APs, web admin, file shares, printers,
# cameras, IoT, databases, remote desktop, media servers.
DEFAULT_PORTS = [
    21, 22, 23, 25, 53, 67, 80, 111, 123, 135, 139, 143, 161, 389, 443, 445,
    515, 548, 554, 631, 853, 1883, 1900, 2049, 3000, 3306, 3389, 5000, 5060,
    5222, 5353, 5432, 5900, 6379, 7547, 8000, 8008, 8080, 8081, 8443, 8883,
    9000, 9100, 9200, 32400, 49152,
]
_ports_csv = os.environ.get("NETKIT_PORTS_CSV", "").strip()
if _ports_csv:
    PORTS = sorted({int(p) for p in re.split(r"[,\s]+", _ports_csv) if p.strip().isdigit()})
else:
    PORTS = DEFAULT_PORTS

SERVICE = {
    21: "ftp", 22: "ssh", 23: "telnet", 25: "smtp", 53: "dns", 67: "dhcp",
    80: "http", 111: "rpcbind", 123: "ntp", 135: "msrpc", 139: "netbios-ssn",
    143: "imap", 161: "snmp", 389: "ldap", 443: "https", 445: "smb",
    515: "lpd", 548: "afp", 554: "rtsp", 631: "ipp", 853: "dns-over-tls",
    1883: "mqtt", 1900: "upnp", 2049: "nfs", 3000: "http-alt", 3306: "mysql",
    3389: "rdp", 5000: "upnp-http", 5060: "sip", 5222: "xmpp", 5353: "mdns",
    5432: "postgres", 5900: "vnc", 6379: "redis", 7547: "tr-069",
    8000: "http-alt", 8008: "http-alt", 8080: "http-proxy", 8081: "http-alt",
    8443: "https-alt", 8883: "mqtt-tls", 9000: "http-alt", 9100: "jetdirect",
    9200: "elasticsearch", 32400: "plex", 49152: "upnp",
}
HTTP_PORTS = {80, 3000, 5000, 8000, 8008, 8080, 8081, 9000, 49152}
TLS_PORTS  = {443, 8443, 8883, 853}


def scan_port(ip, port, timeout=0.6):
    try:
        with socket.create_connection((ip, port), timeout=timeout):
            return port
    except (OSError, socket.timeout):
        return None


def open_ports(ip):
    found = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=32) as ex:
        for r in ex.map(lambda p: scan_port(ip, p), PORTS):
            if r is not None:
                found.append(r)
    return sorted(found)


def http_banner(ip, port, tls=False):
    scheme = "https" if tls else "http"
    try:
        if tls:
            ctx = ssl._create_unverified_context()
            raw = socket.create_connection((ip, port), timeout=2.0)
            sock = ctx.wrap_socket(raw, server_hostname=ip)
        else:
            sock = socket.create_connection((ip, port), timeout=1.5)
        req = (f"GET / HTTP/1.1\r\nHost: {ip}\r\n"
               f"User-Agent: netkit/0.2\r\nConnection: close\r\n\r\n").encode()
        sock.send(req)
        sock.settimeout(2.0)
        chunks = []
        try:
            while len(b"".join(chunks)) < 8192:
                b = sock.recv(4096)
                if not b:
                    break
                chunks.append(b)
        except (OSError, socket.timeout):
            pass
        sock.close()
        data = b"".join(chunks).decode(errors="replace")
    except (OSError, socket.timeout, ssl.SSLError):
        return {}
    if not data.startswith("HTTP/"):
        return {}  # not an HTTP service (binary/gRPC/other) — don't emit noise
    server = realm = title = location = ""
    head = data.split("\r\n\r\n", 1)[0]
    for ln in head.splitlines():
        ll = ln.lower()
        if ll.startswith("server:"):
            server = ln.split(":", 1)[1].strip()
        elif ll.startswith("location:"):
            location = ln.split(":", 1)[1].strip()
        elif "www-authenticate:" in ll:
            m = re.search(r'realm="([^"]+)"', ln)
            if m:
                realm = m.group(1)
    m = re.search(r"<title>([^<]+)</title>", data, re.I)
    if m:
        title = m.group(1).strip()
    status = head.splitlines()[0] if head else ""
    out = {"port": port, "scheme": scheme, "status": status}
    if server: out["server"] = server
    if title: out["title"] = title
    if realm: out["realm"] = realm
    if location: out["location"] = location
    return out


def tls_cert(ip, port):
    try:
        p = subprocess.run(
            ["openssl", "s_client", "-connect", f"{ip}:{port}",
             "-servername", ip],
            input=b"", capture_output=True, timeout=4)
        x = subprocess.run(
            ["openssl", "x509", "-noout", "-subject", "-issuer", "-dates"],
            input=p.stdout, capture_output=True, timeout=4)
        out = {}
        for ln in x.stdout.decode(errors="replace").splitlines():
            if ln.startswith("subject="):
                out["subject"] = ln.split("=", 1)[1].strip()
            elif ln.startswith("issuer="):
                out["issuer"] = ln.split("=", 1)[1].strip()
            elif ln.startswith("notAfter="):
                out["not_after"] = ln.split("=", 1)[1].strip()
        return out
    except (OSError, subprocess.TimeoutExpired):
        return {}


def rdns(ip):
    try:
        socket.setdefaulttimeout(0.5)
        return socket.gethostbyaddr(ip)[0]
    except Exception:
        return ""


def nmap_sv(ip):
    """nmap -sT -sV (connect scan, no root). Returns {port: 'svc product ver'}."""
    args = ["nmap", "-sT", "-sV", "-Pn", "--version-light",
            "-p", ",".join(str(p) for p in PORTS), "-oG", "-", ip]
    if os_detect:
        args = ["sudo", "-n", "nmap", "-sS", "-sV", "-O", "-Pn",
                "-p", ",".join(str(p) for p in PORTS), "-oG", "-", ip]
    try:
        r = subprocess.run(args, capture_output=True, timeout=120)
        text = r.stdout.decode(errors="replace")
    except (OSError, subprocess.TimeoutExpired):
        return {}, ""
    svc = {}
    osmatch = ""
    for ln in text.splitlines():
        if "Ports:" in ln:
            seg = ln.split("Ports:", 1)[1]
            for entry in seg.split(","):
                f = entry.strip().split("/")
                if len(f) >= 5 and f[1] == "open":
                    port = f[0]
                    name = f[4]
                    extra = f[6] if len(f) > 6 else ""
                    svc[int(port)] = (name + (" " + extra if extra else "")).strip()
        if "OS:" in ln and "Seq" not in ln:
            m = re.search(r"OS:\s*(.+)", ln)
            if m:
                osmatch = m.group(1).strip()
    return svc, osmatch


def classify(rec):
    ports = set(rec.get("ports", []))
    vend = (rec.get("vendor") or "").lower()
    text = " ".join([
        rec.get("vendor", ""), rec.get("rdns", ""),
        json.dumps(rec.get("http", [])), json.dumps(rec.get("tls", [])),
    ]).lower()
    if rec["ip"] == gw:
        return "router/gateway"
    if 554 in ports or "camera" in text or "hikvision" in text or "dahua" in text:
        return "camera"
    if {9100, 515, 631} & ports:
        return "printer"
    if {445, 139, 2049, 548} & ports:
        return "nas/file-server"
    if 32400 in ports:
        return "media-server"
    if {1883, 8883} & ports:
        return "iot/mqtt"
    if 3389 in ports:
        return "windows-host"
    if any(k in text for k in ("ubnt", "ubiquiti", "unifi", "tpri", "tp-link",
                               "mercusys", "aruba", "mikrotik", "openwrt", "dd-wrt")) \
            and ({80, 443, 8080, 8443} & ports):
        return "ap/switch/router"
    if 7547 in ports:
        return "cpe/modem (TR-069)"
    if {22, 3000, 5432, 6379, 9200} & ports:
        return "server/computer"
    if ports:
        return "host"
    return "host (no open ports)"


def fingerprint(ip):
    rec = {"ip": ip}
    rec["rdns"] = rdns(ip)
    ports = open_ports(ip)
    rec["ports"] = ports
    rec["services"] = {str(p): SERVICE.get(p, "?") for p in ports}
    rec["http"] = []
    rec["tls"] = []
    for p in ports:
        if p in HTTP_PORTS:
            b = http_banner(ip, p, tls=False)
            if b:
                rec["http"].append(b)
        if p in TLS_PORTS:
            b = http_banner(ip, p, tls=True)
            if b:
                rec["http"].append(b)
            c = tls_cert(ip, p)
            if c:
                c["port"] = p
                rec["tls"].append(c)
    if use_nmap and ports:
        svc, osm = nmap_sv(ip)
        if svc:
            rec["nmap_services"] = {str(k): v for k, v in svc.items()}
        if osm:
            rec["os_guess"] = osm
    return rec


# Resolve ARP for vendor/MAC (read the cache once).
arp_text = subprocess.run(["arp", "-an"], capture_output=True).stdout.decode(errors="replace")
mac_by_ip = {}
for ln in arp_text.splitlines():
    m = re.search(r"\(([\d.]+)\)\s+at\s+([0-9a-f:]+)", ln, re.I)
    if m and m.group(2).lower() != "(incomplete)":
        mac_by_ip[m.group(1)] = ":".join(x.zfill(2) for x in m.group(2).lower().split(":"))

results = []
with concurrent.futures.ThreadPoolExecutor(max_workers=min(16, max(1, len(hosts)))) as ex:
    for rec in ex.map(fingerprint, hosts):
        ip = rec["ip"]
        mac = mac_by_ip.get(ip, "")
        rec["mac"] = mac
        rec["vendor"] = oui.lookup(mac) if mac else ""
        hit = known_hosts.lookup(ip=ip, mac=mac)
        if hit:
            if hit.get("name"): rec["known_name"] = hit["name"]
            if hit.get("role"): rec["known_role"] = hit["role"]
        rec["role"] = classify(rec)
        results.append(rec)

results.sort(key=lambda r: tuple(int(x) for x in r["ip"].split(".")))

if fmt == "json":
    print(json.dumps({"count": len(results), "hosts": results}, indent=2))
    sys.exit(0)


def fmt_ports(rec):
    return ", ".join(f"{p}/{SERVICE.get(p,'?')}" for p in rec.get("ports", []))


def fmt_ident(rec):
    bits = []
    for h in rec.get("http", []):
        if h.get("server"): bits.append(f"{h['scheme']}:{h['port']} {h['server']}")
        elif h.get("title"): bits.append(f"{h['scheme']}:{h['port']} \"{h['title']}\"")
    for t in rec.get("tls", []):
        if t.get("subject"): bits.append(f"tls:{t['port']} {t['subject']}")
    if rec.get("os_guess"): bits.append(f"os:{rec['os_guess']}")
    return " | ".join(bits)


if fmt == "md":
    print(f"# Host fingerprints ({len(results)})\n")
    print("| IP | MAC | Vendor | Role | Name/rDNS | Open ports | Identity |")
    print("| --- | --- | --- | --- | --- | --- | --- |")
    for r in results:
        name = r.get("known_name") or r.get("rdns") or ""
        cells = [r["ip"], r.get("mac", ""), r.get("vendor", ""), r.get("role", ""),
                 name, fmt_ports(r), fmt_ident(r)]
        print("| " + " | ".join(str(c).replace("|", r"\|") for c in cells) + " |")
    sys.exit(0)

# text
print(f"Deep fingerprint — {len(results)} host(s)\n")
for r in results:
    name = r.get("known_name") or r.get("rdns") or ""
    print(f"{r['ip']:<15} {r.get('role',''):<18} {r.get('vendor','')[:24]:<24} {name}")
    if r.get("mac"):
        print(f"    mac      : {r['mac']}")
    if r.get("ports"):
        print(f"    ports    : {fmt_ports(r)}")
    for h in r.get("http", []):
        line = f"    {h['scheme']}:{h['port']:<5}: {h.get('status','')}"
        if h.get("server"): line += f"  server={h['server']}"
        if h.get("title"): line += f"  title=\"{h['title']}\""
        if h.get("location"): line += f"  -> {h['location']}"
        if h.get("realm"): line += f"  realm=\"{h['realm']}\""
        print(line)
    for t in r.get("tls", []):
        print(f"    tls:{t['port']:<5}: subject={t.get('subject','')}  issuer={t.get('issuer','')}")
    if r.get("nmap_services"):
        for p, s in sorted(r["nmap_services"].items(), key=lambda kv: int(kv[0])):
            print(f"    nmap {p:<5}: {s}")
    if r.get("os_guess"):
        print(f"    os guess : {r['os_guess']}")
    print()
PY
