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
STDOUT_FMT=""
ALLOW_PARTIAL=0
USE_ARPSCAN=0

while (( $# )); do
  case "$1" in
    --active) ACTIVE=1; shift ;;
    --include-traceroute) INCLUDE_TRACE=1; shift ;;
    --arpscan) USE_ARPSCAN=1; shift ;;
    --interface) IFACE="$2"; shift 2 ;;
    --json) STDOUT_FMT="json"; shift ;;
    --md)   STDOUT_FMT="md"; shift ;;
    --text) STDOUT_FMT="text"; shift ;;
    --allow-partial) ALLOW_PARTIAL=1; shift ;;
    --yes) export NETKIT_YES=1; shift ;;
    --allow-raw) export NETKIT_ALLOW_RAW=1; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

# --arpscan implies --allow-raw OR strict mode will block it. Tell the user.
if (( USE_ARPSCAN )) && [[ "${NETKIT_ALLOW_RAW:-0}" != "1" ]] && [[ "${NETKIT_STRICT:-1}" == "1" ]]; then
  die "--arpscan requires --allow-raw (or NETKIT_ALLOW_RAW=1) because arp-scan needs sudo."
fi

ensure_output_dir
TS=$(timestamp)
JSON_OUT="${NETKIT_OUTPUT_DIR}/report-${TS}.json"
MD_OUT="${NETKIT_OUTPUT_DIR}/report-${TS}.md"
MMD_OUT="${NETKIT_OUTPUT_DIR}/topology-${TS}.mmd"

[[ -z "$IFACE" ]] && IFACE=$(pick_interface || echo "")
SUBNET=""
if [[ -n "$IFACE" ]]; then
  SUBNET=$(iface_subnet_cidr "$IFACE" 2>/dev/null || echo "")
fi

# If --active was requested, confirm ONCE at the report level (so the user
# isn't reprompted by each submodule and so we don't write a misleading
# 0-hosts report when they decline).
if (( ACTIVE )); then
  if [[ -n "$SUBNET" ]]; then
    guard_active "$SUBNET"
  else
    log_warn "Could not derive subnet for ${IFACE:-?}; skipping active confirmation."
  fi
  # Once confirmed (or NETKIT_YES=1), suppress further prompts in submodules.
  export NETKIT_YES=1
fi

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
if (( USE_ARPSCAN )); then
  HOSTS_FLAGS+=("--arpscan")
  TOPO_FLAGS+=("--arpscan")
  TOPO_MMD_FLAGS+=("--arpscan")
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

ERRORS_FILE="$TMP_DIR/_errors.json"
echo "[]" > "$ERRORS_FILE"

# Run a module and capture rc + last stderr line. On failure write a fallback
# JSON to the destination so the report can still render, but record the
# failure in module_errors so it's visible in the final report.
run_module() {
  local name="$1" out="$2" fallback="$3"; shift 3
  local err rc=0
  err="$(mktemp -t netkit-err.XXXXXX)"
  log_info "  ... ${name}"
  # Temporarily disable errexit so a failing module doesn't kill the report.
  set +e
  "$@" >"$out" 2>"$err"
  rc=$?
  set -e
  if (( rc == 0 )); then
    rm -f "$err"
    return 0
  fi
  local tail
  tail="$(tail -n 5 "$err" 2>/dev/null | tr '\n' ' ' | cut -c 1-300)"
  log_warn "  ${name} failed (rc=${rc}); see report.meta.module_errors"
  printf '%s' "$fallback" > "$out"
  NETKIT_ERR_FILE="$ERRORS_FILE" NETKIT_ERR_MOD="$name" \
    NETKIT_ERR_RC="$rc" NETKIT_ERR_TAIL="$tail" python3 - <<'PY'
import json, os
p = os.environ["NETKIT_ERR_FILE"]
data = json.load(open(p))
data.append({
    "module": os.environ["NETKIT_ERR_MOD"],
    "rc": int(os.environ["NETKIT_ERR_RC"]),
    "stderr_tail": os.environ["NETKIT_ERR_TAIL"],
})
json.dump(data, open(p, "w"))
PY
  rm -f "$err"
  return 0
}

