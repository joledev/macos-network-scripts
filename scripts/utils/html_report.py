"""Render a netkit JSON report as a self-contained, print-friendly HTML.

Pure stdlib. No template engine — just f-strings and a small set of helpers.

The output is designed to look professional in a browser AND to print to a
clean PDF via the browser's File > Print > Save as PDF (or via external
tools like ``weasyprint`` or ``wkhtmltopdf`` if installed).

Print width targets US Letter (8.5") with sensible margins. All CSS is
inline so the artifact is single-file and email-able.
"""
from __future__ import annotations

import html as _html
import json
from typing import Any

CSS = r"""
:root {
  --fg:        #1a1a1a;
  --muted:    #6a6a6a;
  --accent:   #1f6feb;
  --border:   #d0d7de;
  --bg-soft:  #f6f8fa;
  --ok:       #1a7f37;
  --warn:     #9a6700;
  --bad:      #cf222e;
}
* { box-sizing: border-box; }
body {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
  font-size: 13px;
  line-height: 1.5;
  color: var(--fg);
  max-width: 820px;
  margin: 0 auto;
  padding: 32px 32px 64px;
  background: white;
}
header.report-head {
  border-bottom: 2px solid var(--accent);
  padding-bottom: 16px;
  margin-bottom: 24px;
}
header.report-head h1 {
  margin: 0 0 4px;
  font-size: 22px;
  font-weight: 700;
}
header.report-head .subtitle {
  color: var(--muted);
  font-size: 12px;
}
header.report-head .partial-banner {
  margin-top: 12px;
  padding: 10px 14px;
  background: #fff8c5;
  border: 1px solid #d4a72c;
  border-radius: 6px;
  color: #6f4a00;
  font-weight: 600;
}
h2 {
  font-size: 16px;
  font-weight: 600;
  margin: 28px 0 10px;
  padding-bottom: 4px;
  border-bottom: 1px solid var(--border);
}
.summary {
  display: grid;
  grid-template-columns: repeat(2, 1fr);
  gap: 8px 24px;
  margin-bottom: 8px;
}
.summary .row { display: flex; justify-content: space-between; padding: 4px 0; }
.summary .key { color: var(--muted); }
.summary .val { font-family: SF Mono, Menlo, Consolas, monospace; }
table {
  width: 100%;
  border-collapse: collapse;
  font-size: 12px;
  margin: 6px 0 20px;
}
th, td {
  text-align: left;
  padding: 6px 10px;
  border-bottom: 1px solid var(--border);
  vertical-align: top;
}
th {
  background: var(--bg-soft);
  font-weight: 600;
  font-size: 11px;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  color: var(--muted);
}
tr:hover td { background: #fafbfc; }
code, .mono {
  font-family: SF Mono, Menlo, Consolas, monospace;
  font-size: 12px;
}
.badge {
  display: inline-block;
  padding: 2px 8px;
  border-radius: 4px;
  font-size: 10px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.badge.ok    { background: #ddf4ff; color: #0969da; }
.badge.warn  { background: #fff8c5; color: var(--warn); }
.badge.bad   { background: #ffebe9; color: var(--bad); }
.recs { padding-left: 18px; margin: 8px 0; }
.recs li { margin: 4px 0; }
.footer {
  margin-top: 40px;
  padding-top: 12px;
  border-top: 1px solid var(--border);
  font-size: 11px;
  color: var(--muted);
}
.kvgrid {
  display: grid;
  grid-template-columns: 220px 1fr;
  gap: 4px 12px;
  font-size: 12px;
}
.kvgrid .k { color: var(--muted); }
.module-errors {
  margin: 8px 0 16px;
  padding: 10px 14px;
  background: #ffebe9;
  border: 1px solid #cf222e;
  border-radius: 6px;
}
.module-errors h2 {
  border: none;
  margin: 0 0 6px;
  color: var(--bad);
  font-size: 14px;
}

@media print {
  body { max-width: none; padding: 12mm; font-size: 11px; }
  header.report-head { page-break-after: avoid; }
  h2 { page-break-after: avoid; page-break-before: auto; }
  table { page-break-inside: auto; }
  tr { page-break-inside: avoid; page-break-after: auto; }
  .no-print { display: none !important; }
}
"""

def _esc(s: Any) -> str:
    return _html.escape("" if s is None else str(s))

