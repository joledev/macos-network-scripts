#!/usr/bin/env bash
# recon — one-pass aggressive discovery + visualization.
#
# Runs the discovery modules together, merges everything into a single
# per-host model, and emits three artifacts under output/:
#
#   recon-<ts>.json         merged dataset (ip, mac, vendor, rdns, role, open
#                           ports/services, HTTP/TLS, SSDP/mDNS/UBNT identity)
#   recon-<ts>.mmd          classified, styled mermaid map (renders in Obsidian)
#   recon-<ts>.html         self-contained interactive map (read-only, lightweight)
#   recon-<ts>.editor.html  full editor (vis-network): create/edit/delete nodes
#                           & edges, rooms/groups, assign IP/type, save/load JSON
#   recon-<ts>.drawio       open in draw.io / diagrams.net for pro editing
#
# Modules folded in: discover (ARP + optional active sweep), fingerprint
# (ports/HTTP/TLS), ssdp (UPnP), ubnt-discover (Ubiquiti), wifi, interfaces,
# and — best effort — starlink. Each is read-only / connect-scan only; the
# single active ping sweep is confirmed once here (honors --yes).
#
# Usage:
#   recon.sh [--active] [--aggressive] [--interface en7] [--subnets a/24,b/24]
#            [--with-starlink] [--json|--text]
#
#   --active        ping-sweep the subnet(s) first (populates ARP) — confirmed once
#   --aggressive    let fingerprint use nmap -sV (service/version) when present
#   --subnets       comma-separated CIDRs to scan (building/multi-VLAN); default
#                   is the local subnet. Routed ranges yield IPs (no MAC across L3)
#   --snmp-switches host[:community],...  walk each switch's bridge FDB to tag
#                   hosts with the switch:port they're plugged into (Netdisco-style)
#   --with-starlink include the Starlink dish as the upstream node

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

ACTIVE=0
AGGRESSIVE=0
WITH_STARLINK=0
IFACE=""
STDOUT_FMT=""
SUBNETS_CSV=""
SNMP_SWITCHES=""

while (( $# )); do
  case "$1" in
    --active) ACTIVE=1; shift ;;
    --aggressive) AGGRESSIVE=1; shift ;;
    --with-starlink) WITH_STARLINK=1; shift ;;
    --subnets)
      [[ -n "${2:-}" ]] || die_usage "--subnets requires a comma-separated CIDR list"
      SUBNETS_CSV="$2"; shift 2 ;;
    --snmp-switches)
      [[ -n "${2:-}" ]] || die_usage "--snmp-switches requires host[:community],..."
      SNMP_SWITCHES="$2"; shift 2 ;;
    --interface)
      [[ -n "${2:-}" ]] || die_usage "--interface requires a value"
      IFACE="$2"; shift 2 ;;
    --json) STDOUT_FMT="json"; shift ;;
    --text) STDOUT_FMT="text"; shift ;;
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

[[ -z "$IFACE" ]] && IFACE=$(pick_interface || echo "")
SUBNET=""
[[ -n "$IFACE" ]] && SUBNET=$(iface_subnet_cidr "$IFACE" 2>/dev/null || echo "")

