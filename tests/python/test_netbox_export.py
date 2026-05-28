"""netbox_export: NetBox-ready CSV + REST payload mapping from a recon dataset."""
from __future__ import annotations

import csv
import io

import netbox_export as nb

REPORT = {
    "meta": {"generated_at": "20260101-000000"},
    "subnet": "192.168.1.0/24",
    "gateway": "192.168.1.1",
    "hosts": [
        {"ip": "192.168.1.1", "role": "router/gateway", "display": "Starlink",
         "vendor": "TIBRO Corp."},
        {"ip": "192.168.1.53", "role": "camera", "vendor": "TP-Link",
         "identity": "TP-Link Cam", "mac": "50:91:e3:85:dc:5c"},
        {"ip": "192.168.1.99", "role": "host (no open ports)", "vendor": ""},
    ],
}


def test_ip_rows_use_subnet_prefix():
    rows = nb.ip_rows(REPORT)
    assert {r["address"] for r in rows} == {
        "192.168.1.1/24", "192.168.1.53/24", "192.168.1.99/24"}
    cam = next(r for r in rows if r["address"].startswith("192.168.1.53"))
    assert "camera" in cam["description"]


def test_ip_csv_parses_with_header():
    text = nb.ip_csv(REPORT)
    reader = csv.DictReader(io.StringIO(text))
    assert reader.fieldnames == ["address", "status", "dns_name", "description"]
    rows = list(reader)
    assert len(rows) == 3
    assert all(r["status"] == "active" for r in rows)


def test_device_rows_skip_featureless_hosts():
    rows = nb.device_rows(REPORT)
    names = {r["name"] for r in rows}
    # gateway + camera have role/model worth tracking; the bare host is skipped.
    assert "Starlink" in names
    assert any("Cam" in r["device_type"] for r in rows)
    assert "192.168.1.99" not in names


def test_device_csv_columns():
    reader = csv.DictReader(io.StringIO(nb.device_csv(REPORT)))
    assert reader.fieldnames == [
        "name", "role", "manufacturer", "device_type", "site", "status", "comments"]


def test_ip_rows_empty_when_no_hosts():
    assert nb.ip_rows({"hosts": []}) == []


def test_device_rows_include_infrastructure():
    rep = dict(REPORT)
    rep["infrastructure"] = [{
        "id": "sw-sala", "name": "Switch sala", "type": "switch",
        "model": "TP-Link TL-SF1005D", "location": "Sala", "notes": "10/100 unmanaged",
    }]
    rows = nb.device_rows(rep)
    sw = next((r for r in rows if r["name"] == "Switch sala"), None)
    assert sw is not None
    assert sw["role"] == "switch"
    assert "TL-SF1005D" in sw["device_type"]
    assert sw["site"] == "Sala"