def _badge(text: str, kind: str = "ok") -> str:
    return f'<span class="badge {_esc(kind)}">{_esc(text)}</span>'

def _table(headers: list[str], rows: list[list[Any]]) -> str:
    if not rows:
        return '<p class="mono" style="color:var(--muted)">(no data)</p>'
    th = "".join(f"<th>{_esc(h)}</th>" for h in headers)
    body = []
    for r in rows:
        cells = "".join(f"<td>{_esc(c)}</td>" for c in r)
        body.append(f"<tr>{cells}</tr>")
    return f'<table><thead><tr>{th}</tr></thead><tbody>{"".join(body)}</tbody></table>'

def _pct(v: Any) -> str:
    try:
        return f"{float(v):.1f}%"
    except (TypeError, ValueError):
        return _esc(v)


def render(report: dict, *, brand: str = "Network Diagnostic Report") -> str:
    meta = report.get("meta", {}) or {}
    inv  = report.get("inventory", {}) or {}
    ifs  = report.get("interfaces", {}) or {}
    dns  = report.get("dns", {}) or {}
    hosts = report.get("hosts", {}) or {}
    q    = report.get("quality", {}) or {}
    diag = report.get("diagnostics", {}) or {}
    topo = report.get("topology", {}) or {}

    osd = inv.get("os", {}) or {}
    hwd = inv.get("hardware", {}) or {}
    host = inv.get("host", {}) or {}

    ts = meta.get("generated_at", "")
    partial = meta.get("partial", False)
    redacted = meta.get("redacted", False)
    redact_level = meta.get("redact_level", "none")

    default_if = ifs.get("default_interface", "")
    default_gw = ifs.get("default_gateway", "")
    ghttps     = diag.get("github_https", {}) or {}
    targets    = q.get("targets", []) or []
    gw_target  = next((t for t in targets if t.get("target") == default_gw), None) or (targets[0] if targets else {})
    inet_target = next((t for t in targets if t.get("target") != default_gw), {}) if targets else {}

    failed_modules = {e.get("module") for e in (meta.get("module_errors", []) or [])}
    diagnostics_failed = "diagnostics" in failed_modules

    # ---- summary ----
    if diagnostics_failed:
        github_badge = _badge("UNKNOWN", "warn")
    else:
        github_badge = _badge("OK", "ok") if ghttps.get("ok") else _badge("FAIL", "bad")

    summary_rows = [
        ("Active interface", f"<code>{_esc(default_if)}</code> → <code>{_esc(default_gw)}</code>"),
        ("Hosts on LAN", _esc(hosts.get("count", 0))),
        ("Gateway RTT (avg / loss)",
         f"{_esc(gw_target.get('rtt_avg_ms', '?'))} ms / {_pct(gw_target.get('loss_pct', 0))}" if gw_target else "—"),
    ]
    if inet_target:
        summary_rows.append(
            (f"Internet RTT ({_esc(inet_target.get('target',''))})",
             f"{_esc(inet_target.get('rtt_avg_ms','?'))} ms / {_pct(inet_target.get('loss_pct',0))}"))
    summary_rows.append(("DNS query time",
                          f"{_esc(q.get('dns_query_ms', '?'))} ms ({_esc(q.get('dns_domain',''))})"))
    summary_rows.append(("GitHub HTTPS", github_badge))

    summary_html = "".join(
        f'<div class="row"><span class="key">{_esc(k)}</span><span class="val">{v}</span></div>'
        for k, v in summary_rows
    )

    # ---- interfaces table ----
    if_rows = []
    for r in (ifs.get("interfaces") or []):
        if_rows.append([
            r.get("device", ""), r.get("kind", ""),
            r.get("ipv4", ""), r.get("netmask_cidr", ""),
            r.get("status", ""), (r.get("media", "") or "")[:40],
            (r.get("hardware_port", "") or "")[:40],
            "yes" if r.get("is_default_route") else "",
        ])
    if_html = _table(["device", "kind", "ipv4", "cidr", "status", "media", "hardware port", "default"], if_rows)

    # ---- hosts table ----
    host_rows = []
    for h in (hosts.get("hosts") or []):
        host_rows.append([
            h.get("ip", ""), h.get("mac", ""), h.get("vendor", "")[:34],
            h.get("known_name", "") or h.get("name", ""), h.get("role", ""), h.get("source", ""),
        ])
    hosts_html = _table(["IP", "MAC", "Vendor", "Name", "Role", "Source"], host_rows)

    # ---- quality table ----
    q_rows = []
    for t in targets:
        loss = t.get("loss_pct", 0)
        loss_badge = (_badge(_pct(loss), "ok") if loss == 0
                      else _badge(_pct(loss), "warn") if loss < 5
                      else _badge(_pct(loss), "bad"))
        q_rows.append([
            t.get("target", ""),
            t.get("sent", ""), t.get("received", ""),
            loss_badge,
            f"{_esc(t.get('rtt_min_ms', '?'))}",
            f"{_esc(t.get('rtt_avg_ms', '?'))}",
            f"{_esc(t.get('rtt_max_ms', '?'))}",
            f"{_esc(t.get('rtt_stddev_ms', '?'))}",
        ])
    quality_html = _table(["target", "sent", "recv", "loss", "min ms", "avg ms", "max ms", "jitter ms"], q_rows)

    # ---- DNS resolvers ----
    dns_rows = []
    for r in (dns.get("resolvers") or []):
        if not r.get("nameservers"):
            continue
        dns_rows.append([
            r.get("id", ""), r.get("interface", "") or "—",
            ", ".join(r.get("nameservers", []) or []),
            ", ".join(r.get("search", []) or []) or r.get("domain", ""),
        ])
    dns_html = _table(["resolver", "interface", "nameservers", "search / domain"], dns_rows)

    # ---- traceroute ----
    trace = topo.get("traceroute") or []
    if isinstance(trace, dict):
        trace = trace.get("report", {}).get("hubs", []) or []
    trace_rows = []
    for t in trace:
        trace_rows.append([
            t.get("hop") or t.get("count", ""),
            t.get("host", ""),
            t.get("rtt_ms") or t.get("Avg", "") or "",
        ])
    trace_html = _table(["hop", "host", "rtt ms"], trace_rows) if trace_rows else ""

    # ---- diagnostics highlights ----
    tls = diag.get("tls_github", {}) or {}
    docker = diag.get("docker", {}) or {}
    podman = diag.get("podman", {}) or {}
    tailscale = diag.get("tailscale", {}) or {}
    ipv6 = diag.get("ipv6", {}) or {}
    vpns = diag.get("vpn_tunnels", []) or []
    vpn_summary = ", ".join(
        f'{v.get("interface","")}={v.get("inet") or "—"}'
        for v in vpns if v.get("inet")
    ) or "—"
    diag_html = (
        '<div class="kvgrid">'
        f'<div class="k">GitHub HTTPS</div><div>{github_badge} ({_esc(ghttps.get("http_code",""))}, {_esc(ghttps.get("time_s",""))}s)</div>'
        f'<div class="k">TLS github.com</div><div>{_badge("OK","ok") if tls.get("ok") else _badge("FAIL","bad")} · {_esc(tls.get("time_ms","?"))} ms · expires {_esc(tls.get("not_after",""))}</div>'
        f'<div class="k">IPv6 reachability</div><div>{_badge("OK","ok") if ipv6.get("ping6_ok") else _badge("FAIL","warn")} · {_esc(ipv6.get("ping6_avg_ms","?"))} ms to <code>{_esc(ipv6.get("ping6_target",""))}</code></div>'
        f'<div class="k">Docker daemon</div><div>{_esc("running" if docker.get("running") else ("installed" if docker.get("installed") else "absent"))}</div>'
        f'<div class="k">Podman</div><div>{_esc("running" if podman.get("running") else ("installed" if podman.get("installed") else "absent"))}</div>'
        f'<div class="k">Tailscale</div><div>{_esc("logged_in" if tailscale.get("logged_in") else ("installed" if tailscale.get("installed") else "absent"))}{" · " + _esc(tailscale.get("self_ip","")) if tailscale.get("self_ip") else ""}</div>'
        f'<div class="k">VPN tunnels (active)</div><div><code>{_esc(vpn_summary)}</code></div>'
        '</div>'
    )

    # ---- module errors / partial banner ----
    me_html = ""
    if meta.get("module_errors"):
        me_rows = [[e.get("module"), e.get("rc"), e.get("stderr_tail", "")[:200]]
                   for e in meta["module_errors"]]
        me_html = (
            '<section class="module-errors"><h2>Module failures</h2>'
            + _table(["module", "rc", "stderr"], me_rows)
            + '</section>'
        )

    partial_html = ""
    if partial:
        partial_html = (
            '<div class="partial-banner">'
            'PARTIAL REPORT — one or more modules failed. See the '
            '"Module failures" section below.'
            '</div>'
        )

    redact_html = ""
    if redacted:
        redact_html = (
            f'<div class="subtitle" style="margin-top:8px">'
            f'Redaction level: <code>{_esc(redact_level)}</code>. Personally-identifying'
            f' fields tokenized or removed.</div>'
        )

    # ---- recommendations (mirrors generate.sh MD logic) ----
    recs = []
    missing = [t for t, v in (inv.get("tools") or {}).items()
               if v is None and t in {"nmap", "arp-scan", "iperf3", "mtr", "jq"}]
    if missing:
        recs.append(f"Install optional tools: <code>brew install {' '.join(missing)}</code>")
    for t in targets:
        loss = t.get("loss_pct", 0) or 0
        jitter = t.get("rtt_stddev_ms", 0) or 0
        if loss > 5:
            recs.append(f"Packet loss to {_esc(t.get('target',''))} is {loss:.1f}% — investigate the path.")
        if jitter > 30:
            recs.append(f"Jitter to {_esc(t.get('target',''))} is {jitter:.1f} ms — link may be unstable.")
    if q.get("dns_query_ms") and q.get("dns_query_ms", 0) > 100:
        recs.append(f"DNS lookup took {_esc(q['dns_query_ms'])} ms — consider switching resolver.")
    if not diagnostics_failed and not ghttps.get("ok"):
        recs.append("GitHub HTTPS failed — check VPN, proxy, or DNS for github.com.")
    if diagnostics_failed:
        recs.append("Diagnostics module failed — connectivity checks not run.")
    recs_html = (
        '<ul class="recs">' + "".join(f"<li>{r}</li>" for r in recs) + '</ul>'
        if recs else '<p style="color:var(--muted)">No issues detected at the configured thresholds.</p>'
    )

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{_esc(brand)} — {_esc(ts)}</title>
<style>{CSS}</style>
</head>
<body>
<header class="report-head">
  <h1>{_esc(brand)}</h1>
  <div class="subtitle">
    Generated <code>{_esc(ts)}</code>
    · tool version <code>{_esc(meta.get("tool_version", "?"))}</code>
    · schema <code>{_esc(meta.get("schema_version", "?"))}</code>
  </div>
  {redact_html}
  {partial_html}
