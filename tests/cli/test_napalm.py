"""CLI smoke contracts for `netkit napalm` — the OPTIONAL multi-vendor command.

These never require NAPALM to be installed: validation errors and the
"no managed devices" path are exercised with a filter that matches nothing,
so the suite stays hermetic whether or not a devices.toml exists.
"""
from __future__ import annotations


def test_help_exits_zero(run_netkit):
    p = run_netkit("napalm", "--help")
    assert p.returncode == 0
    assert "Usage" in p.stdout
    assert "NAPALM" in p.stdout


def test_unknown_flag_rejected(run_netkit):
    p = run_netkit("napalm", "--bogus")
    assert p.returncode == 2
    assert "Unknown flag" in p.stderr


def test_jobs_bounds_rejected(run_netkit):
    p = run_netkit("napalm", "--jobs", "99")
    assert p.returncode == 2
    assert "jobs" in p.stderr.lower()


def test_bad_getters_rejected(run_netkit):
    p = run_netkit("napalm", "--getters", "a;b")
    assert p.returncode == 2
    assert "getters" in p.stderr.lower()


def test_no_managed_devices_is_graceful(run_netkit):
    # A device filter that matches nothing → graceful exit, never connects,
    # never needs NAPALM installed.
    p = run_netkit("napalm", "--device", "__netkit_test_nope__")
    assert p.returncode == 0
    assert "no napalm-managed devices" in p.stderr.lower()
