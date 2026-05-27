# Command safety

This document describes the allowlist / denylist that any agent (Claude
Code, ChatGPT, MCP-based shell servers) should respect when running this
toolkit on your behalf.

Files referenced:

- [`configs/allowed-commands.example.txt`](../configs/allowed-commands.example.txt)
- [`configs/denied-commands.example.txt`](../configs/denied-commands.example.txt)

Copy them to `configs/allowed-commands.txt` / `configs/denied-commands.txt`
to use locally; both `.txt` files are gitignored (only `.example.txt`
ships).

## Allowlist principles

A command is allowed iff:

1. It is a read-only system inspection (`ifconfig`, `route -n get`,
   `arp -an`, `netstat -rn`, `scutil --dns`, `lsof -nP`).
2. It is a `./bin/netkit <subcommand>` invocation with safe flags only.
3. It is a single bounded outbound probe to a configured target
   (`ping -c N <target>`, `dig <name>`, `curl -sS https://<host>`).
4. It is a Homebrew read (`brew list`, `brew --version`).

## Denylist principles

A command is denied if it:

1. Requires root **and** the user has not explicitly opted in for this run.
2. Modifies network state on this Mac (`networksetup -set*`, `route add`,
   `pfctl`, `ifconfig <iface> {up,down,...}`).
3. Captures packets (`tcpdump`, `tshark` write modes, `pcap`).
4. Scans aggressively (`nmap -A`, `nmap -O`, `nmap --script *`, `nmap -T5`,
   `nmap --min-rate`, `nmap --osscan-*`).
5. Brute-forces, fuzzes, or attempts exploitation.
6. Reads anything in `~/.ssh`, `~/.aws`, `~/.config/gcloud`, `~/.netrc`,
   `~/Library/Keychains`, `~/Library/Containers/.../Data/Documents` etc.
7. Sends data to a third party (curl/wget to anything not on the configured
   target list).
8. Touches `sudo` for anything other than `arp-scan` *and* only when the
   user has called the toolkit with `--arpscan`.

## What "configured target" means

These are the only outbound targets the toolkit is allowed to probe by
default:

- The default gateway (auto-detected).
- IPs / domains in `NETKIT_PING_TARGETS` (default `1.1.1.1,8.8.8.8`).
- `NETKIT_DNS_DOMAIN` (default `github.com`).
- `NETKIT_SSH_TARGETS` if set (default `github.com:22`).
- `api.github.com` for the HTTPS check.

Any other host requires the user to pass it explicitly via a flag.

## How Claude Code should enforce this

Without an MCP server, Claude Code's allowlist comes from
`.claude/settings.json`:

```jsonc
{
  "permissions": {
    "Bash": {
      "allow": [
        "./bin/netkit *",
        "make doctor",
        "make report",
        "ifconfig",
        "arp -an",
        "route -n get *",
        "scutil --dns",
        "lsof -nP -iTCP -sTCP:LISTEN"
      ],
      "deny": [
        "sudo *",
        "tcpdump *",
        "tshark -w*",
        "nmap -A*",
        "nmap -O*",
        "nmap --script*",
        "pfctl *",
        "networksetup -set*",
        "ifconfig * up",
        "ifconfig * down",
        "ifconfig * delete",
        "route add *",
        "rm -rf *"
      ]
    }
  }
}
```

Adapt the patterns to your harness; the point is that **read-only and
toolkit-owned commands are pre-approved**, while **anything that mutates
state or escalates privilege requires you to type-approve in the moment**.

## Manual escape hatch

If you legitimately need to do something on the denylist (e.g. quick
`tcpdump` to debug a duplex mismatch), run it manually outside the toolkit.
That keeps the toolkit and any agent driving it on the safe rail.
