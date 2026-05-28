"""inventory_db: the cross-scan device ledger (union of every host seen)."""
from __future__ import annotations

import inventory_db


def test_update_creates_and_accumulates(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "c"))
    scan1 = [{"ip": "192.168.1.42", "mac": "aa:bb:cc:00:00:01",
              "display": "Cam Taller", "role": "camera", "band": "2.4GHz",
              "vendor": "TP-Link"}]
    led = inventory_db.update(scan1, "20260101-000000", ledger={})
    e = led["aa:bb:cc:00:00:01"]
    assert e["seen_count"] == 1
    assert e["first_seen"] == "20260101-000000"
    assert "192.168.1.42" in e["ips"]
    assert "Cam Taller" in e["names"]

    # Second scan: same MAC, new IP → accumulates, count++, last_seen moves.
    scan2 = [{"ip": "192.168.1.43", "mac": "aa:bb:cc:00:00:01",
              "display": "Cam Taller", "role": "camera", "band": "2.4GHz"}]
    led = inventory_db.update(scan2, "20260102-000000", ledger=led)
    e = led["aa:bb:cc:00:00:01"]
    assert e["seen_count"] == 2
    assert e["first_seen"] == "20260101-000000"
    assert e["last_seen"] == "20260102-000000"
    assert set(e["ips"]) == {"192.168.1.42", "192.168.1.43"}


def test_macless_host_keyed_by_ip():
    led = inventory_db.update([{"ip": "10.0.0.5", "display": "x"}], "t", ledger={})
    assert "ip:10.0.0.5" in led


def test_save_and_load_roundtrip(tmp_path, monkeypatch):
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "c"))
    led = inventory_db.update([{"ip": "1.2.3.4", "mac": "de:ad:be:ef:00:01"}],
                              "t", ledger={})
    p = inventory_db.save(led)
    assert p.is_file()
    assert inventory_db.load()["de:ad:be:ef:00:01"]["mac"] == "de:ad:be:ef:00:01"


def test_absent_lists_devices_not_in_current_scan():
    led = {
        "aa:bb:cc:00:00:01": {"mac": "aa:bb:cc:00:00:01", "ips": ["192.168.1.42"]},
        "aa:bb:cc:00:00:02": {"mac": "aa:bb:cc:00:00:02", "ips": ["192.168.1.99"]},
    }
    present = [{"mac": "aa:bb:cc:00:00:01", "ip": "192.168.1.42"}]
    gone = inventory_db.absent(led, present)
    assert len(gone) == 1
    assert gone[0]["mac"] == "aa:bb:cc:00:00:02"
