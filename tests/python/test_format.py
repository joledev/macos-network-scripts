"""Tests for scripts/utils/format.py — md_table, dump_csv, dump_json."""
from __future__ import annotations

import json

import format as fmt   # noqa: A004  (shadowing built-in `format` — intentional, repo name)


def test_md_table_basic():
    rows = [{"a": 1, "b": 2}, {"a": 3, "b": 4}]
    out = fmt.md_table(rows)
    assert "| a | b |" in out
    assert "| --- | --- |" in out
    assert "| 1 | 2 |" in out
    assert "| 3 | 4 |" in out


def test_md_table_empty_shows_placeholder():
    assert fmt.md_table([]).strip() == "_(no data)_"


def test_md_table_escapes_pipes():
    rows = [{"x": "a|b"}]
    out = fmt.md_table(rows)
    assert "a\\|b" in out


def test_md_table_collapses_newlines():
    rows = [{"x": "line1\nline2"}]
    out = fmt.md_table(rows)
    assert "line1 line2" in out


def test_md_table_columns_arg_orders_explicitly():
    rows = [{"a": 1, "b": 2}]
    out = fmt.md_table(rows, columns=["b", "a"])
    header = out.splitlines()[0]
    assert header == "| b | a |"


def test_dump_csv_preserves_first_row_field_order():
    rows = [{"z": 1, "a": 2}, {"a": 3, "z": 4}]
    out = fmt.dump_csv(rows)
    first_line = out.splitlines()[0]
    assert first_line == "z,a"


def test_dump_csv_empty_is_empty_string():
    assert fmt.dump_csv([]) == ""


def test_dump_csv_writes_blanks_for_missing_keys():
    rows = [{"a": 1, "b": 2}, {"a": 3}]   # second row missing "b"
    out = fmt.dump_csv(rows)
    # The second data line should have an empty cell, not "None".
    second = out.splitlines()[2]
    assert second == "3,"


def test_dump_json_round_trip():
    obj = {"a": 1, "b": [1, 2, 3]}
    out = fmt.dump_json(obj)
    assert json.loads(out) == obj


def test_dump_json_indented_by_default():
    out = fmt.dump_json({"x": 1})
    # Default indent=2 → multi-line output.
    assert "\n" in out
