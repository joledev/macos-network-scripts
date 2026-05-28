#!/usr/bin/env bash
# Export a recon inventory to NetBox — the source-of-truth IPAM/DCIM for the
# building. netkit collects; NetBox documents.
#
#   default / --csv : write NetBox bulk-import CSVs (ip-addresses + devices)
#                     to output/netbox-<ts>-{ips,devices}.csv
#   --push          : create-or-update IP addresses via the NetBox REST API
#                     (NETKIT_NETBOX_URL + NETKIT_NETBOX_TOKEN). Re-runs reconcile.
#
# Reads the latest output/recon-*.json by default, or --input <file>.
#
# Usage: netbox.sh [--input recon-*.json] [--csv|--push]
#   NETKIT_NETBOX_URL=https://netbox.local  NETKIT_NETBOX_TOKEN=<token>

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

MODE="csv"
INPUT=""

while (( $# )); do
  case "$1" in
    --csv)  MODE="csv"; shift ;;
    --push) MODE="push"; shift ;;
    --input)
      [[ -n "${2:-}" ]] || die_usage "--input requires a recon JSON path"
      INPUT="$2"; shift 2 ;;
    --yes) export NETKIT_YES=1; shift ;;
    --dry-run) export NETKIT_DRY_RUN=1; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) die_usage "Unknown flag: $1" ;;
  esac
done

guard_no_sudo
ensure_output_dir

# Resolve the recon JSON (latest by default).
if [[ -z "$INPUT" ]]; then
  INPUT="$(ls -t "${NETKIT_OUTPUT_DIR}"/recon-*.json 2>/dev/null | head -1 || true)"
fi
[[ -n "$INPUT" && -f "$INPUT" ]] || die "No recon JSON found. Run 'netkit recon' first or pass --input <file>."

if [[ "$MODE" == "push" ]]; then
  [[ -n "${NETKIT_NETBOX_URL:-}" && -n "${NETKIT_NETBOX_TOKEN:-}" ]] \
    || die "Set NETKIT_NETBOX_URL and NETKIT_NETBOX_TOKEN to push to NetBox."
fi

if dry_run; then
  log_dry "netbox would:"
  log_dry "  input : ${INPUT/#$NETKIT_ROOT\//}"
  if [[ "$MODE" == "csv" ]]; then
    log_dry "  write : output/netbox-<ts>-ips.csv + output/netbox-<ts>-devices.csv"
  else
    log_dry "  push  : create-or-update IP addresses → ${NETKIT_NETBOX_URL} (token hidden)"
  fi
  exit 0
fi

TS=$(timestamp)
export NETKIT_FMT_INPUT="$INPUT" NETKIT_MODE="$MODE" NETKIT_TS="$TS" NETKIT_ROOT \
       NETKIT_OUTPUT_DIR

python3 - <<'PY'
import json, os, sys

sys.path.insert(0, os.path.join(os.environ["NETKIT_ROOT"], "scripts/utils"))
import netbox_export as nb

report = json.load(open(os.environ["NETKIT_FMT_INPUT"]))
mode = os.environ["NETKIT_MODE"]
out_dir = os.environ["NETKIT_OUTPUT_DIR"]
ts = os.environ["NETKIT_TS"]

if mode == "csv":
    ips = os.path.join(out_dir, f"netbox-{ts}-ips.csv")
    devs = os.path.join(out_dir, f"netbox-{ts}-devices.csv")
    with open(ips, "w") as f:
        f.write(nb.ip_csv(report))
    with open(devs, "w") as f:
        f.write(nb.device_csv(report))
    print(f"IP addresses CSV : {ips}  ({len(nb.ip_rows(report))} rows)")
    print(f"Devices CSV      : {devs}  ({len(nb.device_rows(report))} rows)")
    print("\nImport in NetBox: Bulk Import → IPAM > IP Addresses (ips.csv).")
    print("Devices CSV references role/manufacturer/device_type/site by name —")
    print("create those first (or edit the CSV), then DCIM > Devices import.")
else:
    res = nb.push(report, os.environ["NETKIT_NETBOX_URL"], os.environ["NETKIT_NETBOX_TOKEN"])
    print(f"NetBox push: created={res['created']} updated={res['updated']} failed={res['failed']}")
    for e in res.get("errors", []):
        print(f"  error: {e}")
PY
