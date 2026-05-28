"""infrastructure: load non-discoverable gear + host→node parent map."""
from __future__ import annotations

import infrastructure

TOML = """
[[node]]
id = "sw-sala"
name = "Switch sala"
type = "switch"
model = "TP-Link TL-SF1005D"
speed = "10/100 Mbps"
location = "Sala"
uplink = "192.168.1.1"
ports = ["192.168.1.21", "192.168.1.69"]

[[node]]
id = "patch-1"
type = "bogus-type"
uplink = "sw-sala"
"""


def test_load_normalizes(tmp_path):
    f = tmp_path / "infrastructure.toml"
    f.write_text(TOML)
    nodes = infrastructure.load(str(f))
    assert len(nodes) == 2
    sw = nodes[0]
    assert sw["id"] == "sw-sala" and sw["type"] == "switch"
    assert sw["ports"] == ["192.168.1.21", "192.168.1.69"]
    assert sw["uplink"] == "192.168.1.1"
    # invalid type falls back to "other"; name defaults to id
    assert nodes[1]["type"] == "other"
    assert nodes[1]["name"] == "patch-1"


def test_host_parent_map(tmp_path):
    f = tmp_path / "infrastructure.toml"
    f.write_text(TOML)
    m = infrastructure.host_parent_map(infrastructure.load(str(f)))
    assert m["192.168.1.21"] == "sw-sala"
    assert m["192.168.1.69"] == "sw-sala"
    assert "10.0.0.1" not in m


def test_load_missing_returns_empty(tmp_path):
    assert infrastructure.load(str(tmp_path / "nope.toml")) == []
