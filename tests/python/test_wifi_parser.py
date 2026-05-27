"""Tests for scripts/utils/wifi_parser.py — system_profiler SPAirPortDataType parse."""
from __future__ import annotations

import wifi_parser


def test_parse_minimal_returns_schema():
    """Empty input still returns the full schema (defaults filled)."""
    r = wifi_parser.parse("")
    assert r["interface"] == ""
    assert r["mac"] == ""
    assert r["country_code"] == ""
    assert r["phy_modes"] == ""
    assert r["current"]["ssid"] == ""
    assert r["nearby_aps"] == []


def test_parse_fixture_extracts_interface_and_macaddr(fixtures_dir):
    """Real macOS 26 system_profiler output (anonymized: SSIDs are
    auto-redacted by macOS, MAC is the user's en0)."""
    text = (fixtures_dir / "system_profiler_airport.txt").read_text()
    r = wifi_parser.parse(text)
    assert r["interface"] == "en0"
    assert r["mac"] != ""              # macOS shows the real MAC for en0
    assert ":" in r["mac"]
    assert r["country_code"] == "MX"


def test_parse_fixture_extracts_current_network(fixtures_dir):
    text = (fixtures_dir / "system_profiler_airport.txt").read_text()
    r = wifi_parser.parse(text)
    cur = r["current"]
    # macOS redacts the SSID in system_profiler output since macOS 14.
    assert cur["ssid"] == "<redacted>"
    assert cur["phy_mode"].startswith("802.11")
    assert cur["channel"]              # non-empty
    assert cur["band"] in {"2GHz", "5GHz", "6GHz"}
    assert cur["security"]             # non-empty
    assert isinstance(cur["signal_dbm"], int)
    assert isinstance(cur["noise_dbm"], int)
    assert cur["noise_dbm"] < 0        # noise floor is always negative dBm
    assert isinstance(cur["tx_rate_mbps"], int)


def test_parse_fixture_extracts_nearby_aps(fixtures_dir):
    text = (fixtures_dir / "system_profiler_airport.txt").read_text()
    r = wifi_parser.parse(text)
    assert isinstance(r["nearby_aps"], list)
    # The user has a neighborhood with at least a few APs visible.
    assert len(r["nearby_aps"]) >= 1
    for ap in r["nearby_aps"]:
        # Every entry should have channel and security (the filter drops
        # interface-looking entries that lack both).
        assert ap["channel"] or ap["security"]


def test_parse_drops_interfaces_from_nearby(fixtures_dir):
    """awdl0 / llw0 / similar are NOT real APs and must not appear in
    nearby_aps even when system_profiler lists them with trailing colons."""
    text = (fixtures_dir / "system_profiler_airport.txt").read_text()
    r = wifi_parser.parse(text)
    ssids = {a["ssid"] for a in r["nearby_aps"]}
    assert "awdl0" not in ssids
    assert "llw0"  not in ssids


def test_co_channel_count_with_match():
    """If current = ch 149 and 2 nearby APs are on ch 149, co_channel_count = 2."""
    r = {
        "current": {"channel": "149 (5GHz, 80MHz)"},
        "nearby_aps": [
            {"channel": "149 (5GHz, 80MHz)", "security": "WPA2"},
            {"channel": "6 (2GHz)",          "security": "WPA2"},
            {"channel": "149 (5GHz, 80MHz)", "security": "WPA3"},
        ],
    }
    assert wifi_parser.co_channel_count(r) == 2


def test_co_channel_count_no_current_channel():
    assert wifi_parser.co_channel_count({"current": {"channel": ""}, "nearby_aps": []}) == 0


def test_apply_field_parses_channel_band_width():
    ap = {"phy_mode": "", "channel": "", "band": "", "channel_width": "",
          "security": "", "signal_dbm": None, "noise_dbm": None, "tx_rate_mbps": None}
    wifi_parser._apply_field(ap, "Channel", "149 (5GHz, 80MHz)")
    assert ap["channel"] == "149 (5GHz, 80MHz)"
    assert ap["band"] == "5GHz"
    assert ap["channel_width"] == "80MHz"


def test_apply_field_parses_signal_noise():
    ap = {"signal_dbm": None, "noise_dbm": None}
    wifi_parser._apply_field(ap, "Signal / Noise", "-42 dBm / -88 dBm")
    assert ap["signal_dbm"] == -42
    assert ap["noise_dbm"] == -88


def test_apply_field_ignores_non_numeric_tx_rate():
    """Some macOS versions write "Transmit Rate: unknown" — don't crash."""
    ap = {"tx_rate_mbps": None}
    wifi_parser._apply_field(ap, "Transmit Rate", "unknown")
    assert ap["tx_rate_mbps"] is None
