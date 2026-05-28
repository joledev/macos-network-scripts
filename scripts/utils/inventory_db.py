"""Persistent device ledger — the UNION of every host seen across recon runs.

A single scan is a snapshot: phones sleep, IoT roams, devices come and go (the
Nothing Phone was in one scan and gone the next). This ledger accumulates every
device ever seen, keyed by MAC, with first_seen / last_seen / seen_count and the
set of IPs, names and bands observed — so you can answer "what's EVER been on
this network", not just "what answered right now".

Stored as JSON under ~/.cache/netkit/ so it survives output/ cleanup. Stdlib
only; recon updates it each run and `netkit devices` prints it.
"""
from __future__ import annotations

import json
import os
from pathlib import Path


def path() -> Path:
    base = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache")))
    return base / "netkit" / "inventory.json"


def load() -> dict:
    p = path()
    if not p.is_file():
        return {}
    try:
        with p.open(encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _key(h: dict) -> str:
    mac = (h.get("mac") or "").lower()
    if mac:
        return mac
    ip = h.get("ip") or ""
    return f"ip:{ip}" if ip else ""


def _add(entry: dict, field: str, value) -> None:
    if value and value not in entry[field]:
        entry[field].append(value)


def update(hosts: list[dict], now: str, ledger: dict | None = None) -> dict:
    """Merge a scan's hosts into the ledger (in place) and return it."""
    if ledger is None:
        ledger = load()
    for h in hosts:
        k = _key(h)
        if not k or k == "ip:":
            continue
        e = ledger.get(k)
        if e is None:
            e = {"mac": (h.get("mac") or "").lower(), "ips": [], "names": [],
                 "bands": [], "vendor": "", "role": "",
                 "first_seen": now, "last_seen": now, "seen_count": 0}
            ledger[k] = e
        _add(e, "ips", h.get("ip"))
        _add(e, "names", h.get("display") or h.get("known_name") or h.get("sl_name"))
        _add(e, "bands", h.get("band"))
        if h.get("vendor"):
            e["vendor"] = h["vendor"]
        if h.get("role"):
            e["role"] = h["role"]
        e["last_seen"] = now
        e["seen_count"] = int(e.get("seen_count", 0)) + 1
    return ledger


def save(ledger: dict) -> Path:
    p = path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(ledger, f, indent=2, sort_keys=True)
    tmp.replace(p)
    return p


def absent(ledger: dict, present_hosts: list[dict]) -> list[dict]:
    """Ledger entries NOT in the current scan — devices seen before but gone now."""
    here = {_key(h) for h in present_hosts}
    return [e for k, e in ledger.items() if k not in here]
