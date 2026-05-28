"""CLI smoke contracts for `netkit fleet` — the parallel multi-node runner.

All assertions use --help, --dry-run, bad flags or explicit --targets, so these
tests never send a probe and don't depend on the live network or inventory.
"""
from __future__ import annotations


def test_help_exits_zero(run_netkit):
    p = run_netkit("fleet", "--help")
    assert p.returncode == 0
    assert "Usage" in p.stdout


def test_missing_action_rejected(run_netkit):
    p = run_netkit("fleet")
    assert p.returncode == 2
    assert "action" in p.stderr.lower()


def test_unknown_action_rejected(run_netkit):
    p = run_netkit("fleet", "bogus", "--dry-run")
    assert p.returncode == 2
    assert "unknown action" in p.stderr.lower()


def test_unknown_flag_rejected(run_netkit):
    p = run_netkit("fleet", "reach", "--bogus")
    assert p.returncode == 2
    assert "Unknown flag" in p.stderr


def test_dry_run_with_targets_lists_hosts(run_netkit):
    p = run_netkit("fleet", "reach", "--targets", "10.0.0.1,10.0.0.2", "--dry-run")
    assert p.returncode == 0
    assert "no probes sent" in p.stderr.lower()
    assert "10.0.0.1" in p.stderr
    assert "10.0.0.2" in p.stderr


def test_dry_run_subnet_enumerates(run_netkit):
    p = run_netkit("fleet", "reach", "--subnet", "10.9.9.0/30", "--dry-run")
    assert p.returncode == 0
    assert "10.9.9.1" in p.stderr


def test_jobs_bounds_rejected(run_netkit):
    p = run_netkit("fleet", "reach", "--targets", "10.0.0.1", "--jobs", "99",
                   "--dry-run")
    assert p.returncode == 2
    assert "jobs" in p.stderr.lower()


def test_bad_port_rejected(run_netkit):
    p = run_netkit("fleet", "cert-check", "--targets", "10.0.0.1",
                   "--port", "99999", "--dry-run")
    assert p.returncode == 2
    assert "port" in p.stderr.lower()


def test_oversized_subnet_guarded(run_netkit):
    p = run_netkit("fleet", "reach", "--subnet", "10.0.0.0/16", "--dry-run")
    assert p.returncode != 0
    assert "MAX_HOSTS" in p.stderr


def test_each_action_dry_runs(run_netkit):
    for action in ("reach", "cert-check", "snmp", "fingerprint"):
        p = run_netkit("fleet", action, "--targets", "10.0.0.1", "--dry-run")
        assert p.returncode == 0, f"{action}: {p.stderr}"
        assert action in p.stderr
