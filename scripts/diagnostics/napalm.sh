#!/usr/bin/env bash
# napalm — OPTIONAL multi-vendor inventory of MANY managed devices at once.
#
# Reads configs/devices.toml entries that carry a `driver` field (ios / eos /
# junos / nxos / nxos_ssh / iosxr) and pulls normalized, read-only data from
# each in parallel: facts (model/serial/OS/uptime), interfaces, LLDP neighbors,
# ARP table. NAPALM gives one vendor-agnostic API across the fleet.
#
# This is the ONE part of netkit with a real dependency. The stdlib-only core
# never needs it; if NAPALM isn't installed this command explains how and exits
# cleanly. Install with:  pip install -r requirements/python-optional.txt
#
# Read-only by design — netkit only ever calls NAPALM getters, never config
# merges/commits. Credentials come from devices.toml (prefer `pass = env:VAR`).
#
# Output: JSON / md / text.
#
# Usage:
#   netkit napalm [--device NAME] [--getters facts,interfaces,lldp,arp]
#                 [--jobs N] [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
ONLY_DEVICE=""
GETTERS="facts,interfaces,lldp,arp"
JOBS=8

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --device)
      [[ -n "${2:-}" ]] || die_usage "--device requires a name"
      ONLY_DEVICE="$2"; shift 2 ;;
    --getters)
      [[ -n "${2:-}" ]] || die_usage "--getters requires a comma list"
      GETTERS="$2"; shift 2 ;;
    --jobs)
      [[ -n "${2:-}" ]] || die_usage "--jobs requires a number"
      JOBS="$2"; shift 2 ;;
    --yes) export NETKIT_YES=1; shift ;;
    --dry-run) export NETKIT_DRY_RUN=1; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) die_usage "Unknown flag: $1" ;;
  esac
done

[[ "$JOBS" =~ ^[0-9]+$ ]] && (( JOBS >= 1 && JOBS <= 32 )) \
  || die_usage "--jobs must be 1..32"
[[ "$GETTERS" =~ ^[a-z,]+$ ]] || die_usage "--getters must be comma-separated names"

guard_no_sudo

export NETKIT_ROOT NETKIT_FMT="$FORMAT" NETKIT_ONLY="$ONLY_DEVICE" \
       NETKIT_GETTERS="$GETTERS" NETKIT_JOBS="$JOBS" NETKIT_DRYRUN="$NETKIT_DRY_RUN"

python3 - <<'PY'
import concurrent.futures as cf
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, os.path.join(os.environ["NETKIT_ROOT"], "scripts/utils"))

FMT     = os.environ["NETKIT_FMT"]
ONLY    = os.environ.get("NETKIT_ONLY", "")
GETTERS = [g for g in os.environ["NETKIT_GETTERS"].split(",") if g]
JOBS    = int(os.environ["NETKIT_JOBS"])
DRYRUN  = os.environ.get("NETKIT_DRYRUN", "0") == "1"

try:
    import tomllib
except ImportError:
    print("[error] Python 3.11+ required (tomllib).", file=sys.stderr)
    sys.exit(1)

try:
    from devices import resolve_secret
except Exception:
    def resolve_secret(v):
        if isinstance(v, str) and v.startswith("env:"):
            return os.environ.get(v[4:], "")
        return v or ""


def load_managed() -> list[dict]:
    """devices.toml entries that declare a NAPALM `driver`."""
    path = Path(os.environ["NETKIT_ROOT"]) / "configs" / "devices.toml"
    if not path.is_file():
        return []
    try:
        with path.open("rb") as f:
            data = tomllib.load(f)
    except (OSError, ValueError):
        return []
    out = []
    for d in data.get("device", []):
        if not d.get("driver") or not d.get("host"):
            continue
        if ONLY and d.get("name") != ONLY and d.get("host") != ONLY:
            continue
        out.append({
            "name": d.get("name") or d["host"],
            "host": d["host"],
            "driver": d["driver"],
            "user": d.get("user", ""),
            "password": resolve_secret(d.get("pass")),
            "optional_args": dict(d.get("optional_args") or {}),
        })
    return out


devs = load_managed()

if not devs:
    print("[warn] No NAPALM-managed devices found in configs/devices.toml.",
          file=sys.stderr)
    print("       Add an entry with a `driver` field (see "
          "configs/devices.example.toml).", file=sys.stderr)
    # Empty but valid output so downstream tooling doesn't choke.
    if FMT == "json":
        print(json.dumps({"count": 0, "devices": []}, indent=2))
    sys.exit(0)

