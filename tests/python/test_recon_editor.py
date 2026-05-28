"""recon_editor: self-contained vis-network editor HTML with inlined bundle."""
from __future__ import annotations

import json

import recon_editor

REPORT = {
    "meta": {"generated_at": "20260101-000000"},
    "gateway": "192.168.1.1",
    "dish": {},
    "self_interfaces": [{"device": "en7", "kind": "ethernet", "ipv4": "192.168.1.21",
                         "link_mbps": 100, "max_supported_mbps": 5000}],
    "count": 2,
    "hosts": [
        {"ip": "192.168.1.1", "role": "router/gateway", "display": "Starlink"},
        {"ip": "192.168.1.50", "role": "camera", "vendor": "TP-Link", "ports": [554]},
    ],
}


def test_render_is_self_contained_editor():
    out = recon_editor.render(REPORT)
    assert out.startswith("<!doctype html>")
    assert "vis.Network" in out          # uses vis-network
    assert "manipulation" in out         # editor enabled
    # vendored bundle inlined — no external <script src> / stylesheet refs
    assert "<script src=" not in out
    assert "vis-network" in out          # bundle banner present


def test_graph_has_nodes_and_edges():
    out = recon_editor.render(REPORT)
    blob = out.split("const DATA = ", 1)[1].split(";\n", 1)[0]
    data = json.loads(blob.replace("<\\/", "</"))
    ids = [n["id"] for n in data["nodes"]]
    assert "192.168.1.50" in ids
    assert "internet" in ids
    assert any(e["to"] == "192.168.1.1" for e in data["edges"])
    # roles list drives the type dropdown
    assert "camera" in data["roles"]


def test_editor_actions_present():
    out = recon_editor.render(REPORT)
    for fn in ("saveJSON", "loadJSON", "addRoom", "clusterRooms", "exportPNG"):
        assert fn in out
