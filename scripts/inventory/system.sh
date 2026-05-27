#!/usr/bin/env bash
# Local system + tool inventory (no secrets).
#
# Reports:
#   - OS, arch, model
#   - CPU, RAM
#   - Hostname (machine name only — not ID)
#   - Network interfaces summary
#   - Versions of common dev/network tools
#
# Usage: system.sh [--json|--md|--text]

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
    --yes) export NETKIT_YES=1; shift ;;
    --allow-raw) export NETKIT_ALLOW_RAW=1; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

export NETKIT_FMT="$FORMAT"

python3 - <<'PY'
import json, os, platform, shutil, subprocess

def sh(cmd, default=""):
    try:
        return subprocess.check_output(cmd, shell=True, text=True,
                                       stderr=subprocess.DEVNULL).strip()
    except subprocess.CalledProcessError:
        return default

def cmd_version(cmd):
    if not shutil.which(cmd):
        return None
    # BSD tools have no --version; try a few flags.
    for flag in ("--version", "-V", "-v"):
        out = sh(f"{cmd} {flag} 2>&1")
        if out and "illegal option" not in out and "unrecognized" not in out and "Invalid option" not in out:
            return out.splitlines()[0].strip()
    return "(installed)"

tools = [
    "brew", "git", "python3", "node", "npm",
    "go", "rustc", "cargo",
    "nmap", "arp-scan", "iperf3", "mtr", "tcpdump", "tshark", "wireshark",
    "jq", "yq", "docker", "podman", "colima",
    "tailscale", "wg", "kubectl",
    "dig", "drill", "nslookup", "curl", "ssh",
    "uv", "pipx", "claude",
]

inv = {
    "os": {
        "system": platform.system(),
        "release": platform.release(),
        "version": platform.version(),
        "machine": platform.machine(),
        "product_name": sh("sw_vers -productName"),
        "product_version": sh("sw_vers -productVersion"),
        "build_version": sh("sw_vers -buildVersion"),
    },
    "hardware": {
        "model": sh("sysctl -n hw.model"),
        "cpu_brand": sh("sysctl -n machdep.cpu.brand_string"),
        "cpu_cores": int(sh("sysctl -n hw.ncpu") or 0),
        "memory_gb": round(int(sh("sysctl -n hw.memsize") or 0) / (1024**3), 1),
    },
    "host": {
        "name": platform.node(),
        "user_shell": os.environ.get("SHELL", ""),
    },
    "tools": {t: cmd_version(t) for t in tools},
}

if shutil.which("brew"):
    relevant = ["nmap","arp-scan","iperf3","mtr","jq","yq","graphviz","tshark","tailscale"]
    out = sh("brew list --formula --versions")
    versions = {}
    for line in out.splitlines():
        parts = line.split()
        if parts and parts[0] in relevant:
            versions[parts[0]] = parts[1] if len(parts) > 1 else "installed"
    inv["brew_relevant"] = versions
else:
    inv["brew_relevant"] = {}

fmt = os.environ["NETKIT_FMT"]
bt = "`"
if fmt == "json":
    print(json.dumps(inv, indent=2))
elif fmt == "md":
    print("# System inventory\n")
    print(f"## OS\n- {inv['os']['product_name']} {inv['os']['product_version']} (build {inv['os']['build_version']})")
    print(f"- kernel: {inv['os']['system']} {inv['os']['release']} on {inv['os']['machine']}\n")
    print(f"## Hardware\n- model: {inv['hardware']['model']}\n- cpu: {inv['hardware']['cpu_brand']} ({inv['hardware']['cpu_cores']} cores)\n- memory: {inv['hardware']['memory_gb']} GB\n")
    print("## Tools\n")
    print("| tool | version |")
    print("| --- | --- |")
    for k, v in inv["tools"].items():
        v_disp = v if v else "_not installed_"
        print(f"| {bt}{k}{bt} | {v_disp} |")
    if inv["brew_relevant"]:
        print("\n## Relevant Homebrew packages\n")
        for k, v in inv["brew_relevant"].items():
            print(f"- {k}: {v}")
else:
    o = inv["os"]; h = inv["hardware"]
    print(f"OS       : {o['product_name']} {o['product_version']} ({o['build_version']})")
    print(f"Kernel   : {o['system']} {o['release']}  arch={o['machine']}")
    print(f"Model    : {h['model']}")
    print(f"CPU      : {h['cpu_brand']} ({h['cpu_cores']} cores)")
    print(f"Memory   : {h['memory_gb']} GB")
    print(f"Hostname : {inv['host']['name']}")
    print(f"Shell    : {inv['host']['user_shell']}")
    print()
    print("Tools:")
    for k, v in inv["tools"].items():
        if v is None:
            print(f"  {k:<14} (not installed)")
        else:
            print(f"  {k:<14} {v}")
PY
