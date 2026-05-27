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

### `history`

Lists past reports stored in `output/` with a one-line summary each. Default
is the last 10, newest first.

```fish
./bin/netkit history                 # last 10
./bin/netkit history --all           # everything
./bin/netkit history --limit 5
./bin/netkit history --json | jq '.reports[] | {ts:.timestamp, hosts}'
```

Columns shown: timestamp, hosts, gateway RTT, internet RTT, GitHub HTTPS
status, IPv6 ping status, flags (`PART` if partial, `pasv` if no
`--active`), module-error count.

### `diff [A] [B]`

Compare two reports. Both arguments accept `latest`, `previous`, a full path,
a bare filename, or any unambiguous timestamp substring.

```fish
./bin/netkit diff                              # previous vs latest
./bin/netkit diff 20260527-001952              # that vs latest
./bin/netkit diff 20260527-001952 014039       # two arbitrary reports
./bin/netkit diff previous latest --json
./bin/netkit diff 0019 0140 --md > delta.md
```

Surfaces:

- Hosts added / removed / changed (per-IP MAC, vendor, name, role diffs)
- Quality: per-target RTT and loss delta; significant entries
  (Δ > 10 % RTT or Δ ≥ 1 % loss) prefixed with `*`
- Interface status / IP / media changes
- Diagnostics highlights: GitHub HTTPS, TLS, IPv6 ping, Docker daemon,
  Tailscale logged-in
- VPN tunnel changes (utun IPs and socket owners)
- Listening port deltas

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
