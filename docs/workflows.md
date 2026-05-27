# Workflows

Reusable prompts for analyzing toolkit output with an LLM (Claude Code,
ChatGPT, etc.). All assume Claude Code is operating in this repo's directory.

## 1. Quick health check

> Read the newest `output/report-*.json`. In ≤ 200 words give me: gateway
> latency, internet latency, DNS time, whether GitHub HTTPS is OK, and the
> single biggest concern. Don't paraphrase the whole file.

## 2. Ethernet vs Wi-Fi A/B

> Run `./bin/netkit quality --interface en7 --json --count 60` and
> `./bin/netkit quality --interface en0 --json --count 60`. Then compare:
> mean RTT to each target, jitter, packet loss. Recommend which to leave
> primary.

## 3. New device on the network

> Run `./bin/netkit discover --active --json`. Compare the IP list against
> the previous report under `output/`. Highlight new MACs, missing MACs and
> any vendor changes. Don't act on them — just report.

## 4. Slow build / git push diagnosis

> The user is complaining about slow git push. Run `./bin/netkit diagnose
> --json`. Cross-check: is GitHub HTTPS OK? TLS handshake under 200ms? SSH
> banner returned within 500ms? DNS resolution for github.com under 50ms?
> If any fail, suggest the single most likely cause.

## 5. Generate a tracked report

> Run `./bin/netkit report --active --include-traceroute`. Then read the
> resulting `output/report-*.md`. Summarize anything in the
> "Recommendations" section that wasn't already in the previous report.
> Append a one-line entry to my daily bitácora under
> `$SECOND_BRAIN/Bitacora/daily/<today>/...`.

## 6. Confirm scan scope before going active

Always confirm before opting into `--active` or `--arpscan` on a new
network:

> I'm about to run `./bin/netkit discover --active --interface <iface>` on
> subnet <subnet>. That sends one ping to each of the ~256 hosts in that
> /24. Confirm you own this network and want to proceed.

## 7. Trend over time

> List `output/report-*.json` newest-first. For the last 5 reports, extract
> gateway loss%, gateway avg RTT, internet (1.1.1.1) loss% and avg RTT.
> Render as a small markdown table. Don't speculate beyond what the data
> shows.

## 8. Snapshot before changing the network

Before plugging into a new switch / replacing the router:

> Run `./bin/netkit report --active`. Save the resulting markdown path. I'll
> diff against the post-change report later.

## 9. Investigate one specific host

> A device at 192.168.1.74 is misbehaving. Run `./bin/netkit discover
> --active --json` and tell me: MAC, vendor (from OUI), reverse DNS, and
> whether it answers ping. Don't run anything other than discover + a
> single ping.

## 10. Tool gap analysis

> Read `inventory.tools` from the newest report. List every tool with value
> `null` that the toolkit could use. For each, give me the Homebrew install
> command and one sentence on what it unlocks.
