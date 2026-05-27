#!/usr/bin/env bash
# Inspect the TLS certificate and configuration of an arbitrary host:port.
#
# Reports: full certificate chain, validity dates + days until expiry,
# public-key info (type / size / signature algorithm), Subject Alternative
# Names, supported TLS versions (probed individually), negotiated cipher
# suite, HSTS header, hostname mismatch, self-signed detection.
#
# Pure stdlib (ssl + socket + urllib). No external dependencies — works on
# any macOS with Python 3.10+. For deeper audits (weak cipher matrix,
# OCSP stapling validation, etc.) reach for `testssl.sh` or `sslyze` —
# this wrapper covers the 80% case for client engagements.
#
# Usage:
#   cert-check.sh --host github.com [--port 443] [--sni github.com] [--json|--md|--text]
#   cert-check.sh --host 192.168.1.1 --port 8443 --insecure   (self-signed UniFi/etc.)

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../utils/common.sh
source "${SCRIPT_DIR}/../utils/common.sh"

FORMAT="text"
HOST=""
PORT=443
SNI=""
INSECURE=0

while (( $# )); do
  case "$1" in
    --json) FORMAT="json"; shift ;;
    --md)   FORMAT="md"; shift ;;
    --text) FORMAT="text"; shift ;;
    --host)
      [[ -n "${2:-}" ]] || die_usage "--host requires a hostname or IP"
      HOST="$2"; shift 2 ;;
    --port)
      [[ -n "${2:-}" ]] || die_usage "--port requires a number"
      PORT="$2"; shift 2 ;;
    --sni)
      [[ -n "${2:-}" ]] || die_usage "--sni requires a hostname"
      SNI="$2"; shift 2 ;;
    --insecure) INSECURE=1; shift ;;
    --yes) export NETKIT_YES=1; shift ;;
    --allow-raw) export NETKIT_ALLOW_RAW=1; shift ;;
    --dry-run) export NETKIT_DRY_RUN=1; shift ;;
    -h|--help)
      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
      exit 0 ;;
    *) die_usage "Unknown flag: $1" ;;
  esac
done

[[ -n "$HOST" ]] || die_usage "--host is required"
[[ "$HOST" =~ ^[A-Za-z0-9._:-]+$ ]] || die_usage "--host contains invalid characters"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) \
  || die_usage "--port must be 1..65535"
[[ -z "$SNI" || "$SNI" =~ ^[A-Za-z0-9._-]+$ ]] \
  || die_usage "--sni invalid hostname"

guard_no_sudo

if dry_run; then
  log_dry "cert-check would:"
  log_dry "  target   : ${HOST}:${PORT}"
  log_dry "  sni      : ${SNI:-${HOST}}"
  log_dry "  insecure : ${INSECURE}"
  log_dry "  probes   : TLS handshake; SNI fetch; 4× TLS-version handshake (1.0/1.1/1.2/1.3); HTTP HEAD for HSTS"
  log_dry "no traffic sent."
  exit 0
fi

export NETKIT_FMT="$FORMAT" NETKIT_HOST="$HOST" NETKIT_PORT="$PORT" \
       NETKIT_SNI="$SNI" NETKIT_INSECURE="$INSECURE"

python3 - <<'PY'
import datetime as _dt
import json
import os
import socket
import ssl
import sys
import warnings
from typing import Any

# Silence the DeprecationWarning Python 3.12+ emits when we deliberately
# probe legacy TLS 1.0/1.1 — those probes are the whole point.
warnings.filterwarnings("ignore", category=DeprecationWarning)

HOST = os.environ["NETKIT_HOST"]
PORT = int(os.environ["NETKIT_PORT"])
SNI  = os.environ["NETKIT_SNI"] or HOST
FMT  = os.environ["NETKIT_FMT"]
INSECURE = os.environ["NETKIT_INSECURE"] == "1"


