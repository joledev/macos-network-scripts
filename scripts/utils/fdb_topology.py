"""Compute port-level topology (Netdisco-style) from switch bridge-forwarding
tables + the recon host inventory: which switch/port each device's MAC sits on.

Pure function so it's unit-testable without SNMP. A port carrying many distinct
MACs is treated as an uplink/trunk (a path to another switch), not an access
port, so we don't attribute every MAC to it.
"""
from __future__ import annotations


def build(switches: list[dict], hosts: list[dict], uplink_threshold: int = 4) -> dict:
    """
    switches: [{ host, name, bridge_fdb: [{mac, port, port_name}] }]
    hosts:    recon hosts [{ ip, mac, ... }]
    Returns: { edges:[{mac,ip,switch,switch_name,port,port_name}],
               uplinks:[{switch,switch_name,port,port_name,mac_count}],
               by_mac:{ mac: {switch,port_name,...} } }
    """
    mac_to_ip = {h["mac"].lower(): h["ip"]
                 for h in hosts if h.get("mac") and h.get("ip")}

    edges: list[dict] = []
    uplinks: list[dict] = []
    by_mac: dict[str, dict] = {}

    for sw in switches:
        sw_host = sw.get("host", "")
        sw_name = sw.get("name", "") or sw_host
        by_port: dict[tuple, list[str]] = {}
        for e in sw.get("bridge_fdb", []):
            mac = (e.get("mac") or "").lower()
            if not mac:
                continue
            by_port.setdefault((e.get("port", ""), e.get("port_name", "")), []).append(mac)

        for (port, pname), macs in by_port.items():
            uniq = sorted(set(macs))
            if len(uniq) >= uplink_threshold:
                uplinks.append({"switch": sw_host, "switch_name": sw_name,
                                "port": port, "port_name": pname,
                                "mac_count": len(uniq)})
                continue
            for mac in uniq:
                rec = {"mac": mac, "ip": mac_to_ip.get(mac, ""),
                       "switch": sw_host, "switch_name": sw_name,
                       "port": port, "port_name": pname}
                edges.append(rec)
                # First (non-uplink) sighting wins for the per-MAC summary.
                by_mac.setdefault(mac, rec)

    return {"edges": edges, "uplinks": uplinks, "by_mac": by_mac}


def label(rec: dict) -> str:
    """Short 'switch:port' label for a by_mac entry."""
    if not rec:
        return ""
    port = rec.get("port_name") or rec.get("port") or "?"
    return f"{rec.get('switch_name') or rec.get('switch')}:{port}"
