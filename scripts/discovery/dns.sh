#!/usr/bin/env bash
# Discover DNS configuration: configured resolvers, search domains and per-interface DNS.
#
# Usage: dns.sh [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
case "${1:-}" in
  --json) FORMAT="json" ;;
  --md)   FORMAT="md" ;;
  --text|"") FORMAT="text" ;;
  *) die "Unknown flag: $1" ;;
esac

python3 - <<PY
import json, subprocess, sys

def sh(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        return ""

# scutil --dns is the source of truth on macOS
scutil = sh("scutil --dns")
resolvers = []
current = None
for line in scutil.splitlines():
    s = line.strip()
    if s.startswith("resolver #"):
        if current: resolvers.append(current)
        current = {"id": s, "nameservers": [], "search": [], "domain": "", "interface": ""}
    elif current is not None:
        if s.startswith("nameserver["):
            current["nameservers"].append(s.split(":",1)[1].strip())
        elif s.startswith("search domain"):
            current["search"].append(s.split(":",1)[1].strip())
        elif s.startswith("domain   :"):
            current["domain"] = s.split(":",1)[1].strip()
        elif s.startswith("if_index"):
            # if_index : 16 (en7)
            parts = s.split("(")
            if len(parts) > 1:
                current["interface"] = parts[1].rstrip(")")
if current: resolvers.append(current)

# Per-network-service DNS configuration
services = []
order = sh("networksetup -listnetworkserviceorder")
for line in order.splitlines():
    if line.startswith("("):
        # "(6) USB 10/100/1G/2.5G LAN" — number prefix
        try:
            rest = line.split(")", 1)[1].strip()
        except IndexError:
            continue
        if rest and not rest.startswith("Hardware"):
            services.append(rest)

per_service = []
for s in services:
    dns = sh(f"networksetup -getdnsservers \"{s}\"").strip()
    if dns.startswith("There aren't any"):
        dns_list = []
    else:
        dns_list = [d.strip() for d in dns.splitlines() if d.strip()]
    per_service.append({"service": s, "dns_servers": dns_list})

result = {"resolvers": resolvers, "per_service": per_service}

fmt = "${FORMAT}"
if fmt == "json":
    print(json.dumps(result, indent=2))
elif fmt == "md":
    print("# DNS configuration\n")
    print("## Per-resolver (active)\n")
    print("| resolver | interface | nameservers | search/domain |")
    print("| --- | --- | --- | --- |")
    for r in resolvers:
        sd = ", ".join(r["search"]) or r["domain"] or ""
        ns = ", ".join(r["nameservers"]) or ""
        print(f"| {r['id']} | {r['interface']} | {ns} | {sd} |")
    print("\n## Per network service (saved)\n")
    print("| service | DNS servers |")
    print("| --- | --- |")
    for s in per_service:
        print(f"| {s['service']} | {', '.join(s['dns_servers']) or '_inherited_'} |")
else:
    print("Resolvers (active):")
    for r in resolvers:
        print(f"  {r['id']} ({r['interface']}): {', '.join(r['nameservers'])}")
    print()
    print("Per network service (saved):")
    for s in per_service:
        dns = ", ".join(s["dns_servers"]) or "(inherited)"
        print(f"  {s['service']}: {dns}")
PY
