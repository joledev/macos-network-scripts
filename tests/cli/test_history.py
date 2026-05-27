"""CLI contracts for `netkit history`: --limit validation, --json, --all."""
from __future__ import annotations

import json


def test_no_reports_empty_message(run_netkit, tmp_output_dir):
    p = run_netkit("history")
    assert p.returncode == 0
    assert "no reports" in p.stdout.lower()


def test_limit_rejects_non_integer(run_netkit, tmp_output_dir):
    p = run_netkit("history", "--limit", "nope")
    assert p.returncode == 2
    assert "positive integer" in p.stderr


def test_limit_rejects_zero(run_netkit, tmp_output_dir):
    p = run_netkit("history", "--limit", "0")
    assert p.returncode == 2
    assert "> 0" in p.stderr


def test_limit_rejects_negative(run_netkit, tmp_output_dir):
    p = run_netkit("history", "--limit", "-1")
    assert p.returncode == 2
    assert "positive integer" in p.stderr


def test_limit_without_value(run_netkit, tmp_output_dir):
    p = run_netkit("history", "--limit")
    assert p.returncode == 2
    assert "requires" in p.stderr


def test_unknown_flag_exits_2(run_netkit, tmp_output_dir):
    p = run_netkit("history", "--bogus")
    assert p.returncode == 2


def test_json_against_empty_dir_is_valid(run_netkit, tmp_output_dir):
    p = run_netkit("history", "--json")
    assert p.returncode == 0
    data = json.loads(p.stdout)
    assert data["count"] == 0
    assert data["reports"] == []


def test_caps_at_limit_value(run_netkit, tmp_output_dir):
    """Synthesize 5 minimal report files; --limit 3 returns 3."""
    minimal = {
        "meta": {"schema_version": "1.0.0", "generated_at": "20260101-000000",
                 "active_probe": False, "module_errors": [], "partial": False},
        "hosts": {"count": 0},
        "quality": {"targets": []},
        "diagnostics": {},
    }
    for i in range(5):
        ts = f"20260101-{i:06d}"
        out = dict(minimal)
        out["meta"] = {**minimal["meta"], "generated_at": ts}
        (tmp_output_dir / f"report-{ts}.json").write_text(json.dumps(out))
    p = run_netkit("history", "--limit", "3", "--json")
    assert p.returncode == 0
    data = json.loads(p.stdout)
    assert data["count"] == 3
