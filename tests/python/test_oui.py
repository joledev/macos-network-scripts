"""Tests for scripts/utils/oui.py — vendor lookups from MAC prefixes."""
from __future__ import annotations

import oui


def test_lookup_known_apple_prefix():
    assert oui.lookup("00:11:24:aa:bb:cc") == "Apple"


def test_lookup_unknown_prefix():
    assert oui.lookup("de:ad:be:ef:00:00") == "Unknown"


def test_lookup_handles_uppercase():
    assert oui.lookup("F0:DB:F8:11:22:33") == "Apple"


def test_lookup_handles_hyphen_separator():
    # "00-11-24-aa-bb-cc" is the IEEE dash style; should normalize the same.
    assert oui.lookup("00-11-24-aa-bb-cc") == "Apple"


def test_lookup_short_string_returns_unknown():
    # Less than 6 hex chars after normalization → can't look up.
    assert oui.lookup("00:11") == "Unknown"


def test_lookup_garbage_returns_unknown():
    assert oui.lookup("not a mac") == "Unknown"


def test_lookup_empty_returns_unknown():
    assert oui.lookup("") == "Unknown"


def test_normalize_pads_and_uppercases():
    # _normalize is an internal helper; verify the contract since lookup
    # depends on it.
    assert oui._normalize("0c-dc-91-aa-bb-cc") == "0CDC91"
    assert oui._normalize("F0:db:f8:11:22:33") == "F0DBF8"


def test_cache_lookup_used_when_present(tmp_path, monkeypatch):
    """If ~/.cache/netkit/oui.txt exists, it overrides the builtin table for
    prefixes the builtin doesn't know."""
    cache_root = tmp_path / "cache"
    (cache_root / "netkit").mkdir(parents=True)
    cache_file = cache_root / "netkit" / "oui.txt"
    cache_file.write_text("ABCDEF\tFancyCorp, Inc.\n")
    monkeypatch.setenv("XDG_CACHE_HOME", str(cache_root))
    # Reset module-level cache so it re-reads.
    oui._CACHE = None  # type: ignore[attr-defined]   (test-only access)
    # Reload not strictly needed because _load_cache is called lazily.
    assert oui.lookup("ab:cd:ef:11:22:33") == "FancyCorp, Inc."
