#!/usr/bin/env bash
# devices — print the persistent device ledger: the union of every host seen
# across all recon runs, with first/last-seen and the IPs/names/bands observed.
#
# recon updates this ledger on every run (~/.cache/netkit/inventory.json), so
# this shows the whole environment over time — including devices that were
# present in an earlier scan but absent now.
#
# Output: JSON / md / text.
#
# Usage: devices.sh [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) die_usage "Unknown flag: $1" ;;
  esac
done

export NETKIT_FMT="$FORMAT" NETKIT_ROOT
python3 - <<'PY'
import json, os, sys

sys.path.insert(0, os.path.join(os.environ["NETKIT_ROOT"], "scripts/utils"))
import inventory_db

fmt = os.environ["NETKIT_FMT"]
ledger = inventory_db.load()
rows = sorted(ledger.values(), key=lambda e: (e.get("last_seen", ""), e.get("mac", "")),
              reverse=True)

if fmt == "json":
    print(json.dumps({"count": len(rows), "path": str(inventory_db.path()),
                      "devices": rows}, indent=2))
    sys.exit(0)

if not rows:
    msg = "No ledger yet — run `netkit recon` at least once to populate it."
    print(msg if fmt == "text" else f"_{msg}_")
    sys.exit(0)

if fmt == "md":
    print(f"# Device ledger ({len(rows)} ever seen)\n")
    print("| name | ip(s) | mac | vendor | role | band | seen | first | last |")
    print("| --- | --- | --- | --- | --- | --- | ---: | --- | --- |")
    for e in rows:
        print(f"| {(e.get('names') or [''])[0]} | {', '.join(e.get('ips', []))} | "
              f"{e.get('mac','')} | {e.get('vendor','')} | {e.get('role','')} | "
              f"{', '.join(e.get('bands', []))} | {e.get('seen_count',0)} | "
              f"{e.get('first_seen','')} | {e.get('last_seen','')} |")
    sys.exit(0)

print(f"Device ledger — {len(rows)} device(s) ever seen   ({inventory_db.path()})\n")
print(f"{'name':<22}{'ip':<16}{'vendor':<18}{'band':<10}{'seen':<6}last")
print("-" * 92)
for e in rows:
    print(f"{((e.get('names') or [''])[0])[:21]:<22}{((e.get('ips') or [''])[0]):<16}"
          f"{(e.get('vendor','') or '')[:17]:<18}{(', '.join(e.get('bands', [])))[:9]:<10}"
          f"{str(e.get('seen_count',0)):<6}{e.get('last_seen','')}")
PY
