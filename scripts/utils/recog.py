#!/usr/bin/env python3
"""Match service banners against Rapid7's Recog fingerprint database.

Recog (https://github.com/rapid7/recog, BSD-2-Clause) is a large, curated set
of regular expressions that turn raw banners — an HTTP `Server` header, a page
`<title>`, an HTTP auth realm, an SNMP sysDescr, an SSH banner — into
structured identity: vendor, product, version, device type, OS. We already
collect every one of those signals in `fingerprint.sh` / `snmp.sh`; this module
runs them through Recog so "lighttpd/1.4.x" becomes a TP-Link router and
"Hipcam RealServer/V1.0" becomes an IP camera.

Stdlib only (xml.etree + re). The XML DB is NOT bundled — fetch it once with
`netkit recog fetch` (writes to ~/.cache/netkit/recog/). When the DB is absent
every call returns {}, so callers degrade to their existing heuristics.
"""
from __future__ import annotations

import os
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# Banner kind → Recog XML filename. Only the files whose inputs we actually
# capture are listed; `netkit recog fetch` downloads exactly these.
KIND_FILES: dict[str, str] = {
    "http_server": "http_servers.xml",
    "html_title": "html_title.xml",
    "http_realm": "http_wwwauth.xml",
    "snmp_sysdescr": "snmp_sysdescr.xml",
    "ssh_banner": "ssh_banners.xml",
}

# Recog `flags` attribute tokens → Python re flags.
_FLAG_MAP = {
    "REG_ICASE": re.IGNORECASE,
    "REG_DOT_NEWLINE": re.DOTALL,
    "REG_MULTILINE": re.MULTILINE,
    "REG_LINE_BOL_EOL": re.MULTILINE,
}

# Recog param names we care about → our normalized keys.
_PARAM_MAP = {
    "os.vendor": "os_vendor",
    "os.product": "os",
    "os.family": "os_family",
    "service.vendor": "vendor",
    "service.family": "family",
    "service.product": "product",
    "service.version": "version",
    "hw.vendor": "vendor",
    "hw.product": "product",
    "hw.device": "device_type",
    "device.type": "device_type",
}

_INTERP = re.compile(r"\{([a-zA-Z0-9_.]+)\}")

# Memo: file path -> list of (compiled_regex, [(pos, name, value), ...]).
_DB: dict[str, list] = {}


def _recog_dir() -> Path:
    override = os.environ.get("NETKIT_RECOG_DIR")
    if override:
        return Path(override).expanduser()
    base = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache")))
    return base / "netkit" / "recog"


def available() -> bool:
    """True when at least one Recog XML file is present locally."""
    d = _recog_dir()
    return d.is_dir() and any((d / f).is_file() for f in KIND_FILES.values())


def _compile_file(path: Path) -> list:
    """Parse one Recog XML file into [(regex, params)]. Skips fingerprints whose
    pattern uses Ruby-only syntax that Python's re cannot compile."""
    out: list = []
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError):
        return out
    for fp in root.iter("fingerprint"):
        pattern = fp.get("pattern")
        if not pattern:
            continue
        flags = 0
        for tok in (fp.get("flags") or "").split(","):
            flags |= _FLAG_MAP.get(tok.strip(), 0)
        try:
            rx = re.compile(pattern, flags)
        except re.error:
            continue  # Ruby-specific construct (e.g. (?<name>)) — skip.
        params: list[tuple[int, str, str | None]] = []
        for p in fp.findall("param"):
            try:
                pos = int(p.get("pos", "0"))
            except ValueError:
                continue
            params.append((pos, p.get("name", ""), p.get("value")))
        out.append((rx, params))
    return out


def _load(kind: str) -> list:
    fname = KIND_FILES.get(kind)
    if not fname:
        return []
    path = _recog_dir() / fname
    key = str(path)
    if key in _DB:
        return _DB[key]
    db = _compile_file(path) if path.is_file() else []
    _DB[key] = db
    return db


def _interpolate(value: str, extracted: dict[str, str]) -> str:
    """Resolve `{service.version}`-style references against captured params."""
    def repl(m: re.Match) -> str:
        return extracted.get(m.group(1), m.group(0))
    return _INTERP.sub(repl, value)


def identify(kind: str, banner: str) -> dict:
    """Match `banner` against the Recog file for `kind`. Returns a normalized
    dict (vendor/product/version/device_type/os, plus the human description)
    or {} when the DB is missing or nothing matched."""
    if not banner:
        return {}
    if kind == "ssh_banner":
        # Recog's ssh patterns anchor on the software comment, not the wire
        # banner, so drop the "SSH-2.0-" transport prefix if present.
        banner = re.sub(r"^SSH-\d+(?:\.\d+)?-", "", banner.strip())
    for rx, params in _load(kind):
        m = rx.search(banner)
        if not m:
            continue
        # Raw Recog param values, keyed by Recog name (for interpolation).
        raw: dict[str, str] = {}
        for pos, name, value in params:
            if pos == 0:
                raw[name] = value or ""
            else:
                try:
                    g = m.group(pos)
                except (IndexError, re.error):
                    g = None
                if g is not None:
                    raw[name] = g
        # Second pass: interpolate {refs} now that all captures are known.
        for k in list(raw.keys()):
            if "{" in raw[k]:
                raw[k] = _interpolate(raw[k], raw)
        # Project into our normalized schema.
        out: dict[str, str] = {}
        for rname, oname in _PARAM_MAP.items():
            if raw.get(rname) and not out.get(oname):
                out[oname] = raw[rname]
        if out:
            return out
    return {}


def identify_http(banner: dict) -> dict:
    """Convenience: feed an http_banner() dict (server/title/realm) to Recog and
    return the first/strongest match across the three signals."""
    for kind, key in (("http_server", "server"),
                      ("html_title", "title"),
                      ("http_realm", "realm")):
        val = banner.get(key)
        if val:
            hit = identify(kind, val)
            if hit:
                return hit
    return {}


def label(hit: dict) -> str:
    """One-line human label from a match dict, e.g. 'TP-Link / Router 1.2'."""
    if not hit:
        return ""
    parts = []
    name = " ".join(x for x in (hit.get("vendor"), hit.get("product")) if x)
    if name:
        parts.append(name)
    if hit.get("version"):
        parts.append(hit["version"])
    if hit.get("device_type"):
        parts.append(f"[{hit['device_type']}]")
    elif hit.get("os"):
        parts.append(f"({hit['os']})")
    return " ".join(parts)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("usage: recog.py <kind> <banner>", file=sys.stderr)
        print(f"kinds: {', '.join(KIND_FILES)}", file=sys.stderr)
        sys.exit(2)
    if not available():
        print("recog DB not found — run 'netkit recog fetch' first", file=sys.stderr)
        sys.exit(1)
    res = identify(sys.argv[1], " ".join(sys.argv[2:]))
    print(label(res) or "(no match)")
    print(res)
