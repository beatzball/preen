"""PTY integration exercised only by test-watch.sh; no runtime dependency."""
import json
import shutil
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import termios
import time

repo, out = map(Path, sys.argv[1:])
preen = os.environ["PREEN"]
odd = " z quote'\\tab\tline\nend.txt "
output = bytearray()
p = None
master = None
state = None
pollers = set()
failures = 0


def check(ok, label):
    global failures
    print("  " + ("PASS: " if ok else "FAIL: ") + label, flush=True)
    failures += not ok
    if not ok:
        observation = {"assertion": label, "loads": loads(), "captures_hex": {},
                       "waiter_rows": waiter_rows(), "status": p.poll() if p else None}
        for name in ("selection", "query", "stats"):
            try:
                observation["captures_hex"][name] = (out / name).read_bytes().hex()
            except FileNotFoundError:
                observation["captures_hex"][name] = None
        destination = os.environ.get("PREEN_TEST_DIAGNOSTICS")
        if destination:
            evidence = Path(destination) / (str(os.getpid()) + "-" + str(failures))
            evidence.mkdir(parents=True, exist_ok=True)
            (evidence / "terminal.bin").write_bytes(output)
            for name in ("selection", "query", "stats", "loads", "state", "fzf-pid"):
                if (out / name).is_file():
                    shutil.copy(out / name, evidence / name)
            if state and state.is_dir():
                shutil.copytree(state, evidence / "picker-state")
            observation["evidence"] = str(evidence)
        print("WATCH_DIAGNOSTIC: " + json.dumps(observation), flush=True)


def pump(delay=0.05):
    if select.select([master], [], [], delay)[0]:
        try:
            output.extend(os.read(master, 65536))
        except OSError:
            pass
    if state and (state / "watch-pid").exists():
        try:
            pollers.add(int((state / "watch-pid").read_text()))
        except (ValueError, OSError):
            pass


def until(fn, seconds=7):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        pump()
        if fn():
            return True
        if p.poll() is not None:
            return False
    return False


def loads():
    try:
        return len((out / "loads").read_bytes())
    except FileNotFoundError:
        return 0


def names():
    try:
        return (state / "files").read_bytes().split(b"\0")
    except FileNotFoundError:
        return []


def waiter_rows():
    if not (out / "fzf-pid").exists():
        return []
    finder = int((out / "fzf-pid").read_text())
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="]).decode().splitlines()
    return [row for row in rows if len(row.split(None, 2)) == 3
            and int(row.split(None, 2)[1]) == finder
            and "--watch-await" in row.split(None, 2)[2]]


def query_is(expected):
    return until(lambda: (out / "query").exists()
                 and (out / "query").read_bytes() == os.fsencode(expected) + b"\0", 2)


def picker_stats():
    (out / "stats").unlink(missing_ok=True)
    os.write(master, b"\x0f")
    if not until(lambda: (out / "stats").exists() and b":" in (out / "stats").read_bytes(), 1):
        return None
    try:
        return tuple(map(int, (out / "stats").read_bytes().split(b":")))
    except ValueError:
        return None


def selected(expected):
    (out / "selection").unlink(missing_ok=True)
    os.write(master, b"\x14")  # ctrl-t records the actual highlighted fzf record
    return until(lambda: (out / "selection").exists()
                 and (out / "selection").read_bytes() == os.fsencode(expected) + b"\0", 2)


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def spawn(args):
    global p, master, state, output
    output = bytearray()
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 36, 150, 0, 0))

    def terminal():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    env = dict(os.environ, TERM="xterm-256color", SHELL="/bin/sh",
               FZF_DEFAULT_OPTS="", FZF_DEFAULT_OPTS_FILE="", PREEN_LAYOUT="inline")
    p = subprocess.Popen(["/bin/bash", preen, *args], cwd=repo, env=env,
                         stdin=slave, stdout=slave, stderr=slave, preexec_fn=terminal)
    os.close(slave)
    state = None
    ready = until(lambda: (out / "state").exists() and loads() > 0)
    check(ready, "real fzf opens watch mode")
    if not ready:
        raise RuntimeError(bytes(output).decode(errors="replace"))
    state = Path((out / "state").read_text())
    check(until(lambda: (state / "watch-pid").exists()), "fzf starts its polling callback")


