"""Tests for scripts/utils/known_hosts.py — friendly name / role lookup."""
from __future__ import annotations


import known_hosts


def _write_toml(path, body):
    path.write_text(body)
    return path


def test_no_config_returns_empty(tmp_path, monkeypatch):
    monkeypatch.setenv("NETKIT_KNOWN_HOSTS", str(tmp_path / "missing.toml"))
    monkeypatch.delenv("NETKIT_ROOT", raising=False)
    monkeypatch.setattr(known_hosts, "_CACHE", None)
    assert known_hosts.lookup(ip="192.168.1.1") == {}


def test_lookup_by_ip(tmp_path, monkeypatch):
    f = _write_toml(tmp_path / "k.toml", """
[hosts]
"192.168.1.67" = { name = "desktop-jole", role = "workstation" }
""")
    monkeypatch.setenv("NETKIT_KNOWN_HOSTS", str(f))
    monkeypatch.setattr(known_hosts, "_CACHE", None)
    assert known_hosts.lookup(ip="192.168.1.67") == {
        "name": "desktop-jole", "role": "workstation",
    }


def test_lookup_by_mac_padded(tmp_path, monkeypatch):
    """Single-digit MAC octets should normalize to two digits before matching."""
    f = _write_toml(tmp_path / "k.toml", """
[hosts]
"0f:00:01:aa:bb:cc" = { name = "padme" }
""")
    monkeypatch.setenv("NETKIT_KNOWN_HOSTS", str(f))
    monkeypatch.setattr(known_hosts, "_CACHE", None)
    assert known_hosts.lookup(mac="f:0:1:aa:bb:cc") == {"name": "padme"}


def test_lookup_miss_returns_empty(tmp_path, monkeypatch):
    f = _write_toml(tmp_path / "k.toml", """
[hosts]
"192.168.1.67" = { name = "desktop" }
""")
    monkeypatch.setenv("NETKIT_KNOWN_HOSTS", str(f))
    monkeypatch.setattr(known_hosts, "_CACHE", None)
    assert known_hosts.lookup(ip="10.0.0.1") == {}


def test_string_value_is_treated_as_name(tmp_path, monkeypatch):
    """The TOML allows `"ip" = "name"` shorthand."""
    f = _write_toml(tmp_path / "k.toml", """
[hosts]
"192.168.1.1" = "just-a-name"
""")
    monkeypatch.setenv("NETKIT_KNOWN_HOSTS", str(f))
    monkeypatch.setattr(known_hosts, "_CACHE", None)
    assert known_hosts.lookup(ip="192.168.1.1") == {"name": "just-a-name"}


def test_ip_lookup_wins_over_mac(tmp_path, monkeypatch):
    f = _write_toml(tmp_path / "k.toml", """
[hosts]
"10.0.0.5" = { name = "by-ip" }
"aa:bb:cc:dd:ee:ff" = { name = "by-mac" }
""")
    monkeypatch.setenv("NETKIT_KNOWN_HOSTS", str(f))
    monkeypatch.setattr(known_hosts, "_CACHE", None)
    # Both match — IP-first per the docstring.
    assert known_hosts.lookup(ip="10.0.0.5", mac="aa:bb:cc:dd:ee:ff") == {"name": "by-ip"}


def test_malformed_toml_silently_falls_back(tmp_path, monkeypatch):
    """A broken config shouldn't crash discovery — return empty and move on."""
    f = tmp_path / "k.toml"
    f.write_text("this is = not valid toml [[[")
    monkeypatch.setenv("NETKIT_KNOWN_HOSTS", str(f))
    monkeypatch.setattr(known_hosts, "_CACHE", None)
    assert known_hosts.lookup(ip="1.2.3.4") == {}
