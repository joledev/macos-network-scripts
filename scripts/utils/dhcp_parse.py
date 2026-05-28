"""Parse DHCP (BOOTP) packets out of a classic-format pcap.

DHCP DISCOVER/REQUEST frames carry the strongest passive device signal:
  * option 12  hostname          — often names the device outright
  * option 60  vendor class id   — e.g. "android-dhcp-14", "MSFT 5.0", "udhcp"
  * option 55  parameter request — the ordered list IS the Fingerbank fingerprint
  * chaddr     client MAC

Stdlib-only so it can be unit-tested with synthetic packets and reused by
dhcp.sh (which captures via tcpdump). Reuses lldp_parse.iter_pcap for framing.
"""
from __future__ import annotations

try:
    from lldp_parse import iter_pcap
except Exception:  # pragma: no cover
    iter_pcap = None

MSG_TYPE = {1: "DISCOVER", 2: "OFFER", 3: "REQUEST", 4: "DECLINE",
            5: "ACK", 6: "NAK", 7: "RELEASE", 8: "INFORM"}
DHCP_MAGIC = b"\x63\x82\x53\x63"


def parse_dhcp(payload: bytes) -> dict | None:
    """Parse a DHCP message (bytes after the UDP header)."""
    if len(payload) < 240 or payload[236:240] != DHCP_MAGIC:
        return None
    chaddr = payload[28:34]
    mac = ":".join(f"{b:02x}" for b in chaddr)
    rec: dict = {"mac": mac}
    i = 240
    while i < len(payload):
        t = payload[i]
        if t == 255:                 # End
            break
        if t == 0:                   # Pad
            i += 1
            continue
        if i + 1 >= len(payload):
            break
        ln = payload[i + 1]
        v = payload[i + 2:i + 2 + ln]
        i += 2 + ln
        if t == 53 and v:
            rec["msg_type"] = MSG_TYPE.get(v[0], str(v[0]))
        elif t == 12:
            rec["hostname"] = v.decode(errors="replace").strip("\x00")
        elif t == 60:
            rec["vendor_class"] = v.decode(errors="replace").strip("\x00")
        elif t == 55:
            rec["param_list"] = list(v)
            rec["fingerprint"] = ",".join(str(b) for b in v)
        elif t == 50 and len(v) == 4:
            rec["requested_ip"] = ".".join(str(b) for b in v)
        elif t == 61:
            rec["client_id"] = v.hex()
    return rec


# --- Fingerbank-style OS / device classification ---------------------------
#
# Two signals, strongest first:
#   1. option 60 (vendor class id) — DETERMINISTIC, vendors stamp it.
#   2. option 55 (parameter request list) — a heuristic "fingerprint"; the
#      ordered set of requested options clusters by OS/stack. The canonical
#      database is Fingerbank's (huge, license-bound), so we ship only a small
#      curated set of the most stable signatures and label results "(heuristic)".
#      For exact matches, set FINGERBANK_API_KEY and use fingerbank_lookup().

# Substring → label. First match wins; order specific-before-generic.
_VENDOR_CLASS_RULES: list[tuple[str, str]] = [
    ("android-dhcp", "Android"),
    ("msft 5.0", "Windows"),
    ("msft", "Windows"),
    ("dhcpcd", "Linux (dhcpcd)"),
    ("udhcp", "Embedded Linux / router (BusyBox udhcp)"),
    ("ipxe", "iPXE network boot"),
    ("pxeclient", "PXE network boot"),
    ("aastra", "Aastra/Mitel VoIP phone"),
    ("polycom", "Polycom VoIP phone"),
    ("hewlett-packard", "HP printer"),
    ("htc", "HTC device"),
    ("amazon", "Amazon device"),
    ("roku", "Roku media player"),
    ("digi-", "Digi device"),
    ("ubnt", "Ubiquiti device"),
]

