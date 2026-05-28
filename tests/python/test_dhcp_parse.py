"""dhcp_parse: DHCP option extraction (hostname/vendor/fingerprint) + pcab framing."""
from __future__ import annotations

import struct

import dhcp_parse


def _dhcp_msg(mac: bytes, hostname: str, vendor: str, params: list[int],
              msgtype: int = 1) -> bytes:
    m = bytearray()
    m += bytes([1, 1, 6, 0])              # op, htype, hlen, hops
    m += b"\x11\x22\x33\x44"             # xid
    m += b"\x00\x00\x00\x00"            # secs, flags
    m += b"\x00" * 16                    # ciaddr/yiaddr/siaddr/giaddr
    m += mac + b"\x00" * 10              # chaddr (16)
    m += b"\x00" * 64                    # sname
    m += b"\x00" * 128                   # file
    m += dhcp_parse.DHCP_MAGIC
    m += bytes([53, 1, msgtype])
    h = hostname.encode()
    m += bytes([12, len(h)]) + h
    vc = vendor.encode()
    m += bytes([60, len(vc)]) + vc
    m += bytes([55, len(params)]) + bytes(params)
    m += bytes([255])
    return bytes(m)


def _udp(payload: bytes, sport=68, dport=67) -> bytes:
    return struct.pack(">HHHH", sport, dport, len(payload) + 8, 0) + payload


def _ipv4(payload: bytes) -> bytes:
    total = 20 + len(payload)
    return (bytes([0x45, 0, (total >> 8) & 0xFF, total & 0xFF]) + b"\x00" * 5
            + bytes([17]) + b"\x00\x00" + bytes([0, 0, 0, 0]) + bytes([255, 255, 255, 255])
            + payload)


def _eth(payload: bytes, etype=0x0800) -> bytes:
    return (b"\xff\xff\xff\xff\xff\xff" + b"\xaa\xbb\xcc\xdd\xee\xff"
            + struct.pack(">H", etype) + payload)


def _pcap(frames: list[bytes]) -> bytes:
    out = struct.pack("<IHHIIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1)
    for fr in frames:
        out += struct.pack("<IIII", 0, 0, len(fr), len(fr)) + fr
    return out


PARAMS = [1, 3, 6, 15, 26, 28, 51, 58, 59, 43]


def test_parse_dhcp_options():
    msg = _dhcp_msg(b"\xaa\xbb\xcc\xdd\xee\xff", "Joels-iPhone", "android-dhcp-14", PARAMS)
    rec = dhcp_parse.parse_dhcp(msg)
    assert rec["mac"] == "aa:bb:cc:dd:ee:ff"
    assert rec["hostname"] == "Joels-iPhone"
    assert rec["vendor_class"] == "android-dhcp-14"
    assert rec["msg_type"] == "DISCOVER"
    assert rec["param_list"] == PARAMS
    assert rec["fingerprint"] == "1,3,6,15,26,28,51,58,59,43"


def test_parse_dhcp_rejects_non_dhcp():
    assert dhcp_parse.parse_dhcp(b"\x00" * 300) is None


def test_analyze_full_pcap():
    msg = _dhcp_msg(b"\x11\x22\x33\x44\x55\x66", "NAS01", "udhcp 1.0", [1, 3, 6])
    frame = _eth(_ipv4(_udp(msg)))
    recs = dhcp_parse.analyze(_pcap([frame]))
    assert len(recs) == 1
    assert recs[0]["hostname"] == "NAS01"
    assert recs[0]["mac"] == "11:22:33:44:55:66"


def test_analyze_ignores_non_dhcp_udp():
    # UDP to port 53 (DNS) must be skipped.
    frame = _eth(_ipv4(_udp(b"not-dhcp", sport=5353, dport=53)))
    assert dhcp_parse.analyze(_pcap([frame])) == []
