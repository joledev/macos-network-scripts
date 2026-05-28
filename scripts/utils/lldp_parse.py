"""Parse LLDP and CDP frames out of a classic-format pcap.

Kept dependency-free (stdlib `struct` only) so it can be unit-tested with
synthetic frames and reused by lldp.sh, which captures via `tcpdump -w`.

LLDP frames: EtherType 0x88cc, TLVs are `type(7b) | length(9b)` then value.
CDP frames: 802.3 LLC/SNAP (dst 01:00:0c:cc:cc:cc), TLVs are
`type(2) length(2) value` where length includes the 4-byte header.
"""
from __future__ import annotations

import struct

LLDP_ETHERTYPE = 0x88CC
CDP_DST = "01:00:0c:cc:cc:cc"


def _mac(b: bytes) -> str:
    return ":".join(f"{x:02x}" for x in b)


def _id_str(v: bytes) -> str:
    """LLDP chassis/port id: first byte is a subtype; render MACs as MACs."""
    if not v:
        return ""
    subtype, val = v[0], v[1:]
    if len(val) == 6 and subtype in (4, 3):     # MAC address subtype
        return _mac(val)
    try:
        return val.decode(errors="replace").strip("\x00")
    except Exception:
        return val.hex()


def parse_lldpdu(payload: bytes) -> dict:
    """Parse an LLDP Data Unit (the bytes after the EtherType)."""
    out: dict = {}
    i = 0
    while i + 2 <= len(payload):
        hdr = (payload[i] << 8) | payload[i + 1]
        t = hdr >> 9
        ln = hdr & 0x1FF
        v = payload[i + 2:i + 2 + ln]
        i += 2 + ln
        if t == 0:                       # End of LLDPDU
            break
        if t == 1:
            out["chassis_id"] = _id_str(v)
        elif t == 2:
            out["port_id"] = _id_str(v)
        elif t == 3 and len(v) >= 2:
            out["ttl"] = int.from_bytes(v[:2], "big")
        elif t == 4:
            out["port_desc"] = v.decode(errors="replace").strip("\x00")
        elif t == 5:
            out["system_name"] = v.decode(errors="replace").strip("\x00")
        elif t == 6:
            out["system_desc"] = v.decode(errors="replace").strip("\x00")
        elif t == 7 and len(v) >= 4:
            cap = int.from_bytes(v[0:2], "big")
            out["capabilities"] = _caps(cap)
        elif t == 8 and len(v) >= 1:
            alen = v[0]
            if alen >= 5 and v[1] == 1:           # IPv4 mgmt address
                out["mgmt_address"] = ".".join(str(x) for x in v[2:6])
        elif t == 127 and len(v) >= 4:            # org-specific
            oui, sub = v[:3], v[3]
            data = v[4:]
            if oui == b"\x00\x80\xc2" and sub == 1 and len(data) >= 2:
                out["pvid"] = int.from_bytes(data[:2], "big")   # 802.1 port VLAN
    return out


_CAP_BITS = [(0x01, "other"), (0x02, "repeater"), (0x04, "bridge/switch"),
             (0x08, "wlan-ap"), (0x10, "router"), (0x20, "telephone"),
             (0x40, "docsis"), (0x80, "station")]


def _caps(bits: int) -> list[str]:
    return [name for mask, name in _CAP_BITS if bits & mask]


CDP_TLV = {1: "device_id", 2: "addresses", 3: "port_id", 4: "capabilities",
           5: "software_version", 6: "platform", 10: "native_vlan"}


def parse_cdp(payload: bytes) -> dict:
    """Parse a CDP packet (bytes after the LLC/SNAP header)."""
    out: dict = {}
    if len(payload) < 4:
        return out
    out["cdp_version"] = payload[0]
    out["ttl"] = payload[1]
    i = 4  # skip version, ttl, checksum
    while i + 4 <= len(payload):
        t, ln = struct.unpack(">HH", payload[i:i + 4])
        if ln < 4:
            break
        v = payload[i + 4:i + ln]
        i += ln
        key = CDP_TLV.get(t)
        if not key:
            continue
        if key == "native_vlan" and len(v) >= 2:
            out[key] = int.from_bytes(v[:2], "big")
        elif key in ("addresses", "capabilities"):
            continue  # binary; skip for the summary
        else:
            out[key] = v.decode(errors="replace").strip("\x00")
    return out


def iter_pcap(data: bytes):
    """Yield (ethertype, dst_mac, src_mac, l2_payload) for each pcap record."""
    if len(data) < 24:
        return
    magic = data[:4]
    if magic in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1"):
        end = "<"
    elif magic in (b"\xa1\xb2\xc3\xd4", b"\xa1\xb2\x3c\x4d"):
        end = ">"
    else:
        return
    off = 24
    while off + 16 <= len(data):
        _ts, _us, incl, _orig = struct.unpack(end + "IIII", data[off:off + 16])
        off += 16
        frame = data[off:off + incl]
        off += incl
        if len(frame) < 14:
            continue
        dst = _mac(frame[0:6])
        src = _mac(frame[6:12])
        etype = int.from_bytes(frame[12:14], "big")
        yield etype, dst, src, frame[14:]


def analyze(pcap: bytes) -> dict:
    """Return {lldp:[...], cdp:[...]} parsed from a pcap blob."""
    lldp, cdp = {}, {}
    for etype, dst, src, l2 in iter_pcap(pcap):
        if etype == LLDP_ETHERTYPE:
            rec = parse_lldpdu(l2)
            if rec:
                rec["src_mac"] = src
                lldp[src] = rec
        elif dst.lower() == CDP_DST and etype <= 0x05DC:   # 802.3 length frame
            # LLC AA AA 03 + SNAP (3 OUI + 2 pid); CDP after 8 bytes.
            if len(l2) > 8 and l2[:3] == b"\xaa\xaa\x03":
                rec = parse_cdp(l2[8:])
                if rec:
                    rec["src_mac"] = src
                    cdp[src] = rec
    return {"lldp": list(lldp.values()), "cdp": list(cdp.values())}
