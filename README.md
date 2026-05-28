# macos-network-scripts

[![CI](https://github.com/joledev/macos-network-scripts/actions/workflows/ci.yml/badge.svg)](https://github.com/joledev/macos-network-scripts/actions/workflows/ci.yml)

A defensive, audit-friendly network toolkit for macOS. Discovers your local
network, measures connection quality, diagnoses developer-workflow
connectivity, and produces reports you can keep, diff or hand to an LLM for
analysis — all using read-only checks against networks you own.

Built for a MacBook Air M1 with USB-C 2.5GbE adapter, but works on any macOS
13+ machine.

## What it does

- Lists interfaces with kind (Ethernet, Wi-Fi, Thunderbolt), IP, CIDR, link
  speed and which one routes default traffic.
- Discovers LAN hosts via the ARP cache (passive) or a light ping sweep
  (active, opt-in).
- Maps the topology (mac → gateway → first hop → internet) and emits Mermaid
  diagrams for Obsidian / GitHub.
- Measures latency, jitter, packet loss to gateway + internet targets, plus
  DNS query timing.
- Diagnoses dev connectivity: GitHub HTTPS, TLS, SSH banner, Docker / Podman /
  Tailscale presence, WireGuard tunnels, local listening ports.
- Inventories the system (OS, CPU, RAM) and which CLI tools are installed.
- Generates a combined Markdown + JSON + Mermaid report under `output/`.

## What it does NOT do

- No exploitation, no brute force, no credential harvesting.
- No packet capture without explicit opt-in.
- No scans outside the local subnet by default. Larger ranges require
  `--force`.
- No root by default. Strict mode refuses to run as root.
- No secrets, tokens, SSH keys, or environment variables are read, logged or
  exported.

Use only on networks you own or are authorized to test. See
[`docs/safety-and-legal.md`](docs/safety-and-legal.md).

## Quick start

```fish
# Install optional tools (recommended)
make install

# Verify environment
make doctor

# First report — passive (uses ARP cache only)
./bin/netkit report

# Full report — also pings each address in the subnet, then traceroutes
./bin/netkit report --active --include-traceroute
```

Reports land under `output/`:

- `report-YYYYMMDD-HHMMSS.md`   — human-readable summary
- `report-YYYYMMDD-HHMMSS.json` — machine-readable for analysis
- `topology-YYYYMMDD-HHMMSS.mmd` — Mermaid `graph TD` diagram

## Subcommands

```
./bin/netkit doctor                Verify environment and tools
./bin/netkit interfaces            List interfaces (text/md/json)
./bin/netkit discover [--active]   List LAN hosts
./bin/netkit fingerprint           Deep per-host probe (ports, HTTP/TLS, role)
./bin/netkit ssdp                  UPnP / SSDP discovery (TVs, routers, media)
./bin/netkit ubnt-discover         Ubiquiti discovery (UniFi / airMAX / EdgeMax)
./bin/netkit netbios               NetBIOS/NBNS names (Windows/NAS hostname + workgroup)
./bin/netkit wsd                   WS-Discovery (Windows hosts, printers, scanners)
./bin/netkit ndp                   IPv6 neighbors (hosts ARP/IPv4 cannot see)
./bin/netkit vendorscan            Vendor probes (TP-Link Kasa/Tapo, MikroTik MNDP)
./bin/netkit lldp --allow-raw      LLDP/CDP capture -> switch/port/VLAN topology
./bin/netkit dhcp --allow-raw      DHCP fingerprint (hostname / vendor / opt-55)
./bin/netkit omada                 TP-Link Omada/EAP discovery (UDP 29810)
./bin/netkit devinfo               Authenticated identify of YOUR devices (HTTP/SSH)
./bin/netkit dns                   DNS resolver and per-service config
./bin/netkit mdns [--duration N]   Browse Bonjour / mDNS services
./bin/netkit topology [--mermaid]  Topology map
./bin/netkit quality [--count N]   Latency, jitter, loss, DNS timing
./bin/netkit speedtest             ISP throughput (Ookla or cloudflare-speed-cli)
./bin/netkit throughput --server H LAN throughput via iperf3
./bin/netkit diagnose              Dev workflow connectivity
./bin/netkit wifi [--survey]       RSSI, channel, security + nearby APs; --survey = passive RF site survey
./bin/netkit cameras               IP camera discovery (ONVIF + RTSP)
./bin/netkit starlink              Starlink dish status (needs grpcurl)
./bin/netkit starlink-clients      ALL devices the Starlink router knows (name/band/mesh)
./bin/netkit cert-check --host H   TLS audit for arbitrary host:port
./bin/netkit snmp --host H         Read-only SNMP walk (needs net-snmp)
./bin/netkit unifi                 UniFi Controller inventory (env-based auth)
./bin/netkit napalm                Multi-vendor fleet inventory (optional NAPALM dep)
./bin/netkit fleet <action>        Run a per-host audit across many nodes in parallel
./bin/netkit inventory             OS / hardware / tools
./bin/netkit recon [--active]      One-pass discovery → JSON + mermaid + interactive
                                   map + vis-network editor (.editor.html) + .drawio
                                   (--arpscan catch ICMP-silent hosts; --history fold in past devices)
./bin/netkit devices               Persistent device ledger (union of all scans over time)
./bin/netkit report                Combined report (default safe mode)
./bin/netkit history [--all]       List past reports under output/
./bin/netkit diff [A] [B]          Diff two reports (default: previous vs latest)
./bin/netkit report --redact LEVEL Privacy levels: none|redact|shareable
./bin/netkit oui fetch             Refresh IEEE OUI cache
./bin/netkit recog fetch           Fetch Rapid7 Recog DB (banner → vendor/product/device)
```

Every subcommand accepts `--json`, `--md`, or `--text` (default).

## Forcing a specific interface (Ethernet vs Wi-Fi)

By default the toolkit picks the **default-route interface** (which on macOS
already prefers Ethernet by service order). To force a specific one:

```fish
# One-off
./bin/netkit discover --interface en7

# Persistent across the session
set -x NETKIT_INTERFACE en7
./bin/netkit report
```

Or set `NETKIT_INTERFACE=en7` in `.env`.

## Output formats

```
./bin/netkit interfaces --json | jq .
./bin/netkit discover --md > today.md
./bin/netkit topology --mermaid > topo.mmd
```

## Configuration

Copy `.env.example` → `.env` and adjust. See the example for all knobs.
Key environment variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `NETKIT_INTERFACE` | _(auto)_ | Force a specific interface for all scans |
| `NETKIT_SUBNET` | _(auto)_ | Force a target subnet (CIDR) |
| `NETKIT_MAX_HOSTS` | `256` | Refuse to scan bigger than this without `--force` |
| `NETKIT_STRICT` | `1` | Refuse to run as root; refuse raw-packet ops |
| `NETKIT_DNS_DOMAIN` | `github.com` | Domain used for DNS timing |
| `NETKIT_PING_TARGETS` | `1.1.1.1,8.8.8.8` | Internet ping targets |
| `NETKIT_YES` | `0` | Auto-confirm prompts |

## Documentation

- [`docs/installation.md`](docs/installation.md) — install steps and optional tools
- [`docs/usage.md`](docs/usage.md) — full subcommand reference with examples
- [`docs/safety-and-legal.md`](docs/safety-and-legal.md) — what is and is not allowed
- [`docs/tools.md`](docs/tools.md) — which OS/Homebrew tools the toolkit uses
- [`docs/reports.md`](docs/reports.md) — report format and how to consume them
- [`docs/mcp-and-claude-code.md`](docs/mcp-and-claude-code.md) — using the toolkit with Claude Code / MCP servers
- [`docs/workflows.md`](docs/workflows.md) — recommended LLM workflows
- [`docs/command-safety.md`](docs/command-safety.md) — allowlist / denylist of commands

## Seeing every device (not just what answers right now)

A single scan only sees what responds to ARP/ping at that instant — phones
sleep, IoT ignores ICMP, devices roam. Three features close the gap:

- **`netkit starlink-clients`** queries the Starlink router's gRPC API (read-only,
  anonymous) for its full client list. This is the most complete source: it
  includes devices the sweep missed, each client's band (ethernet/2.4/5 GHz),
  per-client RSSI, and the node it associates with (`recon` uses that
  `upstreamMacAddress` to draw the *real* mesh topology, not a guess).
- **`recon --arpscan`** (needs `--allow-raw`/sudo) ARP-probes every address,
  catching hosts that answer ARP but drop ICMP.
- **`netkit devices`** prints a persistent ledger — the union of every host seen
  across all `recon` runs, with first/last-seen — so transient devices aren't
  lost. `recon --history` folds those past-but-absent devices back into the map.

## Known hosts (friendly names)

Drop a `configs/known-hosts.toml` (gitignored) or `~/.config/netkit/known-hosts.toml`
to map IPs/MACs to friendly names + roles. Reports overlay those onto every
host so `192.168.1.67` shows up as `desktop-jole / workstation` instead of
just an IP.

See [`configs/known-hosts.example.toml`](configs/known-hosts.example.toml).

## Vendor enrichment (IEEE OUI)

`netkit oui fetch` downloads the IEEE OUI registry (~4 MB) into
`~/.cache/netkit/oui.txt`. After that, vendors resolve from ~40k prefixes
instead of the ~50 built into the script. Auto-refreshes after 30 days.

Randomized / locally-administered MACs (phones using private Wi-Fi MACs) are
flagged as `(randomized MAC)` so a blank vendor is explained, not mysterious.

## Device identification (Recog)

`netkit recog fetch` downloads the subset of Rapid7's
[Recog](https://github.com/rapid7/recog) fingerprint DB that maps the banners
netkit already collects — HTTP `Server` headers, page `<title>`, auth realms,
SNMP `sysDescr`, SSH banners — to **vendor / product / version / device-type**.
Once fetched, `fingerprint` and `snmp` enrich every host (e.g. `lighttpd/1.4.x`
→ a TP-Link router, `Hipcam RealServer` → an IP camera). No DB present = the
tools fall back to their built-in heuristics. Stdlib-only; cached for 30 days.

DHCP fingerprinting (`netkit dhcp`) adds an OS/device guess from the vendor
class (deterministic) or the option-55 list (heuristic, Fingerbank-style). For
exact option-55 matches, set `FINGERBANK_API_KEY` (opt-in, never auto-called).

## Auditing many nodes at once

`netkit fleet <action>` fans a per-host audit out over an inventory (or
`--targets` / `--subnet`) with a bounded worker pool, then merges every result
into one report:

```fish
./bin/netkit fleet reach --from-known          # ICMP latency + loss, every known host
./bin/netkit fleet cert-check --subnet 10.0.0.0/28 --port 443
./bin/netkit fleet snmp --from-devices --community public --md
./bin/netkit fleet fingerprint --targets 192.168.1.1,192.168.1.69
```

It confirms once, then runs children with `--yes` (no per-host prompts), and is
bounded by `NETKIT_MAX_HOSTS`. For **managed multi-vendor gear** (Cisco, Arista,
Juniper) there is an optional NAPALM path — `netkit napalm` — which is the one
command with a real dependency (`pip install -r requirements/python-optional.txt`);
everything else stays stdlib-only.

## Roadmap

- [ ] SQLite history of reports (compare deltas over time)
- [ ] iperf3 wrapper for throughput measurement
- [ ] Wi-Fi diagnostic via `wdutil info` (sudo required, opt-in)
- [ ] Optional Obsidian export (writes to a vault path)
- [ ] Linux support for the same `bin/netkit` surface

## Contributing

This is a personal toolkit. PRs welcome if you keep:

1. Strict defaults (no root, no aggressive flags, subnet-bounded).
2. No telemetry, no secrets, no third-party services without opt-in.
3. ShellCheck-clean Bash, ruff-clean stdlib-only Python.

Run the test suite locally with:

```fish
brew install shellcheck
pipx install pytest ruff
make test     # full pytest suite
make lint     # shellcheck + ruff
```

CI runs the same on every push via [.github/workflows/ci.yml](.github/workflows/ci.yml).

## License

MIT — see [`LICENSE`](LICENSE).
