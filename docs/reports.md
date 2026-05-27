# Report format

`./bin/netkit report` produces three artifacts in `output/`, all timestamped
`YYYYMMDD-HHMMSS`:

- `report-*.md` — human-readable Markdown summary.
- `report-*.json` — full machine-readable payload (the source of truth).
- `topology-*.mmd` — Mermaid `graph TD` you can paste into Obsidian or
  GitHub.

## JSON schema (informal)

```jsonc
{
  "meta": {
    "generated_at": "20260526-233611",
    "interface_hint": "en7",
    "active_probe": false,
    "include_traceroute": false
  },
  "inventory": {
    "os": { "product_name": "macOS", "product_version": "26.5", ... },
    "hardware": { "model": "MacBookAir10,1", "cpu_brand": "...", "memory_gb": 8.0, ... },
    "host": { "name": "Joels-MacBook-Air.local", ... },
    "tools": { "nmap": null, "jq": "jq-1.7.1-apple", ... },
    "brew_relevant": { ... }
  },
  "interfaces": {
    "default_interface": "en7",
    "default_gateway": "192.168.1.254",
    "interfaces": [
      { "device": "en7", "kind": "ethernet", "ipv4": "192.168.1.119",
        "netmask_cidr": "24", "status": "active", "media": "1000baseT",
        "hardware_port": "USB 10/100/1G/2.5G LAN", "is_default_route": true,
        "mac": "c8:4d:44:..." },
      ...
    ]
  },
  "dns": {
    "resolvers":   [ { "id": "resolver #1", "interface": "en7", "nameservers": [...], "search": [...] } ],
    "per_service": [ { "service": "Wi-Fi", "dns_servers": ["1.1.1.1", "1.0.0.1"] } ]
  },
  "hosts": {
    "interface": "en7", "subnet": "192.168.1.0/24", "count": 6,
    "hosts": [ { "ip": "192.168.1.254", "mac": "...", "vendor": "Unknown",
                 "name": "_gateway.lan", "source": "arp" }, ... ]
  },
  "quality": {
    "interface": "en7", "gateway": "192.168.1.254",
    "dns_domain": "github.com", "dns_query_ms": 4.0,
    "targets": [
      { "target": "192.168.1.254", "sent": 15, "received": 15,
        "loss_pct": 0.0, "rtt_min_ms": 0.9, "rtt_avg_ms": 1.04,
        "rtt_max_ms": 1.16, "rtt_stddev_ms": 0.10 },
      ...
    ]
  },
  "diagnostics": {
    "github_https":   { "ok": true, "http_code": "200", "time_s": 0.24 },
    "tls_github":     { "ok": true, "time_ms": 157.7, "issuer": "...", "not_after": "Aug  2 23:59:59 2026 GMT" },
    "dns_resolution": [ { "host": "github.com", "ips": ["..."], "time_ms": 15.2 } ],
    "ssh_targets":    [ { "host": "github.com", "port": 22, "ok": true, "banner": "SSH-2.0-...", "time_ms": 156.1 } ],
    "docker":         { "installed": true, "running": false },
    "podman":         { "installed": false, "running": false },
    "tailscale":      { "installed": false, "logged_in": false },
    "vpn_tunnels":    [ { "interface": "utun3", "inet": "192.168.1.119" } ],
    "listening_ports":[ { "proto": "tcp", "port": "8080", "command": "...", "pid": "...", "addr": "127.0.0.1:8080" } ]
  },
  "topology": { ... same as ./bin/netkit topology --json ... }
}
```

## Markdown sections

The Markdown report always contains these sections, in order:

1. **Executive summary** — one-liner per critical signal.
2. **System inventory** — OS / CPU / RAM.
3. **Interfaces** — table with kind, IPs, status, link speed, default route.
4. **DNS** — active resolvers.
5. **LAN hosts** — table with IP / MAC / vendor / name / source.
6. **Quality** — latency / jitter / loss table.
7. **Diagnostics (dev workflow)** — GitHub, TLS, Docker, Tailscale, VPN.
8. **Recommendations** — actionable items (e.g. high jitter, missing tools).
9. **Limitations** — what the report did not check and why.

## Consuming reports

### With jq

```fish
# Hosts with a known vendor
jq '.hosts.hosts[] | select(.vendor != "Unknown")' output/report-*.json

# Average gateway latency
jq '.quality.targets[0].rtt_avg_ms' output/report-*.json

# Tools missing locally
jq '.inventory.tools | to_entries | map(select(.value == null)) | .[].key' output/report-*.json
```

### With an LLM

See [`docs/workflows.md`](workflows.md). The JSON is the canonical input;
ask the model to explain the markdown when you want a narrative.
