"""CLI contracts for `netkit diff`: positional validation, ref resolution."""
from __future__ import annotations

import json


def _seed_two_reports(out_dir, prev_count=10, latest_count=12):
    base = {
        "meta": {"schema_version": "1.0.0", "active_probe": True, "module_errors": [],
                 "partial": False},
        "hosts": {"hosts": []},
        "quality": {"targets": []},
        "diagnostics": {},
        "interfaces": {"interfaces": []},
        "topology": {},
        "dns": {"resolvers": []},
        "inventory": {},
    }
    ts_a = "20260101-000000"
    ts_b = "20260101-010000"
    a = dict(base)
    a["meta"] = {**base["meta"], "generated_at": ts_a}
    b = dict(base)
    b["meta"] = {**base["meta"], "generated_at": ts_b}
    a["hosts"] = {"hosts": [{"ip": f"10.0.0.{i}", "mac": f"aa:bb:cc:00:00:{i:02x}",
                              "vendor": "Unknown", "name": "", "source": "arp"}
                            for i in range(prev_count)]}
    b["hosts"] = {"hosts": [{"ip": f"10.0.0.{i}", "mac": f"aa:bb:cc:00:00:{i:02x}",
                              "vendor": "Unknown", "name": "", "source": "arp"}
                            for i in range(latest_count)]}
    (out_dir / f"report-{ts_a}.json").write_text(json.dumps(a))
    (out_dir / f"report-{ts_b}.json").write_text(json.dumps(b))
    return ts_a, ts_b


def test_extra_positional_rejected(run_netkit, tmp_output_dir):
    _seed_two_reports(tmp_output_dir)
    p = run_netkit("diff", "previous", "latest", "extra")
    assert p.returncode == 2
    assert "at most two" in p.stderr


def test_unknown_flag_rejected(run_netkit, tmp_output_dir):
    _seed_two_reports(tmp_output_dir)
    p = run_netkit("diff", "--bogus")
    assert p.returncode == 2
    assert "Unknown flag" in p.stderr


def test_no_reports_exits_non_zero(run_netkit, tmp_output_dir):
    p = run_netkit("diff")
    assert p.returncode != 0


def test_only_one_report_cannot_diff(run_netkit, tmp_output_dir):
    minimal = {"meta": {"generated_at": "20260101-000000", "module_errors": [],
                        "partial": False},
               "hosts": {"hosts": []}, "quality": {"targets": []},
               "diagnostics": {}, "interfaces": {"interfaces": []},
               "topology": {}, "dns": {"resolvers": []}, "inventory": {}}
    (tmp_output_dir / "report-20260101-000000.json").write_text(json.dumps(minimal))
    p = run_netkit("diff")
    assert p.returncode != 0


def test_diff_previous_vs_latest_reports_added_hosts(run_netkit, tmp_output_dir):
    _seed_two_reports(tmp_output_dir, prev_count=10, latest_count=12)
    p = run_netkit("diff", "--json")
    assert p.returncode == 0, p.stderr
    data = json.loads(p.stdout)
    # latest has 12 hosts, previous had 10 → 2 added.
    assert len(data["hosts"]["added"]) == 2


def test_diff_self_refuses(run_netkit, tmp_output_dir):
    ts_a, _ = _seed_two_reports(tmp_output_dir)
    p = run_netkit("diff", ts_a, ts_a)
    assert p.returncode != 0


def test_ambiguous_ref_errors(run_netkit, tmp_output_dir):
    _seed_two_reports(tmp_output_dir)
    # Both reports start with "20260101-" — that prefix is ambiguous.
    p = run_netkit("diff", "20260101", "latest")
    assert p.returncode != 0
    assert "ambiguous" in (p.stderr + p.stdout).lower()
