#!/usr/bin/env python3
"""Fixture that models a debug adapter with a pipe-inheriting debuggee."""

from __future__ import annotations

import pathlib
import signal
import subprocess
import sys
import time


def run_child(ready: pathlib.Path, terminated: pathlib.Path) -> None:
    def terminate(_signum: int, _frame: object) -> None:
        terminated.write_text("terminated\n", encoding="utf-8")
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, terminate)
    ready.write_text("ready\n", encoding="utf-8")
    while True:
        time.sleep(60)


def run_adapter(ready: pathlib.Path, terminated: pathlib.Path) -> None:
    subprocess.Popen(
        [sys.executable, __file__, "--child", str(ready), str(terminated)]
    )
    while True:
        time.sleep(60)


def main() -> None:
    child = sys.argv[1] == "--child"
    offset = 2 if child else 1
    ready = pathlib.Path(sys.argv[offset])
    terminated = pathlib.Path(sys.argv[offset + 1])
    if child:
        run_child(ready, terminated)
    else:
        run_adapter(ready, terminated)


if __name__ == "__main__":
    main()
