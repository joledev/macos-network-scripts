#!/usr/bin/env bash
# Authenticated device identify — log into YOUR OWN devices (from a gitignored
# configs/devices.toml) over HTTP or SSH and pull model / firmware / neighbors.
# This is how you positively identify gear that hides its model behind a login
# (e.g. TP-Link panels that only show a generic cert), and do light read-only
# administration of your own routers/switches/APs.
#
# Scope: operates ONLY on devices you list in devices.toml with your own
# credentials. It does not scan for or guess credentials, and is not for
# devices you don't own.
#
#   type=http : curl Basic-auth GET of the panel (+ optional form login),
#               extract Server / <title> / model strings.
#   type=ssh  : ssh (key auth by default; sshpass if installed + password set)
#               runs a curated read-only command set (uname/model/neighbors).
#
# Output: JSON / md / text. Passwords are never printed.
#
# Usage: devinfo.sh [--host 192.168.1.42] [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
ONLY_HOST=""

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --host)
      [[ -n "${2:-}" ]] || die_usage "--host requires an IP/hostname"
      ONLY_HOST="$2"; shift 2 ;;
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

CFG="${NETKIT_ROOT}/configs/devices.toml"
if [[ ! -f "$CFG" ]]; then
  log_err "No configs/devices.toml found."
  log_info "Create it from the template: cp configs/devices.example.toml configs/devices.toml"
  log_info "List ONLY your own devices (host/type/user/pass). The file is gitignored."
  exit 2
fi

if dry_run; then
  log_dry "devinfo would, for each device in configs/devices.toml${ONLY_HOST:+ (host=$ONLY_HOST)}:"
  log_dry "  http : curl -u <user>:*** <url>  → Server/title/model"
  log_dry "  ssh  : ssh <user>@<host> '<read-only cmds>' (keys, or sshpass if set)"
  log_dry "no requests sent. (credentials never printed)"
  exit 0
fi

export NETKIT_FMT="$FORMAT" NETKIT_ONLY_HOST="$ONLY_HOST" NETKIT_ROOT

python3 - <<'PY'
import json, os, re, subprocess, sys

sys.path.insert(0, os.path.join(os.environ["NETKIT_ROOT"], "scripts/utils"))
import devices as devmod

fmt = os.environ["NETKIT_FMT"]
only = os.environ.get("NETKIT_ONLY_HOST", "")

MODEL_PAT = re.compile(
    r"(TL-[A-Z0-9-]+|EAP[0-9]+[A-Z]*|Archer[ _A-Z0-9-]{0,16}|Deco[ _A-Z0-9-]{0,12}|"
    r"ER[0-9]{3,}|RT-[A-Z0-9-]+|UAP-[A-Z0-9-]+|MR[0-9]{2,}|WS-C[0-9A-Z-]+)", re.I)


def http_identify(dev: dict) -> dict:
    out = {}
    args = ["curl", "-sS", "-m", "6", "-k", "-i", dev["url"]]
    if dev.get("user"):
        args[2:2] = ["-u", f'{dev["user"]}:{dev["password"]}']
    try:
        r = subprocess.run(args, capture_output=True, timeout=8)
        text = r.stdout.decode(errors="replace")
    except (OSError, subprocess.TimeoutExpired):
        return {"error": "request failed"}
    text = devmod.redact(text, dev["password"])
    for ln in text.splitlines():
        ll = ln.lower()
        if ll.startswith("server:"):
            out["server"] = ln.split(":", 1)[1].strip()
        elif ll.startswith("http/"):
            out["status"] = ln.strip()
    m = re.search(r"<title>([^<]+)</title>", text, re.I)
    if m:
        out["title"] = m.group(1).strip()
    mm = MODEL_PAT.search(text)
    if mm:
        out["model"] = mm.group(1)
    return out


def ssh_identify(dev: dict) -> dict:
    cmd = " ; ".join(dev["commands"])
    base = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=accept-new",
            "-p", str(dev["port"]), f'{dev["user"]}@{dev["host"]}', cmd]
    argv = ["ssh", *base]
    # Use sshpass only if a password is set AND sshpass exists; else key auth.
    if dev.get("password") and _has("sshpass"):
        argv = ["sshpass", "-p", dev["password"], "ssh", *base]
    try:
        r = subprocess.run(argv, capture_output=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired):
        return {"error": "ssh failed"}
    out = devmod.redact(r.stdout.decode(errors="replace"), dev["password"]).strip()
    err = devmod.redact(r.stderr.decode(errors="replace"), dev["password"]).strip()
    res = {"rc": r.returncode}
    if out:
        res["output"] = out
        mm = MODEL_PAT.search(out)
        if mm:
            res["model"] = mm.group(1)
        m2 = re.search(r"^.*model.*$", out, re.I | re.M)
        if m2 and "model" not in res:
            res["model_line"] = m2.group(0).strip()[:80]
    if r.returncode != 0 and err:
        res["error"] = err.splitlines()[-1][:120]
    return res


def _has(cmd):
    from shutil import which
    return which(cmd) is not None


results = []
for dev in devmod.load():
    if only and dev["host"] != only and dev["name"] != only:
        continue
    rec = {"name": dev["name"], "host": dev["host"], "type": dev["type"]}
    if dev["type"] == "ssh":
        rec.update(ssh_identify(dev))
    else:
        rec.update(http_identify(dev))
    results.append(rec)

if not results:
    msg = "no matching device in configs/devices.toml" if only else "configs/devices.toml has no devices"
    if fmt == "json":
        print(json.dumps({"count": 0, "devices": [], "note": msg}))
    else:
        print(f"({msg})")
    sys.exit(0)

if fmt == "json":
    print(json.dumps({"count": len(results), "devices": results}, indent=2))
elif fmt == "md":
    print(f"# Device identify ({len(results)})\n")
    print("| Name | Host | Type | Model | Title / server | Status |")
    print("| --- | --- | --- | --- | --- | --- |")
    for r in results:
        ts = r.get("title") or r.get("server") or r.get("model_line") or ""
        print(f"| {r['name']} | {r['host']} | {r['type']} | {r.get('model','')} | "
              f"{ts} | {r.get('status') or r.get('error') or ('rc='+str(r.get('rc'))) or ''} |")
else:
    for r in results:
        print(f"{r['host']:<15} [{r['type']}] {r['name']}")
        for k in ("model", "title", "server", "model_line", "status"):
            if r.get(k):
                print(f"    {k:<8}: {r[k]}")
        if r.get("output"):
            for ln in r["output"].splitlines()[:12]:
                print(f"    | {ln}")
        if r.get("error"):
            print(f"    error   : {r['error']}")
        print()
PY
