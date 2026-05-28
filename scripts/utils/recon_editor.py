"""Render a netkit recon dataset as a self-contained INTERACTIVE EDITOR.

Built on a vendored, offline copy of vis-network (Apache-2.0). The generated
HTML lets you: create / edit / delete nodes and edges, assign IP / name / type /
room, color by role, cluster nodes into "rooms", and save / load the edited
topology as JSON (so manual layout + groupings survive re-runs). The vis-network
bundle is inlined so the file opens offline with no CDN.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

try:
    from recon_map import ROLE_COLORS, DEFAULT_COLOR, _node_name
except Exception:  # pragma: no cover
    ROLE_COLORS = {}
    DEFAULT_COLOR = "#8c959f"

    def _node_name(rec):
        return rec.get("display") or rec.get("vendor") or rec.get("ip", "")

_ASSET = Path(__file__).resolve().parent / "assets" / "vis-network.min.js"


def _vis_js() -> str:
    try:
        return _ASSET.read_text(encoding="utf-8")
    except OSError:
        return ""


def _color(role: str) -> str:
    return ROLE_COLORS.get(role, DEFAULT_COLOR)


def _build_graph(report: dict):
    hosts = report.get("hosts", [])
    gw = report.get("gateway", "")
    dish = report.get("dish") or {}
    self_ifaces = report.get("self_interfaces", [])
    others = [h for h in hosts if h["ip"] != gw]

    bw, gapx, gapy = 200, 70, 120
    per_row = max(4, min(6, len(others))) if others else 1
    width = per_row * (bw + gapx)
    cx = width / 2

    nodes, edges = [], []

    def add_node(nid, label, role, x, y, extra=None):
        n = {"id": nid, "label": label, "group": role, "x": int(x), "y": int(y),
             "fixed": False, "role": role}
        if extra:
            n.update(extra)
        nodes.append(n)

    y = 0
    add_node("internet", "Internet", "internet", cx, y, {"shape": "ellipse"})
    prev = "internet"
    y += gapy
    if dish:
        add_node("dish", f"Starlink dish\n{dish.get('hardware','')}", "router/gateway",
                 cx, y, {"ip": dish.get("address", ""), "kind": "starlink-dish"})
        edges.append({"from": prev, "to": "dish"})
        prev = "dish"
        y += gapy

    gw_rec = next((h for h in hosts if h["ip"] == gw), None)
    gw_name = _node_name(gw_rec) if gw_rec else gw
    add_node(gw or "gateway", f"{gw_name}\n{gw}".strip(), "router/gateway", cx, y,
             _node_fields(gw_rec) if gw_rec else {"ip": gw})
    edges.append({"from": prev, "to": gw or "gateway"})
    gw_y = y
    y += gapy + 30

    for i, sif in enumerate(self_ifaces):
        sid = "self-" + sif["device"]
        spd, cap = sif.get("link_mbps"), sif.get("max_supported_mbps")
        warn = f"\n LINK {spd}/{cap} Mbps!" if (spd and cap and spd < cap) else ""
        add_node(sid, f"This Mac · {sif['device']}\n{sif.get('ipv4','')}{warn}",
                 "self", 40 + i * (bw + gapx), gw_y,
                 {"ip": sif.get("ipv4", ""), "kind": "this-mac"})
        edges.append({"from": sid, "to": gw or "gateway", "dashes": True})

    for idx, rec in enumerate(others):
        row, col = divmod(idx, per_row)
        nx = col * (bw + gapx) + gapx / 2
        ny = y + row * gapy
        name = _node_name(rec)
        label = f"{name}\n{rec['ip']}" if name and name != rec["ip"] else rec["ip"]
        add_node(rec["ip"], label, rec.get("role", "host"), nx, ny, _node_fields(rec))
        edges.append({"from": gw or "gateway", "to": rec["ip"]})

    return nodes, edges


def _node_fields(rec: dict) -> dict:
    """Custom fields kept on the vis node for the editor's detail form."""
    if not rec:
        return {}
    out = {"ip": rec.get("ip", ""), "vendor": rec.get("vendor", ""),
           "mac": rec.get("mac", ""), "rdns": rec.get("rdns", ""),
           "identity": rec.get("identity", ""), "room": ""}
    if rec.get("ports"):
        out["ports"] = ", ".join(str(p) for p in rec["ports"])
    title_bits = [rec.get("identity"), rec.get("vendor"), rec.get("mac")]
    out["title"] = " · ".join(b for b in title_bits if b) or rec.get("ip", "")
    return out


