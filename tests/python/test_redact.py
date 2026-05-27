"""Tests for scripts/utils/redact.py — 3-level PII redaction."""
from __future__ import annotations

import copy

import redact


# ---- redact_mac ----

def test_mac_none_preserves():
    assert redact.redact_mac("aa:bb:cc:11:22:33", "none") == "aa:bb:cc:11:22:33"


def test_mac_redact_preserves_oui_tokenizes_device():
    out = redact.redact_mac("aa:bb:cc:11:22:33", "redact", salt="s")
    assert out.startswith("aa:bb:cc:")
    assert out != "aa:bb:cc:11:22:33"
    # Hex format preserved.
    assert len(out.split(":")) == 4
    assert all(len(p) <= 6 for p in out.split(":"))


def test_mac_shareable_still_preserves_oui():
    """OUI is vendor info; not PII. Keep at all levels."""
    out = redact.redact_mac("f0:2f:74:88:01:70", "shareable", salt="s")
    assert out.startswith("f0:2f:74:")
    assert out != "f0:2f:74:88:01:70"


def test_mac_stable_within_same_salt():
    a = redact.redact_mac("aa:bb:cc:11:22:33", "redact", salt="run1")
    b = redact.redact_mac("aa:bb:cc:11:22:33", "redact", salt="run1")
    assert a == b


def test_mac_different_salt_yields_different_token():
    a = redact.redact_mac("aa:bb:cc:11:22:33", "redact", salt="run1")
    b = redact.redact_mac("aa:bb:cc:11:22:33", "redact", salt="run2")
    assert a != b


def test_mac_invalid_input_passes_through():
    """Non-MAC strings shouldn't be munged silently."""
    assert redact.redact_mac("not a mac", "redact", salt="s") == "not a mac"
    assert redact.redact_mac("", "redact", salt="s") == ""


# ---- redact_hostname ----

def test_hostname_none_preserves():
    assert redact.redact_hostname("Joels-MacBook-Air.local", "none") == "Joels-MacBook-Air.local"


def test_hostname_redact_hashes_to_token():
    out = redact.redact_hostname("Joels-MacBook-Air.local", "redact", salt="s")
    assert out.startswith("host-")
    assert out.endswith(".local")        # suffix preserved as a category hint
    assert "Joels" not in out


def test_hostname_shareable_drops_to_redacted():
    assert redact.redact_hostname("Joels-MacBook-Air.local", "shareable") == "REDACTED"


def test_hostname_stable_within_same_salt():
    a = redact.redact_hostname("router.lan", "redact", salt="s")
    b = redact.redact_hostname("router.lan", "redact", salt="s")
    assert a == b


def test_hostname_different_inputs_distinct_tokens():
    a = redact.redact_hostname("a.local", "redact", salt="s")
    b = redact.redact_hostname("b.local", "redact", salt="s")
    assert a != b


# ---- redact_ip ----

def test_ip_none_preserves():
    assert redact.redact_ip("192.168.1.1", "none") == "192.168.1.1"


def test_ip_redact_keeps_private_ipv4():
    """Private IPv4 leaks little — common across all home LANs."""
    assert redact.redact_ip("192.168.1.50", "redact", salt="s") == "192.168.1.50"


def test_ip_redact_tokenizes_tailscale_cgnat():
    """100.64/10 is Tailscale CGNAT — identifies the tailnet."""
    out = redact.redact_ip("100.75.204.77", "redact", salt="s")
    assert out.startswith("ts-")
    assert "100.75" not in out


def test_ip_shareable_tokenizes_private_ipv4():
    out = redact.redact_ip("192.168.1.50", "shareable", salt="s")
    # First three octets preserved (common subnet info); last octet tokenized.
    assert out.startswith("192.168.1.")
    assert out != "192.168.1.50"


def test_ip_shareable_drops_tailscale_entirely():
    assert redact.redact_ip("100.75.204.77", "shareable") == "REDACTED"


def test_ip_shareable_tokenizes_tailscale_ula():
    assert redact.redact_ip("fd7a:115c:a1e0::203a:cc4d", "shareable") == "REDACTED"


def test_ip_public_preserved_even_at_shareable():
    """Public IPs are routable from anywhere — leaking them adds nothing."""
    assert redact.redact_ip("1.1.1.1", "shareable", salt="s") == "1.1.1.1"


def test_ip_invalid_passes_through():
    assert redact.redact_ip("not.an.ip", "redact", salt="s") == "not.an.ip"


# ---- redact_search_domain ----

def test_search_domain_tailnet_redacted():
    out = redact.redact_search_domain("tail9c9665.ts.net", "redact", salt="s")
    assert out.startswith("tailnet-")
    assert out.endswith(".ts.net")
    assert "tail9c9665" not in out


def test_search_domain_tailnet_shareable_drops():
    assert redact.redact_search_domain("tail9c9665.ts.net", "shareable") == "REDACTED"


def test_search_domain_generic_local_preserved():
    """`.local`, `.home`, `.internal` are generic — keep them as a category
    hint, no specific tailnet to leak."""
    assert redact.redact_search_domain("local", "redact", salt="s") == "local"
    assert redact.redact_search_domain("home", "shareable") == "home"


# ---- redact_ssid ----

def test_ssid_redact_tokenizes():
    out = redact.redact_ssid("HOMEWIFI_2G", "redact", salt="s")
    assert out.startswith("ssid-")
    assert "HOMEWIFI" not in out


