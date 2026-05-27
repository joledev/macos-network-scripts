#!/usr/bin/env bash
# Diff two netkit reports.
#
# Usage:
#   diff.sh [A] [B]
#
# A and B can be:
#   - omitted:           latest vs the previous one (diff.sh alone)
#   - a single value:    that one vs latest (diff.sh <ts>)
#   - two values:        A vs B (diff.sh <ts1> <ts2>)
#
# Each value can be:
#   - "latest"                  → newest report
#   - "previous"                → second-newest
#   - full path                 → output/report-YYYYMMDD-HHMMSS.json
#   - bare filename             → report-YYYYMMDD-HHMMSS.json
#   - timestamp                 → YYYYMMDD-HHMMSS (or any unambiguous prefix/substring)
#
# Output formats: --text (default), --json, --md.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
ARGS=()


while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --text) FORMAT="text"; shift ;;
    --md)   FORMAT="md"; shift ;;
    -h|--help)
      sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    --*) die_usage "Unknown flag: $1" ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

# Reject extra positionals — silently ignoring them gives a misleading
# "successful" diff against a different pair than the user typed.
if (( ${#ARGS[@]} > 2 )); then
  die_usage "diff accepts at most two report refs (got ${#ARGS[@]}: ${ARGS[*]})"
fi

A_RAW="${ARGS[0]:-previous}"
B_RAW="${ARGS[1]:-latest}"
# Exception: with exactly one positional we want "<arg> vs latest", which
# is already the default. With zero positionals we want "previous vs latest".
if (( ${#ARGS[@]} == 1 )); then
  A_RAW="${ARGS[0]}"
  B_RAW="latest"
fi

ensure_output_dir
export NETKIT_FMT="$FORMAT" NETKIT_A_RAW="$A_RAW" NETKIT_B_RAW="$B_RAW"

python3 - <<'PY'
import json, os, sys
from pathlib import Path

out_dir = Path(os.environ["NETKIT_OUTPUT_DIR"])
fmt     = os.environ["NETKIT_FMT"]
a_raw   = os.environ["NETKIT_A_RAW"]
b_raw   = os.environ["NETKIT_B_RAW"]

reports = sorted(out_dir.glob("report-*.json"), reverse=True)

def resolve(raw: str) -> Path:
    if raw == "latest":
        if not reports: sys.exit("no reports under output/")
        return reports[0]
    if raw == "previous":
        if len(reports) < 2: sys.exit("only one report; nothing to diff against")
        return reports[1]
    # Try as path first
    p = Path(raw)
    if p.is_file():
        return p
    # Try as bare filename in output/
    p2 = out_dir / raw
    if p2.is_file():
        return p2
    # Try as timestamp prefix/substring against report filenames
    matches = [r for r in reports if raw in r.name]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        sys.exit(f"ambiguous: '{raw}' matches {len(matches)} reports: " + ", ".join(m.name for m in matches[:5]))
    sys.exit(f"no report matched '{raw}'")

A_path = resolve(a_raw)
B_path = resolve(b_raw)
if A_path == B_path:
    sys.exit(f"refusing to diff a report against itself ({A_path.name})")

A = json.load(open(A_path))
B = json.load(open(B_path))

# --- Build the diff payload ---

def hosts_by_ip(rep):
    return {h["ip"]: h for h in rep.get("hosts", {}).get("hosts", [])}

A_hosts = hosts_by_ip(A)
B_hosts = hosts_by_ip(B)

added_ips   = sorted(set(B_hosts) - set(A_hosts))
removed_ips = sorted(set(A_hosts) - set(B_hosts))
common_ips  = sorted(set(A_hosts) & set(B_hosts))

host_changes = []
for ip in common_ips:
    a, b = A_hosts[ip], B_hosts[ip]
    changes = {}
    for k in ("mac", "vendor", "name", "known_name", "role", "source"):
        if a.get(k) != b.get(k):
            changes[k] = {"from": a.get(k), "to": b.get(k)}
    if changes:
        host_changes.append({"ip": ip, "changes": changes})

# Quality deltas per target (match by target name)
def quality_by_target(rep):
    return {t["target"]: t for t in rep.get("quality", {}).get("targets", []) or []}
A_q = quality_by_target(A)
B_q = quality_by_target(B)
common_t = sorted(set(A_q) & set(B_q))
quality_diff = []
for tgt in common_t:
    a, b = A_q[tgt], B_q[tgt]
    d_avg  = (b.get("rtt_avg_ms") or 0) - (a.get("rtt_avg_ms") or 0)
    d_loss = (b.get("loss_pct") or 0) - (a.get("loss_pct") or 0)
    pct = (d_avg / (a.get("rtt_avg_ms") or 1)) * 100 if a.get("rtt_avg_ms") else 0
    quality_diff.append({
        "target": tgt,
        "rtt_avg_a": a.get("rtt_avg_ms"),
        "rtt_avg_b": b.get("rtt_avg_ms"),
        "rtt_delta": round(d_avg, 3),
        "rtt_delta_pct": round(pct, 1),
        "loss_a": a.get("loss_pct"),
        "loss_b": b.get("loss_pct"),
        "loss_delta": round(d_loss, 2),
        "significant": abs(pct) > 10.0 or abs(d_loss) >= 1.0,
    })

# Interface status changes (active ↔ inactive ↔ no-such-iface)
def iface_status(rep):
    return {i["device"]: {"status": i.get("status",""), "ipv4": i.get("ipv4",""), "media": i.get("media","")}
            for i in (rep.get("interfaces", {}).get("interfaces") or [])}
A_if = iface_status(A); B_if = iface_status(B)
iface_changes = []
for dev in sorted(set(A_if) | set(B_if)):
    a, b = A_if.get(dev), B_if.get(dev)
    if a != b:
        iface_changes.append({"device": dev, "from": a, "to": b})

# Diagnostics highlights
def diag(rep, *path, default=None):
    cur = rep.get("diagnostics", {})
    for k in path:
        if not isinstance(cur, dict): return default
        cur = cur.get(k, default if k == path[-1] else {})
    return cur

diagnostics_delta = {
    "github_https_ok": [diag(A, "github_https", "ok"), diag(B, "github_https", "ok")],
    "tls_github_ok":   [diag(A, "tls_github", "ok"),   diag(B, "tls_github", "ok")],
    "ipv6_ping_ok":    [diag(A, "ipv6", "ping6_ok"),   diag(B, "ipv6", "ping6_ok")],
    "docker_running":  [diag(A, "docker", "running"),  diag(B, "docker", "running")],
    "tailscale_in":    [diag(A, "tailscale", "logged_in"), diag(B, "tailscale", "logged_in")],
}

# VPN tunnel deltas: by interface name
def utuns(rep):
    return {t["interface"]: t for t in (rep.get("diagnostics", {}).get("vpn_tunnels") or [])
            if t.get("inet")}
A_t = utuns(A); B_t = utuns(B)
tunnel_changes = []
for iface in sorted(set(A_t) | set(B_t)):
    a, b = A_t.get(iface), B_t.get(iface)
    if a != b:
        tunnel_changes.append({"interface": iface, "from": a, "to": b})

# Listening ports diff (by (port, command))
def ports(rep):
    return {(p.get("port"), p.get("command")) for p in (rep.get("diagnostics", {}).get("listening_ports") or [])}
ports_a = ports(A); ports_b = ports(B)
ports_added   = sorted([f"{p}:{c}" for (p, c) in (ports_b - ports_a)])
ports_removed = sorted([f"{p}:{c}" for (p, c) in (ports_a - ports_b)])

result = {
    "a": {"file": A_path.name, "timestamp": A.get("meta", {}).get("generated_at", "")},
    "b": {"file": B_path.name, "timestamp": B.get("meta", {}).get("generated_at", "")},
    "hosts": {
        "added":   [B_hosts[ip] for ip in added_ips],
        "removed": [A_hosts[ip] for ip in removed_ips],
        "changed": host_changes,
        "common_count": len(common_ips),
    },
    "quality": quality_diff,
    "interfaces": iface_changes,
    "diagnostics": diagnostics_delta,
    "vpn_tunnels": tunnel_changes,
    "listening_ports": {"added": ports_added, "removed": ports_removed},
}

if fmt == "json":
    print(json.dumps(result, indent=2, default=str))
    sys.exit(0)

# ---- text / md ----
out = []
def line(s=""): out.append(s)

is_md = (fmt == "md")
b = "**" if is_md else ""

if is_md:
    line(f"# Diff — {result['a']['timestamp']} → {result['b']['timestamp']}\n")
else:
    line(f"netkit diff")
    line(f"  A: {result['a']['file']}  ({result['a']['timestamp']})")
    line(f"  B: {result['b']['file']}  ({result['b']['timestamp']})")
    line("")

# Hosts
line(f"{b}Hosts{b}: +{len(result['hosts']['added'])} new, -{len(result['hosts']['removed'])} removed, ~{len(result['hosts']['changed'])} changed, ={result['hosts']['common_count']} common")
for h in result["hosts"]["added"]:
    label = h.get("known_name") or h.get("name") or h.get("vendor", "")
    line(f"  + {h['ip']:<15} {h['mac']:<19} {label}")
for h in result["hosts"]["removed"]:
    label = h.get("known_name") or h.get("name") or h.get("vendor", "")
    line(f"  - {h['ip']:<15} {h['mac']:<19} {label}")
for c in result["hosts"]["changed"]:
    bits = []
    for k, ch in c["changes"].items():
        bits.append(f"{k}: {ch['from']!r} → {ch['to']!r}")
    line(f"  ~ {c['ip']:<15}  " + "; ".join(bits))
line("")

# Quality
line(f"{b}Quality{b}:")
for q in result["quality"]:
    flag = "  *" if q["significant"] else "   "
    rtt = f"{q['rtt_avg_a']:.2f} → {q['rtt_avg_b']:.2f} ms  Δ {q['rtt_delta']:+.2f} ({q['rtt_delta_pct']:+.1f}%)"
    loss = f"loss Δ {q['loss_delta']:+.1f}%"
    line(f"  {flag} {q['target']:<22} {rtt}   {loss}")
line("")

# Interfaces
if result["interfaces"]:
    line(f"{b}Interfaces{b}:")
    for ic in result["interfaces"]:
        line(f"  ~ {ic['device']}: {ic['from']} → {ic['to']}")
    line("")

# Diagnostics highlights
diag_lines = []
for k, (av, bv) in result["diagnostics"].items():
    if av != bv:
        diag_lines.append(f"  {k}: {av} → {bv}")
if diag_lines:
    line(f"{b}Diagnostics changes{b}:")
    out.extend(diag_lines)
    line("")

# VPN tunnels
if result["vpn_tunnels"]:
    line(f"{b}VPN tunnels{b}:")
    for tc in result["vpn_tunnels"]:
        line(f"  ~ {tc['interface']}:  {tc['from']}  →  {tc['to']}")
    line("")

# Listening ports
lp = result["listening_ports"]
if lp["added"] or lp["removed"]:
    line(f"{b}Listening ports{b}:")
    for p in lp["added"]:   line(f"  + {p}")
    for p in lp["removed"]: line(f"  - {p}")
    line("")

print("\n".join(out))
PY
