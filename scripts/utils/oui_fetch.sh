#!/usr/bin/env bash
# Fetch the IEEE OUI registry into ~/.cache/netkit/oui.txt.
# oui.py auto-loads that file for vendor lookups, replacing the small
# built-in table.
#
# Usage: oui_fetch.sh [--force]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/netkit"
OUI_FILE="${CACHE_DIR}/oui.txt"
mkdir -p "$CACHE_DIR"

# Refresh if missing, older than 30 days, or --force
if [[ -f "$OUI_FILE" ]] && (( ! FORCE )); then
  age_days=$(( ( $(date +%s) - $(stat -f %m "$OUI_FILE") ) / 86400 ))
  if (( age_days < 30 )); then
    log_ok "OUI cache fresh (${age_days}d old) at ${OUI_FILE}. Use --force to refresh."
    exit 0
  fi
  log_info "OUI cache is ${age_days}d old; refreshing."
fi

URL="https://standards-oui.ieee.org/oui/oui.txt"
require_cmd curl
log_info "Downloading IEEE OUI registry from ${URL} (this is ~4 MB)..."
TMP="$(mktemp -t netkit-oui.XXXXXX)"
trap 'rm -f "$TMP"' EXIT
curl -fsSL --max-time 60 "$URL" -o "$TMP"

# Reformat to "<6-hex-no-sep>\t<vendor>"
python3 - "$TMP" "$OUI_FILE" <<'PY'
import sys, re
src, dst = sys.argv[1], sys.argv[2]
rows = []
with open(src, encoding="utf-8", errors="ignore") as f:
    for line in f:
        # Format example:
        #   00-50-56   (hex)        VMware, Inc.
        m = re.match(r"^([0-9A-Fa-f]{2}-[0-9A-Fa-f]{2}-[0-9A-Fa-f]{2})\s+\(hex\)\s+(.+)$", line.strip())
        if not m: continue
        prefix = m.group(1).replace("-", "").upper()
        vendor = m.group(2).strip()
        rows.append(f"{prefix}\t{vendor}")
with open(dst, "w", encoding="utf-8") as f:
    f.write("\n".join(rows) + "\n")
print(f"  wrote {len(rows)} prefixes")
PY

log_ok "OUI cache → ${OUI_FILE}"