if DRYRUN:
    print("[dry-run] napalm would:", file=sys.stderr)
    print(f"[dry-run]   devices : {len(devs)}", file=sys.stderr)
    print(f"[dry-run]   getters : {', '.join(GETTERS)}", file=sys.stderr)
    print(f"[dry-run]   jobs    : {JOBS}", file=sys.stderr)
    for d in devs:
        print(f"[dry-run]   - {d['name']} ({d['host']}, driver={d['driver']})",
              file=sys.stderr)
    print("[dry-run] no connections opened.", file=sys.stderr)
    sys.exit(0)

try:
    from napalm import get_network_driver
except Exception:
    print("[warn] NAPALM is not installed — this is the one optional "
          "integration.", file=sys.stderr)
    print("       Install it with:  pip install -r "
          "requirements/python-optional.txt", file=sys.stderr)
    print("       The rest of netkit needs no extra packages.", file=sys.stderr)
    sys.exit(0)

GETTER_FN = {
    "facts": "get_facts",
    "interfaces": "get_interfaces",
    "lldp": "get_lldp_neighbors",
    "arp": "get_arp_table",
}


def collect(dev: dict) -> dict:
    res = {"name": dev["name"], "host": dev["host"], "driver": dev["driver"],
           "ok": False}
    try:
        Driver = get_network_driver(dev["driver"])
    except Exception as e:  # noqa: BLE001 — unknown driver name
        res["error"] = f"driver: {e}"
        return res
    conn = Driver(hostname=dev["host"], username=dev["user"],
                  password=dev["password"], optional_args=dev["optional_args"])
    try:
        conn.open()
    except Exception as e:  # noqa: BLE001 — auth / reachability
        res["error"] = f"open: {str(e)[:160]}"
        return res
    try:
        for g in GETTERS:
            fn = GETTER_FN.get(g)
            if not fn or not hasattr(conn, fn):
                continue
            try:
                res[g] = getattr(conn, fn)()
            except Exception as e:  # noqa: BLE001 — getter unsupported on platform
                res.setdefault("getter_errors", {})[g] = str(e)[:120]
        res["ok"] = True
    finally:
        try:
            conn.close()
        except Exception:
            pass
    return res


results = []
with cf.ThreadPoolExecutor(max_workers=min(JOBS, len(devs))) as ex:
    for r in ex.map(collect, devs):
        results.append(r)

payload = {"count": len(results),
           "ok": sum(1 for r in results if r.get("ok")),
           "devices": results}

if FMT == "json":
    print(json.dumps(payload, indent=2, default=str))
    sys.exit(0)


def _facts_line(r):
    f = r.get("facts") or {}
    return (f"{f.get('vendor','')} {f.get('model','')} "
            f"{f.get('os_version','')}".strip())


if FMT == "md":
    print(f"# napalm inventory — {payload['ok']}/{payload['count']} ok\n")
    print("| device | host | driver | model / os | interfaces | lldp peers |")
    print("| --- | --- | --- | --- | --- | --- |")
    for r in results:
        ifs = len(r.get("interfaces") or {})
        lldp = sum(len(v) for v in (r.get("lldp") or {}).values())
        cells = [r["name"], r["host"], r["driver"], _facts_line(r), ifs, lldp]
        if not r.get("ok"):
            cells[3] = f"ERROR: {r.get('error','')}"
        print("| " + " | ".join(str(c).replace("|", r"\|") for c in cells) + " |")
    sys.exit(0)

# text
print(f"napalm inventory: {payload['ok']}/{payload['count']} ok\n")
for r in results:
    print(f"{r['name']} ({r['host']}, {r['driver']})")
    if not r.get("ok"):
        print(f"    ! {r.get('error','failed')}")
        print()
        continue
    facts = _facts_line(r)
    if facts:
        print(f"    facts     : {facts}")
    if r.get("interfaces"):
        up = sum(1 for v in r["interfaces"].values() if v.get("is_up"))
        print(f"    interfaces: {len(r['interfaces'])} ({up} up)")
    if r.get("lldp"):
        peers = sum(len(v) for v in r["lldp"].values())
        print(f"    lldp peers: {peers}")
    if r.get("arp"):
        print(f"    arp       : {len(r['arp'])} entries")
    if r.get("getter_errors"):
        for g, e in r["getter_errors"].items():
            print(f"    ! {g}: {e}")
    print()
PY
