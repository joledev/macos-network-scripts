#!/usr/bin/env python3
"""Shared output formatting helpers for netkit Python scripts.

Pure stdlib. Imported by reporting/discovery scripts.
"""
from __future__ import annotations

import csv
import io
import json
import sys
from typing import Any
from collections.abc import Iterable, Mapping


def dump_json(obj: Any, *, indent: int = 2) -> str:
    return json.dumps(obj, indent=indent, default=str, sort_keys=False)


def dump_csv(rows: Iterable[Mapping[str, Any]]) -> str:
    rows = list(rows)
    if not rows:
        return ""
    fieldnames: list[str] = []
    seen: set[str] = set()
    for r in rows:
        for k in r:
            if k not in seen:
                seen.add(k)
                fieldnames.append(k)
    buf = io.StringIO()
    writer = csv.DictWriter(buf, fieldnames=fieldnames)
    writer.writeheader()
    for r in rows:
        writer.writerow({k: ("" if r.get(k) is None else r[k]) for k in fieldnames})
    return buf.getvalue()


def md_table(rows: Iterable[Mapping[str, Any]], columns: list[str] | None = None) -> str:
    rows = list(rows)
    if not rows:
        return "_(no data)_\n"
    if columns is None:
        columns = []
        seen: set[str] = set()
        for r in rows:
            for k in r:
                if k not in seen:
                    seen.add(k)
                    columns.append(k)
    out: list[str] = []
    out.append("| " + " | ".join(columns) + " |")
    out.append("| " + " | ".join("---" for _ in columns) + " |")
    for r in rows:
        out.append("| " + " | ".join(_md_cell(r.get(c)) for c in columns) + " |")
    return "\n".join(out) + "\n"


def _md_cell(v: Any) -> str:
    if v is None:
        return ""
    s = str(v).replace("|", "\\|").replace("\n", " ")
    return s


def emit(obj: Any, fmt: str) -> None:
    """Print obj in the requested format to stdout."""
    if fmt == "json":
        print(dump_json(obj))
    elif fmt == "csv":
        if isinstance(obj, list):
            sys.stdout.write(dump_csv(obj))
        elif isinstance(obj, dict) and isinstance(obj.get("rows"), list):
            sys.stdout.write(dump_csv(obj["rows"]))
        else:
            print("error: CSV requires a list of dicts", file=sys.stderr)
            sys.exit(2)
    elif fmt == "md":
        if isinstance(obj, list):
            sys.stdout.write(md_table(obj))
        elif isinstance(obj, dict) and isinstance(obj.get("rows"), list):
            sys.stdout.write(md_table(obj["rows"]))
        else:
            sys.stdout.write(dump_json(obj))
            sys.stdout.write("\n")
    else:
        print(f"error: unknown format '{fmt}'", file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":  # pragma: no cover
    print("This module is a library; import it from other scripts.", file=sys.stderr)
    sys.exit(1)