def finish(key, label):
    # Include poller's descendants (sleep/git) in the no-orphan assertion.
    table = subprocess.check_output(["ps", "-axo", "pid=,ppid="]).decode().splitlines()
    pairs = [tuple(map(int, row.split())) for row in table if len(row.split()) == 2]
    owned = set(pollers)
    owned.add(int((out / "fzf-pid").read_text()))
    for _ in range(8):
        owned.update(pid for pid, parent in pairs if parent in owned)
    os.write(master, key)
    check(until(lambda: p.poll() is not None, 5), label + " exits")
    end = time.monotonic() + 3
    while any(alive(pid) for pid in owned) and time.monotonic() < end:
        time.sleep(0.05)
    check(bool(owned) and not any(alive(pid) for pid in owned), label + " leaves no polling process or child")
    check(not state.exists(), label + " removes temporary picker state")
    os.close(master)
    pollers.clear()
    for name in ("state", "loads", "selection", "query", "stats"):
        (out / name).unlink(missing_ok=True)


try:
    (repo / "f.txt").write_text("base\nfirst edit\n")
    (repo / odd).write_text("untracked first\n")
    spawn(["watch"])
    check(os.fsencode(odd) in names(), "watch retains odd filename bytes")
    check(until(lambda: b"untracked first" in output), "initial preview renders real diff")
    # Select a non-first item without filtering so insertion before it tests identity.
    os.write(master, b"\x1b[B")
    check(selected("f.txt"), "cursor can move while poller is waiting")
    before = loads()
    output.clear()
    (repo / "f.txt").write_text("base\nsecond edit\n")
    check(until(lambda: loads() > before), "content-only edit reloads within a few seconds")
    check(selected("f.txt"), "content-only edit keeps actual selected file")
    check(until(lambda: b"second edit" in output), "content-only edit refreshes actual preview")
    # Move back to the awkward path; new membership must not reset selection.
    os.write(master, b"\x1b[A")
    check(selected(odd), "actual selection carries whitespace, quote, backslash, tab and newline")
    before = loads()
    (repo / " a-first.txt").write_text("new member\n")
    check(until(lambda: loads() > before and b" a-first.txt" in names()), "new file appears in the open picker")
    check(selected(odd), "inserting an earlier file preserves odd selected path")
    before = loads()
    (repo / "f.txt").write_text("base\n")
    check(until(lambda: loads() > before and b"f.txt" not in names()), "reverted file leaves the open picker")
    check(selected(odd), "removing another file preserves selected path")
    before = loads()
    (repo / odd).write_text("untracked changed\n")
    check(until(lambda: loads() > before), "untracked content-only edit triggers reload")
    check(selected(odd), "untracked content edit preserves odd selected path")
    check(until(lambda: b"last changed" in output), "picker shows last-change timestamp")
    before = loads()
    for _ in range(25):
        pump()
    check(loads() == before, "unchanged content does not reload the picker")
    finish(b"\x1b", "Escape")
    # A clean repository still opens so the first change can arrive later.
    (repo / odd).unlink()
    (repo / " a-first.txt").unlink()
    spawn(["watch"])
    check(not any(names()), "watch starts on a clean repository")
    before = loads()
    (repo / "first.txt").write_text("first change\n")
    check(until(lambda: loads() > before and b"first.txt" in names()), "first change enters initially empty picker")
    finish(b"\x03", "Ctrl-C")
    # Both raw paths share the old delimiter prefix. Their safe IDs must stay
    # distinct through membership changes, viewed badges and query filtering.
    (repo / "first.txt").unlink()
    first, second = "a\x1ffirst.txt", "a\x1fsecond.txt"
    (repo / first).write_text("first US path\n")
    (repo / second).write_text("second US path\n")
    spawn(["watch"])
    os.write(master, b"\x1b[B")
    check(selected(second), "safe IDs distinguish paths sharing the US-delimited prefix")
    before = loads()
    (repo / "0-earlier.txt").write_text("inserted before US paths\n")
    check(until(lambda: loads() > before), "US-path picker reloads after earlier insertion")
    check(selected(second), "earlier insertion preserves selected second US path")

    def count():
        return (state / "viewed-count").read_text()

    # Wait for each actual fzf load, not just the mark file's earlier write.
    for expected in ("1 of 3 viewed", "0 of 3 viewed", "1 of 3 viewed"):
        before = loads()
        os.write(master, b"\x16")
        check(until(lambda: loads() > before and count() == expected), "viewed toggle reloads with count " + expected)
        check(selected(second), "viewed toggle preserves selected US path")
    check(until(lambda: len(waiter_rows()) == 1), "viewed reloads keep exactly one active polling callback")
    before = loads()
    (repo / second).write_text("watched US content changed\n")
    check(until(lambda: loads() > before and count() == "0 of 3 viewed"), "watch clears viewed mark immediately on content edit")
    check(selected(second), "viewed invalidation preserves selected US path")
    before = loads()
    (repo / second).write_text("second US path\n")
    check(until(lambda: loads() > before and count() == "0 of 3 viewed"), "returning old watched content does not restore viewed mark")
    os.write(master, b"second")
    check(selected(second), "query filters the safe-ID display by raw path")
    check(query_is("second"), "picker retains actual query text")
    before = loads()
    os.write(master, b"\x16")
    check(until(lambda: loads() > before and count() == "1 of 3 viewed"), "viewed toggle updates count under a query")
    check(selected(second) and query_is("second"), "viewed reload preserves path and query together")
    header = subprocess.check_output(["/bin/bash", preen, "--watch-header"],
                                     env=dict(os.environ, PREEN_STATE=str(state))).decode()
    check(header.count("watch · last changed") == 1 and "1 of 3 viewed" in header,
          "watch header combines the current viewed count with exactly one timestamp")
    # Fully empty transitions must invalidate old marks while staying open.
    os.write(master, b"\x01\x0b")
    before = loads()
    for name in (first, second, "0-earlier.txt"):
        (repo / name).unlink()
    check(until(lambda: loads() > before and not any(names()) and count() == "0 of 0 viewed"), "watch empties the list and viewed count without exiting")
    finish(b"\x1b", "Escape after viewed and membership churn")
    # Hold a user reload after it produced the old list. Poll publication must
    # already be stopped; otherwise load:bg-cancel can lose a published reload.
    (repo / "race-a.txt").write_text("old list member\n")
    spawn(["watch"])
    (out / "hold-viewed").touch()
    (out / "hold-poll").touch()
    before = loads()
    os.write(master, b"\x16")
    check(until(lambda: (out / "viewed-held").exists()), "timing barrier holds viewed producer before EOF")
    check(until(lambda: not waiter_rows()), "watch cancels polling before viewed list production")
    (repo / "race-b.txt").write_text("must arrive without another edit\n")
    check(until(lambda: (out / "poll-held").exists() or not waiter_rows()), "controlled reload interleaving is ready")
    (out / "release-viewed").touch()
    check(until(lambda: loads() > before), "held user reload finishes")
    (out / "hold-poll").unlink()
    (out / "release-poll").touch()
    os.write(master, b"^race-b.txt$")
    check(until(lambda: picker_stats() == (2, 1)), "new file reaches actual picker after overlapping viewed reload without another edit")
    check(selected("race-b.txt") and query_is("^race-b.txt$"), "recovered reload preserves exact query and new path")
    (out / "hold-editor").touch()
    before = loads()
    os.write(master, b"\x05")
    check(until(lambda: (out / "editor-held").exists()), "timing barrier holds actual editor action")
    check(until(lambda: not waiter_rows()), "watch cancels polling before editor action")
    check((out / "editor-args").read_bytes() == b"+1\0race-b.txt\0", "watch editor keeps line jump and raw path")
    (repo / "race-c.txt").write_text("change while editor is open\n")
    (out / "release-editor").touch()
    check(until(lambda: loads() > before), "held editor returns and reloads")
    check(until(lambda: picker_stats() == (3, 1)), "changes during editor reach picker without another edit")
    check(selected("race-b.txt") and query_is("^race-b.txt$"), "editor reload preserves selected path and query")
    finish(b"\x1b", "Escape after controlled reload interleaving")
except Exception as exc:
    check(False, "PTY integration: " + str(exc))
finally:
    if p and p.poll() is None:
        os.killpg(p.pid, signal.SIGTERM)
        try:
            p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, signal.SIGKILL)
            p.wait()
    if failures:
        print(bytes(output[-4000:]).decode(errors="replace"), file=sys.stderr)
sys.exit(bool(failures))
