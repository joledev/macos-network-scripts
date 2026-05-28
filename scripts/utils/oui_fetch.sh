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
MANUF_FILE="${CACHE_DIR}/manuf"
mkdir -p "$CACHE_DIR"

# Refresh if missing, older than 30 days, or --force. Only skip when BOTH the
# IEEE OUI and the Wireshark manuf caches are already present and fresh.
if [[ -f "$OUI_FILE" ]] && [[ -f "$MANUF_FILE" ]] && (( ! FORCE )); then
  age_days=$(( ( $(date +%s) - $(stat -f %m "$OUI_FILE") ) / 86400 ))
  if (( age_days < 30 )); then
    log_ok "OUI + manuf caches fresh (${age_days}d old) in ${CACHE_DIR}. Use --force to refresh."
    exit 0
  fi
  log_info "Caches are ${age_days}d old; refreshing."
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

# Also fetch Wireshark's `manuf` — richer than IEEE alone: it carries the
# 28-bit (MA-M) and 36-bit (MA-S) sub-blocks plus per-device names that a
# bare 24-bit OUI list misses. oui.py prefers it when present. Best effort:
# a failure here must not fail the IEEE fetch above.
MANUF_URL="https://www.wireshark.org/download/automated/data/manuf"
log_info "Downloading Wireshark manuf (richer MAC DB) from ${MANUF_URL}..."
if curl -fsSL --max-time 60 "$MANUF_URL" -o "${MANUF_FILE}.tmp"; then
  mv "${MANUF_FILE}.tmp" "$MANUF_FILE"
  log_ok "manuf cache → ${MANUF_FILE} ($(grep -cv '^#' "$MANUF_FILE" 2>/dev/null || echo '?') prefixes)"
else
  rm -f "${MANUF_FILE}.tmp"
  log_warn "manuf download failed; continuing with IEEE OUI + built-in table only."
fi
