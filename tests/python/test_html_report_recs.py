"""html_report recommendation rules: 2.4GHz overlapping-channel advice."""
from __future__ import annotations

import re

import html_report


def _base_report(survey_channels):
    return {
        "meta": {"generated_at": "20260101-000000", "tool_version": "x",
                 "schema_version": "1.0.0", "module_errors": []},
        "inventory": {}, "interfaces": {"interfaces": []}, "dns": {"resolvers": []},
        "hosts": {"hosts": [], "count": 0}, "quality": {"targets": []},
        "diagnostics": {"github_https": {"ok": True}}, "topology": {},
        "wifi": {"current": {"security": "WPA3 Personal"},
                 "nearby_aps": [],
                 "survey": {"channels": survey_channels, "recommend_2ghz_channel": 11}},
    }


def _recs_text(report):
    html = html_report.render(report)
    m = re.search(r"<h2>Recommendations</h2>(.*?)</section>", html, re.S)
    return re.sub(r"<[^>]+>", " ", m.group(1)) if m else ""


def test_24ghz_overlap_flagged():
    txt = _recs_text(_base_report({"8": 2, "149": 1}))
    assert "2.4GHz" in txt
    assert "8" in txt
    assert "1, 6 or 11" in txt


def test_24ghz_clean_not_flagged():
    # Only 1 / 6 / 11 (and a 5GHz channel) → no 2.4GHz recommendation.
    txt = _recs_text(_base_report({"1": 1, "11": 1, "149": 2}))
    assert "2.4GHz" not in txt


def _report_with_hosts(hosts):
    r = _base_report({"1": 1})
    r["hosts"] = {"hosts": hosts, "count": len(hosts)}
    return r


def test_iot_segmentation_flagged_with_multiple_cameras():
    hosts = [
        {"ip": "192.168.1.42", "role": "camera"},
        {"ip": "192.168.1.53", "role": "camera"},
        {"ip": "192.168.1.119", "role": "computer"},
    ]
    txt = _recs_text(_report_with_hosts(hosts))
    assert "VLAN" in txt or "guest SSID" in txt
    assert "2 camera" in txt


def test_iot_segmentation_not_flagged_for_single_camera():
    hosts = [
        {"ip": "192.168.1.53", "role": "camera"},
        {"ip": "192.168.1.119", "role": "computer"},
    ]
    txt = _recs_text(_report_with_hosts(hosts))
    assert "separate VLAN" not in txt


def test_mesh_backhaul_flagged_with_aps_and_camera():
    hosts = [
        {"ip": "192.168.1.69", "role": "ap/switch/router"},
        {"ip": "192.168.1.70", "role": "ap/switch/router"},
        {"ip": "192.168.1.53", "role": "camera"},
    ]
    txt = _recs_text(_report_with_hosts(hosts))
    assert "backhaul" in txt
    assert "2 mesh/AP nodes" in txt
