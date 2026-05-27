#!/usr/bin/env bash
# Generate a combined report from all toolkit modules.
#
# Outputs (timestamped):
#   output/report-YYYYMMDD-HHMMSS.json     — machine-readable
#   output/report-YYYYMMDD-HHMMSS.md       — human-readable
#   output/topology-YYYYMMDD-HHMMSS.mmd    — mermaid diagram
#
# Usage:
#   generate.sh [--active] [--interface en7] [--include-traceroute]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

ACTIVE=0
INCLUDE_TRACE=0
IFACE=""

while (( $# )); do
  case "$1" in
    --active) ACTIVE=1; shift ;;
    --include-traceroute) INCLUDE_TRACE=1; shift ;;
    --interface) IFACE="$2"; shift 2 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

ensure_output_dir
TS=$(timestamp)
JSON_OUT="${NETKIT_OUTPUT_DIR}/report-${TS}.json"
MD_OUT="${NETKIT_OUTPUT_DIR}/report-${TS}.md"
MMD_OUT="${NETKIT_OUTPUT_DIR}/topology-${TS}.mmd"

[[ -z "$IFACE" ]] && IFACE=$(pick_interface || echo "")

log_info "Generating report (interface=${IFACE:-auto}, active=${ACTIVE}, traceroute=${INCLUDE_TRACE})"

# Common per-module flag arrays
HOSTS_FLAGS=("--json")
TOPO_FLAGS=("--json")
TOPO_MMD_FLAGS=("--mermaid")
PING_FLAGS=("--json" "--count" "15")

if (( ACTIVE )); then
  HOSTS_FLAGS+=("--active")
  TOPO_FLAGS+=("--active")
  TOPO_MMD_FLAGS+=("--active")
fi
if (( INCLUDE_TRACE )); then
  TOPO_FLAGS+=("--traceroute")
  TOPO_MMD_FLAGS+=("--traceroute")
fi
if [[ -n "$IFACE" ]]; then
  HOSTS_FLAGS+=("--interface" "$IFACE")
  TOPO_FLAGS+=("--interface" "$IFACE")
  TOPO_MMD_FLAGS+=("--interface" "$IFACE")
  PING_FLAGS+=("--interface" "$IFACE")
fi

# Per-module temp files (so we can pass paths to python instead of inlining JSON)
TMP_DIR="$(mktemp -d -t netkit-report.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

log_info "  ... interfaces"
"${SCRIPT_DIR}/../discovery/interfaces.sh" --json > "$TMP_DIR/interfaces.json" 2>/dev/null || echo '{}' > "$TMP_DIR/interfaces.json"

log_info "  ... dns"
"${SCRIPT_DIR}/../discovery/dns.sh" --json > "$TMP_DIR/dns.json" 2>/dev/null || echo '{}' > "$TMP_DIR/dns.json"

log_info "  ... hosts"
"${SCRIPT_DIR}/../discovery/hosts.sh" "${HOSTS_FLAGS[@]}" > "$TMP_DIR/hosts.json" 2>/dev/null || echo '{"hosts":[]}' > "$TMP_DIR/hosts.json"

log_info "  ... quality"
"${SCRIPT_DIR}/../quality/ping.sh" "${PING_FLAGS[@]}" > "$TMP_DIR/quality.json" 2>/dev/null || echo '{"targets":[]}' > "$TMP_DIR/quality.json"

log_info "  ... diagnostics"
"${SCRIPT_DIR}/../diagnostics/dev.sh" --json > "$TMP_DIR/diagnostics.json" 2>/dev/null || echo '{}' > "$TMP_DIR/diagnostics.json"

log_info "  ... inventory"
"${SCRIPT_DIR}/../inventory/system.sh" --json > "$TMP_DIR/inventory.json" 2>/dev/null || echo '{}' > "$TMP_DIR/inventory.json"

log_info "  ... topology"
"${SCRIPT_DIR}/../topology/map.sh" "${TOPO_FLAGS[@]}" > "$TMP_DIR/topology.json" 2>/dev/null || echo '{}' > "$TMP_DIR/topology.json"

log_info "  ... topology (mermaid)"
"${SCRIPT_DIR}/../topology/map.sh" "${TOPO_MMD_FLAGS[@]}" > "$MMD_OUT" 2>/dev/null || echo "graph TD" > "$MMD_OUT"

