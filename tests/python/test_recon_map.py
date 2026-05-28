"""recon_map.render() contract: produces a self-contained HTML map with the
dataset embedded and no CDN dependencies."""
from __future__ import annotations

import json

import recon_map

REPORT = {
    "meta": {"generated_at": "20260101-000000", "kind": "recon"},
    "gateway": "192.168.1.1",
    "subnet": "192.168.1.0/24",
    "interface": "en7",
    "self_interfaces": [
        {"device": "en7", "kind": "ethernet", "ipv4": "192.168.1.21",
         "media": "100baseTX <full-duplex>", "link_mbps": 100,
         "max_supported_mbps": 5000, "is_default_route": True},
    ],
    "wifi": {},
    "dish": {"hardware": "rev3_proto2", "address": "192.168.100.1"},
    "count": 2,
    "hosts": [
        {"ip": "192.168.1.1", "role": "router/gateway", "vendor": "TIBRO",
         "ports": [80], "services": {"80": "http"}},
        {"ip": "192.168.1.50", "role": "camera", "vendor": "TP-Link",
         "ports": [554], "services": {"554": "rtsp"},
         "tls": [{"port": 443, "subject": "CN=TPRI-DEVICE"}]},
    ],
}


def test_render_is_self_contained_html():
    out = recon_map.render(REPORT)
    assert out.startswith("<!doctype html>")
    assert "const DATA" in out
    # no external assets
    assert "http://" not in out.split("const DATA")[0]
    assert "cdn" not in out.lower()


def test_render_includes_nodes_and_roles():
    out = recon_map.render(REPORT)
    assert "192.168.1.50" in out
    assert 'data-role="camera"' in out
    assert "Starlink dish" in out          # dish tier rendered
    assert "This Mac" in out               # self interface rendered


def test_embedded_data_is_valid_json():
    out = recon_map.render(REPORT)
    blob = out.split("const DATA = ", 1)[1].split(";\n", 1)[0]
    data = json.loads(blob.replace("<\\/", "</"))
    assert data["count"] == 2
    assert data["gateway"] == "192.168.1.1"


def test_slow_link_flagged():
    out = recon_map.render(REPORT)
    # en7 negotiated 100 of 5000 -> the self edge must carry the slow class
    assert "slow" in out
