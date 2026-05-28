#!/usr/bin/env bash
# Fetch the Rapid7 Recog fingerprint DB (the subset netkit uses) into
# ~/.cache/netkit/recog/. recog.py auto-loads those XML files to turn HTTP
# Server headers, page titles, auth realms, SNMP sysDescr and SSH banners into
# vendor/product/version/device-type. Recog is BSD-2-Clause.
#
# Only five files are fetched (the signals we actually collect), so this is a
# small, fast download — not the whole Recog corpus.
#
# Usage: recog_fetch.sh [--force]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/netkit/recog"
mkdir -p "$CACHE_DIR"

FILES=(
  http_servers.xml
  html_title.xml
  http_wwwauth.xml
  snmp_sysdescr.xml
  ssh_banners.xml
)

# Refresh only if missing/stale/forced. Use the first file as the freshness mark.
MARK="${CACHE_DIR}/${FILES[0]}"
if [[ -f "$MARK" ]] && (( ! FORCE )); then
  age_days=$(( ( $(date +%s) - $(stat -f %m "$MARK") ) / 86400 ))
  if (( age_days < 30 )); then
    log_ok "Recog DB fresh (${age_days}d old) in ${CACHE_DIR}. Use --force to refresh."
    exit 0
  fi
  log_info "Recog DB is ${age_days}d old; refreshing."
fi

require_cmd curl

# The XML moved between repos/branches over time. Try each base in order and
# use the first that serves the file; bases are independent per file so a
# single reorg doesn't break the whole fetch.
BASES=(
  "https://raw.githubusercontent.com/rapid7/recog/main/xml"
  "https://raw.githubusercontent.com/rapid7/recog/master/xml"
  "https://raw.githubusercontent.com/rapid7/recog-content/main/xml"
)

ok=0
for f in "${FILES[@]}"; do
  fetched=0
  for base in "${BASES[@]}"; do
    if curl -fsSL --max-time 30 "${base}/${f}" -o "${CACHE_DIR}/${f}.tmp" 2>/dev/null; then
      # Sanity: must look like XML, not a 404 page.
      if head -c 64 "${CACHE_DIR}/${f}.tmp" | grep -q '<'; then
        mv "${CACHE_DIR}/${f}.tmp" "${CACHE_DIR}/${f}"
        fetched=1
        ok=$((ok + 1))
        break
      fi
    fi
    rm -f "${CACHE_DIR}/${f}.tmp"
  done
  if (( fetched )); then
    log_ok "  ${f}"
  else
    log_warn "  ${f} — not found at any known location; skipping."
  fi
done

if (( ok == 0 )); then
  die "Could not fetch any Recog file. Check connectivity or the repo layout."
fi
log_ok "Recog DB → ${CACHE_DIR} (${ok}/${#FILES[@]} files)"
