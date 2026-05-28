#!/usr/bin/env bash
# fleet — run one per-host audit across MANY nodes in parallel and aggregate.
#
# Instead of auditing routers/switches/servers one at a time, point fleet at an
# inventory (or an explicit list / a subnet) and it fans the chosen action out
# over a bounded worker pool, then merges every result into one report.
#
# Actions (each runs read-only, no sudo):
#   reach        ICMP latency + loss per host (built-in; no subcommand)
#   cert-check   TLS audit per host        (wraps `netkit cert-check`)
#   snmp         SNMP system/identity      (wraps `netkit snmp`)
#   fingerprint  Deep per-host probe       (wraps `netkit fingerprint`)
#
# Host sources (pick one; default --from-known):
#   --targets a,b,c     explicit IPs / hostnames
#   --from-known        IP keys in configs/known-hosts.toml
#   --from-devices      hosts in configs/devices.toml (your OWN gear)
#   --subnet CIDR       every host in the subnet (bounded by NETKIT_MAX_HOSTS)
#
# Common options:
#   --jobs N            parallel workers (default 8, max 32)
#   --port P            cert-check / snmp port
#   --community S       snmp community (default public)
#   --version 1|2c      snmp version (default 2c)
#   --json|--md|--text  output format (default text)
#
# fleet confirms ONCE, then passes --yes to children so you are not prompted
# per host. Honors --yes / NETKIT_YES=1 and --dry-run.
#
# Usage:
#   netkit fleet reach --from-known
#   netkit fleet cert-check --targets 192.168.1.1,192.168.1.69 --port 443
#   netkit fleet snmp --from-devices --community public --md

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
ACTION=""
SOURCE="known"
TARGETS_CSV=""
SUBNET=""
JOBS=8
PORT=""
COMMUNITY="public"
SNMP_VERSION="2c"
FORCE=0

# First positional (not starting with -) is the action.
if [[ $# -gt 0 && "$1" != -* ]]; then
  ACTION="$1"; shift
fi

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --targets)
      [[ -n "${2:-}" ]] || die_usage "--targets requires a comma-separated list"
      TARGETS_CSV="$2"; SOURCE="targets"; shift 2 ;;
    --from-known)   SOURCE="known"; shift ;;
    --from-devices) SOURCE="devices"; shift ;;
    --subnet)
      [[ -n "${2:-}" ]] || die_usage "--subnet requires a CIDR"
      SUBNET="$2"; SOURCE="subnet"; shift 2 ;;
    --jobs)
      [[ -n "${2:-}" ]] || die_usage "--jobs requires a number"
      JOBS="$2"; shift 2 ;;
    --port)
      [[ -n "${2:-}" ]] || die_usage "--port requires a number"
      PORT="$2"; shift 2 ;;
    --community)
      [[ -n "${2:-}" ]] || die_usage "--community requires a value"
      COMMUNITY="$2"; shift 2 ;;
    --version)
      [[ -n "${2:-}" ]] || die_usage "--version requires 1|2c"
      SNMP_VERSION="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --yes) export NETKIT_YES=1; shift ;;
    --allow-raw) export NETKIT_ALLOW_RAW=1; shift ;;
    --dry-run) export NETKIT_DRY_RUN=1; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) die_usage "Unknown flag: $1" ;;
  esac
done

case "$ACTION" in
  reach|cert-check|snmp|fingerprint) ;;
  "") die_usage "Missing action. One of: reach, cert-check, snmp, fingerprint." ;;
  *)  die_usage "Unknown action '$ACTION'. One of: reach, cert-check, snmp, fingerprint." ;;
esac

[[ "$JOBS" =~ ^[0-9]+$ ]] && (( JOBS >= 1 && JOBS <= 32 )) \
  || die_usage "--jobs must be 1..32"
if [[ -n "$PORT" ]]; then
  [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) \
    || die_usage "--port must be 1..65535"
fi
if [[ "$SOURCE" == "subnet" ]]; then
  guard_subnet_size "$SUBNET" "$FORCE"
fi

guard_no_sudo

export NETKIT_ROOT NETKIT_FMT="$FORMAT" NETKIT_ACTION="$ACTION" \
       NETKIT_SOURCE="$SOURCE" NETKIT_TARGETS="$TARGETS_CSV" NETKIT_SUBNET="$SUBNET" \
       NETKIT_JOBS="$JOBS" NETKIT_PORT="$PORT" NETKIT_COMMUNITY="$COMMUNITY" \
       NETKIT_SNMP_VERSION="$SNMP_VERSION" NETKIT_DRYRUN="$NETKIT_DRY_RUN"

