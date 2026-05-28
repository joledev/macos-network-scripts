"""Render a netkit recon dataset as a self-contained interactive HTML map.

No external assets: inline CSS + vanilla JS + an embedded SVG whose node
positions are computed here in Python (deterministic — no physics needed).
Opens offline, prints cleanly, and lets you hover/click any node to see its
full fingerprint, filter by role, and search by ip / vendor / name.
"""
from __future__ import annotations

import html
import json
from typing import Any

ROLE_COLORS = {
    "router/gateway": "#1f6feb",
    "ap/switch/router": "#2da44e",
    "switch": "#2da44e",
    "camera": "#cf222e",
    "printer": "#8250df",
    "nas/file-server": "#bf8700",
    "media-server": "#bc4c00",
    "tv/media": "#e16f24",
    "iot/mqtt": "#0969da",
    "windows-host": "#57606a",
    "server/computer": "#57606a",
    "cpe/modem (TR-069)": "#1f6feb",
}
DEFAULT_COLOR = "#8c959f"
SELF_COLOR = "#9a6700"


def _color(role: str) -> str:
    return ROLE_COLORS.get(role, DEFAULT_COLOR)


def _esc(s: Any) -> str:
    return html.escape(str(s if s is not None else ""))


def _node_name(rec: dict) -> str:
    sd = rec.get("ssdp") or {}
    ub = rec.get("ubnt") or {}
    return (rec.get("known_name") or sd.get("friendly_name")
            or ub.get("model_full") or ub.get("model")
            or rec.get("vendor") or rec.get("rdns") or rec["ip"])


