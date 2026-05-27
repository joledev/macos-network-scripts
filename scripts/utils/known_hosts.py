#!/usr/bin/env python3
"""Load known-hosts mapping (IP/MAC → friendly name + role) for report enrichment.

Lookup order (first found wins):
  1. $NETKIT_KNOWN_HOSTS                              (explicit)
  2. ./configs/known-hosts.toml                       (repo-local)
  3. ~/.config/netkit/known-hosts.toml                (user-global)

File format (simple TOML subset — no nested tables, no arrays of tables;
parsed by python's tomllib so full TOML works too):

    [hosts]
    "192.168.1.67"  = { name = "desktop-jole", role = "workstation" }
    "192.168.1.98"  = { name = "phoneserver",  role = "ci-hub" }
    "10:24:07:4d:fc:9c" = { name = "router", role = "gateway" }
"""
from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import Any

try:
    import tomllib  # Python 3.11+
except ImportError:  # pragma: no cover
    tomllib = None  # type: ignore


def _candidate_paths() -> list[Path]:
    env = os.environ.get("NETKIT_KNOWN_HOSTS")
    out: list[Path] = []
    if env:
        out.append(Path(env).expanduser())
    repo_root = os.environ.get("NETKIT_ROOT")
    if repo_root:
        out.append(Path(repo_root) / "configs" / "known-hosts.toml")
    out.append(Path.home() / ".config" / "netkit" / "known-hosts.toml")
    return out


def _load_first() -> dict[str, dict[str, Any]]:
    if tomllib is None:
        return {}
    for p in _candidate_paths():
        if p.is_file():
            try:
                with p.open("rb") as f:
                    data = tomllib.load(f)
            except Exception:
                continue
            hosts = data.get("hosts", {})
            if isinstance(hosts, dict):
                return {_norm(k): _to_dict(v) for k, v in hosts.items()}
    return {}


def _to_dict(v: Any) -> dict[str, Any]:
    if isinstance(v, dict):
        return dict(v)
    if isinstance(v, str):
        return {"name": v}
    return {}


def _norm(key: str) -> str:
    """Normalize: MACs lowercased without leading zeros stripped, IPs untouched."""
    s = key.strip().lower()
    if ":" in s and any(c in s for c in "abcdef"):
        # Assume MAC. Pad each octet to 2 chars so f:0:1:... matches 0f:00:01:...
        try:
            parts = [p.zfill(2) for p in s.split(":")]
            return ":".join(parts)
        except Exception:
            return s
    return s


_CACHE: dict[str, dict[str, Any]] | None = None


def all_known() -> dict[str, dict[str, Any]]:
    global _CACHE
    if _CACHE is None:
        _CACHE = _load_first()
    return _CACHE


def lookup(ip: str = "", mac: str = "") -> dict[str, Any]:
    """Return the entry matching either IP or MAC. Empty dict if nothing matched."""
    db = all_known()
    if ip:
        hit = db.get(_norm(ip))
        if hit:
            return hit
    if mac:
        hit = db.get(_norm(mac))
        if hit:
            return hit
    return {}


if __name__ == "__main__":
    db = all_known()
    if not db:
        print("no known-hosts config found", file=sys.stderr)
        sys.exit(1)
    for k, v in db.items():
        print(f"{k}\t{v}")
