"""drawio_export: valid mxGraphModel XML with a node per host."""
from __future__ import annotations

import xml.dom.minidom as minidom

import drawio_export

REPORT = {
    "meta": {"generated_at": "20260101-000000"},
    "gateway": "192.168.1.1",
    "dish": {"hardware": "rev3", "address": "192.168.100.1"},
    "self_interfaces": [{"device": "en7", "kind": "ethernet", "ipv4": "192.168.1.21",
                         "link_mbps": 100, "max_supported_mbps": 5000}],
    "count": 2,
    "hosts": [
        {"ip": "192.168.1.1", "role": "router/gateway", "display": "Starlink"},
        {"ip": "192.168.1.50", "role": "camera", "vendor": "TP-Link",
         "ports": [554], "identity": "TP-Link Cam"},
    ],
}


def test_render_is_valid_xml():
    xml = drawio_export.render(REPORT)
    dom = minidom.parseString(xml)              # raises if malformed
    assert dom.getElementsByTagName("mxfile")
    assert dom.getElementsByTagName("mxGraphModel")


def test_has_cell_per_host_plus_scaffold():
    xml = drawio_export.render(REPORT)
    dom = minidom.parseString(xml)
    cells = dom.getElementsByTagName("mxCell")
    # 2 scaffold cells (0,1) + internet + dish + gateway + self + 1 device + edges
    ids = [c.getAttribute("id") for c in cells]
    assert "node-192-168-1-50" in ids
    assert "node-192-168-1-1" in ids
    assert "dish" in ids


def test_labels_escaped_not_raw_markup():
    xml = drawio_export.render(REPORT)
    # <br> must be entity-escaped inside value="" so the XML stays well-formed.
    assert "value=\"Router" in xml or "value=\"Starlink" in xml
    assert "&lt;br&gt;" in xml


def test_infrastructure_node_rendered():
    import xml.dom.minidom as minidom
    rep = dict(REPORT)
    rep["infrastructure"] = [{"id": "sw-sala", "name": "Switch sala", "type": "switch",
                              "model": "TL-SF1005D", "parent": "192.168.1.1", "ports": []}]
    xml = drawio_export.render(rep)
    minidom.parseString(xml)             # still well-formed
    assert "Switch sala" in xml
    assert "inf-sw-sala" in xml
