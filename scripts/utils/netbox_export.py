"""Turn a netkit recon dataset into NetBox-ready data.

Two outputs:
  * CSV files for NetBox's bulk import (ipam ip-addresses + dcim devices).
  * REST payloads + a push() that create-or-updates IP addresses via the NetBox
    API (stdlib urllib; token-authenticated), so re-runs reconcile instead of
    duplicating.

netkit stays the lightweight per-VLAN collector; NetBox is the source of truth.
"""
from __future__ import annotations

import csv
import io
import ipaddress
import json
import urllib.error
import urllib.request


def _prefix_len(report: dict) -> int:
    subnet = report.get("subnet", "") or ""
    try:
        return ipaddress.ip_network(subnet, strict=False).prefixlen
    except ValueError:
        return 24


def _addr(ip: str, plen: int) -> str:
    return f"{ip}/{plen}"


def _desc(h: dict) -> str:
    bits = [h.get("role", ""), h.get("identity", "") or h.get("vendor", "")]
    return " · ".join(b for b in bits if b)


def _dns_name(h: dict) -> str:
    n = h.get("display") or h.get("rdns") or ""
    # NetBox dns_name must be hostname-ish.
    return n if all(c.isalnum() or c in ".-" for c in n) else ""


def ip_rows(report: dict) -> list[dict]:
    default_plen = _prefix_len(report)
    rows = []
    for h in report.get("hosts", []):
        ip = h.get("ip", "")
        if not ip:
            continue
        plen = h.get("prefixlen") or default_plen   # per-host prefix in multi-subnet
        rows.append({
            "address": _addr(ip, plen),
            "status": "active",
            "dns_name": _dns_name(h),
            "description": _desc(h)[:200],
        })
    return rows


def device_rows(report: dict) -> list[dict]:
    """Devices that look like infrastructure (have a model/role worth tracking).

    NetBox device import references role/manufacturer/device_type/site by name,
    which must already exist; treat this CSV as a starting point to edit.
    """
    rows = []
    site = report.get("site", "") or "building"
    for h in report.get("hosts", []):
        role = h.get("role", "host")
        model = h.get("identity", "") or h.get("vendor", "")
        if role in ("host", "host (no open ports)") and not model:
            continue
        rows.append({
            "name": h.get("display") or h.get("rdns") or h.get("ip", ""),
            "role": role.replace("/", "-"),
            "manufacturer": (h.get("vendor", "") or "").split()[0] if h.get("vendor") else "",
            "device_type": model[:60],
            "site": site,
            "status": "active",
            "comments": f"{h.get('ip','')} {h.get('mac','')}".strip(),
        })
    # Manually-declared infrastructure (unmanaged switches, patch panels, ...).
    for n in report.get("infrastructure", []) or []:
        model = n.get("model", "")
        rows.append({
            "name": n.get("name") or n.get("id", ""),
            "role": (n.get("type") or "other").replace("/", "-"),
            "manufacturer": model.split()[0] if model else "",
            "device_type": (model or n.get("type", ""))[:60],
            "site": n.get("location") or site,
            "status": "active",
            "comments": (n.get("notes", "") or n.get("speed", "")).strip(),
        })
    return rows


def _csv(rows: list[dict], fields: list[str]) -> str:
    buf = io.StringIO()
    w = csv.DictWriter(buf, fieldnames=fields)
    w.writeheader()
    for r in rows:
        w.writerow({k: r.get(k, "") for k in fields})
    return buf.getvalue()


def ip_csv(report: dict) -> str:
    return _csv(ip_rows(report), ["address", "status", "dns_name", "description"])


def device_csv(report: dict) -> str:
    return _csv(device_rows(report),
                ["name", "role", "manufacturer", "device_type", "site", "status", "comments"])


# ---- REST push (create-or-update IP addresses) ----
def _api(url: str, token: str, method="GET", payload=None, timeout=8):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={
        "Authorization": f"Token {token}", "Content-Type": "application/json",
        "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        body = r.read().decode(errors="replace")
        return r.status, (json.loads(body) if body else {})


def push(report: dict, url: str, token: str) -> dict:
    """Create-or-update each host's IP in NetBox ipam/ip-addresses."""
    base = url.rstrip("/")
    created = updated = failed = 0
    errors = []
    for row in ip_rows(report):
        addr = row["address"]
        try:
            q = f"{base}/api/ipam/ip-addresses/?address={addr.replace('/', '%2F')}"
            _st, found = _api(q, token)
            results = found.get("results", []) if isinstance(found, dict) else []
            if results:
                _api(f"{base}/api/ipam/ip-addresses/{results[0]['id']}/",
                     token, method="PATCH", payload=row)
                updated += 1
            else:
                _api(f"{base}/api/ipam/ip-addresses/", token, method="POST", payload=row)
                created += 1
        except (urllib.error.URLError, OSError, ValueError) as e:
            failed += 1
            errors.append(f"{addr}: {e}")
    return {"created": created, "updated": updated, "failed": failed, "errors": errors[:10]}
