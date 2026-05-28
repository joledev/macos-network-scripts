"""devices: config load, env-secret resolution, password redaction."""
from __future__ import annotations

import devices

TOML = """
[[device]]
name = "AP"
host = "192.168.1.42"
type = "http"
user = "admin"
pass = "env:AP_PASS"
url  = "https://192.168.1.42/"

[[device]]
host = "192.168.1.1"
type = "ssh"
"""


def test_resolve_secret_env(monkeypatch):
    monkeypatch.setenv("AP_PASS", "s3cret")
    assert devices.resolve_secret("env:AP_PASS") == "s3cret"
    assert devices.resolve_secret("inline") == "inline"
    assert devices.resolve_secret(None) == ""


def test_resolve_secret_missing_env(monkeypatch):
    monkeypatch.delenv("NOPE", raising=False)
    assert devices.resolve_secret("env:NOPE") == ""


def test_redact():
    assert devices.redact("user=admin pass=s3cret done", "s3cret") == "user=admin pass=*** done"
    assert devices.redact("nothing", "") == "nothing"


def test_load_resolves_and_defaults(tmp_path, monkeypatch):
    monkeypatch.setenv("AP_PASS", "topsecret")
    f = tmp_path / "devices.toml"
    f.write_text(TOML)
    devs = devices.load(str(f))
    assert len(devs) == 2
    ap = devs[0]
    assert ap["name"] == "AP" and ap["host"] == "192.168.1.42"
    assert ap["password"] == "topsecret"      # env resolved
    assert ap["type"] == "http"
    second = devs[1]
    assert second["name"] == "192.168.1.1"     # name defaults to host
    assert second["type"] == "ssh"
    assert second["port"] == 22
    assert second["commands"]                  # default read-only command set


def test_load_missing_file_returns_empty(tmp_path):
    assert devices.load(str(tmp_path / "nope.toml")) == []