run_module "interfaces"  "$TMP_DIR/interfaces.json"  '{}' \
  "${SCRIPT_DIR}/../discovery/interfaces.sh" --json
run_module "dns"         "$TMP_DIR/dns.json"         '{}' \
  "${SCRIPT_DIR}/../discovery/dns.sh" --json
run_module "hosts"       "$TMP_DIR/hosts.json"       '{"hosts":[]}' \
  "${SCRIPT_DIR}/../discovery/hosts.sh" "${HOSTS_FLAGS[@]}"
run_module "quality"     "$TMP_DIR/quality.json"     '{"targets":[]}' \
  "${SCRIPT_DIR}/../quality/ping.sh" "${PING_FLAGS[@]}"
run_module "diagnostics" "$TMP_DIR/diagnostics.json" '{}' \
  "${SCRIPT_DIR}/../diagnostics/dev.sh" --json
run_module "inventory"   "$TMP_DIR/inventory.json"   '{}' \
  "${SCRIPT_DIR}/../inventory/system.sh" --json
run_module "topology"    "$TMP_DIR/topology.json"    '{}' \
  "${SCRIPT_DIR}/../topology/map.sh" "${TOPO_FLAGS[@]}"
run_module "topology_mermaid" "$MMD_OUT" 'graph TD' \
  "${SCRIPT_DIR}/../topology/map.sh" "${TOPO_MMD_FLAGS[@]}"

# Combine all JSONs
export NETKIT_TMP_DIR="$TMP_DIR" NETKIT_TS="$TS" NETKIT_IFACE_HINT="$IFACE"
export NETKIT_ACTIVE="$ACTIVE" NETKIT_TRACE="$INCLUDE_TRACE"
export NETKIT_JSON_OUT="$JSON_OUT" NETKIT_MD_OUT="$MD_OUT"
export NETKIT_ERRORS_FILE="$ERRORS_FILE"

python3 - <<'PY'
import json, os, sys

tmp = os.environ["NETKIT_TMP_DIR"]
def load(name):
    p = os.path.join(tmp, f"{name}.json")
    try:
        return json.load(open(p))
    except (OSError, json.JSONDecodeError) as e:
        return {"_load_error": str(e)}

try:
    module_errors = json.load(open(os.environ["NETKIT_ERRORS_FILE"]))
except Exception:
    module_errors = []

try:
    tool_version = open(os.path.join(os.environ.get("NETKIT_ROOT", ""), "VERSION")).read().strip()
except OSError:
    tool_version = "unknown"

report = {
    "meta": {
        "schema_version": "1.0.0",
        "tool_version": tool_version,
        "generated_at": os.environ["NETKIT_TS"],
        "interface_hint": os.environ["NETKIT_IFACE_HINT"],
        "active_probe": os.environ["NETKIT_ACTIVE"] == "1",
        "include_traceroute": os.environ["NETKIT_TRACE"] == "1",
        "module_errors": module_errors,
        "partial": bool(module_errors),
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

failed_modules = {e.get("module") for e in module_errors}
diagnostics_failed = "diagnostics" in failed_modules

out = []
out.append(f"# Network report — {data['meta']['generated_at']}\n")
if module_errors:
    out.append("> **PARTIAL REPORT** — one or more modules failed. See the\n> _Module failures_ section below. Re-run with `--allow-partial` to\n> preserve exit code 0.\n")
out.append("## Executive summary\n")
default_if = ifs.get("default_interface","")
default_gw = ifs.get("default_gateway","")
out.append(f"- **Active interface:** {bt}{default_if}{bt} → gateway {bt}{default_gw}{bt}")
out.append(f"- **Hosts visible on LAN:** {hosts.get('count', 0)}")
# Surface arp-scan degradation explicitly so the user notices vendor data
# came from the OUI cache only (not from arp-scan's own vendor DB).
arp = hosts.get("arp_scan") or {}
if arp.get("requested") and not arp.get("ran"):
    out.append(f"- **arp-scan:** requested but **did NOT run** ({arp.get('reason','?')}). Vendor enrichment came from the OUI cache only.")
if q.get("targets"):
    gw = q["targets"][0] if q["targets"] else None
    if gw:
        out.append(f"- **Gateway latency:** {gw.get('rtt_avg_ms','?')} ms avg, {pct(gw.get('loss_pct',0))} loss")
    inet = [t for t in q["targets"] if t.get("target") not in (default_gw,)][:1]
    if inet:
        out.append(f"- **Internet latency ({inet[0]['target']}):** {inet[0].get('rtt_avg_ms','?')} ms avg, {pct(inet[0].get('loss_pct',0))} loss")
ghttps = diag.get("github_https",{}) if isinstance(diag, dict) else {}
if diagnostics_failed:
    out.append("- **GitHub HTTPS:** UNKNOWN (diagnostics module failed)")
else:
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
if not diagnostics_failed and not ghttps.get("ok"):
    recs.append("GitHub HTTPS failed — check VPN, proxy, or DNS for github.com.")
if diagnostics_failed:
    recs.append("Diagnostics module failed — connectivity checks were not run. Investigate scripts/diagnostics/dev.sh.")

out.append("## Recommendations\n")
if recs:
    for r in recs:
        out.append(f"- {r}")
else:
    out.append("- No issues detected. Re-run with `--active` to deepen the LAN sweep.")
out.append("")

if module_errors:
    out.append("## Module failures\n")
    out.append("| module | rc | stderr (tail) |")
    out.append("| --- | ---: | --- |")
    for e in module_errors:
        tail = (e.get("stderr_tail") or "").replace("|", r"\|")
        out.append(f"| {e.get('module')} | {e.get('rc')} | {tail} |")
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

case "$STDOUT_FMT" in
  json) cat "$JSON_OUT" ;;
  md)   cat "$MD_OUT" ;;
  text)
    # Compact text summary distilled from the JSON.
    NETKIT_JSON_PATH="$JSON_OUT" python3 - <<'PY'