# Exact option-55 fingerprint → label (heuristic; see note above).
_OPT55_FINGERPRINTS: dict[str, str] = {
    "1,3,6,15,119,95,252,44,46": "Apple macOS/iOS",
    "1,121,3,6,15,119,252,95,44,46": "Apple macOS",
    "1,3,6,15,119,252": "Apple iOS/macOS",
    "1,33,3,6,15,28,51,58,59": "Android",
    "1,3,6,15,26,28,51,58,59,43": "Android",
    "1,3,6,15,31,33,43,44,46,47,119,121,249,252": "Windows",
    "1,15,3,6,44,46,47,31,33,121,249,43": "Windows 10/11",
    "1,3,6,12,15,28,42": "Printer / embedded",
    "1,3,6,12,15,17,23,28,29,31,33,40,41,42": "Linux",
    "1,3,6": "IoT / minimal stack",
}


def classify_os(rec: dict) -> str:
    """Best-effort OS/device label from a parsed DHCP record. Empty if unknown.

    vendor_class (option 60) is authoritative when present; otherwise the
    option-55 fingerprint is matched against the curated table and suffixed
    "(heuristic)" so callers don't over-trust it.
    """
    vc = (rec.get("vendor_class") or "").strip().lower()
    if vc:
        for needle, label in _VENDOR_CLASS_RULES:
            if needle in vc:
                return label
    fp = rec.get("fingerprint") or ""
    if fp and fp in _OPT55_FINGERPRINTS:
        return f"{_OPT55_FINGERPRINTS[fp]} (heuristic)"
    return ""


def fingerbank_lookup(fingerprint: str, api_key: str, timeout: float = 4.0) -> dict:
    """Opt-in exact lookup against the Fingerbank cloud DB (needs an API key).

    Never called automatically — keeps the toolkit offline by default. Returns
    {} on any error so callers can treat it as best-effort enrichment.
    """
    if not fingerprint or not api_key:
        return {}
    import json as _json
    import urllib.parse
    import urllib.request
    qs = urllib.parse.urlencode({
        "key": api_key,
        "dhcp_fingerprint": fingerprint,
    })
    url = f"https://api.fingerbank.org/api/v2/combinations/interrogate?{qs}"
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            data = _json.loads(resp.read().decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001 — best effort; network/parse/auth errors
        return {}
    dev = data.get("device", {}) or {}
    return {
        "name": dev.get("name", ""),
        "score": data.get("score"),
        "version": data.get("version", ""),
    }


def _udp_dhcp(ip_pkt: bytes) -> bytes | None:
    """Return the DHCP payload from an IPv4 packet, or None."""
    if len(ip_pkt) < 20 or (ip_pkt[0] >> 4) != 4:
        return None
    ihl = (ip_pkt[0] & 0x0F) * 4
    if ip_pkt[9] != 17 or len(ip_pkt) < ihl + 8:   # protocol 17 = UDP
        return None
    udp = ip_pkt[ihl:]
    sport = int.from_bytes(udp[0:2], "big")
    dport = int.from_bytes(udp[2:4], "big")
    if 67 not in (sport, dport) and 68 not in (sport, dport):
        return None
    return udp[8:]


def analyze(pcap: bytes) -> list[dict]:
    """Parse DHCP records from a pcap blob, de-duplicated by (mac, fingerprint).

    DISCOVER/REQUEST (from clients) carry the device fingerprint; OFFER/ACK
    (from the server) are kept too but rarely fingerprintable.
    """
    if iter_pcap is None:
        return []
    seen = {}
    for etype, _dst, _src, l2 in iter_pcap(pcap):
        if etype != 0x0800:           # IPv4 only
            continue
        dhcp = _udp_dhcp(l2)
        if dhcp is None:
            continue
        rec = parse_dhcp(dhcp)
        if not rec:
            continue
        key = (rec.get("mac"), rec.get("fingerprint", ""), rec.get("msg_type", ""))
        # Prefer a record that actually carries identity fields.
        score = sum(bool(rec.get(k)) for k in ("hostname", "vendor_class", "fingerprint"))
        prev = seen.get(key)
        if not prev or score > prev[0]:
            seen[key] = (score, rec)
    out = [r for _s, r in seen.values()]
    for r in out:
        guess = classify_os(r)
        if guess:
            r["os_guess"] = guess
    return out
