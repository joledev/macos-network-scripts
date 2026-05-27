# Safety and legal use

This toolkit is for **defensive network analysis** of networks you own or
have written authorization to inspect. Running it against networks you do not
control may be illegal — e.g. unauthorized scanning is criminalized under the
US CFAA, the UK Computer Misuse Act, MX Código Penal Federal Art. 211 bis 1,
and similar statutes elsewhere.

## What the toolkit is allowed to do (by default)

- Read passive state on this Mac: interfaces, ARP cache, routing table, DNS
  configuration, listening sockets, installed tools.
- Make tiny outbound probes from your machine: ping a handful of hosts,
  resolve a domain, open a TCP socket to read a banner.
- Optionally ping every address in **your own subnet** when you pass
  `--active`. The number of hosts is capped by `NETKIT_MAX_HOSTS` (default
  256, i.e. one /24). Bigger ranges require `--force`.

## What the toolkit refuses to do

- Run as root (strict mode is on by default — see `NETKIT_STRICT`).
- Capture packets without explicit opt-in.
- Brute force, exploit, fuzz, or alter remote configuration.
- Read SSH keys, environment secrets, credential stores, password managers.
- Send traffic outside the local subnet beyond a fixed list of ping targets
  and DNS lookups you configured.
- Use aggressive nmap modes (`-A`, `-O`, `--script`, `-T5`, `--osscan-*`).
- Touch `arp-scan` without an explicit `--arpscan` flag.

## What you should add for stronger guarantees

- Run on a dedicated user account when scanning unfamiliar segments.
- Keep `NETKIT_STRICT=1` in `.env` (the default).
- Do not increase `NETKIT_MAX_HOSTS` unless you control the segment.
- When in doubt, run `./bin/netkit doctor` — it prints the picked interface,
  subnet and gateway so you can confirm what will be scanned before scanning.

## Legal sanity checklist

Before running `--active` or `--arpscan` on a network:

1. You own the network, or
2. You are an employee/contractor with documented authorization, or
3. You have written permission from the owner.

For CTFs, lab environments, isolated test VLANs and your home network you
own, the answer is usually trivially yes. Be explicit anyway — keep an
authorization note in `output/.authorization.md` if you scan customer
networks.

## Reporting issues

Found a bug, false positive, or accidental aggressive default? Open an issue
on the GitHub repo. Do **not** publish output from a real customer or
production network — sanitize IPs/MACs before sharing.
