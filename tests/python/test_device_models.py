"""device_models: Apple code translation + TXT-record identity extraction."""
from __future__ import annotations

import device_models


def test_apple_marketing_name():
    assert "MacBook Air" in device_models.lookup("MacBookAir10,1")


def test_apple_category_fallback_for_unknown_code():
    # Not in the curated map, but the prefix still classifies it.
    out = device_models.lookup("iPhone99,9")
    assert out.startswith("iPhone")
    assert "iPhone99,9" in out


def test_empty_code_returns_empty():
    assert device_models.lookup("") == ""
    assert device_models.lookup("NotAnAppleCode") == ""


def test_identify_airplay_tv():
    txt = {"model": "SmartTV 4K", "manufacturer": "Hisense",
           "fn": "Habitación principal", "deviceid": "95:27:E1:22:B9:B3"}
    ident = device_models.identify(txt, "_airplay._tcp")
    assert ident["manufacturer"] == "Hisense"
    assert ident["model"] == "SmartTV 4K"
    assert ident["friendly_name"] == "Habitación principal"
    assert ident["mac"] == "95:27:e1:22:b9:b3"
    assert "AirPlay" in ident["kind"]


def test_identify_googlecast_md():
    ident = device_models.identify({"md": "Chromecast", "fn": "Living Room"},
                                   "_googlecast._tcp")
    assert ident["model"] == "Chromecast"
    assert ident["kind"].startswith("tv/media")


def test_identify_non_mac_deviceid_dropped():
    # pi/deviceid that isn't a MAC must not be surfaced as one.
    ident = device_models.identify({"deviceid": "not-a-mac", "model": "X"},
                                   "_airplay._tcp")
    assert "mac" not in ident


def test_tplink_camera_tapo_tc_series():
    assert device_models.tplink_camera("TC40") == "TP-Link Tapo camera (TC40)"
    assert device_models.tplink_camera("TC70") == "TP-Link Tapo camera (TC70)"


def test_tplink_camera_tapo_c_series_with_suffix():
    assert device_models.tplink_camera("C320WS") == "TP-Link Tapo camera (C320WS)"
    # Embedded in a longer string (what a user pins or ONVIF returns).
    assert "C320WS" in device_models.tplink_camera("Tapo C320WS Outdoor")


def test_tplink_camera_vigi_business_line():
    assert device_models.tplink_camera("VIGI C340") == "TP-Link VIGI camera (VIGIC340)"


def test_tplink_camera_ignores_non_camera_strings():
    assert device_models.tplink_camera("") == ""
    assert device_models.tplink_camera("iPhone15,2") == ""
    assert device_models.tplink_camera("MacBookAir10,1") == ""
    # Router model codes must not be mistaken for a camera.
    assert device_models.tplink_camera("Archer AX55") == ""
    assert device_models.tplink_camera("AC1200") == ""