# Combine all JSONs
export NETKIT_TMP_DIR="$TMP_DIR" NETKIT_TS="$TS" NETKIT_IFACE_HINT="$IFACE"
export NETKIT_ACTIVE="$ACTIVE" NETKIT_TRACE="$INCLUDE_TRACE"
export NETKIT_JSON_OUT="$JSON_OUT" NETKIT_MD_OUT="$MD_OUT"

python3 - <<'PY'
import json, os, sys

tmp = os.environ["NETKIT_TMP_DIR"]
def load(name):
    p = os.path.join(tmp, f"{name}.json")
    try:
        return json.load(open(p))
    except (OSError, json.JSONDecodeError) as e:
        return {"_load_error": str(e)}

report = {
    "meta": {
        "generated_at": os.environ["NETKIT_TS"],
        "interface_hint": os.environ["NETKIT_IFACE_HINT"],
        "active_probe": os.environ["NETKIT_ACTIVE"] == "1",
        "include_traceroute": os.environ["NETKIT_TRACE"] == "1",
    },
    "inventory": load("inventory"),
    "interfaces": load("interfaces"),
    "dns": load("dns"),
    "hosts": load("hosts"),
    "quality": load("quality"),
    "diagnostics": load("diagnostics"),
    "topology": load("topology"),
}

with open(os.environ["NETKIT_JSON_OUT"], "w") as f:
    json.dump(report, f, indent=2, default=str)

# ---- Markdown synthesis ----
data = report
inv = data.get("inventory", {})
ifs = data.get("interfaces", {})
dns = data.get("dns", {})
hosts = data.get("hosts", {})
q = data.get("quality", {})
diag = data.get("diagnostics", {})

bt = "`"
def pct(v):
    try: return f"{float(v):.1f}%"
    except Exception: return str(v)

out = []
out.append(f"# Network report — {data['meta']['generated_at']}\n")
out.append("## Executive summary\n")
default_if = ifs.get("default_interface","")
default_gw = ifs.get("default_gateway","")
out.append(f"- **Active interface:** {bt}{default_if}{bt} → gateway {bt}{default_gw}{bt}")
out.append(f"- **Hosts visible on LAN:** {hosts.get('count', 0)}")
if q.get("targets"):
    gw = q["targets"][0] if q["targets"] else None
    if gw:
        out.append(f"- **Gateway latency:** {gw.get('rtt_avg_ms','?')} ms avg, {pct(gw.get('loss_pct',0))} loss")
    inet = [t for t in q["targets"] if t.get("target") not in (default_gw,)][:1]
    if inet:
        out.append(f"- **Internet latency ({inet[0]['target']}):** {inet[0].get('rtt_avg_ms','?')} ms avg, {pct(inet[0].get('loss_pct',0))} loss")
ghttps = diag.get("github_https",{}) if isinstance(diag, dict) else {}
out.append(f"- **GitHub HTTPS:** {'OK' if ghttps.get('ok') else 'FAIL'}")
out.append(f"- **DNS query ({q.get('dns_domain','')}):** {q.get('dns_query_ms','?')} ms\n")

out.append("## System inventory\n")
osd = inv.get("os", {}); hwd = inv.get("hardware", {})
out.append(f"- {osd.get('product_name','')} {osd.get('product_version','')} on {hwd.get('model','')}")
out.append(f"- CPU: {hwd.get('cpu_brand','')} ({hwd.get('cpu_cores','?')} cores), RAM: {hwd.get('memory_gb','?')} GB\n")

out.append("## Interfaces\n")
out.append("| device | kind | ipv4 | cidr | status | media | hardware_port | default |")
out.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
for r in ifs.get("interfaces", []):
    cells = [str(r.get(c,"") or "") for c in ("device","kind","ipv4","netmask_cidr","status","media","hardware_port")]
    cells.append("yes" if r.get("is_default_route") else "")
    out.append("| " + " | ".join(cells) + " |")
out.append("")

out.append("## DNS\n")
for r in dns.get("resolvers", []):
    if r.get("nameservers"):
        out.append(f"- **{r.get('id')}** ({r.get('interface') or '-'}): {', '.join(r['nameservers'])}")
out.append("")

