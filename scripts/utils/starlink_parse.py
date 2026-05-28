"""Parse the Starlink router's get_status gRPC reply into a flat client list.

The Starlink router (gen-2/gen-3) answers an anonymous get_status on :9000 with
a nested structure; the connected-client array lives a few levels down under
wifiGetStatus and the exact path shifts between firmware builds, so we search
for it by key. Each client carries the band (ETH/2.4/5 GHz), per-client RSSI,
and — crucially — upstreamMacAddress + hopsFromController, which reveal the
real mesh topology (who associates with which node).

Stdlib only, so it can be unit-tested with a synthetic reply and reused by both
starlink_clients.sh and recon.sh.
"""
from __future__ import annotations

BAND = {"ETH": "ethernet", "RF_2GHZ": "2.4GHz", "RF_5GHZ": "5GHz"}


def _find(obj, key):
    """Depth-first search for the first value stored under `key`."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == key:
                return v
            r = _find(v, key)
            if r is not None:
                return r
    elif isinstance(obj, list):
        for i in obj:
            r = _find(i, key)
            if r is not None:
                return r
    return None


def parse_clients(data: dict) -> list[dict]:
    """Return a normalized client list from a parsed get_status reply."""
    raw = _find(data, "clients") or []
    out: list[dict] = []
    for c in raw:
        if not isinstance(c, dict):
            continue
        iface = c.get("iface", "")
        out.append({
            "name": c.get("name", ""),
            "ip": c.get("ipAddress", ""),
            "mac": (c.get("macAddress", "") or "").lower(),
            "iface": iface,
            "band": BAND.get(iface, iface),
            "signal_dbm": c.get("signalStrength"),
            "snr": c.get("snr"),
            "upstream_mac": (c.get("upstreamMacAddress", "") or "").lower(),
            "hops": c.get("hopsFromController"),
            "role": c.get("role", ""),
            "dhcp_active": c.get("dhcpLeaseActive"),
            "upload_mb": c.get("uploadMb"),
            "download_mb": c.get("downloadMb"),
            "associated_s": c.get("associatedTimeS"),
        })
    out.sort(key=lambda c: (c["ip"] == "", c["ip"]))
    return out
