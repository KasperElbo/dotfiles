#!/usr/bin/env python3
"""Exercise a CoreCLR DAP adapter through a breakpoint and evaluation."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import select
import signal
import subprocess
import sys
import time
from typing import Any, Callable


class DapClient:
    def __init__(self, command: list[str], timeout: float) -> None:
        self.timeout = timeout
        self.sequence = 0
        self.pending: list[dict[str, Any]] = []
        self.transcript: list[dict[str, Any]] = []
        self.process_group: int | None = None
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=os.name == "posix",
        )
        if os.name == "posix":
            self.process_group = self.process.pid

    def send(self, command: str, arguments: dict[str, Any]) -> int:
        self.sequence += 1
        message = {
            "seq": self.sequence,
            "type": "request",
            "command": command,
            "arguments": arguments,
        }
        payload = json.dumps(message, separators=(",", ":")).encode()
        assert self.process.stdin is not None
        self.process.stdin.write(f"Content-Length: {len(payload)}\r\n\r\n".encode() + payload)
        self.process.stdin.flush()
        return self.sequence

    def _read(self, deadline: float) -> dict[str, Any]:
        assert self.process.stdout is not None
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
            raise TimeoutError("timed out waiting for a DAP message")

        headers: dict[str, str] = {}
        while True:
            line = self.process.stdout.readline()
            if not line:
                raise RuntimeError(f"debug adapter exited with status {self.process.poll()}")
            if line == b"\r\n":
                break
            name, value = line.decode().split(":", 1)
            headers[name.lower()] = value.strip()

        length = int(headers["content-length"])
        payload = self.process.stdout.read(length)
        if len(payload) != length:
            raise RuntimeError("debug adapter returned a truncated DAP message")
        message = json.loads(payload)
        self.transcript.append(message)
        return message

    def wait_for(self, predicate: Callable[[dict[str, Any]], bool]) -> dict[str, Any]:
        deadline = time.monotonic() + self.timeout
        for index, message in enumerate(self.pending):
            if predicate(message):
                return self.pending.pop(index)

        while True:
            message = self._read(deadline)
            if predicate(message):
                return message
            self.pending.append(message)

    def request(self, command: str, arguments: dict[str, Any]) -> dict[str, Any]:
        sequence = self.send(command, arguments)
        response = self.wait_for(
            lambda message: message.get("type") == "response"
            and message.get("request_seq") == sequence
        )
        if not response.get("success"):
            raise RuntimeError(
                f"DAP {command} failed: {response.get('message', '<no diagnostic>')}"
            )
        return response

    def event(self, name: str) -> dict[str, Any]:
        return self.wait_for(
            lambda message: message.get("type") == "event"
            and message.get("event") == name
        )

    def _group_exists(self) -> bool:
        if self.process_group is None:
            return self.process.poll() is None
        try:
            os.killpg(self.process_group, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    def _signal_process_tree(self, requested_signal: signal.Signals) -> None:
        if self.process_group is not None:
            os.killpg(self.process_group, requested_signal)
        elif self.process.poll() is None:
            self.process.send_signal(requested_signal)

    def close(self) -> list[str]:
        """Terminate the adapter and every launched debuggee without raising."""
        notes: list[str] = []
        try:
            if self._group_exists():
                try:
                    self._signal_process_tree(signal.SIGTERM)
                except ProcessLookupError:
                    pass

                deadline = time.monotonic() + 1
                while self._group_exists() and time.monotonic() < deadline:
                    self.process.poll()
                    time.sleep(0.05)

                if self._group_exists():
                    try:
                        self._signal_process_tree(signal.SIGKILL)
                    except ProcessLookupError:
                        pass

            try:
                self.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                notes.append("adapter did not exit after process-tree termination")
        except Exception as error:  # Cleanup must not replace the DAP failure.
            notes.append(f"process-tree cleanup failed: {error}")
        return notes

    def diagnostics(self) -> str:
        notes = self.close()
        stderr = b""
        try:
            _, stderr = self.process.communicate(timeout=1)
        except subprocess.TimeoutExpired as error:
            stderr = error.stderr or b""
            notes.append("adapter pipes remained open after process-tree termination")
            for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
                if stream is not None:
                    try:
                        stream.close()
                    except Exception as close_error:
                        notes.append(f"closing an adapter pipe failed: {close_error}")
        except Exception as error:  # Diagnostics must preserve the original exception.
            notes.append(f"collecting adapter stderr failed: {error}")
        rendered = "\n".join(json.dumps(message, sort_keys=True) for message in self.transcript)
        cleanup = "\n".join(notes)
        return (
            f"DAP transcript:\n{rendered}\n"
            f"Adapter stderr:\n{stderr.decode(errors='replace')}\n"
            f"Cleanup diagnostics:\n{cleanup}"
        )


def breakpoint_line(source: pathlib.Path) -> int:
    for number, line in enumerate(source.read_text(encoding="utf-8").splitlines(), 1):
        if "// BREAKPOINT" in line:
            return number
    raise RuntimeError(f"breakpoint marker is missing from {source}")


def run(adapter: pathlib.Path, assembly: pathlib.Path, source: pathlib.Path, timeout: float) -> None:
    client = DapClient([str(adapter), "--interpreter=vscode"], timeout)
    try:
        client.request(
            "initialize",
            {
                "clientID": "dotfiles-contract-test",
                "clientName": "dotfiles contract test",
                "adapterID": "coreclr",
                "pathFormat": "path",
                "linesStartAt1": True,
                "columnsStartAt1": True,
                "supportsVariableType": True,
                "supportsVariablePaging": True,
                "locale": "en-us",
            },
        )
        # netcoredbg 3.2.0 advertises its capabilities in response to
        # initialize but does not send the optional initialized event before
        # accepting configuration requests. Continue after the successful
        # response; any later event remains buffered by DapClient.
        breakpoint = breakpoint_line(source)
        response = client.request(
            "setBreakpoints",
            {
                "source": {"name": source.name, "path": str(source)},
                "lines": [breakpoint],
                "breakpoints": [{"line": breakpoint}],
                "sourceModified": False,
            },
        )
        breakpoints = response.get("body", {}).get("breakpoints", [])
        if len(breakpoints) != 1:
            raise RuntimeError(f"debug adapter did not accept the breakpoint: {response}")

        client.request(
            "launch",
            {
                "name": ".NET debugger architecture smoke",
                "type": "coreclr",
                "request": "launch",
                "program": str(assembly),
                "cwd": str(assembly.parent),
                "console": "internalConsole",
                "stopAtEntry": False,
                "justMyCode": True,
            },
        )
        client.request("configurationDone", {})
        stopped = client.event("stopped")
        if stopped.get("body", {}).get("reason") != "breakpoint":
            raise RuntimeError(f"debug adapter stopped for the wrong reason: {stopped}")

        thread_id = stopped["body"]["threadId"]
        stack = client.request(
            "stackTrace", {"threadId": thread_id, "startFrame": 0, "levels": 1}
        )
        frames = stack.get("body", {}).get("stackFrames", [])
        if not frames:
            raise RuntimeError("debug adapter returned no stack frame at the breakpoint")

        evaluation = client.request(
            "evaluate",
            {
                "expression": "value",
                "frameId": frames[0]["id"],
                "context": "watch",
            },
        )
        result = str(evaluation.get("body", {}).get("result", ""))
        if result != "42":
            raise RuntimeError(f"debug evaluation returned {result!r}, expected '42'")

        client.request("continue", {"threadId": thread_id})
        client.wait_for(
            lambda message: message.get("type") == "event"
            and message.get("event") in {"exited", "terminated"}
        )
        print("DAP breakpoint/evaluate smoke passed (value == 42).")
    except Exception:
        print(client.diagnostics(), file=sys.stderr)
        raise
    finally:
        client.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("adapter", type=pathlib.Path)
    parser.add_argument("assembly", type=pathlib.Path)
    parser.add_argument("source", type=pathlib.Path)
    parser.add_argument("--timeout", type=float, default=30)
    args = parser.parse_args()
    run(args.adapter.resolve(), args.assembly.resolve(), args.source.resolve(), args.timeout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