def render(report: dict, *, brand: str = "Network map") -> str:
    hosts = report.get("hosts", [])
    gw = report.get("gateway", "")
    dish = report.get("dish") or {}
    self_ifaces = report.get("self_interfaces", [])
    ts = report.get("meta", {}).get("generated_at", "")

    gw_rec = next((h for h in hosts if h["ip"] == gw), None)
    others = [h for h in hosts if h["ip"] != gw]

    # ---- deterministic layout ----
    per_row = min(6, max(3, len(others))) if others else 1
    box_w, box_h = 168, 56
    gap_x, gap_y = 30, 80
    margin = 40
    width = max(980, margin * 2 + per_row * box_w + (per_row - 1) * gap_x)
    cx = width / 2

    nodes = []   # {id,x,y,role,color,title,sub,rec}
    edges = []   # {x1,y1,x2,y2,label,cls}

    y = margin
    inet = {"id": "internet", "x": cx, "y": y, "role": "internet",
            "color": "#1a1a1a", "title": "Internet", "sub": ""}
    nodes.append(inet)
    prev = inet
    y += box_h + gap_y

    if dish:
        d = {"id": "dish", "x": cx, "y": y, "role": "router", "color": "#1f6feb",
             "title": "Starlink dish", "sub": _esc(dish.get("hardware", "")),
             "rec": {"role": "starlink-dish", **dish}}
        nodes.append(d)
        edges.append({"a": prev, "b": d, "label": "", "cls": "uplink"})
        prev = d
        y += box_h + gap_y

    gw_node = {"id": "gw", "x": cx, "y": y, "role": "router/gateway",
               "color": _color("router/gateway"),
               "title": gw or "Gateway",
               "sub": _esc(_node_name(gw_rec)) if gw_rec else "router",
               "rec": gw_rec or {"ip": gw, "role": "router/gateway"}}
    nodes.append(gw_node)
    edges.append({"a": prev, "b": gw_node, "label": "", "cls": "uplink"})
    gw_y = y
    y += box_h + gap_y + 30

    # this Mac (self) — to the left of the gateway, link-speed labelled
    for i, sif in enumerate(self_ifaces):
        sx = margin + box_w / 2 + i * (box_w + gap_x)
        sy = gw_y
        spd = sif.get("link_mbps")
        cap = sif.get("max_supported_mbps")
        warn = spd and cap and spd < cap
        snode = {"id": f"self_{sif['device']}", "x": sx, "y": sy,
                 "role": "self", "color": SELF_COLOR,
                 "title": f"This Mac · {sif['device']}",
                 "sub": _esc(sif.get("ipv4", "")),
                 "rec": {"role": "this-mac", **sif,
                         "link_warning": "negotiated below capacity" if warn else ""}}
        nodes.append(snode)
        lbl = f"{spd} Mbps" if spd else sif.get("kind", "")
        edges.append({"a": snode, "b": gw_node, "label": lbl,
                      "cls": "slow" if warn else "selflink"})

    # device tier
    for idx, rec in enumerate(others):
        row, col = divmod(idx, per_row)
        row_count = min(per_row, len(others) - row * per_row)
        row_width = row_count * box_w + (row_count - 1) * gap_x
        start_x = cx - row_width / 2 + box_w / 2
        nx = start_x + col * (box_w + gap_x)
        ny = y + row * (box_h + gap_y)
        node = {"id": "n" + rec["ip"].replace(".", "_"), "x": nx, "y": ny,
                "role": rec.get("role", "host"), "color": _color(rec.get("role", "")),
                "title": rec["ip"], "sub": _esc(_node_name(rec))[:26], "rec": rec}
        nodes.append(node)
        edges.append({"a": gw_node, "b": node, "label": "", "cls": "link"})

    rows_used = (len(others) + per_row - 1) // per_row if others else 0
    height = int(y + rows_used * (box_h + gap_y) + margin)

    # ---- SVG ----
    svg_edges = []
    for e in edges:
        a, b = e["a"], e["b"]
        x1, y1 = a["x"], a["y"] + box_h / 2
        x2, y2 = b["x"], b["y"] - box_h / 2
        mid_x, mid_y = (x1 + x2) / 2, (y1 + y2) / 2
        svg_edges.append(
            f'<line class="edge {e["cls"]}" x1="{x1:.0f}" y1="{y1:.0f}" '
            f'x2="{x2:.0f}" y2="{y2:.0f}" '
            f'data-a="{a["id"]}" data-b="{b["id"]}"/>')
        if e["label"]:
            svg_edges.append(
                f'<text class="edgelabel {e["cls"]}" x="{mid_x:.0f}" y="{mid_y:.0f}">'
                f'{_esc(e["label"])}</text>')

    svg_nodes = []
    for n in nodes:
        x = n["x"] - box_w / 2
        yb = n["y"] - box_h / 2
        rec_json = _esc(json.dumps(n.get("rec", {"ip": n["title"], "role": n["role"]})))
        svg_nodes.append(
            f'<g class="node" data-id="{n["id"]}" data-role="{_esc(n["role"])}" '
            f'data-rec="{rec_json}" transform="translate({x:.0f},{yb:.0f})">'
            f'<rect width="{box_w}" height="{box_h}" rx="8" '
            f'style="fill:{n["color"]}"/>'
            f'<text class="ntitle" x="10" y="22">{_esc(n["title"])}</text>'
            f'<text class="nsub" x="10" y="40">{n["sub"]}</text>'
            f'</g>')

    # ---- legend (role -> count), clickable filters ----
    role_counts: dict[str, int] = {}
    for h in hosts:
        role_counts[h.get("role", "host")] = role_counts.get(h.get("role", "host"), 0) + 1
    legend = "".join(
        f'<span class="lg" data-role="{_esc(r)}" style="--c:{_color(r)}">'
        f'<i></i>{_esc(r)} <b>{c}</b></span>'
        for r, c in sorted(role_counts.items(), key=lambda kv: -kv[1])
    )

    data_js = json.dumps(report, default=str).replace("</", "<\\/")

    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>{_esc(brand)} — {_esc(ts)}</title>