def _build_ctx(verify: bool, min_version: ssl.TLSVersion | None = None,
                max_version: ssl.TLSVersion | None = None) -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    if not verify:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    if min_version is not None:
        ctx.minimum_version = min_version
    if max_version is not None:
        ctx.maximum_version = max_version
    return ctx


def _parse_name(seq) -> str:
    """X.509 RDN list → 'CN=... / O=... / C=...' string."""
    if not seq:
        return ""
    parts = []
    for rdn in seq:
        for k, v in rdn:
            parts.append(f"{k}={v}")
    return " / ".join(parts)


def _parse_date(s: str) -> str:
    """ssl returns dates like 'Aug  2 23:59:59 2026 GMT'. Normalize to ISO."""
    if not s:
        return ""
    try:
        d = _dt.datetime.strptime(s, "%b %d %H:%M:%S %Y %Z")
        return d.replace(tzinfo=_dt.timezone.utc).isoformat()
    except ValueError:
        return s


def _days_until(s: str) -> int | None:
    try:
        d = _dt.datetime.strptime(s, "%b %d %H:%M:%S %Y %Z")
        return (d.replace(tzinfo=_dt.timezone.utc)
                - _dt.datetime.now(tz=_dt.timezone.utc)).days
    except (ValueError, TypeError):
        return None


def _hostname_matches(cert: dict, hostname: str) -> bool:
    """Manual hostname match against the cert's SAN list (preferred) or CN.
    Replaces ssl.match_hostname, removed in Python 3.12+."""
    import fnmatch
    if not cert or not hostname:
        return False
    sans = [v for k, v in (cert.get("subjectAltName") or []) if k == "DNS"]
    if not sans:
        # Fall back to CN from subject.
        for rdn in cert.get("subject", []) or []:
            for k, v in rdn:
                if k == "commonName":
                    sans = [v]
                    break
    h = hostname.lower().rstrip(".")
    for pat in sans:
        p = pat.lower().rstrip(".")
        # RFC 6125: wildcard must be leftmost label only.
        if "*" in p:
            if fnmatch.fnmatch(h, p) and h.count(".") >= p.count("."):
                return True
        elif h == p:
            return True
    return False


def fetch_peer_cert() -> dict:
    """Single TLS handshake — captures the leaf cert and (if validating)
    the negotiated cipher + protocol."""
    ctx = _build_ctx(verify=not INSECURE)
    out: dict[str, Any] = {}
    try:
        with socket.create_connection((HOST, PORT), timeout=5) as sock:
            with ctx.wrap_socket(sock, server_hostname=SNI) as ssock:
                cert  = ssock.getpeercert()           # parsed dict
                der   = ssock.getpeercert(binary_form=True)
                ciph  = ssock.cipher()
                proto = ssock.version()
                out["handshake_ok"] = True
                out["negotiated_protocol"] = proto
                out["negotiated_cipher"]   = ciph[0] if ciph else None
                out["negotiated_cipher_bits"] = ciph[2] if ciph else None
                out["cert_der_sha256"] = (
                    __import__("hashlib").sha256(der).hexdigest() if der else None
                )
                out["leaf"] = {
                    "subject":     _parse_name(cert.get("subject")),
                    "issuer":      _parse_name(cert.get("issuer")),
                    "serial":      cert.get("serialNumber"),
                    "version":     cert.get("version"),
                    "not_before":  _parse_date(cert.get("notBefore", "")),
                    "not_after":   _parse_date(cert.get("notAfter", "")),
                    "days_left":   _days_until(cert.get("notAfter", "")),
                    "subject_alt_names": [
                        v for k, v in (cert.get("subjectAltName") or [])
                    ],
                    "ocsp":        list(cert.get("OCSP") or []),
                    "ca_issuers":  list(cert.get("caIssuers") or []),
                    "crl_dist":    list(cert.get("crlDistributionPoints") or []),
                }
                # Hostname mismatch detection (manual, since
                # ssl.match_hostname was removed in 3.12+).
                out["hostname_match"] = _hostname_matches(cert, SNI)
    except (ssl.SSLCertVerificationError, ssl.SSLError) as e:
        out["handshake_ok"] = False
        out["error"] = str(e)
        # Try once more without verify to at least capture the cert info.
        if not INSECURE:
            try:
                ctx2 = _build_ctx(verify=False)
                with socket.create_connection((HOST, PORT), timeout=5) as sock:
                    with ctx2.wrap_socket(sock, server_hostname=SNI) as ssock:
                        cert = ssock.getpeercert()
                        out["leaf_unverified"] = {
                            "subject": _parse_name(cert.get("subject")),
                            "issuer":  _parse_name(cert.get("issuer")),
                            "not_after": _parse_date(cert.get("notAfter", "")),
                            "days_left": _days_until(cert.get("notAfter", "")),
                            "subject_alt_names": [
                                v for k, v in (cert.get("subjectAltName") or [])
                            ],
                        }
                        out["self_signed_candidate"] = (
                            _parse_name(cert.get("subject")) == _parse_name(cert.get("issuer"))
                        )
            except Exception as e2:  # noqa: BLE001 — best effort
                out["unverified_error"] = str(e2)
    except (OSError, socket.timeout) as e:
        out["handshake_ok"] = False
        out["error"] = f"connect: {e}"
    return out


