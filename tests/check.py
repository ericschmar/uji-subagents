#!/usr/bin/env python3
import errno
import fcntl
import os
import pty
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def command(data, mode):
    return [
        "uji",
        "run",
        "--config-dir",
        str(ROOT / "tests/config"),
        "--data-dir",
        data,
        mode,
    ]


def terminal_check(data):
    pid, master = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 120, 0, 0))
        os.execvp("uji", command(data, "ui"))
    chunks = []
    deadline = time.monotonic() + 30
    status = None
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                try:
                    value = os.read(master, 65536)
                    if not value:
                        break
                    chunks.append(value)
                    if b"\x1b[6n" in value:
                        os.write(master, b"\x1b[1;1R")
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    break
            ended, found = os.waitpid(pid, os.WNOHANG)
            if ended:
                status = found
                break
        else:
            os.kill(pid, signal.SIGKILL)
            raise RuntimeError("UI test timed out")
    finally:
        if status is None:
            _, status = os.waitpid(pid, 0)
        os.close(master)
    output = b"".join(chunks).decode(errors="replace")
    if os.waitstatus_to_exitcode(status) != 0 or "passed terminal UI" not in output:
        raise RuntimeError(output)
    print(
        "passed terminal UI: right sidebar, live view, steering input, drafts, return shortcut, approval, narrow layout"
    )


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="uji-managed-tests-") as data:
        for mode in ("unit", "integration"):
            subprocess.run(command(data, mode), check=True, timeout=30)
        terminal_check(data)
