#!/usr/bin/env bash
# Browse mDNS / Bonjour services advertised on the LAN.
#
# Runs dns-sd -B for a curated list of service types for a few seconds,
# captures instance names + the hostnames they advertise, and emits a
# JSON / text summary. Best-effort: most home networks reveal AirPlay
# receivers, Chromecasts, printers, file shares and the like.
#
# Usage: mdns.sh [--duration 3] [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
DURATION=3


while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --duration)
      [[ -n "${2:-}" ]] || die_usage "--duration requires seconds (1..30)"
      DURATION="$2"; shift 2 ;;
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
  || die_usage "--duration must be 1..30 (got: ${DURATION})"

guard_no_sudo
require_cmd dns-sd

if dry_run; then
  log_dry "mdns would:"
  log_dry "  browse  : 9 well-known Bonjour service types"
  log_dry "  duration: ${DURATION} s each (in parallel)"
  log_dry "  resolve : try socket.gethostbyname for each <instance>.local"
  log_dry "no probes sent."
  exit 0
fi

export NETKIT_MDNS_DURATION="$DURATION" NETKIT_FMT="$FORMAT"

python3 - <<'PY'
import concurrent.futures, json, os, re, socket, subprocess, sys, threading, time

sys.path.insert(0, os.path.join(os.environ.get("NETKIT_ROOT", ""), "scripts/utils"))
try:
    import device_models
except ImportError:
    device_models = None

DURATION = int(os.environ["NETKIT_MDNS_DURATION"])
FMT      = os.environ["NETKIT_FMT"]


def _unescape_txt(v: str) -> str:
    # dns-sd escapes spaces in TXT values as "\ " and as "\032".
    return v.replace("\\032", " ").replace("\\ ", " ").replace("\\\\", "\\")


def resolve_txt(instance: str, service: str, timeout: float = 2.0) -> dict:
    """`dns-sd -L` one instance briefly; return {host, port, txt:{...}}."""
    out = {"host": "", "port": "", "txt": {}}
    try:
        proc = subprocess.Popen(
            ["dns-sd", "-L", instance, service, "local."],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
    except OSError:
        return out
    killer = threading.Timer(timeout, proc.terminate)
    killer.daemon = True
    killer.start()
    try:
        for line in proc.stdout:
            if "can be reached at" in line:
                m = re.search(r"can be reached at (\S+?):(\d+)", line)
                if m:
                    out["host"] = m.group(1).rstrip(".")
                    out["port"] = m.group(2)
            elif "=" in line and "STARTING" not in line and "DATE" not in line:
                toks = re.split(r"(?<!\\) ", line.strip())
                for t in toks:
                    if "=" in t:
                        k, v = t.split("=", 1)
                        if k and v:
                            out["txt"][k] = _unescape_txt(v)
                if out["txt"]:
                    break  # first full TXT line is enough
    finally:
        killer.cancel()
        if proc.poll() is None:
            proc.terminate()
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            proc.kill(); proc.wait(timeout=1)
    return out

# Curated service types worth browsing on a home/office LAN. Naming is the
# de-facto Apple / Bonjour registry — keep _tcp / _udp explicit.
TYPES = [
    "_device-info._tcp",   # model code (Apple `model=`, others)
    "_workstation._tcp",   # generic hostnames (Linux/macOS)
    "_companion-link._tcp",# Apple ecosystem (Continuity)
    "_airplay._tcp",       # AppleTV, AirPlay-capable speakers (model/manufacturer)
    "_raop._tcp",           # AirPlay audio receivers
    "_googlecast._tcp",    # Chromecast / Google Home (md=/fn=)
    "_hap._tcp",            # HomeKit accessories
    "_sonos._tcp",          # Sonos speakers
    "_spotify-connect._tcp",# Spotify Connect endpoints
    "_smb._tcp",            # SMB / Windows file sharing
    "_ipp._tcp",            # IPP printers
    "_pdl-datastream._tcp", # raw print (model in TXT)
    "_printer._tcp",       # legacy printer advertisements
]

# dns-sd "Add" line format:
#   Timestamp  Add  Flags  ifIndex  Domain  ServiceType  Instance
# instance can contain spaces — take everything after the 7th column.
ADD_RE = re.compile(r"^\s*\d+:\d+:\d+\.\d+\s+Add\s+\S+\s+\S+\s+\S+\s+\S+\s+(.+)$")

def browse(svc_type: str) -> set[str]:
    """Browse one service type for DURATION seconds. Returns instance names.

    dns-sd streams indefinitely. We start a Timer that SIGTERMs the child
    after DURATION; readline then returns "" and the loop exits cleanly.
    """
    import threading
    instances: set[str] = set()
    proc = subprocess.Popen(
        ["dns-sd", "-B", svc_type, "local."],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, bufsize=1,
    )
    killer = threading.Timer(DURATION, proc.terminate)
    killer.daemon = True
    killer.start()
    try:
        for line in proc.stdout:
            m = ADD_RE.match(line)
            if m:
                instances.add(m.group(1).strip())
    finally:
        killer.cancel()
        if proc.poll() is None:
            proc.terminate()
        try:
            proc.wait(timeout=1)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=1)
    return instances