def test_ssid_macos_redacted_passes_through():
    """macOS already replaces real SSIDs with '<redacted>' in
    system_profiler since macOS 14 — leave that token alone."""
    assert redact.redact_ssid("<redacted>", "redact", salt="s") == "<redacted>"
    assert redact.redact_ssid("<redacted>", "shareable") == "<redacted>"


# ---- redact_report ----

def _sample_report() -> dict:
    return {
        "meta": {
            "schema_version": "1.0.0", "tool_version": "0.2.0",
            "generated_at": "20260527-000000",
            "active_probe": False, "module_errors": [], "partial": False,
        },
        "inventory": {
            "host": {"name": "Joels-MacBook-Air.local", "user_shell": "/opt/homebrew/bin/fish"},
            "os":   {"product_name": "macOS", "product_version": "26.5", "build_version": "25F71"},
        },
        "interfaces": {"interfaces": [
            {"device": "en7", "mac": "c8:4d:44:27:24:9a", "ipv4": "192.168.1.119"},
        ]},
        "dns": {"resolvers": [
            {"id": "resolver #1", "interface": "utun4",
             "nameservers": ["100.100.100.100"],
             "search": ["tail9c9665.ts.net"]},
            {"id": "resolver #2", "interface": "en7",
             "nameservers": ["192.168.1.254"], "search": []},
        ]},
        "hosts": {"count": 1, "hosts": [
            {"ip": "192.168.1.67", "mac": "f0:2f:74:88:01:70",
             "vendor": "ASUSTek", "name": "", "known_name": "desktop-jole",
             "role": "workstation", "source": "arp-scan"},
        ]},
        "quality": {"targets": []},
        "diagnostics": {
            "tailscale": {"installed": True, "logged_in": True,
                          "self_ip": "100.75.204.77"},
            "vpn_tunnels": [{"interface": "utun4", "inet": "100.75.204.77",
                             "socket_owners": ["tailscaled"]}],
            "listening_ports": [{"proto": "tcp", "port": "7000",
                                 "command": "ControlCe", "pid": "1188",
                                 "addr": "*:7000"}],
            "ipv6": {"global_addresses": ["2806:290:c80b:2383::3"],
                     "ula_addresses": ["fd7a:115c:a1e0::203a:cc4d"]},
        },
        "topology": {"hosts": []},
    }


def test_report_none_returns_same_dict():
    r = _sample_report()
    out = redact.redact_report(r, "none")
    assert out is r   # contract: 'none' is a no-op pass-through


def test_report_redact_sets_meta_flags():
    r = _sample_report()
    out = redact.redact_report(r, "redact")
    assert out["meta"]["redacted"] is True
    assert out["meta"]["redact_level"] == "redact"
    # Input wasn't mutated.
    assert "redacted" not in r["meta"]


def test_report_redact_tokenizes_hostname_and_tailnet():
    r = _sample_report()
    out = redact.redact_report(r, "redact")
    assert out["inventory"]["host"]["name"].startswith("host-")
    assert out["dns"]["resolvers"][0]["search"][0].startswith("tailnet-")
    assert out["diagnostics"]["tailscale"]["self_ip"].startswith("ts-")
    # MAC OUI preserved.
    assert out["hosts"]["hosts"][0]["mac"].startswith("f0:2f:74:")
    assert out["hosts"]["hosts"][0]["mac"] != "f0:2f:74:88:01:70"
    # known_name hashed.
    assert out["hosts"]["hosts"][0]["known_name"].startswith("host-")
    assert "desktop-jole" not in out["hosts"]["hosts"][0]["known_name"]


def test_report_redact_preserves_role():
    """role is operator naming; preserved at 'redact', dropped at 'shareable'."""
    r = _sample_report()
    out = redact.redact_report(r, "redact")
    assert out["hosts"]["hosts"][0]["role"] == "workstation"


def test_report_shareable_drops_role_and_pid_etc():
    r = _sample_report()
    out = redact.redact_report(r, "shareable")
    assert out["hosts"]["hosts"][0]["role"] == "REDACTED"
    assert out["diagnostics"]["listening_ports"][0]["command"] == "REDACTED"
    assert out["diagnostics"]["listening_ports"][0]["pid"]     == "REDACTED"
    assert out["diagnostics"]["tailscale"]["self_ip"]          == "REDACTED"
    assert out["inventory"]["host"]["user_shell"]              == "REDACTED"
    assert out["inventory"]["os"]["build_version"]             == "REDACTED"


def test_report_shareable_keeps_public_ip():
    """github.com / cloudflare IPs are public; no PII gain from dropping."""
    r = _sample_report()
    r["quality"] = {"targets": [{"target": "1.1.1.1", "rtt_avg_ms": 40.0}]}
    out = redact.redact_report(r, "shareable")
    # Targets aren't touched (they're caller-supplied probe destinations,
    # not infrastructure identifiers).
    assert out["quality"]["targets"][0]["target"] == "1.1.1.1"


def test_report_does_not_mutate_input():
    r = _sample_report()
    snapshot = copy.deepcopy(r)
    redact.redact_report(r, "shareable")
    assert r == snapshot, "redact_report must not mutate its argument"


def test_report_invalid_level_raises():
    import pytest
    with pytest.raises(ValueError):
        redact.redact_report(_sample_report(), "bogus")
