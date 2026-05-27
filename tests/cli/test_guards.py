"""CLI contracts for the safety guards: subnet cap, sudo refusal, arpscan
requires --allow-raw."""
from __future__ import annotations


def test_subnet_size_cap_rejects_large_range(run_netkit, tmp_output_dir):
    """NETKIT_MAX_HOSTS=8 + --subnet 10.0.0.0/22 → 1024 hosts → die."""
    p = run_netkit(
        "discover", "--subnet", "10.0.0.0/22", "--interface", "lo0",
        env_extra={"NETKIT_MAX_HOSTS": "8"},
    )
    assert p.returncode != 0
    assert "--force" in p.stderr


def test_subnet_size_cap_force_overrides(run_netkit, tmp_output_dir):
    """--force lets the user past the cap (but passive discover does no
    probing; here we only test the guard does NOT abort)."""
    p = run_netkit(
        "discover", "--subnet", "10.0.0.0/22", "--interface", "lo0",
        "--force",
        env_extra={"NETKIT_MAX_HOSTS": "8"},
    )
    # The script may still fail because lo0 has no real LAN; we only
    # check the guard didn't kill it pre-emptively.
    assert "--force" not in p.stderr  # the guard message is no longer printed


def test_arpscan_requires_allow_raw_in_strict_mode(run_netkit, tmp_output_dir):
    """Pass --subnet explicitly so iface_subnet_cidr doesn't fail on lo0
    before the arpscan guard runs."""
    p = run_netkit(
        "discover", "--arpscan",
        "--interface", "lo0", "--subnet", "127.0.0.0/30",
        env_extra={"NETKIT_STRICT": "1", "NETKIT_ALLOW_RAW": "0",
                   "NETKIT_YES": "0"},
    )
    assert p.returncode != 0
    assert "--allow-raw" in p.stderr or "declined" in p.stderr.lower()


def test_arpscan_with_allow_raw_passes_guard(run_netkit, tmp_output_dir):
    """With --allow-raw the guard accepts. arp-scan itself may still fail
    (no sudo cached) but the netkit guard must not be what blocks it."""
    p = run_netkit(
        "discover", "--arpscan", "--allow-raw",
        "--interface", "lo0", "--subnet", "127.0.0.0/30",
        env_extra={"NETKIT_STRICT": "1"},
    )
    # The "declined" / "--allow-raw" messages from guard_raw_packet must
    # not appear when we explicitly opted in.
    assert "Re-run with --allow-raw" not in p.stderr


def test_report_requires_allow_raw_for_arpscan(run_netkit, tmp_output_dir):
    """The report-level --arpscan check (generate.sh) must refuse without
    --allow-raw, even outside dry-run."""
    p = run_netkit(
        "report", "--arpscan", "--interface", "lo0",
        env_extra={"NETKIT_STRICT": "1", "NETKIT_ALLOW_RAW": "0"},
    )
    assert p.returncode != 0
    assert "--allow-raw" in p.stderr


def test_dry_run_bypasses_guards(run_netkit, tmp_output_dir):
    """--dry-run must NOT abort because of --arpscan or --active — the
    whole point is to show the plan without confirming/escalating."""
    p = run_netkit(
        "--dry-run", "report", "--arpscan", "--active",
        "--interface", "lo0",
        env_extra={"NETKIT_STRICT": "1", "NETKIT_ALLOW_RAW": "0"},
        # No --yes — guard_active would prompt; --dry-run skips it.
    )
    assert p.returncode == 0
    assert "[dry-run]" in p.stderr or "[dry-run]" in p.stdout


def test_version_flag(run_netkit):
    p = run_netkit("--version")
    assert p.returncode == 0
    assert p.stdout.strip().startswith("netkit ")
