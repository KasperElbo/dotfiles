#!/usr/bin/env python3
"""Regression coverage for DAP adapter/debuggee process cleanup."""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import tempfile
import time
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
SUPPORT = REPO_ROOT / "tests/support/dap-smoke.py"
FIXTURE = REPO_ROOT / "tests/fixtures/dap-process-tree.py"
SPEC = importlib.util.spec_from_file_location("dap_smoke", SUPPORT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SUPPORT}")
DAP_SMOKE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DAP_SMOKE)


def wait_for(path: pathlib.Path, timeout: float = 5) -> None:
    deadline = time.monotonic() + timeout
    while not path.exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    if not path.exists():
        raise AssertionError(f"timed out waiting for {path}")


class DapCleanupTest(unittest.TestCase):
    def test_diagnostics_terminate_adapter_and_debuggee_without_raising(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            ready = root / "child-ready"
            terminated = root / "child-terminated"
            client = DAP_SMOKE.DapClient(
                [sys.executable, str(FIXTURE), str(ready), str(terminated)],
                timeout=0.1,
            )
            try:
                wait_for(ready)
                started = time.monotonic()
                diagnostics: list[str] = []

                def fail_after_diagnostics() -> None:
                    try:
                        raise TimeoutError("original DAP timeout")
                    except Exception:
                        diagnostics.append(client.diagnostics())
                        raise
                    finally:
                        client.close()

                with self.assertRaisesRegex(TimeoutError, "original DAP timeout"):
                    fail_after_diagnostics()
                wait_for(terminated)
                self.assertLess(time.monotonic() - started, 3)
                self.assertIn("DAP transcript:", diagnostics[0])
                self.assertIn("Adapter stderr:", diagnostics[0])
            finally:
                client.close()


if __name__ == "__main__":
    unittest.main()
