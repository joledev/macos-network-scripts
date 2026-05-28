"""CLI smoke contracts for the aggressive discovery commands:
fingerprint / ssdp / ubnt-discover.

Every assertion uses --help, --dry-run or a bad flag, so these tests never
send a packet or depend on the live network.
"""
from __future__ import annotations

import pytest

ALL_CMDS = ["fingerprint", "ssdp", "ubnt-discover"]


@pytest.mark.parametrize("cmd", ALL_CMDS)
def test_help_exits_zero(run_netkit, cmd):
    p = run_netkit(cmd, "--help")
    assert p.returncode == 0
    assert "Usage" in p.stdout


@pytest.mark.parametrize("cmd", ALL_CMDS)
def test_unknown_flag_rejected(run_netkit, cmd):
    p = run_netkit(cmd, "--bogus")
    assert p.returncode == 2
    assert "Unknown flag" in p.stderr


@pytest.mark.parametrize("cmd", ALL_CMDS)
def test_dry_run_sends_nothing(run_netkit, cmd):
    # fingerprint needs an explicit host list to be deterministic offline.
    args = [cmd, "--dry-run"]
    if cmd == "fingerprint":
        args = [cmd, "--hosts", "192.168.1.1", "--dry-run"]
    p = run_netkit(*args)
    assert p.returncode == 0
    assert "no traffic sent" in p.stderr.lower()


def test_fingerprint_rejects_bad_host(run_netkit):
    p = run_netkit("fingerprint", "--hosts", "not-an-ip", "--dry-run")
    assert p.returncode == 2
    assert "invalid token" in p.stderr.lower()


def test_fingerprint_rejects_bad_ports(run_netkit):
    p = run_netkit("fingerprint", "--hosts", "192.168.1.1",
                   "--ports", "abc", "--dry-run")
    assert p.returncode == 2


@pytest.mark.parametrize("cmd", ["ssdp", "ubnt-discover"])
@pytest.mark.parametrize("dur", ["0", "999"])
def test_duration_bounds(run_netkit, cmd, dur):
    p = run_netkit(cmd, "--duration", dur)
    assert p.returncode == 2
    assert "duration" in p.stderr.lower()


def test_recon_help(run_netkit):
    p = run_netkit("recon", "--help")
    assert p.returncode == 0
    assert "recon" in p.stdout


def test_recon_unknown_flag(run_netkit):
    p = run_netkit("recon", "--bogus")
    assert p.returncode == 2
    assert "Unknown flag" in p.stderr


def test_recon_dry_run_runs_nothing(run_netkit, tmp_output_dir):
    p = run_netkit("recon", "--active", "--dry-run")
    assert p.returncode == 0
    assert "no probes executed" in p.stderr.lower()


# ---- Tier-1 enrichment commands: netbios / wsd / ndp ----
TIER1_CMDS = ["netbios", "wsd", "ndp"]


@pytest.mark.parametrize("cmd", TIER1_CMDS)
def test_tier1_help(run_netkit, cmd):
    p = run_netkit(cmd, "--help")
    assert p.returncode == 0
    assert "Usage" in p.stdout


@pytest.mark.parametrize("cmd", TIER1_CMDS)
def test_tier1_unknown_flag(run_netkit, cmd):
    p = run_netkit(cmd, "--bogus")
    assert p.returncode == 2
    assert "Unknown flag" in p.stderr


@pytest.mark.parametrize("cmd", TIER1_CMDS)
def test_tier1_dry_run(run_netkit, cmd):
    p = run_netkit(cmd, "--dry-run")
    assert p.returncode == 0
    assert "[dry-run]" in p.stderr


def test_netbios_rejects_bad_host(run_netkit):
    p = run_netkit("netbios", "--hosts", "nope", "--dry-run")
    assert p.returncode == 2
    assert "invalid token" in p.stderr.lower()


def test_wsd_rejects_bad_duration(run_netkit):
    p = run_netkit("wsd", "--duration", "0")
    assert p.returncode == 2