# Build the host list first (so dry-run can show it and we can confirm a count).
HOSTS="$(python3 - <<'PY'
import ipaddress, os, sys
sys.path.insert(0, os.path.join(os.environ["NETKIT_ROOT"], "scripts/utils"))

src = os.environ["NETKIT_SOURCE"]
hosts: list[str] = []

if src == "targets":
    hosts = [h.strip() for h in os.environ["NETKIT_TARGETS"].split(",") if h.strip()]
elif src == "subnet":
    try:
        net = ipaddress.IPv4Network(os.environ["NETKIT_SUBNET"], strict=False)
        hosts = [str(h) for h in net.hosts()]
    except ValueError:
        hosts = []
elif src == "devices":
    try:
        import devices
        hosts = [d["host"] for d in devices.load() if d.get("host")]
    except Exception:
        hosts = []
else:  # known
    try:
        import known_hosts
        for k in known_hosts.all_known():
            # IP keys only (skip MAC-keyed entries — we can't address those).
            try:
                ipaddress.ip_address(k)
                hosts.append(k)
            except ValueError:
                continue
    except Exception:
        hosts = []

# De-dup, preserve order.
seen = set()
ordered = [h for h in hosts if not (h in seen or seen.add(h))]
print("\n".join(ordered))
PY
)"

HOST_COUNT=$(printf '%s\n' "$HOSTS" | grep -c . || true)

if (( HOST_COUNT == 0 )); then
  die "No hosts resolved for source '${SOURCE}'. Check your inventory or pass --targets."
fi

if dry_run; then
  log_dry "fleet would:"
  log_dry "  action  : ${ACTION}"
  log_dry "  source  : ${SOURCE} (${HOST_COUNT} hosts)"
  log_dry "  jobs    : ${JOBS} parallel workers"
  case "$ACTION" in
    reach)       log_dry "  per host: ping -c 2 (ICMP latency + loss)" ;;
    cert-check)  log_dry "  per host: netkit cert-check --host <h>${PORT:+ --port $PORT} --json --yes" ;;
    snmp)        log_dry "  per host: netkit snmp --host <h> --community *** --version ${SNMP_VERSION} --json --yes" ;;
    fingerprint) log_dry "  per host: netkit fingerprint --hosts <h> --json --yes" ;;
  esac
  printf '%s\n' "$HOSTS" | sed 's/^/  - /' >&2
  log_dry "no probes sent."
  exit 0
fi

if ! confirm "Run '${ACTION}' across ${HOST_COUNT} host(s) with ${JOBS} workers. Proceed?"; then
  die "fleet declined."
fi

log_info "fleet ${ACTION} → ${HOST_COUNT} host(s), ${JOBS} workers"

export NETKIT_HOSTS="$HOSTS"

python3 - <<'PY'
import concurrent.futures as cf
import json
import os
import re
import subprocess
import sys

ROOT   = os.environ["NETKIT_ROOT"]
NETKIT = os.path.join(ROOT, "bin", "netkit")
FMT    = os.environ["NETKIT_FMT"]
ACTION = os.environ["NETKIT_ACTION"]
JOBS   = int(os.environ["NETKIT_JOBS"])
PORT   = os.environ.get("NETKIT_PORT", "")
COMM   = os.environ.get("NETKIT_COMMUNITY", "public")
SVER   = os.environ.get("NETKIT_SNMP_VERSION", "2c")
hosts  = [h for h in os.environ["NETKIT_HOSTS"].splitlines() if h.strip()]


