"""fdb_topology: MAC→switch→port mapping with uplink/trunk suppression."""
from __future__ import annotations

import fdb_topology

SWITCHES = [{
    "host": "10.0.0.2", "name": "sw-core",
    "bridge_fdb": [
        {"mac": "aa:aa:aa:00:00:01", "port": "5", "port_name": "Gi0/5"},
        {"mac": "aa:aa:aa:00:00:02", "port": "6", "port_name": "Gi0/6"},
        # An uplink/trunk port carrying many MACs:
        {"mac": "bb:bb:bb:00:00:01", "port": "1", "port_name": "Gi0/1"},
        {"mac": "bb:bb:bb:00:00:02", "port": "1", "port_name": "Gi0/1"},
        {"mac": "bb:bb:bb:00:00:03", "port": "1", "port_name": "Gi0/1"},
        {"mac": "bb:bb:bb:00:00:04", "port": "1", "port_name": "Gi0/1"},
    ],
}]
HOSTS = [
    {"ip": "10.0.0.10", "mac": "aa:aa:aa:00:00:01"},
    {"ip": "10.0.0.11", "mac": "AA:AA:AA:00:00:02"},   # mixed case
]


def test_access_ports_map_mac_to_ip_and_port():
    r = fdb_topology.build(SWITCHES, HOSTS)
    by_mac = r["by_mac"]
    assert by_mac["aa:aa:aa:00:00:01"]["ip"] == "10.0.0.10"
    assert by_mac["aa:aa:aa:00:00:01"]["port_name"] == "Gi0/5"
    assert by_mac["aa:aa:aa:00:00:02"]["ip"] == "10.0.0.11"   # case-insensitive match


def test_uplink_port_suppressed():
    r = fdb_topology.build(SWITCHES, HOSTS, uplink_threshold=4)
    # Gi0/1 carries 4 MACs → flagged as uplink, not per-MAC edges.
    assert any(u["port_name"] == "Gi0/1" and u["mac_count"] == 4 for u in r["uplinks"])
    assert all(e["port_name"] != "Gi0/1" for e in r["edges"])


def test_label():
    rec = {"switch_name": "sw-core", "port_name": "Gi0/5"}
    assert fdb_topology.label(rec) == "sw-core:Gi0/5"
    assert fdb_topology.label({}) == ""


def test_empty_inputs():
    r = fdb_topology.build([], [])
    assert r == {"edges": [], "uplinks": [], "by_mac": {}}
