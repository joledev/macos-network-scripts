"""Parse `system_profiler SPAirPortDataType` plain-text output into a dict.

Extracted from scripts/diagnostics/wifi.sh so it can be unit-tested with a
fixture (`tests/fixtures/system_profiler_airport.txt`). The wifi.sh heredoc
imports this and calls parse(text).

The output schema:
    {
        "interface":     "en0",
        "mac":           "ab:cd:...",
        "country_code":  "MX",
        "phy_modes":     "802.11 a/b/g/n/ac/ax",
        "current":       { "ssid", "phy_mode", "channel", "band",
                           "channel_width", "security",
                           "signal_dbm", "noise_dbm", "tx_rate_mbps" },
        "nearby_aps":    [ same shape minus interface fields ],
    }
"""
from __future__ import annotations

import contextlib
import re
from typing import Any

_SSID_HEADING = re.compile(r"^[^:]+:$")
_CHANNEL      = re.compile(r"(\d+)\s*\(([^,]+)(?:,\s*(\S+))?\)")
_SIGNOISE     = re.compile(r"(-?\d+)\s*dBm\s*/\s*(-?\d+)\s*dBm")
_IFACE        = re.compile(r"^en\d+:$")


def _empty_ap() -> dict[str, Any]:
    return {
        "ssid": "", "phy_mode": "", "channel": "", "band": "",
        "channel_width": "", "security": "",
        "signal_dbm": None, "noise_dbm": None, "tx_rate_mbps": None,
    }


def _apply_field(ap: dict, key: str, value: str) -> None:
    if key == "PHY Mode":
        ap["phy_mode"] = value
    elif key == "Channel":
        ap["channel"] = value
        m = _CHANNEL.match(value)
        if m:
            ap["band"] = m.group(2).strip()
            if m.group(3):
                ap["channel_width"] = m.group(3).strip()
    elif key == "Security":
        ap["security"] = value
    elif key == "Signal / Noise":
        m = _SIGNOISE.search(value)
        if m:
            ap["signal_dbm"] = int(m.group(1))
            ap["noise_dbm"]  = int(m.group(2))
    elif key == "Transmit Rate":
        with contextlib.suppress(ValueError):
            ap["tx_rate_mbps"] = int(value)


def parse(text: str) -> dict[str, Any]:
    """Parse the output of `system_profiler SPAirPortDataType`."""
    result: dict[str, Any] = {
        "interface": "", "mac": "", "country_code": "", "phy_modes": "",
        "current": _empty_ap(),
        "nearby_aps": [],
    }
    result["current"].pop("ssid")  # we'll set below; just keeping schema uniform
    result["current"] = {"ssid": "", **_empty_ap()}
    # Strip the stub-ssid duplicate, simpler:
    result["current"]["ssid"] = ""

    section: str | None = None
    target: dict | None = None

    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        stripped = line.strip()
        if not stripped:
            continue

        # Section switches.
        if stripped == "Current Network Information:":
            section = "current"
            target = None
            continue
        if stripped == "Other Local Wi-Fi Networks:":
            section = "nearby"
            target = None
            continue

        # Top-level interface-scoped attrs.
        if _IFACE.match(stripped):
            result["interface"] = stripped.rstrip(":")
            continue
        if stripped.startswith("MAC Address:"):
            result["mac"] = stripped.split(":", 1)[1].strip()
            continue
        if stripped.startswith("Country Code:") and not result["country_code"]:
            result["country_code"] = stripped.split(":", 1)[1].strip()
            continue
        if stripped.startswith("Supported PHY Modes:"):
            result["phy_modes"] = stripped.split(":", 1)[1].strip()
            continue

        # Section-specific.
        if section == "current":
            if _SSID_HEADING.match(stripped):
                result["current"]["ssid"] = stripped.rstrip(":")
                target = result["current"]
            elif ":" in stripped and target is not None:
                key, _, val = stripped.partition(":")
                _apply_field(target, key.strip(), val.strip())
        elif section == "nearby":
            if _SSID_HEADING.match(stripped):
                ap = {"ssid": stripped.rstrip(":"), **_empty_ap()}
                ap["ssid"] = stripped.rstrip(":")
                result["nearby_aps"].append(ap)
                target = ap
            elif ":" in stripped and target is not None:
                key, _, val = stripped.partition(":")
                _apply_field(target, key.strip(), val.strip())

    # Filter out interfaces (awdl0/llw0 etc.) that fell into "nearby" by
    # virtue of having a trailing colon.
    result["nearby_aps"] = [
        a for a in result["nearby_aps"]
        if a.get("channel") or a.get("security")
    ]
    return result


def co_channel_count(result: dict[str, Any]) -> int:
    """Number of nearby APs sharing the connected channel."""
    ch = result.get("current", {}).get("channel", "")
    m = re.match(r"(\d+)", ch)
    if not m:
        return 0
    num = m.group(1)
    return sum(
        1 for a in result.get("nearby_aps", [])
        if re.match(rf"^{num}\b", a.get("channel", ""))
    )


if __name__ == "__main__":   # pragma: no cover
    import json
    import sys
    print(json.dumps(parse(sys.stdin.read()), indent=2))
