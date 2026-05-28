"""Render a netkit recon dataset as a draw.io / diagrams.net file (.drawio).

Emits an uncompressed mxGraphModel wrapped in <mxfile>, which draw.io opens
directly — giving a full editor (move/group/restyle, network shape libraries,
add rooms/racks, assign fields) on top of the discovered topology.
"""
from __future__ import annotations

import html
from typing import Any

try:
    from recon_map import ROLE_COLORS, DEFAULT_COLOR, _node_name
except Exception:  # pragma: no cover - standalone fallback
    ROLE_COLORS = {}
    DEFAULT_COLOR = "#8c959f"

    def _node_name(rec):
        return rec.get("display") or rec.get("vendor") or rec.get("ip", "")


def _esc(s: Any) -> str:
    return html.escape(str(s if s is not None else ""), quote=True)


# draw.io reads value="" as an XML attribute, then (with html=1) renders its
# decoded content as HTML. So markup must be double-escaped: "<br>" lives in the
# attribute as "&lt;br&gt;" and decodes back to a real <br> at render time.
BR = "&lt;br&gt;"
B0, B1 = "&lt;b&gt;", "&lt;/b&gt;"


def _color(role: str) -> str:
    return ROLE_COLORS.get(role, DEFAULT_COLOR)


def _cell(cid, value, style, x, y, w, h, parent="1"):
    return (f'<mxCell id="{_esc(cid)}" value="{value}" style="{style}" '
            f'vertex="1" parent="{_esc(parent)}">'
            f'<mxGeometry x="{x}" y="{y}" width="{w}" height="{h}" as="geometry"/>'
            f'</mxCell>')


def _edge(cid, src, dst, style="edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;"):
    return (f'<mxCell id="{_esc(cid)}" style="{style}" edge="1" parent="1" '
            f'source="{_esc(src)}" target="{_esc(dst)}">'
            f'<mxGeometry relative="1" as="geometry"/></mxCell>')


def _label(rec) -> str:
    name = _node_name(rec)
    parts = [_esc(rec.get("ip", ""))]
    if name and name != rec.get("ip"):
        parts.append(_esc(name))
    ident = rec.get("identity")
    if ident and _esc(ident) not in parts:
        parts.append(_esc(ident))
    if rec.get("ports"):
        parts.append(_esc("ports " + "/".join(str(p) for p in rec["ports"][:6])))
    return BR.join(parts)


def render(report: dict) -> str:
    hosts = report.get("hosts", [])
    gw = report.get("gateway", "")
    dish = report.get("dish") or {}
    self_ifaces = report.get("self_interfaces", [])

    others = [h for h in hosts if h["ip"] != gw]
    gw_rec = next((h for h in hosts if h["ip"] == gw), None)

    bw, bh = 200, 70
    gapx, gapy = 60, 70
    per_row = max(4, min(6, len(others))) if others else 1
    width = per_row * (bw + gapx)
    cx = width // 2

    cells = []

    def nid(ip):
        return "node-" + ip.replace(".", "-")

    y = 40
    # Internet
    cells.append(_cell("internet", "Internet",
                       "ellipse;whiteSpace=wrap;html=1;fillColor=#1a1a1a;fontColor=#fff;",
                       cx - 60, y, 120, 50))
    prev = "internet"
    y += 50 + gapy
    if dish:
        cells.append(_cell("dish", f'Starlink dish{BR}{_esc(dish.get("hardware",""))}',
                           "rounded=1;whiteSpace=wrap;html=1;fillColor=#1f6feb;fontColor=#fff;",
                           cx - bw // 2, y, bw, bh))
        cells.append(_edge("e-inet-dish", prev, "dish"))
        prev = "dish"
        y += bh + gapy

    gw_id = nid(gw) if gw else "gateway"
    gw_label = (_label(gw_rec) if gw_rec else _esc(gw)) or "Gateway"
    cells.append(_cell(gw_id, f"Router / Gateway{BR}{gw_label}",
                       f"rounded=1;whiteSpace=wrap;html=1;fillColor={_color('router/gateway')};fontColor=#fff;",
                       cx - bw // 2, y, bw, bh))
    cells.append(_edge("e-up-gw", prev, gw_id))
    gw_y = y
    y += bh + gapy + 30

    # self (this Mac)
    for i, sif in enumerate(self_ifaces):
        sid = "self-" + sif["device"]
        spd = sif.get("link_mbps")
        cap = sif.get("max_supported_mbps")
        warn = f"{BR}{B0}LINK {spd}/{cap} Mbps{B1}" if (spd and cap and spd < cap) else ""
        cells.append(_cell(sid, f'This Mac{BR}{_esc(sif["device"])} {_esc(sif.get("kind",""))}'
                                f'{BR}{_esc(sif.get("ipv4",""))}{warn}',
                           "rounded=1;whiteSpace=wrap;html=1;fillColor=#fff8c5;",
                           60 + i * (bw + gapx), gw_y, bw, bh))
        cells.append(_edge(f"e-self-{i}", sid, gw_id,
                           "edgeStyle=orthogonalEdgeStyle;html=1;dashed=1;"))

    # device tier(s)
    for idx, rec in enumerate(others):
        row, col = divmod(idx, per_row)
        nx = col * (bw + gapx) + (gapx // 2)
        ny = y + row * (bh + gapy)
        cells.append(_cell(nid(rec["ip"]), _label(rec),
                           f"rounded=1;whiteSpace=wrap;html=1;fillColor={_color(rec.get('role',''))};fontColor=#fff;",
                           nx, ny, bw, bh))
        cells.append(_edge(f"e-{idx}", gw_id, nid(rec["ip"])))

    body = "".join(cells)
    model = (f'<mxGraphModel dx="800" dy="600" grid="1" gridSize="10" guides="1" '
             f'tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" '
             f'math="0" shadow="0"><root>'
             f'<mxCell id="0"/><mxCell id="1" parent="0"/>{body}</root></mxGraphModel>')
    ts = report.get("meta", {}).get("generated_at", "recon")
    return (f'<mxfile host="netkit" type="device">'
            f'<diagram name="netkit recon {_esc(ts)}">{model}</diagram></mxfile>')
