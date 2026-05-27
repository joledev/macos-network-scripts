"""Redaction helpers for netkit reports.

Three levels:

- ``none``       : no redaction; full data (default for personal use).
- ``redact``     : tokenize PII consistently (same input → same token within
                   the report). MACs preserve the OUI (first 3 octets) and
                   tokenize the device portion. Hostnames / SSIDs / search
                   domains are hashed to short tokens. Private IPs stay as-is
                   (they're already common across many home networks); public
                   IPs stay as-is (they're routable from anywhere). Tailnet
                   identifier becomes ``tailnet-XXXX``.
- ``shareable``  : stronger redaction. Drop or replace with ``"REDACTED"``:
                   full MACs (only OUI preserved), hostnames, listening port
                   PIDs/commands/addresses, Tailscale IPs and tailnet, dish
                   device ID, OS build_version. Useful for sharing reports
                   with vendors / partners / public issue trackers.

Tokenization stability:

- By default, hashing uses ``meta.generated_at`` as the salt — same value
  always produces the same token within one report, but tokens change
  between reports (max privacy).
- If ``NETKIT_REDACTION_SALT`` env var is set, that string is used as the
  salt instead — tokens stay stable across reports, so ``netkit diff`` can
  still match by token. Useful for tracking the same network over time
  without revealing the underlying values.

Used by scripts/reports/generate.sh. Pure stdlib (hashlib).
"""
from __future__ import annotations

import hashlib
import ipaddress
import os
import re

# ---- types and constants ----

_MAC_RE       = re.compile(r"^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$", re.I)
_TS_DOMAIN_RE = re.compile(r"^[a-z0-9-]+\.ts\.net\.?$", re.I)
_TS_ULA_PREFIX = "fd7a:115c:a1e0"          # Tailscale unique-local prefix

REDACTED = "REDACTED"


# ---- low-level helpers ----

def _salt() -> str:
    """Return the salt for token generation. Caller may override per
    ``redact_report`` by passing salt= explicitly; this is the env default."""
    return os.environ.get("NETKIT_REDACTION_SALT", "")


def _token(value: str, prefix: str, salt: str, n: int = 4) -> str:
    """Stable short token from ``value`` and ``salt``. Hex digest truncated
    so the token stays readable in tables (e.g. ``host-3f9a``)."""
    h = hashlib.blake2b(
        (value or "").encode("utf-8"),
        salt=(salt or "")[:16].encode("utf-8").ljust(16, b"\0"),
        digest_size=8,
    ).hexdigest()[:n]
    return f"{prefix}-{h}"


def redact_mac(mac: str, level: str, salt: str = "") -> str:
    """Preserve OUI (first 3 octets = vendor) at both ``redact`` and
    ``shareable`` levels; tokenize the last 3 octets at both."""
    if level == "none" or not mac:
        return mac
    if not _MAC_RE.match(mac):
        return mac   # not a MAC; leave it alone
    parts = mac.lower().split(":")
    oui = ":".join(parts[:3])
    dev_token = _token(":".join(parts[3:]), "x", salt, n=6)
    return f"{oui}:{dev_token[2:]}"  # drop the "x-" prefix, keep just the hex


def redact_hostname(name: str, level: str, salt: str = "") -> str:
    """At ``redact``: hash to ``host-XXXX``. At ``shareable``: full REDACTED."""
    if level == "none" or not name:
        return name
    if level == "shareable":
        return REDACTED
    # 'redact' — keep .local / .lan suffix as a hint about scope.
    suffix = ""
    base = name
    for s in (".local", ".lan", ".home", ".internal"):
        if name.lower().endswith(s):
            suffix = s
            base = name[: -len(s)]
            break
    return _token(base.lower(), "host", salt) + suffix


def redact_ip(ip: str, level: str, salt: str = "") -> str:
    """Private IPv4/IPv6 stays at ``redact``, becomes ``REDACTED`` at
    ``shareable``. Tailscale CGNAT (100.64.0.0/10) and ULA prefix are also
    redacted because they identify the tailnet."""
    if level == "none" or not ip:
        return ip
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return ip
    # Tailscale CGNAT and ULA: identify the tailnet; tokenize at redact,
    # drop at shareable.
    is_tailscale = (
        (isinstance(addr, ipaddress.IPv4Address) and addr in ipaddress.ip_network("100.64.0.0/10"))
        or (isinstance(addr, ipaddress.IPv6Address) and str(addr).startswith(_TS_ULA_PREFIX))
    )
    if level == "shareable":
        if is_tailscale:
            return REDACTED
        # Private IPv4 → preserve only the /24 prefix, tokenize the host part.
        if isinstance(addr, ipaddress.IPv4Address) and addr.is_private:
            octets = str(addr).split(".")
            return ".".join(octets[:3]) + "." + _token(octets[3], "h", salt, n=2)[2:]
        if addr.is_global:
            return str(addr)   # public IPs are routable; leave as-is
        return REDACTED
    # redact level
    if is_tailscale:
        return _token(str(addr), "ts", salt)
    return ip   # private + public IPs are fine at 'redact'


