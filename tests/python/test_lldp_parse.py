"""lldp_parse: verify LLDP + CDP TLV decoding and pcap framing with synthetic
frames (no live capture / sudo needed)."""
from __future__ import annotations

import struct

import lldp_parse


def _lldp_tlv(t: int, value: bytes) -> bytes:
    hdr = (t << 9) | (len(value) & 0x1FF)
    return struct.pack(">H", hdr) + value


def _build_lldpdu() -> bytes:
    out = b""
    out += _lldp_tlv(1, bytes([4]) + bytes.fromhex("aabbccddeeff"))   # chassis = MAC
    out += _lldp_tlv(2, bytes([5]) + b"Gi0/1")                        # port id (ifname)
    out += _lldp_tlv(3, struct.pack(">H", 120))                       # ttl
    out += _lldp_tlv(4, b"GigabitEthernet0/1")                        # port desc
    out += _lldp_tlv(5, b"switch01")                                  # system name
    out += _lldp_tlv(6, b"TP-Link JetStream Switch")                  # system desc
    out += _lldp_tlv(7, struct.pack(">HH", 0x0004, 0x0004))           # caps = bridge
    out += _lldp_tlv(8, bytes([5, 1, 192, 168, 1, 2]))               # mgmt ipv4
    out += _lldp_tlv(127, b"\x00\x80\xc2\x01" + struct.pack(">H", 20))  # PVID=20
    out += _lldp_tlv(0, b"")                                          # end
    return out


def _cdp_tlv(t: int, value: bytes) -> bytes:
    return struct.pack(">HH", t, len(value) + 4) + value


def _build_cdp() -> bytes:
    body = bytes([2, 180, 0, 0])  # version, ttl, checksum
    body += _cdp_tlv(1, b"switchA")
    body += _cdp_tlv(3, b"FastEthernet0/1")
    body += _cdp_tlv(6, b"cisco WS-C2960")
    body += _cdp_tlv(10, struct.pack(">H", 2))
    return body


def _eth(dst: bytes, src: bytes, etype_or_len: int, payload: bytes) -> bytes:
    return dst + src + struct.pack(">H", etype_or_len) + payload


def _pcap(frames: list[bytes]) -> bytes:
    out = struct.pack("<IHHIIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1)
    for fr in frames:
        out += struct.pack("<IIII", 0, 0, len(fr), len(fr)) + fr
    return out


def test_lldp_tlvs():
    rec = lldp_parse.parse_lldpdu(_build_lldpdu())
    assert rec["chassis_id"] == "aa:bb:cc:dd:ee:ff"
    assert rec["port_id"] == "Gi0/1"
    assert rec["ttl"] == 120
    assert rec["system_name"] == "switch01"
    assert "TP-Link" in rec["system_desc"]
    assert rec["mgmt_address"] == "192.168.1.2"
    assert rec["pvid"] == 20
    assert "bridge/switch" in rec["capabilities"]


def test_cdp_tlvs():
    rec = lldp_parse.parse_cdp(_build_cdp())
    assert rec["device_id"] == "switchA"
    assert rec["port_id"] == "FastEthernet0/1"
    assert rec["platform"] == "cisco WS-C2960"
    assert rec["native_vlan"] == 2


def test_analyze_pcap_lldp_and_cdp():
    lldpdu = _build_lldpdu()
    lldp_frame = _eth(bytes.fromhex("0180c200000e"), bytes.fromhex("aabbccddeeff"),
                      0x88CC, lldpdu)
    cdp_body = _build_cdp()
    snap = b"\xaa\xaa\x03\x00\x00\x0c\x20\x00"
    cdp_payload = snap + cdp_body
    cdp_frame = _eth(bytes.fromhex("01000ccccccc"), bytes.fromhex("112233445566"),
                     len(cdp_payload), cdp_payload)
    res = lldp_parse.analyze(_pcap([lldp_frame, cdp_frame]))
    assert res["lldp"] and res["lldp"][0]["system_name"] == "switch01"
    assert res["lldp"][0]["src_mac"] == "aa:bb:cc:dd:ee:ff"
    assert res["cdp"] and res["cdp"][0]["device_id"] == "switchA"


def test_empty_pcap():
    assert lldp_parse.analyze(b"") == {"lldp": [], "cdp": []}