# Browse all types in parallel.
results: dict[str, list[str]] = {}
with concurrent.futures.ThreadPoolExecutor(max_workers=len(TYPES)) as ex:
    futures = {ex.submit(browse, t): t for t in TYPES}
    for f in concurrent.futures.as_completed(futures):
        t = futures[f]
        try:
            results[t] = sorted(f.result())
        except Exception:
            results[t] = []

# Best-effort hostname → IP resolution. macOS resolves *.local via mDNS
# automatically through getaddrinfo, so we just try each instance name.
def _ascii_hostname(name: str) -> str:
    """Sanitize an mDNS instance name for hostname resolution.

    Bonjour instance names allow Unicode and spaces (e.g. "Joel’s MacBook
    Air" with U+2019); hostnames don't. Convert to ASCII, replace spaces
    with hyphens, strip anything that isn't [A-Za-z0-9._-]."""
    # Replace common fancy punctuation that maps to ASCII equivalents.
    table = str.maketrans({"’": "'", "‘": "'", "“": '"', "”": '"'})
    s = name.translate(table)
    # Drop apostrophes entirely (macOS hostnames never include them).
    s = s.replace("'", "")
    # Spaces → hyphens.
    s = s.replace(" ", "-")
    # Drop anything outside the safe set.
    s = re.sub(r"[^A-Za-z0-9._-]", "", s)
    return s

def resolve(name: str) -> str:
    candidates = []
    for n in (name, _ascii_hostname(name)):
        if not n: continue
        if n.endswith(".local"):
            candidates.append(n)
        else:
            candidates.extend([n, f"{n}.local"])
    seen = set()
    for c in candidates:
        if c in seen: continue
        seen.add(c)
        try:
            socket.setdefaulttimeout(0.6)
            return socket.gethostbyname(c)
        except (socket.gaierror, socket.timeout, OSError):
            continue
    return ""

# Build a flat list of (type, instance, ip) — easier to consume than the
# nested dict for reports.
flat: list[dict] = []
seen: set[tuple[str, str]] = set()
for t, names in results.items():
    for n in names:
        key = (t, n)
        if key in seen:
            continue
        seen.add(key)
        flat.append({"service": t, "instance": n, "ip": ""})

# Enrich each instance: resolve its TXT record (model/manufacturer/serial/mac)
# and its IP, in parallel.
def enrich(r: dict) -> None:
    info = resolve_txt(r["instance"], r["service"])
    if info.get("host"):
        r["host"] = info["host"]
    if info.get("port"):
        r["port"] = info["port"]
    txt = info.get("txt") or {}
    if txt:
        r["txt"] = txt
        if device_models is not None:
            for k, v in device_models.identify(txt, r["service"]).items():
                r[k] = v
    r["ip"] = resolve(r["instance"]) or (resolve(info["host"]) if info.get("host") else "")

with concurrent.futures.ThreadPoolExecutor(max_workers=min(12, max(1, len(flat)))) as ex:
    list(ex.map(enrich, flat))

out = {
    "duration_s": DURATION,
    "service_types_browsed": TYPES,
    "by_type": results,
    "instances": flat,
    "count": len(flat),
    "resolved_count": sum(1 for r in flat if r["ip"]),
}

def _ident(r):
    """Compact 'manufacturer model (name)' identity string for a record."""
    bits = []
    mk = r.get("manufacturer", "")
    md = r.get("model_name") or r.get("model", "")
    if mk and md and mk.lower() not in md.lower():
        bits.append(f"{mk} {md}")
    elif md:
        bits.append(md)
    elif mk:
        bits.append(mk)
    if r.get("friendly_name") and r["friendly_name"] not in r["instance"]:
        bits.append(f"“{r['friendly_name']}”")
    return " ".join(bits)


if FMT == "json":
    print(json.dumps(out, indent=2))
elif FMT == "md":
    print(f"# mDNS / Bonjour services ({out['count']} instances)\n")
    print(f"_Browsed {len(TYPES)} service types for {DURATION} s, resolved {out['resolved_count']} to IPs._\n")
    if not flat:
        print("_no Bonjour services responded._"); sys.exit(0)
    print("| service | instance | ip | identity | mac |")
    print("| --- | --- | --- | --- | --- |")
    for r in flat:
        ident = _ident(r).replace("|", r"\|")
        print(f"| {r['service']} | {r['instance']} | {r['ip'] or '-'} | {ident or '-'} | {r.get('mac','-') or '-'} |")
else:
    print(f"mDNS browse — {len(TYPES)} types × {DURATION}s, "
          f"{out['count']} instance(s), {out['resolved_count']} resolved")
    print()
    if not flat:
        print("(no Bonjour services responded)")
        sys.exit(0)
    print(f"{'service':<24} {'ip':<16} {'instance':<34} identity")
    print("-" * 110)
    for r in flat:
        print(f"{r['service']:<24} {(r['ip'] or '-'):<16} {r['instance'][:34]:<34} {_ident(r)}")
PY
