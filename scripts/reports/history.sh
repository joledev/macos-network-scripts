#!/usr/bin/env bash
# List past reports stored under $NETKIT_OUTPUT_DIR with a one-line summary
# each (timestamp, hosts, gateway RTT, partial flag, error count).
#
# Usage:
#   history.sh [--all] [--limit N] [--json|--text]
#
# Default: text format, newest first, capped at 10 entries.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
LIMIT=10
SHOW_ALL=0

die_usage() { log_err "$*"; exit 2; }

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --text) FORMAT="text"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --limit)
      [[ -n "${2:-}" ]] || die_usage "--limit requires a positive integer"
      LIMIT="$2"; shift 2 ;;
    --all) SHOW_ALL=1; shift ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die_usage "Unknown flag: $1" ;;
  esac
done

# Validate --limit. Reject non-integers, zero and negative values up front.
[[ "$LIMIT" =~ ^[0-9]+$ ]] || die_usage "--limit must be a positive integer (got: ${LIMIT})"
(( LIMIT > 0 )) || die_usage "--limit must be > 0 (got: ${LIMIT})"

ensure_output_dir
export NETKIT_FMT="$FORMAT" NETKIT_LIMIT="$LIMIT" NETKIT_SHOW_ALL="$SHOW_ALL"

python3 - <<'PY'
import json, os, sys
from pathlib import Path

out_dir = Path(os.environ["NETKIT_OUTPUT_DIR"])
fmt     = os.environ["NETKIT_FMT"]
limit   = int(os.environ["NETKIT_LIMIT"])
show_all = os.environ["NETKIT_SHOW_ALL"] == "1"

files = sorted(out_dir.glob("report-*.json"), reverse=True)
if not show_all:
    files = files[:limit]

rows = []
for p in files:
    try:
        d = json.load(open(p))
    except Exception as e:
        rows.append({"file": p.name, "error": f"parse: {e}"})
        continue
    meta = d.get("meta", {})
    q = d.get("quality", {})
    h = d.get("hosts", {})
    diag = d.get("diagnostics", {})
    targets = q.get("targets", []) or []
    gw = targets[0] if targets else {}
    inet = next((t for t in targets[1:] if t.get("target")), {})
    rows.append({
        "file": p.name,
        "timestamp":     meta.get("generated_at", ""),
        "schema":        meta.get("schema_version", ""),
        "partial":       bool(meta.get("partial", False)),
        "active":        bool(meta.get("active_probe", False)),
        "errors":        len(meta.get("module_errors", []) or []),
        "hosts":         h.get("count", 0),
        "gateway_rtt":   gw.get("rtt_avg_ms"),
        "gateway_loss":  gw.get("loss_pct"),
        "inet_target":   inet.get("target", ""),
        "inet_rtt":      inet.get("rtt_avg_ms"),
        "inet_loss":     inet.get("loss_pct"),
        "github_ok":     bool(diag.get("github_https", {}).get("ok", False)),
        "ipv6_ok":       bool(diag.get("ipv6", {}).get("ping6_ok", False)),
    })

if fmt == "json":
    print(json.dumps({"count": len(rows), "reports": rows}, indent=2))

elif fmt == "md":
    print(f"# Report history ({len(rows)})\n")
    if not rows:
        print("_no reports under output/_"); sys.exit(0)
    cols = ["timestamp", "hosts", "gw RTT ms", "inet RTT ms", "github", "ipv6", "partial", "errors"]
    print("| " + " | ".join(cols) + " |")
    print("| " + " | ".join("---" for _ in cols) + " |")
    for r in rows:
        gw = f"{r['gateway_rtt']:.2f}" if r.get("gateway_rtt") is not None else "-"
        inet = f"{r['inet_rtt']:.2f}" if r.get("inet_rtt") is not None else "-"
        print(f"| {r['timestamp']} | {r['hosts']} | {gw} | {inet} | "
              f"{'OK' if r['github_ok'] else 'FAIL'} | "
              f"{'OK' if r['ipv6_ok'] else '-'} | "
              f"{'YES' if r['partial'] else ''} | {r['errors']} |")

else:  # text
    if not rows:
        print("(no reports under output/)"); sys.exit(0)
    print(f"netkit history — {len(rows)} report(s) {'(all)' if show_all else f'(last {limit})'}\n")
    fmt = "{:<17} {:>5} {:>9} {:>9} {:>5} {:>4} {:<10} {:>3}"
    print(fmt.format("timestamp", "hosts", "gw_ms", "inet_ms", "gh", "v6", "flags", "err"))
    print("-" * 75)
    for r in rows:
        gw   = f"{r['gateway_rtt']:.2f}" if r.get("gateway_rtt") is not None else "-"
        inet = f"{r['inet_rtt']:.2f}"    if r.get("inet_rtt")    is not None else "-"
        flags = []
        if r["partial"]:     flags.append("PART")
        if not r["active"]:  flags.append("pasv")
        flag_str = ",".join(flags) or "ok"
        print(fmt.format(
            r["timestamp"], r["hosts"], gw, inet,
            "OK" if r["github_ok"] else "FAIL",
            "OK" if r["ipv6_ok"] else "-",
            flag_str, r["errors"],
        ))
PY