# Building / multi-VLAN: scan a list of ranges. Default to the local subnet.
# Validate each CIDR up front.
if [[ -n "$SUBNETS_CSV" ]]; then
  IFS=',' read -r -a SUBNET_LIST <<< "$SUBNETS_CSV"
  for _c in "${SUBNET_LIST[@]}"; do
    _c="${_c// /}"; [[ -z "$_c" ]] && continue
    [[ "$_c" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] \
      || die_usage "--subnets has invalid CIDR: '${_c}'"
  done
else
  SUBNET_LIST=("$SUBNET")
fi

ensure_output_dir
TS=$(timestamp)
JSON_OUT="${NETKIT_OUTPUT_DIR}/recon-${TS}.json"
MMD_OUT="${NETKIT_OUTPUT_DIR}/recon-${TS}.mmd"
HTML_OUT="${NETKIT_OUTPUT_DIR}/recon-${TS}.html"
EDITOR_OUT="${NETKIT_OUTPUT_DIR}/recon-${TS}.editor.html"
DRAWIO_OUT="${NETKIT_OUTPUT_DIR}/recon-${TS}.drawio"

if dry_run; then
  log_dry "recon would (interface=${IFACE:-auto}, subnets=${SUBNETS_CSV:-${SUBNET:-?}}, active=${ACTIVE}, aggressive=${AGGRESSIVE}):"
  log_dry "  discover    : scripts/discovery/hosts.sh --json $([[ $ACTIVE == 1 ]] && echo --active) (per subnet)"
  log_dry "  fingerprint : scripts/discovery/fingerprint.sh --json --hosts <discovered> $([[ $AGGRESSIVE == 1 ]] && echo --aggressive)"
  log_dry "  ssdp        : scripts/discovery/ssdp.sh --json"
  log_dry "  ubnt        : scripts/discovery/ubnt.sh --json"
  log_dry "  wifi        : scripts/diagnostics/wifi.sh --json"
  log_dry "  interfaces  : scripts/discovery/interfaces.sh --json"
  (( WITH_STARLINK )) && log_dry "  starlink    : scripts/diagnostics/starlink.sh --json"
  log_dry "would write: output/recon-<ts>.{json,mmd,html}"
  log_dry "no probes executed."
  exit 0
fi

# Confirm the active sweep ONCE, then suppress submodule prompts.
if (( ACTIVE )) && ! dry_run; then
  if [[ -n "$SUBNET" ]]; then
    guard_active "$SUBNET"
  else
    log_warn "Could not derive subnet for ${IFACE:-?}; skipping active sweep."
    ACTIVE=0
  fi
  export NETKIT_YES=1
fi
# fingerprint confirms its own TCP probing; recon runs unattended, so opt in.
export NETKIT_YES=1

log_info "recon: discovering and fingerprinting on ${IFACE:-auto} (${SUBNET:-?})"

TMP_DIR="$(mktemp -d -t netkit-recon.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

run_one() {
  local name="$1" out="$2" fallback="$3"; shift 3
  log_info "  ... ${name}"
  set +e
  "$@" >"$out" 2>/dev/null
  local rc=$?
  set -e
  (( rc != 0 )) && printf '%s' "$fallback" > "$out"
  return 0
}

# 1) discover per subnet (passive ARP + optional active sweep), then merge the
#    union. Remote (routed) subnets yield IPs but no MAC/vendor — L2 stops at
#    the router; fingerprint (L3) still profiles them.
DISC_BASE=("--json"); (( ACTIVE )) && DISC_BASE+=("--active")
[[ -n "$IFACE" ]] && DISC_BASE+=("--interface" "$IFACE")
_disc_files=()
_i=0
for _sn in "${SUBNET_LIST[@]}"; do
  _f="$TMP_DIR/hosts_${_i}.json"
  if [[ -n "$_sn" ]]; then
    run_one "discover ${_sn}" "$_f" '{"hosts":[]}' \
      "${SCRIPT_DIR}/hosts.sh" "${DISC_BASE[@]}" --subnet "$_sn"
  else
    run_one "discover" "$_f" '{"hosts":[]}' "${SCRIPT_DIR}/hosts.sh" "${DISC_BASE[@]}"
  fi
  _disc_files+=("$_f")
  _i=$((_i + 1))
done

python3 - "$TMP_DIR/hosts.json" "${_disc_files[@]}" <<'PY'
import json, sys
out_path, files = sys.argv[1], sys.argv[2:]
merged, meta = {}, {}
for p in files:
    try:
        d = json.load(open(p))
    except Exception:
        continue
    if not meta:
        meta = {k: d.get(k) for k in ("interface", "subnet", "local_ip", "local_ips")}
    for h in d.get("hosts", []):
        ip = h.get("ip")
        if ip and ip not in merged:
            merged[ip] = h
res = dict(meta)
res["hosts"] = sorted(
    merged.values(),
    key=lambda h: tuple(int(x) for x in h["ip"].split(".")) if h.get("ip", "").count(".") == 3 else (0,))
res["count"] = len(res["hosts"])
json.dump(res, open(out_path, "w"))
PY

# Extract discovered IPs for the fingerprint host list.
HOSTS_CSV="$(python3 -c '
import json,sys
try:
    d=json.load(open(sys.argv[1]))
    print(",".join(h["ip"] for h in d.get("hosts",[]) if h.get("ip")))
except Exception:
    print("")
' "$TMP_DIR/hosts.json")"

# 2) fingerprint (only if we have hosts)
if [[ -n "$HOSTS_CSV" ]]; then
  FP_FLAGS=("--json" "--hosts" "$HOSTS_CSV"); (( AGGRESSIVE )) && FP_FLAGS+=("--aggressive")
  run_one "fingerprint" "$TMP_DIR/fingerprint.json" '{"hosts":[]}' \
    "${SCRIPT_DIR}/fingerprint.sh" "${FP_FLAGS[@]}"
else
  echo '{"hosts":[]}' > "$TMP_DIR/fingerprint.json"
fi

# 3) ssdp / 4) ubnt / 5) mdns / 6) netbios / 7) wsd / 8) ndp / 9) wifi / 10) interfaces
run_one "ssdp"       "$TMP_DIR/ssdp.json"       '{"devices":[]}' "${SCRIPT_DIR}/ssdp.sh" --json
run_one "ubnt"       "$TMP_DIR/ubnt.json"       '{"devices":[]}' "${SCRIPT_DIR}/ubnt.sh" --json
run_one "mdns"       "$TMP_DIR/mdns.json"       '{"instances":[]}' "${SCRIPT_DIR}/mdns.sh" --json --duration 5
run_one "wsd"        "$TMP_DIR/wsd.json"        '{"devices":[]}' "${SCRIPT_DIR}/wsd.sh" --json
run_one "vendor"     "$TMP_DIR/vendor.json"     '{"devices":[]}' "${SCRIPT_DIR}/vendorscan.sh" --json
run_one "ndp"        "$TMP_DIR/ndp.json"        '{"neighbors":[]}' "${SCRIPT_DIR}/ndp.sh" --json
[[ -n "$IFACE" ]] && run_one "ndp" "$TMP_DIR/ndp.json" '{"neighbors":[]}' "${SCRIPT_DIR}/ndp.sh" --json --interface "$IFACE"
if [[ -n "$HOSTS_CSV" ]]; then
  run_one "netbios" "$TMP_DIR/netbios.json" '{"hosts":[]}' "${SCRIPT_DIR}/netbios.sh" --json --hosts "$HOSTS_CSV"
else
  echo '{"hosts":[]}' > "$TMP_DIR/netbios.json"
fi
run_one "wifi"       "$TMP_DIR/wifi.json"       '{}' "${SCRIPT_DIR}/../diagnostics/wifi.sh" --json
run_one "interfaces" "$TMP_DIR/interfaces.json" '{}' "${SCRIPT_DIR}/interfaces.sh" --json
if (( WITH_STARLINK )); then
  run_one "starlink" "$TMP_DIR/starlink.json" '{}' "${SCRIPT_DIR}/../diagnostics/starlink.sh" --json
else
  echo '{}' > "$TMP_DIR/starlink.json"
fi

# 11) SNMP switches (optional) — walk bridge FDB for port-level topology.
SWITCH_FILES=""
if [[ -n "$SNMP_SWITCHES" ]]; then
  IFS=',' read -r -a _SW <<< "$SNMP_SWITCHES"
  _j=0
  for _tok in "${_SW[@]}"; do
    _tok="${_tok// /}"; [[ -z "$_tok" ]] && continue
    _sw_ip="${_tok%%:*}"
    _sw_comm="public"; [[ "$_tok" == *:* ]] && _sw_comm="${_tok#*:}"
    _sf="$TMP_DIR/switch_${_j}.json"
    run_one "snmp ${_sw_ip}" "$_sf" '{}' \
      "${SCRIPT_DIR}/../diagnostics/snmp.sh" --host "$_sw_ip" --community "$_sw_comm" --bridge --json
    SWITCH_FILES+="${_sf} "
    _j=$((_j + 1))
  done
fi

# ---- Merge + emit JSON, mermaid, HTML ----
NETKIT_GW="$(default_gateway 2>/dev/null || echo "")"
export NETKIT_TMP_DIR="$TMP_DIR" NETKIT_TS="$TS" NETKIT_ROOT \
       NETKIT_JSON_OUT="$JSON_OUT" NETKIT_MMD_OUT="$MMD_OUT" NETKIT_HTML_OUT="$HTML_OUT" \
       NETKIT_EDITOR_OUT="$EDITOR_OUT" NETKIT_DRAWIO_OUT="$DRAWIO_OUT" \
       NETKIT_IFACE="$IFACE" NETKIT_SUBNET="$SUBNET" NETKIT_GW \
       NETKIT_SUBNETS="${SUBNETS_CSV:-$SUBNET}" \
       NETKIT_SWITCH_FILES="${SWITCH_FILES}" \
       NETKIT_STDOUT_FMT="$STDOUT_FMT"

python3 - <<'PY'
import json, os, re, sys

tmp = os.environ["NETKIT_TMP_DIR"]
root = os.environ["NETKIT_ROOT"]
sys.path.insert(0, os.path.join(root, "scripts/utils"))


def load(name):
    try:
        return json.load(open(os.path.join(tmp, f"{name}.json")))
    except Exception:
        return {}


hosts_mod = load("hosts")
fp_mod    = load("fingerprint")
ssdp_mod  = load("ssdp")
ubnt_mod  = load("ubnt")
mdns_mod  = load("mdns")
nb_mod    = load("netbios")
wsd_mod   = load("wsd")
vendor_mod = load("vendor")
ndp_mod   = load("ndp")
wifi_mod  = load("wifi")
ifs_mod   = load("interfaces")
sl_mod    = load("starlink")

gw = os.environ.get("NETKIT_GW", "")

import ipaddress
_subnet_nets = []
for _c in (os.environ.get("NETKIT_SUBNETS", "") or "").split(","):
    _c = _c.strip()
    if _c:
        try:
            _subnet_nets.append(ipaddress.ip_network(_c, strict=False))
        except ValueError:
            pass


def host_subnet(ip):
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return None
    for n in _subnet_nets:
        if a in n:
            return n
    return None


# --- index helpers ---
fp_by_ip = {h["ip"]: h for h in fp_mod.get("hosts", []) if h.get("ip")}

ssdp_by_ip = {}
for d in ssdp_mod.get("devices", []):
    ip = d.get("ip", "")
    if not re.match(r"^\d+\.\d+\.\d+\.\d+$", ip):
        continue
    cur = ssdp_by_ip.get(ip)
    # Prefer the richest announcement (one with a friendly name + manufacturer).
    score = sum(bool(d.get(k)) for k in ("friendly_name", "manufacturer", "model_name"))
    if not cur or score > cur[0]:
        ssdp_by_ip[ip] = (score, d)
ssdp_by_ip = {ip: d for ip, (s, d) in ssdp_by_ip.items()}

ubnt_by_ip = {}
ubnt_by_mac = {}
for d in ubnt_mod.get("devices", []):
    if d.get("ip"):
        ubnt_by_ip[d["ip"]] = d
    for m in d.get("macs", []):
        ubnt_by_mac[m.lower()] = d

# mDNS instances → best identity per ip (and per mac when present).
mdns_by_ip = {}
mdns_by_mac = {}
for inst in mdns_mod.get("instances", []):
    ident = {k: inst.get(k) for k in
             ("model", "model_name", "manufacturer", "friendly_name", "kind")
             if inst.get(k)}
    if not ident:
        continue
    ip = inst.get("ip", "")
    score = sum(bool(ident.get(k)) for k in ("model_name", "manufacturer", "friendly_name"))
    if re.match(r"^\d+\.\d+\.\d+\.\d+$", ip):
        cur = mdns_by_ip.get(ip)
        if not cur or score > cur[0]:
            mdns_by_ip[ip] = (score, ident)
    if inst.get("mac"):
        mdns_by_mac[inst["mac"].lower()] = ident
mdns_by_ip = {ip: ident for ip, (s, ident) in mdns_by_ip.items()}

nb_by_ip = {h["ip"]: h for h in nb_mod.get("hosts", []) if h.get("ip")}
wsd_by_ip = {d["ip"]: d for d in wsd_mod.get("devices", []) if d.get("ip")}
vendor_by_ip = {d["ip"]: d for d in vendor_mod.get("devices", []) if d.get("ip")}
ndp_by_mac = {}
for n in ndp_mod.get("neighbors", []):
    if n.get("mac"):
        ndp_by_mac.setdefault(n["mac"].lower(), []).append(n["address"])


def reclassify(rec):
    """Sharpen the role using SSDP/mDNS/NetBIOS/WSD/UBNT signals on top of
    fingerprint's guess."""
    role = rec.get("role", "host")
    sd = rec.get("ssdp") or {}
    md = rec.get("mdns") or {}
    nb = rec.get("netbios") or {}
    wd = rec.get("wsd") or {}
    dtype = (sd.get("device_type") or "").lower()
    blob = " ".join([
        dtype, (sd.get("friendly_name") or "").lower(), (sd.get("model_name") or "").lower(),
        (sd.get("manufacturer") or "").lower(), (md.get("kind") or "").lower(),
        (md.get("model_name") or md.get("model") or "").lower(),
        (wd.get("hint") or "").lower(),
    ])
    if rec.get("ubnt"):
        return "ap/switch/router"
    if rec["ip"] == gw or "internetgatewaydevice" in dtype:
        return "router/gateway"
    if any(k in blob for k in ("mediarenderer", "dial", "chromecast", "smarttv",
                               "roku", "appletv", "androidtv", "tv", "cast")):
        return "tv/media"
    if "mediaserver" in dtype:
        return "media-server"
    if "printer" in blob or "scanner" in blob:
        return "printer"
    if "file-server" in (nb.get("services") or []) or "nas" in blob:
        return "nas/file-server"
    if md.get("kind", "").startswith("apple"):
        return "computer" if role in ("host", "host (no open ports)") else role
    return role


merged = {}
for h in hosts_mod.get("hosts", []):
    ip = h.get("ip")
    if not ip:
        continue
    rec = {
        "ip": ip, "mac": h.get("mac", ""), "vendor": h.get("vendor", ""),
        "rdns": h.get("name", ""), "sources": ["arp"],
    }
    if h.get("known_name"): rec["known_name"] = h["known_name"]
    if h.get("role"): rec["known_role"] = h["role"]
    merged[ip] = rec

# Overlay fingerprint
for ip, f in fp_by_ip.items():
    rec = merged.setdefault(ip, {"ip": ip, "sources": []})
    rec.setdefault("sources", [])
    rec["mac"] = rec.get("mac") or f.get("mac", "")
    rec["vendor"] = rec.get("vendor") or f.get("vendor", "")
    rec["rdns"] = rec.get("rdns") or f.get("rdns", "")
    rec["ports"] = f.get("ports", [])
    rec["services"] = f.get("services", {})
    if f.get("http"): rec["http"] = f["http"]
    if f.get("tls"): rec["tls"] = f["tls"]
    if f.get("nmap_services"): rec["nmap_services"] = f["nmap_services"]
    if f.get("os_guess"): rec["os_guess"] = f["os_guess"]
    rec["role"] = f.get("role", rec.get("role", "host"))
    if "fingerprint" not in rec["sources"]:
        rec["sources"].append("fingerprint")

# Overlay ssdp / ubnt
for ip, d in ssdp_by_ip.items():
    rec = merged.setdefault(ip, {"ip": ip, "sources": []})
    rec.setdefault("sources", [])
    rec["ssdp"] = {k: d.get(k) for k in
                   ("friendly_name", "manufacturer", "model_name", "model_number",
                    "device_type", "serial", "server") if d.get(k)}
    if "ssdp" not in rec["sources"]:
        rec["sources"].append("ssdp")
for ip, d in ubnt_by_ip.items():
    rec = merged.setdefault(ip, {"ip": ip, "sources": []})
    rec.setdefault("sources", [])
    rec["ubnt"] = {k: d.get(k) for k in
                   ("model", "model_full", "firmware", "hostname", "essid", "uptime_s")
                   if d.get(k)}
    if "ubnt" not in rec["sources"]:
        rec["sources"].append("ubnt")
# ubnt may match by mac when its IP differs from the ARP IP
for ip, rec in merged.items():
    mac = (rec.get("mac") or "").lower()
    if mac and mac in ubnt_by_mac and "ubnt" not in rec:
        d = ubnt_by_mac[mac]
        rec["ubnt"] = {k: d.get(k) for k in
                       ("model", "model_full", "firmware", "hostname", "essid", "uptime_s")
                       if d.get(k)}

# Overlay mDNS / NetBIOS / WSD / IPv6 signals onto each host.
for ip, rec in merged.items():
    mac = (rec.get("mac") or "").lower()
    if ip in mdns_by_ip:
        rec["mdns"] = mdns_by_ip[ip]
    elif mac and mac in mdns_by_mac:
        rec["mdns"] = mdns_by_mac[mac]
    if rec.get("mdns") and "mdns" not in rec["sources"]:
        rec["sources"].append("mdns")
    if ip in nb_by_ip:
        nb = nb_by_ip[ip]
        rec["netbios"] = {k: nb.get(k) for k in ("hostname", "workgroup", "services") if nb.get(k)}
        rec["sources"].append("netbios")
    if ip in wsd_by_ip:
        wd = wsd_by_ip[ip]
        rec["wsd"] = {k: wd.get(k) for k in ("hint", "types") if wd.get(k)}
        rec["sources"].append("wsd")
    if ip in vendor_by_ip:
        vd = vendor_by_ip[ip]
        rec["vendor_proto"] = {k: vd.get(k) for k in
                               ("protocol", "model", "name", "hw_ver", "sw_ver",
                                "version", "platform", "board") if vd.get(k)}
        rec["sources"].append(vd.get("protocol", "vendor"))
    if mac and mac in ndp_by_mac:
        rec["ipv6"] = ndp_by_mac[mac]
        rec["sources"].append("ipv6")


def best_name(rec):
    nb = rec.get("netbios") or {}
    md = rec.get("mdns") or {}
    sd = rec.get("ssdp") or {}
    ub = rec.get("ubnt") or {}
    vp = rec.get("vendor_proto") or {}
    http_title = next((h.get("title") for h in (rec.get("http") or []) if h.get("title")), "")
    for cand in (rec.get("known_name"), nb.get("hostname"), md.get("friendly_name"),
                 sd.get("friendly_name"), vp.get("name"), md.get("model_name"),
                 ub.get("model_full"), ub.get("model"), sd.get("model_name"),
                 http_title, rec.get("rdns")):
        if cand:
            return cand
    return ""


for rec in merged.values():
    rec.setdefault("role", "host")
    rec["role"] = reclassify(rec)
    rec["display"] = best_name(rec)
    md = rec.get("mdns") or {}
    sd = rec.get("ssdp") or {}
    ub = rec.get("ubnt") or {}
    vp = rec.get("vendor_proto") or {}
    manu = md.get("manufacturer") or sd.get("manufacturer") or ""
    model = (md.get("model_name") or md.get("model") or sd.get("model_name")
             or ub.get("model_full") or ub.get("model") or vp.get("model") or "")
    ident = f"{manu} {model}".strip()
    if ident:
        rec["identity"] = ident
    sn = host_subnet(rec["ip"])
    if sn is not None:
        rec["subnet"] = str(sn)
        rec["prefixlen"] = sn.prefixlen

hosts = sorted(merged.values(),
               key=lambda r: tuple(int(x) for x in r["ip"].split(".")) if re.match(r"^\d+\.\d+\.\d+\.\d+$", r["ip"]) else (0,))

# Manually-declared infrastructure (unmanaged switches, patch panels, cable
# runs) — gear with no IP that scans can't see. Inject it so the map is complete
# and re-parent any hosts that hang off it.
import infrastructure
infra_nodes = infrastructure.load()
_parent_of = infrastructure.host_parent_map(infra_nodes)
for h in hosts:
    h["parent"] = _parent_of.get(h.get("ip", ""), gw)
for n in infra_nodes:
    n["parent"] = n.get("uplink") or gw   # uplink: a host/gateway IP or another node id

# Self interfaces (this Mac) + the slow-link flag baked in for the map.
self_ifaces = []
for r in ifs_mod.get("interfaces", []):
    if r.get("status") == "active" and r.get("ipv4"):
        self_ifaces.append({
            "device": r["device"], "kind": r.get("kind", ""), "ipv4": r["ipv4"],
            "media": r.get("media", ""), "link_mbps": r.get("link_mbps"),
            "max_supported_mbps": r.get("max_supported_mbps"),
            "is_default_route": r.get("is_default_route", False),
        })

wifi_cur = (wifi_mod.get("current") or {}) if isinstance(wifi_mod, dict) else {}

# Port-level topology from SNMP bridge FDB (Netdisco-style): tag each host with
# the switch:port it's plugged into.
fdb_topo = {"edges": [], "uplinks": [], "by_mac": {}}
switch_files = [f for f in os.environ.get("NETKIT_SWITCH_FILES", "").split() if f]
if switch_files:
    import fdb_topology
    switches = []
    for sf in switch_files:
        try:
            sd = json.load(open(sf))
        except Exception:
            continue
        if sd.get("bridge_fdb"):
            sysd = sd.get("system") or {}
            switches.append({
                "host": sd.get("host", ""),
                "name": sysd.get("name") or sysd.get("sysName") or sd.get("host", ""),
                "bridge_fdb": sd["bridge_fdb"],
            })
    if switches:
        fdb_topo = fdb_topology.build(switches, hosts)
        for h in hosts:
            mac = (h.get("mac") or "").lower()
            if mac in fdb_topo["by_mac"]:
                h["switch_port"] = fdb_topology.label(fdb_topo["by_mac"][mac])

dish = {}
if isinstance(sl_mod, dict) and (sl_mod.get("hardware") or sl_mod.get("tcp_reachable")):
    dish = {
        "hardware": sl_mod.get("hardware"), "software": sl_mod.get("software"),
        "ping_latency_ms": sl_mod.get("ping_latency_ms"),
        "eth_speed_mbps": sl_mod.get("eth_speed_mbps"),
        "address": "192.168.100.1",
    }

report = {
    "meta": {
        "schema_version": "1.0.0", "generated_at": os.environ["NETKIT_TS"],
        "kind": "recon",
    },
    "interface": os.environ.get("NETKIT_IFACE", ""),
    "subnet": os.environ.get("NETKIT_SUBNET", ""),
    "gateway": gw,
    "self_interfaces": self_ifaces,
    "wifi": wifi_cur,
    "dish": dish,
    "fdb_topology": {"uplinks": fdb_topo["uplinks"], "edge_count": len(fdb_topo["edges"])},
    "infrastructure": infra_nodes,
    "count": len(hosts),
    "hosts": hosts,
}

with open(os.environ["NETKIT_JSON_OUT"], "w") as f:
    json.dump(report, f, indent=2, default=str)

# ---- enriched mermaid ----
ROLE_CLASS = {
    "router/gateway": "router", "ap/switch/router": "ap", "switch": "ap",
    "camera": "camera", "printer": "printer", "nas/file-server": "nas",
    "media-server": "media", "tv/media": "tv", "iot/mqtt": "iot",
    "windows-host": "computer", "server/computer": "computer",
    "cpe/modem (TR-069)": "router",
}


def node_id(ip):
    return "n" + ip.replace(".", "_")


def esc(s):
    return str(s).replace('"', "'").replace("[", "(").replace("]", ")").replace("|", "/")


def label(rec):
    parts = [rec["ip"]]
    name = rec.get("display") or rec.get("vendor") or ""
    if name:
        parts.append(esc(name)[:28])
    ident = rec.get("identity") or ""
    if ident and ident.lower() not in (name or "").lower():
        parts.append(esc(ident)[:26])
    if rec.get("ports"):
        svc = "/".join(str(p) for p in rec["ports"][:5])
        parts.append("ports " + svc)
    if rec.get("switch_port"):
        parts.append("@ " + esc(rec["switch_port"]))
    return "<br/>".join(parts)


INFRA_CLASS = {"switch": "ap", "patch-panel": "unknown", "router": "router",
               "ap": "ap", "modem": "router", "media-converter": "unknown",
               "other": "unknown"}
infra_by_id = {n["id"]: n for n in infra_nodes}


def infra_node_id(nid):
    return "inf_" + re.sub(r"[^A-Za-z0-9_]", "_", nid)


def ent_id(parent):
    """Resolve a parent value (gateway IP / host IP / infra id) to a node id."""
    if not parent or parent == gw:
        return gw_id
    if parent in infra_by_id:
        return infra_node_id(parent)
    if re.match(r"^\d+\.\d+\.\d+\.\d+$", parent):
        return node_id(parent)
    return gw_id


lines = ["graph TD"]
lines.append('  inet([" Internet "])')
gw_id = node_id(gw) if gw else "gw"
if dish:
    lines.append(f'  dish["Starlink dish<br/>{esc(dish.get("hardware",""))}<br/>{esc(dish.get("address",""))}"]')
    lines.append("  inet --> dish")
    lines.append(f"  dish --> {gw_id}")
else:
    lines.append(f"  inet --> {gw_id}")

# gateway node
gw_rec = next((h for h in hosts if h["ip"] == gw), None)
gw_label = label(gw_rec) if gw_rec else (gw or "gateway")
lines.append(f'  {gw_id}["Router / Gateway<br/>{gw_label}"]')

# Infrastructure nodes (unmanaged switches, patch panels, ...) parented by uplink.
for n in infra_nodes:
    iid = infra_node_id(n["id"])
    parts = [esc(n["name"])]
    if n.get("model"):
        parts.append(esc(n["model"])[:28])
    if n.get("speed"):
        parts.append(esc(n["speed"]))
    if n.get("location"):
        parts.append(esc(n["location"]))
    lines.append(f'  {iid}["{"<br/>".join(parts)}"]')
    lines.append(f"  {ent_id(n.get('parent'))} --> {iid}")

for rec in hosts:
    if rec["ip"] == gw:
        continue
    nid = node_id(rec["ip"])
    lines.append(f'  {nid}["{label(rec)}"]')
    lines.append(f"  {ent_id(rec.get('parent', gw))} --> {nid}")

# this Mac (self) with its link-speed label — surfaces a slow uplink visually
for sif in self_ifaces:
    sid = "self_" + sif["device"]
    spd = sif.get("link_mbps")
    cap = sif.get("max_supported_mbps")
    warn = ""
    if spd and cap and spd < cap:
        warn = f"<br/>LINK {spd}/{cap} Mbps (!)"
    lines.append(f'  {sid}(["This Mac<br/>{sif["device"]} {sif.get("kind","")}<br/>{sif["ipv4"]}{warn}"])')
    edge = f'{spd} Mbps' if spd else sif.get("kind", "")
    lines.append(f'  {sid} -- "{edge}" --> {ent_id(_parent_of.get(sif["ipv4"], gw))}')

# class styling
lines.append("  classDef router fill:#1f6feb,stroke:#0b3d91,color:#fff;")
lines.append("  classDef ap fill:#2da44e,stroke:#116329,color:#fff;")
lines.append("  classDef camera fill:#cf222e,stroke:#7d1620,color:#fff;")
lines.append("  classDef printer fill:#8250df,stroke:#4c2889,color:#fff;")
lines.append("  classDef nas fill:#bf8700,stroke:#7a5800,color:#fff;")
lines.append("  classDef media fill:#bc4c00,stroke:#7a3000,color:#fff;")
lines.append("  classDef tv fill:#e16f24,stroke:#9a4a12,color:#fff;")
lines.append("  classDef iot fill:#0969da,stroke:#06316e,color:#fff;")
lines.append("  classDef computer fill:#57606a,stroke:#2d333b,color:#fff;")
lines.append("  classDef unknown fill:#d0d7de,stroke:#8c959f,color:#1a1a1a;")
lines.append("  classDef selfnode fill:#fff8c5,stroke:#9a6700,color:#1a1a1a;")
if gw_rec or gw:
    lines.append(f"  class {gw_id} router;")
for rec in hosts:
    if rec["ip"] == gw:
        continue
    cls = ROLE_CLASS.get(rec.get("role", ""), "unknown")
    lines.append(f"  class {node_id(rec['ip'])} {cls};")
for sif in self_ifaces:
    lines.append(f'  class self_{sif["device"]} selfnode;')
for n in infra_nodes:
    lines.append(f'  class {infra_node_id(n["id"])} {INFRA_CLASS.get(n["type"], "unknown")};')

with open(os.environ["NETKIT_MMD_OUT"], "w") as f:
    f.write("\n".join(lines) + "\n")

# ---- interactive HTML map (static, lightweight) ----
try:
    import recon_map
    with open(os.environ["NETKIT_HTML_OUT"], "w") as f:
        f.write(recon_map.render(report))
except Exception as e:
    print(f"warn: html map render failed: {e}", file=sys.stderr)

# ---- interactive editor (vis-network) ----
try:
    import recon_editor
    with open(os.environ["NETKIT_EDITOR_OUT"], "w") as f:
        f.write(recon_editor.render(report))
except Exception as e:
    print(f"warn: editor render failed: {e}", file=sys.stderr)

# ---- draw.io export ----
try:
    import drawio_export
    with open(os.environ["NETKIT_DRAWIO_OUT"], "w") as f:
        f.write(drawio_export.render(report))
except Exception as e:
    print(f"warn: drawio export failed: {e}", file=sys.stderr)

# ---- stdout summary ----
fmt = os.environ.get("NETKIT_STDOUT_FMT", "")
if fmt == "json":
    print(json.dumps(report, indent=2, default=str))
else:
    by_role = {}
    for h in hosts:
        by_role.setdefault(h.get("role", "host"), []).append(h["ip"])
    print(f"\nrecon — {len(hosts)} host(s) on {report['subnet'] or '?'} via {report['interface'] or '?'}")
    print(f"gateway: {gw}" + (f"   uplink: Starlink {dish.get('hardware','')}" if dish else ""))
    print()
    for role in sorted(by_role):
        print(f"  {role:<20} {len(by_role[role])}  ({', '.join(by_role[role])})")
PY

log_ok "JSON   → ${JSON_OUT/#$NETKIT_ROOT\//}"
log_ok "Mermaid→ ${MMD_OUT/#$NETKIT_ROOT\//}"
log_ok "Map    → ${HTML_OUT/#$NETKIT_ROOT\//}"
log_ok "Editor → ${EDITOR_OUT/#$NETKIT_ROOT\//}"
log_ok "draw.io→ ${DRAWIO_OUT/#$NETKIT_ROOT\//}"
