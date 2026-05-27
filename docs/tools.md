# Tools the toolkit uses

## Built into macOS — always available

| Tool | What netkit uses it for |
| --- | --- |
| `ifconfig` | Per-interface IP, MAC, netmask, status |
| `networksetup` | Hardware port labels, service order, media speed, DNS |
| `route` | Default-route interface + gateway |
| `arp` | Passive LAN host discovery via ARP cache |
| `scutil` | Active DNS resolver chain |
| `ping` | Latency / jitter / loss to gateway + internet |
| `traceroute` | Path to internet fallback |
| `dig` | DNS resolution timing |
| `curl` | GitHub HTTPS check |
| `lsof` | Local listening TCP ports |
| `dns-sd` | mDNS warmup (Bonjour) so AppleTV / printers show in ARP |
| `sysctl` / `sw_vers` | Hardware + OS inventory |

## Optional, via Homebrew

| Tool | Used when present | Without it |
| --- | --- | --- |
| `nmap` | Faster `--active` discovery (`nmap -sn`) | Falls back to a parallel ping sweep |
| `arp-scan` | Richer L2 discovery with vendor names (needs sudo) | Skipped — toolkit reads ARP cache only |
| `mtr` | Better topology traceroute | Falls back to `traceroute` |
| `iperf3` | Future throughput tests (roadmap) | — |
| `jq` | Pretty-printing JSON reports for humans | Reports still emit JSON; just less pretty |
| `tcpdump`, `tshark` | Used only if you opt into packet capture (not default) | Toolkit skips capture entirely |

## Tools the toolkit will *never* invoke without opt-in

- Anything that needs root permission (`arp-scan`, raw `nmap`, `tcpdump`).
- Anything that modifies network state (`networksetup -setairportpower`,
  `route add`, `pfctl`, `ifconfig` mutations).
- External services beyond the configured ping targets / TLS check to
  github.com.

If you want any of these for your own debugging, run them manually outside
the toolkit.