<style>
:root{{--fg:#1a1a1a;--muted:#6a6a6a;--border:#d0d7de;--bg:#f6f8fa;}}
*{{box-sizing:border-box}}
body{{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;
margin:0;color:var(--fg);background:#fff;font-size:13px}}
header{{padding:14px 20px;border-bottom:2px solid #1f6feb}}
header h1{{margin:0;font-size:18px}}
header .sub{{color:var(--muted);font-size:12px}}
.toolbar{{display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:10px 20px;
border-bottom:1px solid var(--border);background:var(--bg)}}
.toolbar input{{padding:5px 8px;border:1px solid var(--border);border-radius:6px;font-size:13px;width:220px}}
.lg{{display:inline-flex;align-items:center;gap:5px;padding:3px 8px;border:1px solid var(--border);
border-radius:20px;cursor:pointer;font-size:11px;user-select:none;background:#fff}}
.lg.off{{opacity:.35}}
.lg i{{width:10px;height:10px;border-radius:50%;background:var(--c);display:inline-block}}
.wrap{{display:flex;gap:0;align-items:stretch}}
.canvas{{flex:1;overflow:auto;max-height:calc(100vh - 120px)}}
svg{{display:block}}
.edge{{stroke:#c0c6cd;stroke-width:1.5}}
.edge.uplink{{stroke:#1f6feb;stroke-width:2.5}}
.edge.slow{{stroke:#cf222e;stroke-width:2.5;stroke-dasharray:5 3}}
.edge.selflink{{stroke:#9a6700;stroke-width:2}}
.edge.hl{{stroke:#1f6feb;stroke-width:3}}
.edgelabel{{font-size:10px;fill:var(--muted)}}
.edgelabel.slow{{fill:#cf222e;font-weight:700}}
.node{{cursor:pointer}}
.node rect{{stroke:rgba(0,0,0,.25);stroke-width:1;transition:opacity .1s}}
.node.dim{{opacity:.18}}
.node.sel rect{{stroke:#1a1a1a;stroke-width:3}}
.ntitle{{fill:#fff;font-size:12px;font-weight:700;font-family:SFMono-Regular,Menlo,monospace}}
.nsub{{fill:rgba(255,255,255,.92);font-size:11px}}
#detail{{width:330px;border-left:1px solid var(--border);padding:14px;overflow:auto;
max-height:calc(100vh - 120px);background:#fff}}
#detail h2{{margin:0 0 4px;font-size:15px}}
#detail .role{{display:inline-block;padding:2px 8px;border-radius:10px;color:#fff;font-size:11px;margin-bottom:8px}}
#detail .kv{{display:grid;grid-template-columns:90px 1fr;gap:2px 8px;font-size:12px;margin:6px 0}}
#detail .kv .k{{color:var(--muted)}}
#detail code{{font-family:SFMono-Regular,Menlo,monospace;font-size:11px;word-break:break-all}}
#detail .sec{{margin-top:10px;border-top:1px solid var(--border);padding-top:8px}}
#detail .muted{{color:var(--muted)}}
.tag{{display:inline-block;background:var(--bg);border:1px solid var(--border);border-radius:4px;
padding:1px 6px;margin:2px 2px 0 0;font-size:11px;font-family:SFMono-Regular,Menlo,monospace}}
@media print{{#detail{{display:none}} .toolbar input{{display:none}}}}
</style></head>
<body>
<header><h1>{_esc(brand)}</h1>
<div class="sub">{_esc(report.get("count",0))} hosts · gateway <code>{_esc(gw)}</code>
· {_esc(report.get("subnet",""))} · generated <code>{_esc(ts)}</code></div></header>
<div class="toolbar">
  <input id="q" placeholder="search ip / vendor / name…" autocomplete="off">
  {legend}
</div>
<div class="wrap">
  <div class="canvas">
    <svg width="{width}" height="{height}" viewBox="0 0 {width} {height}">
      <g id="edges">{''.join(svg_edges)}</g>
      <g id="nodes">{''.join(svg_nodes)}</g>
    </svg>
  </div>
  <div id="detail"><p class="muted">Hover or click a node to inspect it.
  Click a legend chip to filter by role.</p></div>
</div>
<script>
const DATA = {data_js};
const $ = s => document.querySelector(s);
const nodes = [...document.querySelectorAll('.node')];
const edges = [...document.querySelectorAll('.edge')];
const off = new Set();

function row(k,v){{return v?`<div class="k">${{k}}</div><div>${{v}}</div>`:'';}}
function esc(s){{return String(s==null?'':s).replace(/[&<>]/g,c=>({{'&':'&amp;','<':'&lt;','>':'&gt;'}}[c]));}}

function detail(rec){{
  const role = rec.role||'host';
  const color = (DATA.hosts.find(h=>h.role===role)?0:0, roleColor(role));
  let h = `<h2><code>${{esc(rec.ip||'')}}</code></h2>`;
  h += `<span class="role" style="background:${{color}}">${{esc(role)}}</span>`;
  h += '<div class="kv">';
  h += row('vendor', esc(rec.vendor));
  h += row('mac', rec.mac?`<code>${{esc(rec.mac)}}</code>`:'');
  h += row('rDNS', esc(rec.rdns));
  h += row('name', esc(rec.known_name));
  h += row('media', esc(rec.media));
  if(rec.link_mbps) h += row('link', `${{esc(rec.link_mbps)}} Mbps`+(rec.link_warning?` <b style="color:#cf222e">(${{esc(rec.link_warning)}})</b>`:''));
  h += '</div>';
  if(rec.ports && rec.ports.length){{
    h += '<div class="sec"><b>Open ports</b><br>';
    h += rec.ports.map(p=>`<span class="tag">${{p}}/${{esc((rec.services||{{}})[p]||'?')}}</span>`).join('');
    h += '</div>';
  }}
  (rec.http||[]).forEach(x=>{{
    h += `<div class="sec"><b>${{esc(x.scheme)}}:${{esc(x.port)}}</b> ${{esc(x.status||'')}}`;
    if(x.server) h += `<br>server: <code>${{esc(x.server)}}</code>`;
    if(x.title) h += `<br>title: ${{esc(x.title)}}`;
    if(x.location) h += `<br>→ <code>${{esc(x.location)}}</code>`;
    h += '</div>';
  }});
  (rec.tls||[]).forEach(t=>{{
    h += `<div class="sec"><b>TLS :${{esc(t.port)}}</b><br>subject: <code>${{esc(t.subject)}}</code>`;
    if(t.issuer) h += `<br>issuer: <code>${{esc(t.issuer)}}</code>`;
    if(t.not_after) h += `<br>expires: ${{esc(t.not_after)}}`;
    h += '</div>';
  }});
  if(rec.ssdp){{
    h += '<div class="sec"><b>UPnP / SSDP</b><div class="kv">';
    for(const [k,v] of Object.entries(rec.ssdp)) h += row(k, esc(v));
    h += '</div></div>';
  }}
  if(rec.ubnt){{
    h += '<div class="sec"><b>Ubiquiti</b><div class="kv">';
    for(const [k,v] of Object.entries(rec.ubnt)) h += row(k, esc(v));
    h += '</div></div>';
  }}
  if(rec.os_guess) h += `<div class="sec"><b>OS guess</b><br>${{esc(rec.os_guess)}}</div>`;
  if(rec.sources) h += `<div class="sec muted">sources: ${{esc((rec.sources||[]).join(', '))}}</div>`;
  $('#detail').innerHTML = h;
}}

const ROLE_COLORS = {json.dumps(ROLE_COLORS)};
function roleColor(r){{return ROLE_COLORS[r]||'{DEFAULT_COLOR}';}}

function setSel(node){{
  nodes.forEach(n=>n.classList.remove('sel'));
  edges.forEach(e=>e.classList.remove('hl'));
  if(!node) return;
  node.classList.add('sel');
  const id = node.dataset.id;
  edges.forEach(e=>{{if(e.dataset.a===id||e.dataset.b===id)e.classList.add('hl');}});
  detail(JSON.parse(node.dataset.rec));
}}

nodes.forEach(n=>{{
  n.addEventListener('mouseenter',()=>{{if(!$('.node.sel'))detail(JSON.parse(n.dataset.rec));}});
  n.addEventListener('click',()=>setSel(n));
}});

function applyFilters(){{
  const q = $('#q').value.trim().toLowerCase();
  nodes.forEach(n=>{{
    const rec = JSON.parse(n.dataset.rec);
    const role = n.dataset.role;
    const hay = [rec.ip,rec.vendor,rec.rdns,rec.known_name,
                 rec.ssdp&&rec.ssdp.friendly_name,rec.ssdp&&rec.ssdp.model_name]
                .filter(Boolean).join(' ').toLowerCase();
    const hideRole = off.has(role);
    const hideQ = q && !hay.includes(q);
    n.classList.toggle('dim', hideRole||hideQ);
  }});
}}
$('#q').addEventListener('input',applyFilters);
document.querySelectorAll('.lg').forEach(l=>{{
  l.addEventListener('click',()=>{{
    const r=l.dataset.role;
    if(off.has(r)){{off.delete(r);l.classList.remove('off');}}
    else{{off.add(r);l.classList.add('off');}}
    applyFilters();
  }});
}});
</script>
</body></html>"""
