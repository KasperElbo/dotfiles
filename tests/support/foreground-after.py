#!/usr/bin/env python3
"""Run a command as the foreground job of a fresh pseudo-terminal and report
whether that job still owns the terminal once the command has finished.

Prints "foreground kept" or "foreground lost" and exits 0 either way; any other
outcome (the command failing, no answer, a timeout) exits 1. The command runs
under bash, which prints what the terminal's foreground group is after it.
"""

import os
import pty
import select
import sys

REPORT = (
    'python3 -c \'import os; print("foreground", "kept" if '
    'os.tcgetpgrp(0) == os.getpgrp() else "lost")\' </dev/tty'
)


def main() -> int:
    command = sys.argv[1]
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("bash", ["bash", "-c", f"{command} || exit 97\n{REPORT}"])
    output = b""
    while True:
        ready, _, _ = select.select([fd], [], [], 60)
        if not ready:
            os.kill(pid, 9)
            print("no output from the pseudo-terminal for 60s", file=sys.stderr)
            return 1
        try:
            data = os.read(fd, 4096)
        except OSError:
            break
        if not data:
            break
        output += data
    _, status = os.waitpid(pid, 0)
    text = output.decode(errors="replace")
    for line in text.splitlines():
        if line.strip() in ("foreground kept", "foreground lost"):
            print(line.strip())
            return 0
    print(f"exit {os.waitstatus_to_exitcode(status)}, output:\n{text}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