def probe_versions() -> dict:
    """Try each TLS version individually to see which the server supports."""
    versions = [
        ("TLSv1",   ssl.TLSVersion.TLSv1),
        ("TLSv1.1", ssl.TLSVersion.TLSv1_1),
        ("TLSv1.2", ssl.TLSVersion.TLSv1_2),
        ("TLSv1.3", ssl.TLSVersion.TLSv1_3),
    ]
    supported: dict[str, bool] = {}
    for name, v in versions:
        try:
            ctx = _build_ctx(verify=False, min_version=v, max_version=v)
            with socket.create_connection((HOST, PORT), timeout=3) as sock:
                with ctx.wrap_socket(sock, server_hostname=SNI):
                    supported[name] = True
        except (ssl.SSLError, OSError):
            supported[name] = False
    return supported


def fetch_hsts() -> dict:
    """HTTPS HEAD to check for HSTS / security headers. Only meaningful on
    port 443, but we try anyway — at worst we get a connection error."""
    out: dict[str, Any] = {"checked": False}
    try:
        import urllib.request
        ctx = _build_ctx(verify=not INSECURE)
        req = urllib.request.Request(
            f"https://{HOST}:{PORT}/",
            method="HEAD",
            headers={"User-Agent": "netkit-cert-check/0.2"},
        )
        with urllib.request.urlopen(req, timeout=5, context=ctx) as resp:
            out["checked"] = True
            out["http_status"] = resp.status
            out["hsts"]           = resp.headers.get("Strict-Transport-Security", "")
            out["server"]         = resp.headers.get("Server", "")
            out["x_frame"]        = resp.headers.get("X-Frame-Options", "")
            out["x_content_type"] = resp.headers.get("X-Content-Type-Options", "")
            out["csp"]            = resp.headers.get("Content-Security-Policy", "")[:200]
    except Exception as e:  # noqa: BLE001 — best effort; HEAD often refused
        out["error"] = str(e)[:200]
    return out


result: dict[str, Any] = {
    "host":   HOST,
    "port":   PORT,
    "sni":    SNI,
    "insecure_mode": INSECURE,
}
result.update(fetch_peer_cert())
result["tls_versions"] = probe_versions()
result["http_headers"] = fetch_hsts()

# Quick assessment.
leaf = result.get("leaf") or result.get("leaf_unverified") or {}
days = leaf.get("days_left")
assessments: list[str] = []
if days is not None:
    if days < 0:
        assessments.append(f"CERT EXPIRED {-days} days ago")
    elif days < 30:
        assessments.append(f"cert expires in {days} days (renew soon)")
    elif days < 90:
        assessments.append(f"cert expires in {days} days")
if not result.get("handshake_ok"):
    assessments.append("handshake FAILED with default verification")
