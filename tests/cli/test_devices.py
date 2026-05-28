"""CLI smoke contracts for `netkit devices` (the persistent ledger viewer)."""
from __future__ import annotations


def test_help_exits_zero(run_netkit):
    p = run_netkit("devices", "--help")
    assert p.returncode == 0
    assert "Usage" in p.stdout


def test_unknown_flag_rejected(run_netkit):
    p = run_netkit("devices", "--bogus")
    assert p.returncode == 2
    assert "Unknown flag" in p.stderr


def test_empty_ledger_is_graceful(run_netkit, tmp_path):
    # Point the cache at an empty dir → no ledger yet, but exit 0.
    p = run_netkit("devices", env_extra={"XDG_CACHE_HOME": str(tmp_path / "empty")})
    assert p.returncode == 0
    assert "No ledger yet" in p.stdout


def test_json_shape_with_seeded_ledger(run_netkit, tmp_path):
    import json
    cache = tmp_path / "c" / "netkit"
    cache.mkdir(parents=True)
    (cache / "inventory.json").write_text(json.dumps({
        "aa:bb:cc:00:00:01": {"mac": "aa:bb:cc:00:00:01", "ips": ["192.168.1.42"],
                              "names": ["Cam"], "bands": ["2.4GHz"], "vendor": "TP-Link",
                              "role": "camera", "first_seen": "t1", "last_seen": "t2",
                              "seen_count": 3}}))
    p = run_netkit("devices", "--json", env_extra={"XDG_CACHE_HOME": str(tmp_path / "c")})
    assert p.returncode == 0
    data = json.loads(p.stdout)
    assert data["count"] == 1
    assert data["devices"][0]["role"] == "camera"
