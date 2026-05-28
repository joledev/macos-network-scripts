#!/usr/bin/env python3
"""Minimal OUI (MAC → vendor) lookup with offline fallback.

The IEEE OUI registry is huge; we ship a curated subset of common home/
office vendors so the toolkit works fully offline. For unknown OUIs the
caller can opt into a one-time download (cached to ~/.cache/netkit/oui.txt).
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

# Curated common prefixes (uppercase, no separators). Edit freely.
_BUILTIN_OUI: dict[str, str] = {
    # Apple
    "001124": "Apple", "0017F2": "Apple", "0023DF": "Apple", "002608": "Apple",
    "3C0754": "Apple", "806576": "Apple", "F0DBF8": "Apple", "BC926B": "Apple",
    "F4F5D8": "Apple", "E0F847": "Apple", "B844D9": "Apple",
    # Common routers / vendors
    "002500": "Cisco", "000142": "Cisco", "C8D44C": "Cisco-Linksys",
    "001018": "Broadcom", "000D88": "D-Link", "00179A": "D-Link",
    "B0BE76": "TP-Link", "00141B": "TP-Link", "AC84C6": "TP-Link",
    "001A2B": "Netgear", "1F3F8C": "Netgear",
    "0024A5": "Buffalo",
    "F8E903": "Sagemcom",
    "002327": "Huawei", "F4DB7B": "Huawei",
    "001839": "ZTE",
    # IoT / common SOHO
    "EC1A59": "Belkin", "94103E": "Belkin",
    "DCA632": "Raspberry Pi", "B827EB": "Raspberry Pi", "E45F01": "Raspberry Pi",
    "00163E": "Xensource", "525400": "QEMU/KVM",
    # Smart home
    "CC50E3": "Espressif", "DC4F22": "Espressif", "807D3A": "Espressif",
    "001788": "Philips Hue",
    # Mobile
    "001EC2": "Samsung", "0026E8": "Samsung", "78A873": "Samsung",
    "5C0CCB": "Google", "F4F5E8": "Google",
}


def _normalize(mac: str) -> str:
    return "".join(c for c in mac.upper() if c in "0123456789ABCDEF")[:6]


def _normalize_full(mac: str) -> str:
    return "".join(c for c in mac.upper() if c in "0123456789ABCDEF")[:12]


def mac_kind(mac: str) -> str:
    """Classify a MAC by its first-octet bits (IEEE 802 U/L and I/G bits).

    Returns one of: "universal" (real OUI-assigned), "random/local" (the
    locally-administered bit is set — phones using private/randomized Wi-Fi
    MACs land here, which is WHY their OUI never resolves to a vendor),
    "multicast", or "unknown" (too short / non-hex).
    """
    full = _normalize_full(mac)
    if len(full) < 2:
        return "unknown"
    try:
        first = int(full[:2], 16)
    except ValueError:
        return "unknown"
    if first & 0x01:           # I/G bit — group address
        return "multicast"
    if first & 0x02:           # U/L bit — locally administered
        return "random/local"
    return "universal"


def is_locally_administered(mac: str) -> bool:
    """True when the MAC's locally-administered bit is set (random/private MAC)."""
    return mac_kind(mac) == "random/local"


def lookup(mac: str) -> str:
    full = _normalize_full(mac)
    if len(full) < 6:
        return "Unknown"
    # Wireshark manuf is richest: try MA-S (36-bit) → MA-M (28-bit) → OUI (24-bit).
    manuf = _load_manuf()
    if manuf:
        for nib in (9, 7, 6):
            if len(full) >= nib and full[:nib] in manuf[nib]:
                return manuf[nib][full[:nib]]
    prefix = full[:6]
    if prefix in _BUILTIN_OUI:
        return _BUILTIN_OUI[prefix]
    cache = _load_cache()
    if cache and prefix in cache:
        return cache[prefix]
    return "Unknown"


def _cache_path() -> Path:
    base = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache")))
    return base / "netkit" / "oui.txt"


def _manuf_path() -> Path:
    base = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache")))
    return base / "netkit" / "manuf"


_MANUF_CACHE: dict[int, dict[str, str]] | None = None
_MANUF_LOADED = False


def _load_manuf() -> dict[int, dict[str, str]] | None:
    """Parse the Wireshark `manuf` file into per-prefix-length maps.

    manuf lines: `PREFIX<TAB>short[<TAB>long]`, where PREFIX is `XX:XX:XX`
    (24-bit) or `XX:XX:XX:XX:X0:00/28` (MA-M) or `.../36` (MA-S). We key each
    entry by its hex-nibble count (6/7/9) so lookup can try most-specific first.
    """
    global _MANUF_CACHE, _MANUF_LOADED
    if _MANUF_LOADED:
        return _MANUF_CACHE
    _MANUF_LOADED = True
    p = _manuf_path()
    if not p.is_file():
        _MANUF_CACHE = None
        return None
    by_len: dict[int, dict[str, str]] = {6: {}, 7: {}, 9: {}}
    try:
        with p.open(encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.rstrip("\n")
                if not line or line.startswith("#"):
                    continue
                parts = line.split("\t")
                if len(parts) < 2:
                    continue
                pfx = parts[0].strip()
                name = ""
                if len(parts) >= 3 and parts[2].strip():
                    name = parts[2].strip()
                else:
                    name = parts[1].strip()
                if "/" in pfx:
                    mac_part, _, bits_s = pfx.partition("/")
                    try:
                        bits = int(bits_s)
                    except ValueError:
                        continue
                else:
                    mac_part = pfx
                    bits = (mac_part.count(":") + 1) * 8
                hexs = "".join(c for c in mac_part.upper() if c in "0123456789ABCDEF")
                nib = bits // 4
                if nib in by_len and len(hexs) >= nib:
                    by_len[nib][hexs[:nib]] = name
    except OSError:
        _MANUF_CACHE = None
        return None
    _MANUF_CACHE = by_len if any(by_len.values()) else None
    return _MANUF_CACHE


def _load_cache() -> dict[str, str] | None:
    p = _cache_path()
    if not p.is_file():
        return None
    out: dict[str, str] = {}
    try:
        with p.open(encoding="utf-8", errors="ignore") as f:
            for line in f:
                # Format: "001A2B  Vendor Name"
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split(None, 1)
                if len(parts) == 2:
                    out[_normalize(parts[0])] = parts[1].strip()
    except OSError:
        return None
    return out or None


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: oui.py <mac> [<mac> ...]", file=sys.stderr)
        sys.exit(2)
    for mac in sys.argv[1:]:
        print(f"{mac}\t{lookup(mac)}")