def reach(host: str) -> dict:
    try:
        p = subprocess.run(["ping", "-c", "2", "-W", "800", "-q", host],
                            capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return {"host": host, "ok": False, "alive": False}
    out = p.stdout
    rtt = re.search(r"=\s*[\d.]+/([\d.]+)/", out)
    loss = re.search(r"([\d.]+)%\s*packet loss", out)
    return {
        "host": host,
        "ok": p.returncode == 0,
        "alive": p.returncode == 0,
        "rtt_ms": float(rtt.group(1)) if rtt else None,
        "loss_pct": float(loss.group(1)) if loss else None,
    }


def _run_json(cmd: list[str]) -> tuple[dict, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    except (OSError, subprocess.TimeoutExpired) as e:
        return {}, str(e)[:120]
    if not p.stdout.strip():
        return {}, (p.stderr.strip().splitlines() or [""])[-1][:120]
    try:
        return json.loads(p.stdout), ""
    except json.JSONDecodeError:
        return {}, "non-JSON output"


def cert_check(host: str) -> dict:
    cmd = [NETKIT, "cert-check", "--host", host, "--json", "--yes"]
    if PORT:
        cmd += ["--port", PORT]
    data, err = _run_json(cmd)
    if not data:
        return {"host": host, "ok": False, "error": err}
    leaf = data.get("leaf") or data.get("leaf_unverified") or {}
    return {
        "host": host,
        "ok": True,
        "handshake_ok": data.get("handshake_ok"),
        "protocol": data.get("negotiated_protocol"),
        "subject": leaf.get("subject", ""),
        "days_left": leaf.get("days_left"),
        "findings": data.get("assessments", []),
    }


def snmp(host: str) -> dict:
    cmd = [NETKIT, "snmp", "--host", host, "--community", COMM,
           "--version", SVER, "--json", "--yes"]
    if PORT:
        cmd += ["--port", PORT]
    data, err = _run_json(cmd)
    if not data:
        return {"host": host, "ok": False, "error": err}
    syst = data.get("system", {})
    return {
        "host": host,
        "ok": bool(data.get("reachable")),
        "sys_name": syst.get("sysName", ""),
        "identified_as": syst.get("identified_as", ""),
        "descr": (syst.get("sysDescr", "") or "")[:80],
        "interfaces": len(data.get("interfaces", [])),
    }


def fingerprint(host: str) -> dict:
    cmd = [NETKIT, "fingerprint", "--hosts", host, "--json", "--yes"]
    data, err = _run_json(cmd)
    if not data:
        return {"host": host, "ok": False, "error": err}
    rows = data.get("hosts", [])
    rec = rows[0] if rows else {}
    recog = rec.get("recog") or {}
    rid = " ".join(x for x in (recog.get("vendor"), recog.get("product"),
                               recog.get("version")) if x)
    return {
        "host": host,
        "ok": True,
        "role": rec.get("role", ""),
        "vendor": rec.get("vendor", ""),
        "ports": len(rec.get("ports", [])),
        "identified_as": rid,
    }


FN = {"reach": reach, "cert-check": cert_check, "snmp": snmp,
      "fingerprint": fingerprint}[ACTION]

results: list[dict] = []
with cf.ThreadPoolExecutor(max_workers=JOBS) as ex:
    for r in ex.map(FN, hosts):
        results.append(r)

# Stable order by host (numeric where possible).
def _key(r):
    parts = r["host"].split(".")
    if len(parts) == 4 and all(p.isdigit() for p in parts):
        return (0, tuple(int(p) for p in parts), "")
    return (1, (), r["host"])
results.sort(key=_key)

payload = {"action": ACTION, "count": len(results),
           "ok": sum(1 for r in results if r.get("ok")), "results": results}

if FMT == "json":
    print(json.dumps(payload, indent=2, default=str))
    sys.exit(0)


def _cols(action):
    return {
        "reach":       ["host", "alive", "rtt_ms", "loss_pct"],
        "cert-check":  ["host", "handshake_ok", "protocol", "days_left", "subject"],
        "snmp":        ["host", "ok", "sys_name", "identified_as", "interfaces"],
        "fingerprint": ["host", "role", "vendor", "ports", "identified_as"],
    }[action]


cols = _cols(ACTION)
if FMT == "md":
    print(f"# fleet {ACTION} — {payload['ok']}/{payload['count']} ok\n")
    print("| " + " | ".join(cols) + " |")
    print("| " + " | ".join("---" for _ in cols) + " |")
    for r in results:
        print("| " + " | ".join(str(r.get(c, "")).replace("|", r"\|") for c in cols) + " |")
        if r.get("error"):
            print(f"| {r['host']} | error: {r['error']} | | | |")
    sys.exit(0)

# text
print(f"fleet {ACTION}: {payload['ok']}/{payload['count']} ok\n")
widths = {"host": 18}
header = "  ".join(f"{c:<{widths.get(c, 14)}}" for c in cols)
print(header)
print("-" * len(header))
for r in results:
    line = "  ".join(f"{str(r.get(c, '') if r.get(c) is not None else ''):<{widths.get(c, 14)}}" for c in cols)
    print(line)
    if r.get("error"):
        print(f"    ! {r['error']}")
    if ACTION == "cert-check" and r.get("findings"):
        for f in r["findings"]:
            print(f"    * {f}")
PY
