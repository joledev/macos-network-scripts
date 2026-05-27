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
- `--yes` — auto-confirm `--active` prompts.
- `--allow-raw` — allow raw-packet operations (arp-scan, sudo mtr).
- `--dry-run` — print the probes that would run, exit without executing.

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

### `speedtest` (alias `isp`)

ISP throughput + ping. Picks `speedtest` (Ookla, recommended) first,
then `cloudflare-speed-cli` (already on this Mac), then a coarse `curl`
fallback.

```fish
./bin/netkit speedtest                 # auto-pick tool
./bin/netkit speedtest --json
```

### `throughput` (alias `iperf`)

LAN throughput via iperf3. Use against a peer on the same network to
verify cabling / NIC negotiation / switch capacity.

```fish
# On a peer machine (Linux / NAS / another Mac):
./bin/netkit throughput --listen --port 5201

# On this Mac:
./bin/netkit throughput --server 192.168.1.115
./bin/netkit throughput --server <host> --duration 30 --udp
./bin/netkit throughput --server <host> --reverse        # download-direction
```

### `wifi` (alias `wireless`)

Current SSID, RSSI, channel, security, supported PHY modes, transmit
rate, plus a scan of nearby APs (without sudo via
`system_profiler SPAirPortDataType`). Pass `--allow-raw` with a primed
sudo timestamp to also pull richer info from `wdutil info`.

```fish
./bin/netkit wifi
./bin/netkit wifi --json
sudo -v && ./bin/netkit wifi --allow-raw
```

### `cameras` (alias `onvif`)

Discovers IP cameras via three complementary techniques: WS-Discovery
UDP multicast (ONVIF), RTSP DESCRIBE banner grab on port 554, and HTTP
fingerprint on ports 80 / 8000 / 8080 / 8443. Picks vendor hints from
common server strings (Hikvision, Dahua, Reolink, Axis, Amcrest,
Foscam, TP-Link Tapo, Ubiquiti UniFi, etc.).

```fish
./bin/netkit cameras                            # probe arp-cache hosts
./bin/netkit cameras --hosts 192.168.1.50,.51   # probe specific candidates
./bin/netkit cameras --duration 5 --json
```

### `starlink` (alias `dishy`)

Queries a Starlink dish on its gRPC API. Defaults to
`192.168.100.1:9200` (the dish's well-known local address). Reports
device state, uptime, throughput, pop-ping latency, obstruction
fraction, hardware/software versions and active alerts.

Requires `brew install grpcurl`.

```fish
./bin/netkit starlink
./bin/netkit starlink --json
./bin/netkit starlink --host 192.168.100.1 --port 9200
```

### `mdns` (alias `bonjour`)

Browses common Bonjour / mDNS service types on the LAN for a short window
(default 3 s) and tries to resolve each advertised instance to an IP. Useful
for finding AppleTVs, Chromecasts, printers, smart-home bridges, and other
Apple/IoT devices that don't show up in arp-scan but advertise services.

```fish
./bin/netkit mdns
./bin/netkit mdns --duration 5 --json
```

Limitations: many IoT devices (smart bulbs, plugs, ESP-class boards) do not
advertise via mDNS at all. arp-scan or `discover --active` remains the
canonical inventory tool — mDNS just enriches it.

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

Runs every module above and writes **four** files under `output/`:

- `report-<ts>.md` — Markdown summary
- `report-<ts>.json` — machine-readable
- `report-<ts>.html` — self-contained HTML with print-friendly CSS;
  open in Safari/Chrome and use **File → Print → Save as PDF** to
  hand off to a customer. Set `NETKIT_REPORT_BRAND="My Company"` to
  change the header title.
- `topology-<ts>.mmd` — Mermaid diagram

```fish
./bin/netkit report
./bin/netkit report --active --include-traceroute --interface en7
set -x NETKIT_REPORT_BRAND "Joel - Network Audit"
./bin/netkit report --active
open output/(ls -t output | grep '\.html$' | head -1)
```

### `report --redact <level>`

Three privacy levels for sharing reports outside your own workflow.
`none` is the default — full data, what you've been seeing all along.

```fish
./bin/netkit report --redact none         # default: no redaction
./bin/netkit report --redact redact       # tokenize PII (stable within report)
./bin/netkit report --redact shareable    # max redaction for public sharing
```

| What gets redacted | `none` | `redact` | `shareable` |
| --- | --- | --- | --- |
| Hostname / `known_name` | preserved | hashed `host-XXXX` (suffix `.local`/`.lan` kept) | `REDACTED` |
| `user_shell` | preserved | preserved | `REDACTED` |
| OS `build_version` | preserved | preserved | `REDACTED` |
| MAC addresses | preserved | OUI kept (vendor), device portion tokenized | OUI kept, device tokenized |
| Private IPv4 | preserved | preserved | `/24` kept, host octet tokenized |
| Tailscale IPs / `.ts.net` search domains | preserved | tokenized (`ts-XXXX`, `tailnet-XXXX.ts.net`) | `REDACTED` |
| `role` from `known-hosts.toml` | preserved | preserved | `REDACTED` |
| Listening ports `pid` / `command` / `addr` | preserved | preserved | `REDACTED` |
| Public IPs (`1.1.1.1`, etc.) | preserved | preserved | preserved (already routable) |
| TLS issuer / cert info | preserved | preserved | preserved (public chain) |

**Token stability:** by default, tokens are stable within one report (same
input → same output) but change between reports because the salt is the
report's timestamp. To make tokens stable across reports (e.g. for
`netkit diff` of redacted reports of the same network), set:

```fish
set -x NETKIT_REDACTION_SALT "stable-salt-for-client-X"
./bin/netkit report --redact redact
```

`meta.redacted=true` and `meta.redact_level=<level>` are written into the
JSON so downstream tools can detect a redacted report and refuse to
re-publish a "full" copy on top of it.

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
