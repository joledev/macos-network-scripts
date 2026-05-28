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


def test_recon_rejects_bad_subnet(run_netkit):
    p = run_netkit("recon", "--subnets", "not-a-cidr", "--dry-run")
    assert p.returncode == 2
    assert "invalid cidr" in p.stderr.lower()


def test_recon_subnets_dry_run_lists_them(run_netkit, tmp_output_dir):
    p = run_netkit("recon", "--subnets", "10.0.1.0/24,10.0.2.0/24", "--dry-run")
    assert p.returncode == 0
    assert "10.0.1.0/24" in p.stderr


def test_recon_snmp_switches_flag_parses(run_netkit, tmp_output_dir):
    # Flag is accepted (no crash); dry-run does no SNMP.
    p = run_netkit("recon", "--snmp-switches", "10.0.0.2:public", "--dry-run")
    assert p.returncode == 0


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


# ---- vendorscan (Tier 2) ----
def test_vendorscan_help(run_netkit):
    p = run_netkit("vendorscan", "--help")
    assert p.returncode == 0
    assert "Usage" in p.stdout


def test_vendorscan_dry_run(run_netkit):
    p = run_netkit("vendorscan", "--dry-run")
    assert p.returncode == 0
    assert "no traffic sent" in p.stderr.lower()


def test_vendorscan_rejects_bad_duration(run_netkit):
    p = run_netkit("vendorscan", "--duration", "99")
    assert p.returncode == 2


# ---- lldp (root-gated capture) ----
def test_lldp_help(run_netkit):
    p = run_netkit("lldp", "--help")
    assert p.returncode == 0
    assert "Usage" in p.stdout


def test_lldp_dry_run(run_netkit):
    p = run_netkit("lldp", "--dry-run")
    assert p.returncode == 0
    assert "no capture run" in p.stderr.lower()


def test_lldp_rejects_bad_duration(run_netkit):
    p = run_netkit("lldp", "--duration", "3")
    assert p.returncode == 2


# ---- dhcp (root-gated capture) ----
def test_dhcp_help(run_netkit):
    p = run_netkit("dhcp", "--help")
    assert p.returncode == 0
    assert "Usage" in p.stdout


def test_dhcp_dry_run(run_netkit):
    p = run_netkit("dhcp", "--dry-run")
    assert p.returncode == 0
    assert "no capture run" in p.stderr.lower()


def test_dhcp_rejects_bad_duration(run_netkit):
    p = run_netkit("dhcp", "--duration", "2")
    assert p.returncode == 2


# ---- omada (TP-Link Omada/EAP discovery) ----
def test_omada_help(run_netkit):
    p = run_netkit("omada", "--help")
    assert p.returncode == 0
    assert "Usage" in p.stdout


def test_omada_dry_run(run_netkit):
    p = run_netkit("omada", "--dry-run")
    assert p.returncode == 0
    assert "no traffic sent" in p.stderr.lower()


def test_omada_rejects_bad_duration(run_netkit):
    p = run_netkit("omada", "--duration", "1")
    assert p.returncode == 2


# ---- devinfo (authenticated, owned devices) ----
def test_devinfo_help(run_netkit):
    p = run_netkit("devinfo", "--help")
    assert p.returncode == 0
    assert "Usage" in p.stdout


def test_devinfo_unknown_flag(run_netkit):
    p = run_netkit("devinfo", "--bogus")
    assert p.returncode == 2


# ---- routes (segment discovery) ----
def test_routes_help(run_netkit):
    p = run_netkit("routes", "--help")
    assert p.returncode == 0
    assert "Usage" in p.stdout


def test_routes_runs(run_netkit):
    # Pure read of the routing table — should always succeed and name a segment.
    p = run_netkit("routes", "--json")
    assert p.returncode == 0
    assert "directly_connected" in p.stdout


# ---- netbox-export ----
def test_netbox_help(run_netkit):
    p = run_netkit("netbox-export", "--help")
    assert p.returncode == 0
    assert "Usage" in p.stdout


def test_netbox_csv_from_input(run_netkit, tmp_output_dir):
    import json
    recon = {"meta": {"generated_at": "20260101-000000"}, "subnet": "10.0.0.0/24",
             "gateway": "10.0.0.1",
             "hosts": [{"ip": "10.0.0.1", "role": "router/gateway", "display": "GW"}]}
    f = tmp_output_dir / "recon-20260101-000000.json"
    f.write_text(json.dumps(recon))
    p = run_netkit("netbox-export", "--csv", "--input", str(f))
    assert p.returncode == 0
    assert "ips.csv" in p.stdout
    assert any(x.name.endswith("-ips.csv") for x in tmp_output_dir.iterdir())
