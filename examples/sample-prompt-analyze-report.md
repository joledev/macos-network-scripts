# Example: ask Claude Code to analyze the latest report

Drop this into Claude Code from inside the repo:

```
Read the newest output/report-*.json (use ls -t | head -1). In ≤ 250 words:

1. Executive summary — interface in use, ip, gateway, hosts found.
2. Two biggest concerns (if any). Use the data, not speculation.
3. The single command I should run next.

If output/ is empty, say so and tell me to run ./bin/netkit report first.
```
