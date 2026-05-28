"""Load configs/infrastructure.toml — non-discoverable network gear (unmanaged
switches, patch panels, cable runs, media converters) that has no IP and so
never shows up in a scan. recon injects these so the topology is complete.
"""
from __future__ import annotations

import os
from pathlib import Path

try:
    import tomllib  # Python 3.11+
except ImportError:  # pragma: no cover
    tomllib = None  # type: ignore

VALID_TYPES = {"switch", "patch-panel", "router", "ap", "modem",
               "media-converter", "other"}


def _config_path() -> Path:
    root = os.environ.get("NETKIT_ROOT", ".")
    return Path(root) / "configs" / "infrastructure.toml"


def load(path: str | None = None) -> list[dict]:
    p = Path(path) if path else _config_path()
    if tomllib is None or not p.is_file():
        return []
    try:
        with p.open("rb") as f:
            data = tomllib.load(f)
    except (OSError, ValueError):
        return []
    out: list[dict] = []
    seen: set[str] = set()
    for n in data.get("node", []):
        nid = (n.get("id") or n.get("name") or "").strip()
        if not nid or nid in seen:
            continue
        seen.add(nid)
        ntype = (n.get("type") or "other").lower()
        out.append({
            "id": nid,
            "name": n.get("name", "") or nid,
            "type": ntype if ntype in VALID_TYPES else "other",
            "model": n.get("model", ""),
            "speed": n.get("speed", ""),
            "location": n.get("location", ""),
            "uplink": str(n.get("uplink", "") or ""),
            "ports": [str(p) for p in (n.get("ports") or [])],
            "notes": n.get("notes", ""),
        })
    return out


def host_parent_map(infra: list[dict]) -> dict[str, str]:
    """ip → infra node id, for hosts declared on a node's `ports`."""
    m: dict[str, str] = {}
    for node in infra:
        for ip in node.get("ports", []):
            m[ip] = node["id"]
    return m