</header>

<section><h2>Executive summary</h2><div class="summary">{summary_html}</div></section>

<section><h2>System</h2>
<div class="kvgrid">
  <div class="k">OS</div><div>{_esc(osd.get("product_name",""))} {_esc(osd.get("product_version",""))} (build {_esc(osd.get("build_version",""))})</div>
  <div class="k">Hardware</div><div>{_esc(hwd.get("model",""))} · {_esc(hwd.get("cpu_brand",""))} ({_esc(hwd.get("cpu_cores","?"))} cores) · {_esc(hwd.get("memory_gb","?"))} GB</div>
  <div class="k">Hostname</div><div><code>{_esc(host.get("name",""))}</code></div>
</div>
</section>

<section><h2>Network interfaces</h2>{if_html}</section>

<section><h2>DNS resolvers</h2>{dns_html}</section>

<section><h2>LAN hosts ({_esc(hosts.get("count", 0))})</h2>{hosts_html}</section>

<section><h2>Link quality</h2>{quality_html}</section>

{('<section><h2>Path to internet</h2>' + trace_html + '</section>') if trace_html else ''}

<section><h2>Diagnostics</h2>{diag_html}</section>

<section><h2>Recommendations</h2>{recs_html}</section>

{me_html}

<div class="footer">
Generated by <strong>netkit</strong> {_esc(meta.get("tool_version",""))} on macOS.
Schema {_esc(meta.get("schema_version","?"))}. To save as PDF, open this file in
Safari / Chrome and use <strong>File → Print → Save as PDF</strong>.
</div>

</body>
</html>"""


if __name__ == "__main__":   # pragma: no cover
    import sys
    if len(sys.argv) > 1:
        with open(sys.argv[1]) as _f:
            data = json.load(_f)
    else:
        data = json.load(sys.stdin)
    print(render(data))