out.append(f"## LAN hosts ({hosts.get('count', 0)})\n")
if hosts.get("hosts"):
    out.append("| IP | MAC | Vendor | Name | Source |")
    out.append("| --- | --- | --- | --- | --- |")
    for h in hosts["hosts"]:
        cells = [str(h.get(c,"") or "") for c in ("ip","mac","vendor","name","source")]
        out.append("| " + " | ".join(cells) + " |")
else:
    out.append("_no hosts in ARP cache. Re-run with `--active` to probe._")
out.append("")

out.append("## Quality\n")
out.append(f"- DNS lookup: **{q.get('dns_query_ms','?')} ms** ({q.get('dns_domain','')})\n")
out.append("| target | sent | recv | loss % | min ms | avg ms | max ms | stddev (jitter) ms |")
out.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
for r in q.get("targets", []):
    out.append(f"| {r.get('target','?')} | {r.get('sent','')} | {r.get('received','')} | "
               f"{r.get('loss_pct',0):.1f} | {r.get('rtt_min_ms',0):.2f} | "
               f"{r.get('rtt_avg_ms',0):.2f} | {r.get('rtt_max_ms',0):.2f} | {r.get('rtt_stddev_ms',0):.2f} |")
out.append("")

out.append("## Diagnostics (dev workflow)\n")
out.append(f"- **GitHub HTTPS:** ok={ghttps.get('ok')}, http={ghttps.get('http_code')}, time={ghttps.get('time_s')}s")
tls = diag.get("tls_github",{}) if isinstance(diag, dict) else {}
out.append(f"- **TLS github.com:** ok={tls.get('ok')}, time={tls.get('time_ms')} ms, not_after={tls.get('not_after','')}")
out.append(f"- **Docker:** {diag.get('docker',{})}")
out.append(f"- **Podman:** {diag.get('podman',{})}")
out.append(f"- **Tailscale:** {diag.get('tailscale',{})}")
vpn = ", ".join(f"{v['interface']}={v.get('inet') or '-'}" for v in diag.get('vpn_tunnels',[])) if isinstance(diag, dict) else ""
out.append(f"- **VPN tunnels:** {vpn or '_none_'}\n")

# Recommendations
recs = []
missing = [t for t,v in (inv.get("tools") or {}).items()
           if v is None and t in {"nmap","arp-scan","iperf3","mtr","jq"}]
if missing:
    recs.append(f"Install optional tools for fuller reports: `brew install {' '.join(missing)}`")
for r in q.get("targets", []):
    if r.get("loss_pct", 0) > 5:
        recs.append(f"Packet loss to {r['target']} is {r['loss_pct']:.1f}% — investigate the path.")
    if r.get("rtt_stddev_ms", 0) > 30:
        recs.append(f"Jitter to {r['target']} is {r['rtt_stddev_ms']:.1f} ms — link may be unstable.")
if q.get("dns_query_ms") and q.get("dns_query_ms", 0) > 100:
    recs.append(f"DNS lookup took {q['dns_query_ms']} ms — consider switching resolver.")
if not ghttps.get("ok"):
    recs.append("GitHub HTTPS failed — check VPN, proxy, or DNS for github.com.")

out.append("## Recommendations\n")
if recs:
    for r in recs:
        out.append(f"- {r}")
else:
    out.append("- No issues detected. Re-run with `--active` to deepen the LAN sweep.")
out.append("")

out.append("## Limitations\n")
out.append("- Active scans are bounded to your local subnet by default and capped at NETKIT_MAX_HOSTS.")
out.append("- Tools that require root (arp-scan, raw nmap modes, tcpdump) are skipped unless explicitly enabled.")
out.append("- macOS link speed is reported from `networksetup -getMedia`; not all adapters expose it.")
out.append("- No credential, token or secret is collected or written.")

with open(os.environ["NETKIT_MD_OUT"], "w") as f:
    f.write("\n".join(out) + "\n")
PY

log_ok "Report → ${MD_OUT/#$NETKIT_ROOT\//}"
log_ok "JSON   → ${JSON_OUT/#$NETKIT_ROOT\//}"
log_ok "Mermaid→ ${MMD_OUT/#$NETKIT_ROOT\//}"

echo
echo "$MD_OUT"
echo "$JSON_OUT"
echo "$MMD_OUT"