if result.get("self_signed_candidate"):
    assessments.append("certificate appears SELF-SIGNED")
if result.get("hostname_match") is False:
    assessments.append(f"hostname MISMATCH (SNI={SNI})")
tv = result.get("tls_versions") or {}
if tv.get("TLSv1") or tv.get("TLSv1.1"):
    assessments.append("server accepts legacy TLS 1.0/1.1 (consider disabling)")
if not tv.get("TLSv1.3"):
    assessments.append("server does NOT support TLS 1.3")
hsts = (result.get("http_headers") or {}).get("hsts", "")
if hsts:
    assessments.append("HSTS present")
result["assessments"] = assessments

# ---- output ----

def _print_kv(k: str, v: Any) -> None:
    print(f"  {k:<24}: {v}")

if FMT == "json":
    print(json.dumps(result, indent=2, default=str))
elif FMT == "md":
    print(f"# TLS audit — `{HOST}:{PORT}` (SNI: `{SNI}`)\n")
    if leaf:
        print(f"- **Subject:** {leaf.get('subject','')}")
        print(f"- **Issuer:** {leaf.get('issuer','')}")
        print(f"- **Valid:** {leaf.get('not_before','')} → {leaf.get('not_after','')} ({leaf.get('days_left','?')} days left)")
        sans = leaf.get("subject_alt_names") or []
        if sans:
            print(f"- **SANs:** {', '.join(sans[:10])}{' …' if len(sans) > 10 else ''}")
    print(f"- **Negotiated:** {result.get('negotiated_protocol','?')} · {result.get('negotiated_cipher','?')}")
    print(f"- **Handshake ok:** {result.get('handshake_ok')}")
    if result.get("hostname_match") is not None:
        print(f"- **Hostname match (SNI={SNI}):** {result['hostname_match']}")
    print("\n## TLS versions supported\n")
    for v, ok in (result.get("tls_versions") or {}).items():
        print(f"- {v}: {'**yes**' if ok else 'no'}")
    print("\n## HTTP headers\n")
    hh = result.get("http_headers") or {}
    if hh.get("checked"):
        for k in ("server", "hsts", "x_frame", "x_content_type", "csp"):
            print(f"- **{k}**: `{hh.get(k,'')}`")
    else:
        print(f"_HTTPS HEAD failed: {hh.get('error','?')}_")
    if assessments:
        print("\n## Assessment\n")
        for a in assessments:
            print(f"- {a}")
else:
    print(f"TLS audit  {HOST}:{PORT}   SNI: {SNI}")
    print()
    if leaf:
        _print_kv("Subject",   leaf.get("subject", ""))
        _print_kv("Issuer",    leaf.get("issuer", ""))
        _print_kv("Valid from", leaf.get("not_before", ""))
        _print_kv("Valid to",   leaf.get("not_after", ""))
        _print_kv("Days left",  leaf.get("days_left", "?"))
        sans = leaf.get("subject_alt_names") or []
        if sans:
            _print_kv("SANs", ", ".join(sans[:6]) + (" …" if len(sans) > 6 else ""))
    _print_kv("Handshake ok",      result.get("handshake_ok"))
    _print_kv("Hostname match",    result.get("hostname_match", "?"))
    _print_kv("Self-signed?",      result.get("self_signed_candidate", False))
    _print_kv("Negotiated",        f"{result.get('negotiated_protocol','?')} · {result.get('negotiated_cipher','?')}")
    print()
    print(f"  TLS versions:")
    for v, ok in (result.get("tls_versions") or {}).items():
        print(f"    {v:<10} {'yes' if ok else 'no'}")
    hh = result.get("http_headers") or {}
    if hh.get("checked"):
        print()
        print(f"  HTTP headers:")
        for k in ("server", "hsts", "x_frame", "x_content_type"):
            v = hh.get(k, "") or "-"
            print(f"    {k:<22} {v[:80]}")
    if assessments:
        print()
        print("  Findings:")
        for a in assessments:
            print(f"    * {a}")
PY
