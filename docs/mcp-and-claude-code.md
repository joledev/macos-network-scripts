# Using this toolkit with Claude Code (and MCP servers)

This repo is built to play well with Claude Code as a sidekick — for both
running the scripts and analyzing the reports. The recommendations below are
generic; adapt them to your own MCP setup.

## What Claude Code can do today, no MCP required

Out of the box, Claude Code (via its Bash and Read tools) can:

- Run `./bin/netkit <anything>` for you in this directory.
- Read the generated `output/report-*.md` and `.json` files and explain them.
- Diff two reports to spot regressions (e.g. "compare yesterday's WiFi run
  vs. today's Ethernet run").
- Suggest the next command based on what the previous report said
  (e.g. "loss to 1.1.1.1 was 7%, let's traceroute").

You do not need any MCP server for this to work — only that Claude Code can
shell out to `bin/netkit`.

## Recommended MCP servers (when you want more)

Use these only if you already have them set up. The toolkit has no
dependency on any MCP.

| MCP server | Why it helps | What to ask Claude to do |
| --- | --- | --- |
| **Filesystem MCP** | Lets Claude read/write the repo with explicit allowlists. | "Index every `output/*.md` and summarize trends in latency over the last week." |
| **GitHub MCP** | Open issues with the recommendations Claude finds. | "From the last report, open a GitHub issue for any 'recommendation' that I haven't yet addressed." |
| **SQLite MCP** | Store report deltas locally so you can ask trend questions. | "Insert this report into the `netkit_runs` table, then show me the 7-day rolling average of gateway latency." |
| **Obsidian MCP** | Push the Markdown report into your vault. | "Append the executive summary to `$SECOND_BRAIN/Bitacora/daily/2026-05/2026-05-26.md` under a `## Network` heading." |
| **Docker MCP** | Cross-check Docker daemon state. | "If `diag.docker.running == false`, start the daemon and re-run diagnose." |

### Servers we *don't* recommend for this repo

- **Shell/command MCP with broad permissions** — Claude Code already has a
  shell. Adding a second one is redundant and widens the attack surface.
  See [`command-safety.md`](command-safety.md) for what to allow if you
  already have one.
- **Playwright MCP** — no UI to drive here.
- **Web fetch MCP** — only useful for OUI updates; not a daily need.

## Skills / workflows worth creating

Define these as Claude Code custom skills (or just prompts you reuse). All
are read-only over the toolkit; none should write outside `output/`.

| Skill | Trigger | Behavior |
| --- | --- | --- |
| **Network Report Analyst** | "Analyze my latest network report" | Reads the newest `output/report-*.json`, returns executive summary + delta vs. the prior report. |
| **LAN Inventory Auditor** | "Audit my LAN" | Runs `netkit discover --active`, flags hosts whose MAC vendor is `Unknown` or whose rDNS is empty. |
| **Topology Mapper** | "Map my topology to Obsidian" | Runs `netkit topology --mermaid`, writes the `.mmd` into the configured vault path. |
| **macOS Network Troubleshooter** | "Why is the network slow?" | Runs `netkit quality --count 60`, `netkit diagnose`, correlates jitter spikes with DNS slowness. |
| **Homelab Connectivity Doctor** | "Doctor my homelab" | Runs `netkit doctor`, `netkit diagnose`, with VPN-aware SSH targets. |
| **Security-Safe Command Runner** | Default for this repo | Refuses any command not in [`configs/allowed-commands.example.txt`](../configs/allowed-commands.example.txt). |

## How Claude Code should run the toolkit

A short rulebook:

1. Always pass `--json` when you intend to analyze the output yourself.
2. Default to passive scans (no `--active`) unless the user explicitly asked
   for an active sweep — the difference is one ping per IP in the subnet.
3. Never raise `NETKIT_MAX_HOSTS` to scan bigger ranges without confirming.
4. Never bypass strict mode (`NETKIT_STRICT=0`) without confirming.
5. When generating reports, always include `--active --include-traceroute`
   only if the user is troubleshooting; otherwise the default is fine.
6. Read the resulting `output/report-*.md` for narrative and
   `output/report-*.json` for any quantitative claim.

## Preventing accidental harm

- Treat anything outside the local subnet as out-of-scope.
- If the user asks "scan the whole office," prompt them to confirm scope and
  authorization first.
- See [`command-safety.md`](command-safety.md) for the allowlist/denylist
  pattern.

## Future integrations (roadmap, not yet implemented)

- A `netkit history` subcommand that pushes the JSON into a local SQLite
  database for trend questions.
- A `netkit obsidian` subcommand that writes a daily note into a vault.
- A `netkit ci` mode that returns non-zero when a key metric regresses.