def redact_search_domain(domain: str, level: str, salt: str = "") -> str:
    """``*.ts.net`` and other private suffixes are identifying. Tokenize at
    ``redact``, drop at ``shareable``."""
    if level == "none" or not domain:
        return domain
    d = domain.rstrip(".")
    if _TS_DOMAIN_RE.match(d):
        if level == "shareable":
            return REDACTED
        return _token(d.lower(), "tailnet", salt) + ".ts.net"
    # other private suffixes (.local / .home / .lan / .internal) are kept;
    # they're generic categories, not identifiers.
    return domain


def redact_ssid(ssid: str, level: str, salt: str = "") -> str:
    """SSIDs of nearby networks are powerful re-identifiers (wigle.net maps
    them to physical locations). Tokenize at redact, REDACTED at shareable."""
    if level == "none" or not ssid:
        return ssid
    # macOS already redacts SSIDs in `system_profiler` output since macOS 14,
    # so most of the time we receive "<redacted>" — pass through.
    if ssid == "<redacted>":
        return ssid
    if level == "shareable":
        return REDACTED
    return _token(ssid, "ssid", salt)


# ---- top-level transformer ----

def redact_report(report: dict, level: str, salt: str | None = None) -> dict:
    """Return a NEW dict (does not mutate input) with redaction applied to
    every field that carries PII. The shape of the dict is preserved so MD/
    JSON renderers don't have to change."""
    if level not in ("none", "redact", "shareable"):
        raise ValueError(f"invalid redaction level: {level}")
    if level == "none":
        return report
    # Per-report salt: prefer caller-provided, else env var, else
    # generated_at (so tokens are stable within a single report).
    if salt is None:
        salt = _salt() or (report.get("meta", {}) or {}).get("generated_at", "")

    import copy
    r = copy.deepcopy(report)

    # meta
    meta = r.setdefault("meta", {})
    meta["redacted"] = True
    meta["redact_level"] = level

    # inventory
    inv = r.get("inventory") or {}
    host = inv.get("host") or {}
    if host.get("name"):
        host["name"] = redact_hostname(host["name"], level, salt)
    if level == "shareable" and host.get("user_shell"):
        host["user_shell"] = REDACTED
    if level == "shareable":
        osd = inv.get("os") or {}
        if osd.get("build_version"):
            osd["build_version"] = REDACTED

    # interfaces
    ifs = r.get("interfaces") or {}
    for iface in (ifs.get("interfaces") or []):
        if iface.get("mac"):
            iface["mac"] = redact_mac(iface["mac"], level, salt)

    # dns
    dns = r.get("dns") or {}
    for resolver in (dns.get("resolvers") or []):
        if level == "shareable" and resolver.get("nameservers"):
            resolver["nameservers"] = [
                redact_ip(ns, level, salt) for ns in resolver["nameservers"]
            ]
        resolver["search"] = [
            redact_search_domain(d, level, salt) for d in (resolver.get("search") or [])
        ]
        if resolver.get("domain"):
            resolver["domain"] = redact_search_domain(resolver["domain"], level, salt)

    # hosts
    hosts = (r.get("hosts") or {}).get("hosts") or []
    for h in hosts:
        if h.get("mac"):
            h["mac"] = redact_mac(h["mac"], level, salt)
        if h.get("name"):
            h["name"] = redact_hostname(h["name"], level, salt)
        if h.get("known_name"):
            h["known_name"] = redact_hostname(h["known_name"], level, salt)
        # role is operator-supplied; drop at shareable to avoid leaking
        # customer naming.
        if level == "shareable" and h.get("role"):
            h["role"] = REDACTED

    # topology section mirrors hosts; redact the same way.
    topo_hosts = (r.get("topology") or {}).get("hosts") or []
    for h in topo_hosts:
        if h.get("mac"):
            h["mac"] = redact_mac(h["mac"], level, salt)
        if h.get("name"):
            h["name"] = redact_hostname(h["name"], level, salt)
        if h.get("known_name"):
            h["known_name"] = redact_hostname(h["known_name"], level, salt)

    # diagnostics
    diag = r.get("diagnostics") or {}
    for tun in (diag.get("vpn_tunnels") or []):
        if tun.get("inet"):
            tun["inet"] = redact_ip(tun["inet"], level, salt)
        if level == "shareable" and tun.get("socket_owners"):
            tun["socket_owners"] = [REDACTED for _ in tun["socket_owners"]]

    ts = diag.get("tailscale") or {}
    if ts.get("self_ip"):
        ts["self_ip"] = redact_ip(ts["self_ip"], level, salt)
    if level == "shareable" and "logged_in" in ts:
        ts["logged_in"] = REDACTED

    if level == "shareable":
        for p in (diag.get("listening_ports") or []):
            for k in ("pid", "command", "addr"):
                if p.get(k):
                    p[k] = REDACTED

    ipv6 = diag.get("ipv6") or {}
    for key in ("global_addresses", "ula_addresses"):
        if ipv6.get(key):
            ipv6[key] = [redact_ip(a, level, salt) for a in ipv6[key]]

    return r
