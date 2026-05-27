#!/usr/bin/env bash
# Diagnostics for a developer workflow:
#   - Connectivity to GitHub (HTTPS + SSH)
#   - DNS resolution sanity
#   - TLS handshake to github.com:443
#   - Docker / Podman daemon
#   - VPN: Tailscale / WireGuard (utun) presence
#   - Local listening ports
#
# Strictly read-only and safe.
#
# Usage: dev.sh [--ssh-targets host:port,...] [--json|--md|--text]

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
SSH_TARGETS="${NETKIT_SSH_TARGETS:-github.com:22}"

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md) FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --ssh-targets) SSH_TARGETS="$2"; shift 2 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

python3 - <<PY
import json, os, socket, ssl, subprocess, sys, time

def sh(cmd, timeout=5):
    try:
        r = subprocess.run(cmd, shell=True, text=True, timeout=timeout,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"

result = {}

# GitHub HTTPS
t0 = time.time()
rc, out, err = sh("curl -sS -o /dev/null -w '%{http_code}\\n%{time_total}\\n' https://api.github.com/", 10)
elapsed = time.time() - t0
lines = out.strip().splitlines()
result["github_https"] = {
    "ok": rc == 0,
    "http_code": lines[0] if lines else "",
    "time_s": float(lines[1]) if len(lines) > 1 else None,
    "error": err.strip() or None,
}

# DNS resolution
dns_targets = ["github.com", "${NETKIT_DNS_DOMAIN}", "cloudflare.com"]
dns_results = []
for d in dns_targets:
    try:
        t = time.time()
        socket.setdefaulttimeout(3.0)
        ips = socket.gethostbyname_ex(d)[2]
        dns_results.append({"host": d, "ips": ips, "time_ms": round((time.time()-t)*1000, 1)})
    except Exception as e:
        dns_results.append({"host": d, "error": str(e)})
result["dns_resolution"] = dns_results

# TLS handshake to github.com:443
try:
    ctx = ssl.create_default_context()
    t = time.time()
    with socket.create_connection(("github.com", 443), timeout=5) as s:
        with ctx.wrap_socket(s, server_hostname="github.com") as ss:
            cert = ss.getpeercert()
    result["tls_github"] = {
        "ok": True,
        "time_ms": round((time.time()-t)*1000, 1),
        "issuer": " / ".join("=".join(p) for x in cert.get("issuer", []) for p in x),
        "subject": " / ".join("=".join(p) for x in cert.get("subject", []) for p in x),
        "not_after": cert.get("notAfter"),
    }
except Exception as e:
    result["tls_github"] = {"ok": False, "error": str(e)}

# SSH (banner grab only) for each target
ssh_results = []
for tgt in [t.strip() for t in "${SSH_TARGETS}".split(",") if t.strip()]:
    if ":" in tgt:
        host, port = tgt.rsplit(":", 1); port = int(port)
    else:
        host, port = tgt, 22
    try:
        t = time.time()
        with socket.create_connection((host, port), timeout=4) as s:
            s.settimeout(2)
            banner = s.recv(256).decode(errors="replace").strip()
        ssh_results.append({"host": host, "port": port, "ok": True,
                            "banner": banner, "time_ms": round((time.time()-t)*1000,1)})
    except Exception as e:
        ssh_results.append({"host": host, "port": port, "ok": False, "error": str(e)})
result["ssh_targets"] = ssh_results

# Docker
rc, out, _ = sh("docker version --format json", 4)
if rc == 0 and out.strip():
    try:
        dv = json.loads(out)
        result["docker"] = {"installed": True, "running": True, "server": dv.get("Server",{}).get("Version")}
    except Exception:
        result["docker"] = {"installed": True, "running": True, "raw": out.strip()[:200]}
else:
    rc2, _, _ = sh("command -v docker")
    result["docker"] = {"installed": rc2 == 0, "running": False}

# Podman
rc, out, _ = sh("podman info --format json", 4)
if rc == 0 and out.strip():
    result["podman"] = {"installed": True, "running": True}
else:
    rc2, _, _ = sh("command -v podman")
    result["podman"] = {"installed": rc2 == 0, "running": False}

# Tailscale
rc, out, _ = sh("tailscale status --json", 4)
if rc == 0 and out.strip():
    try:
        ts = json.loads(out)
        result["tailscale"] = {"installed": True, "logged_in": bool(ts.get("Self",{}).get("Online")),
                               "self_ip": ts.get("Self",{}).get("TailscaleIPs",[None])[0]}
    except Exception:
        result["tailscale"] = {"installed": True, "raw_ok": True}
else:
    rc2, _, _ = sh("command -v tailscale")
    result["tailscale"] = {"installed": rc2 == 0, "logged_in": False}

# WireGuard / VPN tunnels (utun interfaces)
rc, out, _ = sh("ifconfig", 4)
utuns = []
current = None
for line in out.splitlines():
    if line.startswith("utun"):
        current = line.split(":")[0]
        utuns.append({"interface": current, "inet": None})
    elif current and "inet " in line and "127.0.0.1" not in line:
        parts = line.strip().split()
        if "inet" in parts:
            utuns[-1]["inet"] = parts[parts.index("inet")+1]
result["vpn_tunnels"] = utuns

# Listening ports (TCP/UDP). lsof is the cleanest on macOS.
ports = []
rc, out, _ = sh("lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null", 5)
if rc == 0:
    seen = set()
    for line in out.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 9: continue
        cmd = parts[0]; pid = parts[1]
        addr = parts[8]
        port = addr.rsplit(":",1)[-1] if ":" in addr else addr
        key = (cmd, port)
        if key in seen: continue
        seen.add(key)
        ports.append({"proto": "tcp", "port": port, "command": cmd, "pid": pid, "addr": addr})
result["listening_ports"] = ports[:80]

fmt = "${FORMAT}"
if fmt == "json":
    print(json.dumps(result, indent=2))
elif fmt == "md":
    print("# Developer connectivity diagnostics\n")
    g = result["github_https"]
    print(f"## GitHub HTTPS\n- ok: **{g['ok']}**, http: {g.get('http_code')}, time: {g.get('time_s')} s\n")
    tls = result["tls_github"]
    print(f"## TLS to github.com\n- ok: **{tls.get('ok')}** ({tls.get('time_ms')} ms)\n- issuer: {tls.get('issuer','')}\n- not_after: {tls.get('not_after','')}\n")
    print("## DNS\n")
    print("| host | ips | time ms |\n| --- | --- | --- |")
    for d in result["dns_resolution"]:
        if "ips" in d:
            print(f"| {d['host']} | {', '.join(d['ips'])} | {d['time_ms']} |")
        else:
            print(f"| {d['host']} | _error_ | {d.get('error','')} |")
    print("\n## SSH banners\n")
    for s in result["ssh_targets"]:
        if s["ok"]:
            print(f"- **{s['host']}:{s['port']}** ok, {s['time_ms']} ms — {s['banner']}")
        else:
            print(f"- **{s['host']}:{s['port']}** failed — {s.get('error')}")
    print(f"\n## Docker\n- {result['docker']}\n")
    print(f"## Podman\n- {result['podman']}\n")
    print(f"## Tailscale\n- {result['tailscale']}\n")
    print(f"## VPN tunnels (utun)\n")
    for v in result["vpn_tunnels"]:
        print(f"- {v['interface']}: {v.get('inet','(no ip)')}")
    print(f"\n## Listening TCP ports (top {len(result['listening_ports'])})\n")
    print("| port | command | pid | addr |\n| --- | --- | --- | --- |")
    for p in result["listening_ports"]:
        print(f"| {p['port']} | {p['command']} | {p['pid']} | {p['addr']} |")
else:
    g = result["github_https"]
    print(f"GitHub HTTPS    : ok={g['ok']} http={g.get('http_code')} time={g.get('time_s')}s")
    tls = result["tls_github"]
    print(f"TLS github.com  : ok={tls.get('ok')} ({tls.get('time_ms')} ms) cert until {tls.get('not_after','?')}")
    print("DNS resolution  :")
    for d in result["dns_resolution"]:
        if "ips" in d:
            print(f"  {d['host']:<20} -> {', '.join(d['ips'])} ({d['time_ms']} ms)")
        else:
            print(f"  {d['host']:<20} -> ERROR {d.get('error')}")
    print("SSH banners     :")
    for s in result["ssh_targets"]:
        if s["ok"]:
            print(f"  {s['host']}:{s['port']:<5} {s['time_ms']} ms  {s['banner'][:50]}")
        else:
            print(f"  {s['host']}:{s['port']:<5} FAILED  {s.get('error')}")
    print(f"Docker          : {result['docker']}")
    print(f"Podman          : {result['podman']}")
    print(f"Tailscale       : {result['tailscale']}")
    print(f"VPN tunnels     : {[v['interface']+'='+(v.get('inet') or '-') for v in result['vpn_tunnels']]}")
    print(f"Listening ports : {len(result['listening_ports'])} TCP")
PY
