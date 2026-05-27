# Installation

The toolkit runs on Python 3 stdlib + the BSD tools shipped with macOS. Nothing
extra is strictly required.

## Required (already on macOS)

- `python3` (3.10+)
- `ifconfig`, `route`, `arp`, `netstat`, `networksetup`, `scutil`, `ping`,
  `traceroute`, `curl`, `dig`, `lsof`

## Recommended (Homebrew, all optional)

```fish
make install   # installs everything in requirements/brew.txt
```

What `make install` adds:

| Tool | Why |
| --- | --- |
| `nmap` | Faster, multi-host discovery (`-sn`) |
| `arp-scan` | L2 host discovery (needs sudo) |
| `iperf3` | Throughput tests against a peer |
| `mtr` | Combined traceroute + ping |
| `jq` | JSON exploration of reports |
| `yq` | YAML conversion of reports if desired |
| `graphviz` | DOT fallback for topology diagrams (Mermaid is the default) |

If `brew` is not installed, follow [https://brew.sh](https://brew.sh) first.

## Manual install of a single tool

```fish
brew install nmap arp-scan iperf3 mtr jq
```

## Verify

```fish
make doctor
# or
./bin/netkit doctor
```

A clean run shows `required errors : 0` at the bottom.

## Optional: add `bin/` to your PATH

```fish
fish_add_path /Users/joledev/Dev/macos-network-scripts/bin
```

Then `netkit doctor` works from anywhere.

## Optional: passwordless sudo for `arp-scan`

`arp-scan` requires root because it sends raw ARP frames. The toolkit calls
`sudo -n arp-scan` (no password prompt) only if you have a valid sudo
timestamp. You can prime it manually:

```fish
sudo -v
./bin/netkit discover --active --arpscan
```

If you want this routinely without typing a password, add a `sudoers.d` rule
restricted to `arp-scan`. The toolkit does **not** set this up for you.
