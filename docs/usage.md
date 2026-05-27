# Usage

All commands run from the repo root:

```fish
cd /Users/joledev/Dev/macos-network-scripts
./bin/netkit <subcommand> [flags]
```

## Common flags

- `--interface en7` — force a specific interface (auto-detected by default).
- `--subnet 192.168.1.0/24` — force a target subnet.
- `--json` / `--md` / `--text` (default) — output format.
- `--mermaid` — Mermaid `graph TD` (topology only).
- `--active` — send light probes (ping sweep) to populate ARP.
- `--force` — bypass the `NETKIT_MAX_HOSTS` safety cap.

## Subcommands

### `doctor`

Verifies tools, permissions, the picked interface and the output directory.
Returns non-zero if a required tool is missing.

```fish
./bin/netkit doctor
```

### `interfaces`

Lists every macOS interface with its kind (ethernet/wifi/thunderbolt/virtual),
IP, CIDR, status, link speed and whether it is the default route.

```fish
./bin/netkit interfaces
./bin/netkit interfaces --json | jq '.interfaces[] | select(.kind=="ethernet")'
```

### `discover` (alias `hosts`)

Lists LAN hosts.

```fish
# Passive: ARP cache only — instant, no traffic generated.
./bin/netkit discover

# Active: ping sweep then re-read ARP. Bounded to your subnet.
./bin/netkit discover --active

# Add arp-scan (requires sudo + brew install arp-scan)
./bin/netkit discover --active --arpscan
```

Output columns: IP, MAC, vendor (from offline OUI table), reverse-DNS name,
source (`arp` or `arp-scan`).

### `dns`

Shows both the active resolver chain (`scutil --dns`) and the saved per-service
DNS settings (`networksetup -getdnsservers`).

### `topology` (alias `topo`, `map`)

Combines interfaces + hosts + (optional) traceroute. Default output is text;
add `--mermaid` for an Obsidian-friendly graph.

```fish
./bin/netkit topology
./bin/netkit topology --mermaid > topo.mmd
./bin/netkit topology --traceroute --target 1.1.1.1
```

### `quality` (alias `ping`)

Pings gateway + configured targets, computes min/avg/max/jitter and packet
loss. Also runs one `dig` for DNS timing.

```fish
./bin/netkit quality
./bin/netkit quality --count 60 --targets 1.1.1.1,github.com
./bin/netkit quality --md > quality.md
```

### `diagnose` (alias `diag`, `dev`)

Read-only sanity check for a developer workflow:

- GitHub HTTPS round-trip + status code
- TLS handshake to github.com:443 (issuer, expiry)
- DNS resolution timing for github.com / cloudflare.com
- SSH banner for configured targets (default `github.com:22`)
- Docker / Podman daemon presence
- Tailscale state, WireGuard `utun` tunnels
- Local TCP listeners

```fish
./bin/netkit diagnose --ssh-targets github.com:22,server.local:22
```

### `inventory` (alias `inv`)

OS, hardware, hostname, list of installed CLI tools with versions, relevant
Homebrew packages.

### `report` (alias `all`)

Runs every module above and writes three files under `output/`.

```fish
./bin/netkit report
./bin/netkit report --active --include-traceroute --interface en7
```

## Recipes

### Compare Ethernet vs Wi-Fi quality side by side

```fish
./bin/netkit quality --interface en7 --json > eth.json
./bin/netkit quality --interface en0 --json > wifi.json
diff <(jq '.targets' eth.json) <(jq '.targets' wifi.json)
```

### Watch packet loss to gateway every minute

```fish
while true
  ./bin/netkit quality --count 30 --targets 192.168.1.254 --json \
    | jq -r '"\(now | strftime("%H:%M")) loss=\(.targets[0].loss_pct)% avg=\(.targets[0].rtt_avg_ms)ms"'
  sleep 60
end
```

### Generate a fresh report and open the markdown

```fish
./bin/netkit report --active && open (ls -t output/report-*.md | head -1)
```
