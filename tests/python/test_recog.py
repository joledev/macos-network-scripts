"""Tests for scripts/utils/recog.py — Recog banner → identity matching.

Uses the trimmed XML fixtures under tests/fixtures/recog/ via NETKIT_RECOG_DIR,
so nothing touches the network or the developer's cached DB.
"""
from __future__ import annotations

import importlib

import pytest


@pytest.fixture()
def recog(fixtures_dir, monkeypatch):
    monkeypatch.setenv("NETKIT_RECOG_DIR", str(fixtures_dir / "recog"))
    mod = importlib.import_module("recog")
    mod._DB.clear()          # reset per-file compile memo for a clean read
    return mod


def test_available_true_with_fixtures(recog):
    assert recog.available() is True


def test_available_false_without_db(monkeypatch, tmp_path):
    monkeypatch.setenv("NETKIT_RECOG_DIR", str(tmp_path / "empty"))
    import recog as mod
    mod._DB.clear()
    assert mod.available() is False


def test_identify_apache_with_version(recog):
    hit = recog.identify("http_server", "Apache/2.4.7 (Ubuntu)")
    assert hit["vendor"] == "Apache"
    assert hit["product"] == "HTTPD"
    assert hit["version"] == "2.4.7"


def test_identify_lighttpd(recog):
    hit = recog.identify("http_server", "lighttpd/1.4.35")
    assert hit["vendor"] == "lighttpd"
    assert hit["version"] == "1.4.35"


def test_identify_camera_device_type(recog):
    hit = recog.identify("http_server", "Hipcam RealServer/V1.0")
    assert hit["vendor"] == "Hipcam"
    assert hit["device_type"] == "Webcam"


def test_identify_no_match_returns_empty(recog):
    assert recog.identify("http_server", "nginx") == {}


def test_uncompilable_fingerprint_is_skipped_not_fatal(recog):
    # The fixture has a Ruby-only (?<name>) pattern; loading must not raise and
    # the other fingerprints in the same file must still work.
    assert recog.identify("http_server", "1.0 BadEngine") == {}
    assert recog.identify("http_server", "lighttpd/1.4.35")["vendor"] == "lighttpd"


def test_identify_http_prefers_first_signal(recog):
    hit = recog.identify_http({"server": "lighttpd/1.4.35"})
    assert hit["vendor"] == "lighttpd"


def test_identify_http_title_with_icase_flag(recog):
    # html_title fixture uses REG_ICASE; a lowercased title must still match.
    hit = recog.identify_http({"title": "tp-link wireless n router"})
    assert hit["vendor"] == "TP-Link"
    assert hit["device_type"] == "Router"


def test_label_formats_match(recog):
    assert recog.label({"vendor": "Hipcam", "device_type": "Webcam"}) == "Hipcam [Webcam]"
    assert recog.label({"vendor": "Apache", "product": "HTTPD", "version": "2.4.7"}) \
        == "Apache HTTPD 2.4.7"
    assert recog.label({}) == ""
