"""Shared pytest fixtures for the netkit test suite.

Adds scripts/utils/ to sys.path so test modules can import the helpers
directly without a package install.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
UTILS_DIR = REPO_ROOT / "scripts" / "utils"
NETKIT_BIN = REPO_ROOT / "bin" / "netkit"

# Make scripts/utils importable as top-level modules (oui, known_hosts, format).
sys.path.insert(0, str(UTILS_DIR))


@pytest.fixture(autouse=True)
def _isolate_user_cache(tmp_path, monkeypatch):
    """Point XDG_CACHE_HOME at an empty per-test dir so tests never read the
    developer's real ~/.cache/netkit (oui.txt / Wireshark manuf). Without this,
    oui lookups would resolve against whatever the user happens to have cached,
    making vendor-string assertions non-hermetic. Tests that want a cache create
    files under their own XDG_CACHE_HOME. Also resets oui's manuf memo."""
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "xdg_cache"))
    try:
        import oui
        oui._MANUF_LOADED = False
        oui._MANUF_CACHE = None
    except Exception:
        pass
    yield


@pytest.fixture()
def repo_root() -> Path:
    return REPO_ROOT


@pytest.fixture()
def netkit_bin() -> Path:
    return NETKIT_BIN


@pytest.fixture()
def tmp_output_dir(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    """Isolated output directory; netkit writes here instead of repo's output/."""
    d = tmp_path / "output"
    d.mkdir()
    monkeypatch.setenv("NETKIT_OUTPUT_DIR", str(d))
    return d


@pytest.fixture()
def run_netkit(netkit_bin: Path):
    """Run `bin/netkit` with extra env, capture stdout/stderr/exit code."""
    def _run(*args, env_extra=None, check=False, timeout=30):
        env = os.environ.copy()
        if env_extra:
            env.update(env_extra)
        proc = subprocess.run(
            [str(netkit_bin), *map(str, args)],
            capture_output=True, text=True, env=env, timeout=timeout,
        )
        if check and proc.returncode != 0:
            raise AssertionError(
                f"netkit {args} exited {proc.returncode}\n"
                f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
            )
        return proc
    return _run


@pytest.fixture()
def fixtures_dir() -> Path:
    return REPO_ROOT / "tests" / "fixtures"


def has_command(cmd: str) -> bool:
    return shutil.which(cmd) is not None
