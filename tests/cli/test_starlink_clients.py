"""CLI smoke contracts for `netkit starlink-clients`.

Uses --help / --dry-run / bad flags so the suite never reaches the network.
"""
from __future__ import annotations


def test_help_exits_zero(run_netkit):
    p = run_netkit("starlink-clients", "--help")
    assert p.returncode == 0
    assert "Usage" in p.stdout


def test_dry_run_sends_nothing(run_netkit):
    p = run_netkit("starlink-clients", "--dry-run")
    assert p.returncode == 0
    assert "no other traffic sent" in p.stderr.lower()


def test_unknown_flag_rejected(run_netkit):
    p = run_netkit("starlink-clients", "--bogus")
    assert p.returncode == 2
    assert "Unknown flag" in p.stderr


def test_bad_host_rejected(run_netkit):
    p = run_netkit("starlink-clients", "--host", "not-an-ip")
    assert p.returncode == 2
    assert "host" in p.stderr.lower()


def test_bad_port_rejected(run_netkit):
    p = run_netkit("starlink-clients", "--port", "99999")
    assert p.returncode == 2
    assert "port" in p.stderr.lower()
