"""starlink_parse: extract the client list from a get_status gRPC reply."""
from __future__ import annotations

import starlink_parse

# Trimmed, masked sample shaped like a real router reply (clients nested under
# wifiGetStatus, schema varies by firmware — the parser searches by key).
SAMPLE = {
    "apiVersion": "126",
    "getStatus": {
        "wifiGetStatus": {
            "clients": [
                {"name": "TC40", "ipAddress": "192.168.1.42",
                 "macAddress": "20:23:51:AA:BB:CC", "iface": "RF_2GHZ",
                 "signalStrength": -62, "snr": 32, "hopsFromController": 1,
                 "upstreamMacAddress": "74:24:9f:5d:ab:b5", "role": "CLIENT",
                 "dhcpLeaseActive": True, "uploadMb": 936, "downloadMb": 35},
                {"name": "haloMeshH30", "ipAddress": "192.168.1.69",
                 "macAddress": "00:EB:D8:00:00:01", "iface": "ETH",
                 "hopsFromController": 1, "role": "CLIENT",
                 "upstreamMacAddress": "74:24:9f:5d:ab:b5"},
                {"name": "Controller", "macAddress": "74:24:9F:5D:AB:B5",
                 "iface": "ETH", "role": "CONTROLLER"},
            ]
        }
    },
}


def test_parse_finds_all_clients():
    clients = starlink_parse.parse_clients(SAMPLE)
    assert len(clients) == 3


def test_band_and_mac_normalized():
    by_ip = {c["ip"]: c for c in starlink_parse.parse_clients(SAMPLE)}
    tc40 = by_ip["192.168.1.42"]
    assert tc40["band"] == "2.4GHz"
    assert tc40["mac"] == "20:23:51:aa:bb:cc"        # lowercased
    assert tc40["signal_dbm"] == -62
    assert tc40["upstream_mac"] == "74:24:9f:5d:ab:b5"
    halo = by_ip["192.168.1.69"]
    assert halo["band"] == "ethernet"


def test_clientless_reply_is_empty():
    assert starlink_parse.parse_clients({"getStatus": {}}) == []
    assert starlink_parse.parse_clients({}) == []


def test_ipless_controller_sorts_last():
    clients = starlink_parse.parse_clients(SAMPLE)
    assert clients[-1]["name"] == "Controller"   # no ipAddress → sorted last