def _group_options() -> dict:
    groups: dict[str, Any] = {}
    for role, color in ROLE_COLORS.items():
        groups[role] = {"color": {"background": color, "border": "#1a1a1a"},
                        "font": {"color": "#fff"}}
    groups["internet"] = {"color": {"background": "#1a1a1a"}, "font": {"color": "#fff"}}
    groups["self"] = {"color": {"background": "#fff8c5", "border": "#9a6700"}}
    groups["host"] = {"color": {"background": DEFAULT_COLOR}}
    return groups


def render(report: dict, *, brand: str = "Network editor") -> str:
    nodes, edges = _build_graph(report)
    groups = _group_options()
    ts = report.get("meta", {}).get("generated_at", "")
    gw = report.get("gateway", "")
    roles = sorted(set([n["role"] for n in nodes] + list(ROLE_COLORS)))
    data_js = json.dumps({"nodes": nodes, "edges": edges, "groups": groups,
                          "roles": roles}, default=str).replace("</", "<\\/")
    vis = _vis_js()

    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>{brand} — {ts}</title>
<style>
*{{box-sizing:border-box}}
body{{margin:0;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;font-size:13px}}
header{{padding:10px 16px;border-bottom:2px solid #1f6feb;display:flex;gap:10px;align-items:center;flex-wrap:wrap}}
header h1{{margin:0;font-size:16px}}
header .sub{{color:#6a6a6a;font-size:12px}}
button{{font:inherit;padding:5px 10px;border:1px solid #d0d7de;border-radius:6px;background:#fff;cursor:pointer}}
button:hover{{background:#f6f8fa}}
button.primary{{background:#1f6feb;color:#fff;border-color:#1f6feb}}
.wrap{{display:flex;height:calc(100vh - 52px)}}
#net{{flex:1;background:#fafbfc}}
#panel{{width:300px;border-left:1px solid #d0d7de;padding:12px;overflow:auto}}
#panel h2{{font-size:14px;margin:0 0 8px}}
label{{display:block;font-size:11px;color:#6a6a6a;margin:8px 0 2px}}
input,select,textarea{{width:100%;padding:5px 7px;border:1px solid #d0d7de;border-radius:6px;font:inherit}}
.row{{display:flex;gap:6px}}.row>*{{flex:1}}
.muted{{color:#6a6a6a}}
.toolbar{{display:flex;gap:6px;flex-wrap:wrap;margin-left:auto}}
.hint{{font-size:11px;color:#6a6a6a;margin-top:10px;line-height:1.5}}
</style></head>
<body>
<header>
  <h1>{brand}</h1>
  <span class="sub">{report.get("count",0)} hosts · gw {gw} · {ts}</span>
  <span class="toolbar">
    <button onclick="addNode()">+ Node</button>
    <button onclick="net.addEdgeMode()">+ Edge</button>
    <button onclick="addRoom()">+ Room</button>
    <button onclick="clusterRooms()">Cluster rooms</button>
    <button onclick="net.openCluster &amp;&amp; uncluster()">Uncluster</button>
    <button onclick="saveJSON()">Save JSON</button>
    <button onclick="document.getElementById('loadf').click()">Load JSON</button>
    <button onclick="exportPNG()">PNG</button>
    <input id="loadf" type="file" accept="application/json" style="display:none" onchange="loadJSON(event)">
  </span>
</header>
<div class="wrap">
  <div id="net"></div>
  <div id="panel">
    <h2>Selection</h2>
    <div id="form"><p class="muted">Click a node to edit it, or use + Node / + Edge.
    Drag to reposition. Assign a Room to group devices (then “Cluster rooms”).</p></div>
    <div class="hint">Edits live in this page. <b>Save JSON</b> to persist your
    layout/rooms/IPs and <b>Load JSON</b> to restore them after a new scan.</div>
  </div>
</div>
<script>{vis}</script>
<script>
const DATA = {data_js};
const nodes = new vis.DataSet(DATA.nodes);
const edges = new vis.DataSet(DATA.edges);
const container = document.getElementById('net');
const options = {{
  physics: false,
  nodes: {{ shape:'box', margin:8, widthConstraint:{{maximum:190}},
            font:{{multi:false,size:12,face:'SFMono-Regular,Menlo,monospace'}} }},
  edges: {{ color:{{color:'#b8c0c8'}}, smooth:{{type:'cubicBezier'}} }},
  groups: DATA.groups,
  manipulation: {{
    enabled: true,
    addNode: (data, cb) => {{ data.label = prompt('Label for new node:', 'new device') || 'node'; data.group='host'; data.ip=''; cb(data); selectAfter(data.id); }},
    editNode: (data, cb) => {{ cb(data); }},
    addEdge: (data, cb) => {{ if(data.from!==data.to) cb(data); }},
  }},
  interaction: {{ hover:true, multiselect:true }},
}};
const net = new vis.Network(container, {{nodes, edges}}, options);
const ROLES = DATA.roles;

function esc(s){{return String(s==null?'':s).replace(/[&<>"]/g,c=>({{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}}[c]));}}

function rooms(){{
  const set = new Set();
  nodes.get().forEach(n=>{{ if(n.room) set.add(n.room); }});
  return [...set].sort();
}}

function showForm(id){{
  const n = nodes.get(id);
  if(!n){{ document.getElementById('form').innerHTML='<p class="muted">No selection.</p>'; return; }}
  const roleOpts = ROLES.map(r=>`<option ${{r===n.group?'selected':''}}>${{esc(r)}}</option>`).join('');
  const roomList = rooms();
  const roomOpts = ['<option value=""></option>'].concat(roomList.map(r=>`<option ${{r===n.room?'selected':''}}>${{esc(r)}}</option>`)).join('');
  document.getElementById('form').innerHTML = `
    <label>Name / label</label><input id="f-label" value="${{esc(n.label||'')}}">
    <div class="row"><div><label>IP</label><input id="f-ip" value="${{esc(n.ip||'')}}"></div>
    <div><label>MAC</label><input id="f-mac" value="${{esc(n.mac||'')}}"></div></div>
    <label>Type / role</label><select id="f-role">${{roleOpts}}</select>
    <label>Room / group</label><select id="f-room">${{roomOpts}}</select>
    <label>Vendor / model</label><input id="f-vendor" value="${{esc(n.vendor||n.identity||'')}}">
    <label>Notes</label><textarea id="f-notes" rows="2">${{esc(n.notes||'')}}</textarea>
    <div class="row" style="margin-top:10px">
      <button class="primary" onclick="applyForm('${{esc(id)}}')">Apply</button>
      <button onclick="delNode('${{esc(id)}}')">Delete</button>
    </div>`;
}}

function applyForm(id){{
  const g = i=>document.getElementById(i).value;
  nodes.update({{id, label:g('f-label'), ip:g('f-ip'), mac:g('f-mac'),
    group:g('f-role'), role:g('f-role'), room:g('f-room'),
    vendor:g('f-vendor'), notes:g('f-notes')}});
  showForm(id);
}}
function delNode(id){{ nodes.remove(id); document.getElementById('form').innerHTML='<p class="muted">Deleted.</p>'; }}
function selectAfter(id){{ setTimeout(()=>{{ net.selectNodes([id]); showForm(id); }}, 50); }}
function addNode(){{ net.addNodeMode(); }}

function addRoom(){{
  const name = prompt('Room / group name:'); if(!name) return;
  const sel = net.getSelectedNodes();
  if(!sel.length){{ alert('Select one or more nodes first, then + Room.'); return; }}
  sel.forEach(id=>nodes.update({{id, room:name}}));
  alert(`Assigned ${{sel.length}} node(s) to room “${{name}}”.`);
}}
function clusterRooms(){{
  rooms().forEach(room=>{{
    net.cluster({{
      joinCondition: o => o.room === room,
      clusterNodeProperties: {{ label:'🏠 '+room, shape:'box',
        color:{{background:'#eaeef2',border:'#57606a'}}, font:{{color:'#1a1a1a'}}, room:room }}
    }});
  }});
}}
function uncluster(){{
  nodes.getIds().forEach(id=>{{ if(net.isCluster(id)) net.openCluster(id); }});
}}

net.on('selectNode', p=>{{ if(p.nodes.length) showForm(p.nodes[0]); }});
net.on('deselectNode', ()=>{{ document.getElementById('form').innerHTML='<p class="muted">No selection.</p>'; }});
net.on('doubleClick', p=>{{ if(p.nodes.length && net.isCluster(p.nodes[0])) net.openCluster(p.nodes[0]); }});

function saveJSON(){{
  const pos = net.getPositions();
  const ns = nodes.get().map(n=>({{...n, ...(pos[n.id]||{{}})}}));
  const blob = new Blob([JSON.stringify({{nodes:ns, edges:edges.get()}}, null, 2)],
                        {{type:'application/json'}});
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'netkit-topology.json'; a.click();
}}
function loadJSON(ev){{
  const f = ev.target.files[0]; if(!f) return;
  const r = new FileReader();
  r.onload = () => {{ try {{ const d=JSON.parse(r.result);
    nodes.clear(); edges.clear(); nodes.add(d.nodes||[]); edges.add(d.edges||[]);
    net.fit(); }} catch(e) {{ alert('Bad JSON: '+e); }} }};
  r.readAsText(f);
}}
function exportPNG(){{
  const a=document.createElement('a');
  a.href=container.querySelector('canvas').toDataURL('image/png');
  a.download='netkit-topology.png'; a.click();
}}
net.fit();
</script>
</body></html>"""