import json, os
r = json.load(open(os.environ["NETKIT_JSON_PATH"]))
m = r.get("meta", {}); ifs = r.get("interfaces", {}); q = r.get("quality", {})
d = r.get("diagnostics", {}); h = r.get("hosts", {})
errors = m.get("module_errors", [])
failed = {e.get("module") for e in errors}
if m.get("partial"):
    print("*** PARTIAL REPORT — see Module failures below ***\n")
print(f"Generated      : {m.get('generated_at')}")
print(f"Interface      : {ifs.get('default_interface')} -> {ifs.get('default_gateway')}")
print(f"LAN hosts      : {h.get('count', 0)}")
if q.get("targets"):
    g = q["targets"][0]
    print(f"Gateway RTT    : avg={g.get('rtt_avg_ms','?')} ms  loss={g.get('loss_pct',0)}%")
    inet = [t for t in q['targets'] if t.get('target') != ifs.get('default_gateway')][:1]
    if inet:
        i = inet[0]
        print(f"Internet RTT   : {i.get('target')} avg={i.get('rtt_avg_ms','?')} ms loss={i.get('loss_pct',0)}%")
if "diagnostics" in failed:
    print("GitHub HTTPS   : UNKNOWN (diagnostics module failed)")
else:
    print(f"GitHub HTTPS   : {'OK' if d.get('github_https',{}).get('ok') else 'FAIL'}")
arp = (h.get("arp_scan") or {})
if arp.get("requested") and not arp.get("ran"):
    print(f"arp-scan       : SKIPPED ({arp.get('reason','?')}) — vendors from OUI cache only")
if errors:
    print()
    print("Module failures:")
    for e in errors:
        print(f"  {e.get('module')}: rc={e.get('rc')}  {e.get('stderr_tail','')}")
PY
    ;;
  "")
    echo
    echo "$MD_OUT"
    echo "$JSON_OUT"
    echo "$MMD_OUT"
    ;;
  *) die "Unknown --json/--md/--text combination" ;;
esac

# Partial-report exit contract: if any module failed, exit non-zero unless
# the caller opted in via --allow-partial. Artifacts are already on disk.
if python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) else 2)' "$ERRORS_FILE" 2>/dev/null; then
  if (( ALLOW_PARTIAL )); then
    log_warn "Report is partial; --allow-partial set, exit 0."
    exit 0
  fi
  log_err "Report is partial (module_errors not empty). Exit 1. Pass --allow-partial to override."
  exit 1
fi
