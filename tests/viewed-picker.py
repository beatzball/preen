#!/usr/bin/env python3
"""Exercise the actual fzf process through a PTY, including asynchronous loads."""
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import struct
import sys
import termios
import time

repo, box = map(Path, sys.argv[1:])
box.mkdir(parents=True, exist_ok=True)
editor = box / "editor"
editor.write_text('#!/bin/sh\nprintf "%s" "$1" > "$PREEN_EDITOR_LOG"\n')
editor.chmod(0o755)
env = dict(os.environ, TERM="xterm-256color", SHELL="/bin/bash",
           XDG_STATE_HOME=str(box / "state"), EDITOR=str(editor),
           PREEN_EDITOR_LOG=str(box / "edited"), PREEN_SELECTED_LOG=str(box / "selected"),
           FZF_DEFAULT_OPTS='--bind \'ctrl-g:execute-silent(printf "%s" {1} > "$PREEN_SELECTED_LOG")\'')
pid, fd = pty.fork()
if pid == 0:
    os.chdir(repo)
    os.execve("/bin/bash", ["/bin/bash", os.environ["PREEN"], "diff"], env)
fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 36, 150, 0, 0))
output = bytearray()


def pump(seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if not select.select([fd], [], [], max(0, end - time.monotonic()))[0]:
            continue
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        output.extend(data)
        if b"\x1b[6n" in data:
            os.write(fd, b"\x1b[1;1R")


def key(data, seconds=0.5):
    os.write(fd, data)
    pump(seconds)


def wait_for(check, reason):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if check():
            return
        pump(0.1)
    raise AssertionError(reason)


def marks():
    return list((box / "state").rglob("*.viewed"))


def selected():
    path = box / "selected"
    path.unlink(missing_ok=True)
    key(b"\x07", 0.2)
    wait_for(path.exists, "selection callback did not run")
    return path.read_bytes()


try:
    wait_for(lambda: b"0 of 4 viewed" in output, "initial picker did not render")
    key(b"txt")
    initial = selected()
    assert initial, "initial selection is empty"
    start = len(output)
    key(b"\x16", 0.2)
    wait_for(lambda: len(marks()) == 1, "ctrl-v did not create exactly one mark")
    wait_for(lambda: b"1 of 4 viewed" in output[start:], "header did not update after mark")
    assert selected() == initial, "filtered selection moved after marking"
    key(b"\x16", 0.2)
    wait_for(lambda: not marks(), "second ctrl-v did not unmark same file")
    assert selected() == initial, "filtered selection moved after unmarking"
    key(b"\x0e")
    second = selected()
    assert second != initial, "cursor did not move to another filtered row"
    key(b"\x16", 0.2)
    wait_for(lambda: len(marks()) == 1, "non-first row did not get marked")
    assert selected() == second, "non-first filtered selection moved after marking"
    key(b"\x16", 0.2)
    wait_for(lambda: not marks(), "non-first row did not get unmarked")
    assert selected() == second, "non-first filtered selection moved after unmarking"
    key(b"\x01\x0bhas")  # clear query; select the file whose name contains US
    key(b"\x16", 0.2)
    wait_for(lambda: len(marks()) == 1, "US filename did not get a mark")
    assert marks()[0].with_suffix(".path").read_bytes() == b"has\x1fsep.txt\0", "US filename was truncated"
    key(b"\x05", 0.2)
    wait_for(lambda: (box / "edited").exists(), "editor callback did not run")
    assert (box / "edited").read_bytes() == b"has\x1fsep.txt", "editor got wrong US filename"
    key(b"\x03", 0.2)
except BaseException:
    sys.stderr.write("Terminal tail: " + repr(bytes(output[-1000:])) + "\n")
    raise
finally:
    (box / "terminal.log").write_bytes(output)
    # Reap a child that already exited before signalling: on macOS a stale
    # process-group signal can report EPERM even though normal exit succeeded.
    done, _ = os.waitpid(pid, os.WNOHANG)
    if not done:
        try:
            os.killpg(pid, signal.SIGTERM)
        except PermissionError:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            done, _ = os.waitpid(pid, os.WNOHANG)
            if done:
                break
            time.sleep(0.05)
        else:
            try:
                os.killpg(pid, signal.SIGKILL)
            except PermissionError:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
    os.close(fd)
