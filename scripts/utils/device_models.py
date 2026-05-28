"""Translate device model codes (mostly from mDNS/Bonjour TXT records) into
human-readable identities.

Two layers:
  * apple_category(code)  — robust prefix → product family (iPhone/iPad/Mac/...)
  * APPLE_MARKETING       — curated exact code → marketing name (common recent
                            devices); extend freely, lookup() falls back to the
                            family + raw code when a code isn't listed.

Non-Apple devices generally put a readable string in TXT already
(e.g. Chromecast `md=`, AirPlay `model=`/`manufacturer=`), so identify() just
surfaces those.
"""
from __future__ import annotations

import re

# Curated common Apple machine-id → marketing name. Not exhaustive on purpose;
# apple_category() handles anything not listed. Extend as needed.
APPLE_MARKETING = {
    # Apple silicon Macs
    "MacBookAir10,1": "MacBook Air (M1, 2020)",
    "Mac14,2": "MacBook Air (M2, 2022)",
    "Mac15,12": "MacBook Air (M3, 2024)",
    "MacBookPro17,1": "MacBook Pro (13-inch, M1, 2020)",
    "Mac14,7": "MacBook Pro (13-inch, M2, 2022)",
    "Mac14,5": "MacBook Pro (14-inch, M2 Pro/Max, 2023)",
    "Mac15,3": "MacBook Pro (14-inch, M3, 2023)",
    "Macmini9,1": "Mac mini (M1, 2020)",
    "Mac14,3": "Mac mini (M2, 2023)",
    "iMac21,1": "iMac (24-inch, M1, 2021)",
    "Mac13,1": "Mac Studio (M1 Max, 2022)",
    # Apple TV
    "AppleTV5,3": "Apple TV HD",
    "AppleTV6,2": "Apple TV 4K (1st gen)",
    "AppleTV11,1": "Apple TV 4K (2nd gen)",
    "AppleTV14,1": "Apple TV 4K (3rd gen)",
    # HomePod
    "AudioAccessory1,1": "HomePod",
    "AudioAccessory5,1": "HomePod mini",
    "AudioAccessory6,1": "HomePod (2nd gen)",
    # iPhone (recent)
    "iPhone12,1": "iPhone 11",
    "iPhone13,2": "iPhone 12",
    "iPhone14,5": "iPhone 13",
    "iPhone14,7": "iPhone 14",
    "iPhone15,2": "iPhone 14 Pro",
    "iPhone15,4": "iPhone 15",
    "iPhone16,1": "iPhone 15 Pro",
    "iPhone17,3": "iPhone 16",
    # iPad
    "iPad13,1": "iPad Air (4th gen)",
    "iPad13,16": "iPad Air (5th gen, M1)",
    "iPad14,1": "iPad mini (6th gen)",
}

_APPLE_PREFIX = [
    ("iPhone", "iPhone"),
    ("iPad", "iPad"),
    ("iPod", "iPod touch"),
    ("Watch", "Apple Watch"),
    ("AppleTV", "Apple TV"),
    ("AudioAccessory", "HomePod"),
    ("MacBookAir", "MacBook Air"),
    ("MacBookPro", "MacBook Pro"),
    ("MacBook", "MacBook"),
    ("Macmini", "Mac mini"),
    ("MacPro", "Mac Pro"),
    ("iMacPro", "iMac Pro"),
    ("iMac", "iMac"),
    ("Mac", "Mac"),  # generic Apple-silicon "Mac14,2" etc — keep last
]


def apple_category(code: str) -> str:
    """Map an Apple machine-id (e.g. 'iPhone14,5') to its product family."""
    if not code:
        return ""
    for prefix, name in _APPLE_PREFIX:
        if code.startswith(prefix):
            return name
    return ""


def lookup(code: str) -> str:
    """Marketing name if known, else 'Family (code)', else ''."""
    if not code:
        return ""
    if code in APPLE_MARKETING:
        return APPLE_MARKETING[code]
    cat = apple_category(code)
    if cat:
        return f"{cat} ({code})"
    return ""


# TXT keys that carry a model, in priority order, per service flavor.
_MODEL_KEYS = ["model", "am", "md", "usb_MDL", "product", "ty", "MODEL"]
_VENDOR_KEYS = ["manufacturer", "integrator", "usb_MFG", "vendor", "MFG"]
_NAME_KEYS = ["fn", "ty", "n", "FriendlyName"]
_SERIAL_KEYS = ["serialNumber", "SN", "ssn"]
_MAC_KEYS = ["deviceid", "pi", "mac"]


def _first(txt: dict, keys) -> str:
    for k in keys:
        if txt.get(k):
            return str(txt[k]).strip()
    return ""


def identify(txt: dict, service: str = "") -> dict:
    """Distill a TXT dict (+ optional service type) into a device identity:
    {model, model_name, manufacturer, friendly_name, serial, mac, kind}."""
    txt = txt or {}
    model = _first(txt, _MODEL_KEYS)
    vendor = _first(txt, _VENDOR_KEYS)
    name = _first(txt, _NAME_KEYS)
    serial = _first(txt, _SERIAL_KEYS)
    mac = _first(txt, _MAC_KEYS)
    if mac and not re.match(r"^[0-9a-fA-F]{2}([:-][0-9a-fA-F]{2}){5}$", mac):
        mac = ""  # pi/deviceid aren't always MACs

    # Apple machine-ids translate to a marketing name.
    model_name = lookup(model)

    kind = ""
    svc = service.lower()
    if "_googlecast" in svc:
        kind = "tv/media (Cast)"
    elif "_airplay" in svc or "_raop" in svc:
        kind = "tv/media (AirPlay)"
    elif "_ipp" in svc or "_printer" in svc or "_pdl" in svc:
        kind = "printer"
    elif "_hap" in svc:
        kind = "homekit accessory"
    elif "_smb" in svc:
        kind = "file server"
    elif "_sonos" in svc:
        kind = "speaker (Sonos)"
    elif apple_category(model):
        kind = "apple device"

    out = {}
    for key, val in (("model", model), ("model_name", model_name),
                     ("manufacturer", vendor), ("friendly_name", name),
                     ("serial", serial), ("mac", mac.lower()), ("kind", kind)):
        if val:
            out[key] = val
    return out
