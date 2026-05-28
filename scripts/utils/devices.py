"""Load configs/devices.toml — the user's OWN devices for authenticated
identify/manage (netkit devinfo). Passwords may be given inline or, preferably,
as "env:VAR" so the secret stays out of the file. Never prints secrets.
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Any

try:
    import tomllib  # Python 3.11+
except ImportError:  # pragma: no cover
    tomllib = None  # type: ignore

DEFAULT_SSH_COMMANDS = [
    "uname -a",
    "cat /etc/os-release 2>/dev/null",
    "cat /etc/openwrt_release 2>/dev/null",
    "cat /tmp/sysinfo/model 2>/dev/null",
    "ip -o link 2>/dev/null || ifconfig -a 2>/dev/null",
    "ip neigh 2>/dev/null || arp -an 2>/dev/null",
]


def _config_path() -> Path:
    root = os.environ.get("NETKIT_ROOT", ".")
    return Path(root) / "configs" / "devices.toml"


def resolve_secret(value: Any) -> str:
    """`env:VAR` → the env var's value; anything else returned as-is."""
    if isinstance(value, str) and value.startswith("env:"):
        return os.environ.get(value[4:], "")
    return value or ""


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
    for d in data.get("device", []):
        if not d.get("host"):
            continue
        out.append({
            "name": d.get("name", "") or d["host"],
            "host": d["host"],
            "type": (d.get("type") or "http").lower(),
            "user": d.get("user", ""),
            "password": resolve_secret(d.get("pass")),
            "url": d.get("url", "") or f"http://{d['host']}/",
            "login_url": d.get("login_url", ""),
            "info_url": d.get("info_url", ""),
            "port": int(d.get("port", 22) or 22),
            "commands": list(d.get("commands") or DEFAULT_SSH_COMMANDS),
        })
    return out


def redact(text: str, password: str) -> str:
    """Mask a password if it leaks into captured output/logs."""
    if password and text:
        return text.replace(password, "***")
    return text
