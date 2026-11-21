"""Real-fzf history navigation and isolation from a simultaneous watch picker."""
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

repo, box, sha, empty, odd = sys.argv[1:]
box = Path(box)
box.mkdir(parents=True, exist_ok=True)
real_fzf = subprocess.check_output(['which', 'fzf'], text=True).strip()
shim = box / 'shim'
shim.mkdir()
(shim / 'fzf').write_text('''#!/bin/sh
[ -n "${PREEN_STATE:-}" ] || exec "$LOG_REAL_FZF" "$@"
slot="$LOG_PTY/$LOG_SLOT"
n=$(cat "$slot/count" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s' "$PREEN_STATE" > "$slot/state"
cat "$PREEN_STATE/kind" > "$slot/kind"
printf '%s' "$n" > "$slot/count"
exec "$LOG_REAL_FZF" "$@" --bind 'ctrl-t:execute-silent(printf "%s\\000%s\\000%s\\000%s\\000" "$FZF_TOTAL_COUNT" "$FZF_MATCH_COUNT" {q} {1} > "$LOG_PTY/$LOG_SLOT/stats")'
''')
(shim / 'vim').write_text('''#!/bin/sh
printf '%s\\0' "$@" > "$LOG_PTY/editor"
''')
for path in shim.iterdir():
    path.chmod(0o755)
children = []


def pump(delay=0.05):
    fds = [c['fd'] for c in children if c['p'].poll() is None]
    if not fds:
        time.sleep(delay)
        return
    ready, _, _ = select.select(fds, [], [], delay)
    for child in children:
        if child['fd'] in ready:
            try:
                data = os.read(child['fd'], 65536)
                child['output'].extend(data)
                if b'\x1b[6n' in data:
                    os.write(child['fd'], b'\x1b[1;1R')
            except OSError:
                pass


def until(check, reason, seconds=8):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        pump()
        if check():
            return
    raise AssertionError(reason)


def spawn(slot, args):
    slotdir = box / slot
    slotdir.mkdir()
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 36, 150, 0, 0))

    def terminal():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    env = dict(os.environ, TERM='xterm-256color', SHELL='/bin/bash',
               LOG_PTY=str(box), LOG_SLOT=slot, LOG_REAL_FZF=real_fzf,
               XDG_STATE_HOME=str(box / 'state'), EDITOR=str(shim / 'vim'),
               FZF_DEFAULT_OPTS='', FZF_DEFAULT_OPTS_FILE='',
               PATH=str(shim) + ':' + os.environ['PATH'], PREEN_LAYOUT='inline')
    p = subprocess.Popen(['/bin/bash', os.environ['PREEN'], *args], cwd=repo,
                         env=env, stdin=slave, stdout=slave, stderr=slave,
                         preexec_fn=terminal)
    os.close(slave)
    child = dict(p=p, fd=master, output=bytearray(), slot=slotdir)
    children.append(child)
    until(lambda: (slotdir / 'count').exists(), slot + ' picker did not open')
    return child


def key(child, data):
    os.write(child['fd'], data)
    for _ in range(4):
        pump()


def level(child, count, kind):
    until(lambda: (child['slot'] / 'count').read_text() == str(count)
          and (child['slot'] / 'kind').read_text().strip() == kind,
          'level did not become ' + kind)


def stats(child):
    path = child['slot'] / 'stats'
    path.unlink(missing_ok=True)
    end = time.monotonic() + 4
    while time.monotonic() < end:
        os.write(child['fd'], b'\x14')
        for _ in range(3):
            pump()
        if path.exists() and path.read_bytes().count(b'\0') == 4:
            return path.read_bytes().split(b'\0')[:4]
        if child['p'].poll() is not None:
            break
    raise AssertionError('fzf stats callback did not run')


def expect_stats(child, total, matches):
    until(lambda: stats(child)[:2] == [str(total).encode(), str(matches).encode()],
          f'fzf should show {matches} of {total} rows')


def finish(child, data):
    key(child, data)
    until(lambda: child['p'].poll() is not None, 'quit did not exit')
    state = Path((child['slot'] / 'state').read_text())
    assert not state.exists(), 'quit left temporary state'
    assert child['p'].returncode == 0, 'picker quit returned failure'


try:
    watch = None
    if subprocess.call([os.environ['PREEN'], '--watch-check']) == 0:
        watch = spawn('watch', ['watch'])
        expect_stats(watch, 2, 2)
        watch_state = Path((watch['slot'] / 'state').read_text())
        until(lambda: (watch_state / 'watch-hash').exists(), 'watch did not publish')
        watch_hash = (watch_state / 'watch-hash').read_bytes()
    log = spawn('log', ['log', sha + '^!'])
    expect_stats(log, 1, 1)
    key(log, b'\r')
    level(log, 2, 'log')
    expect_stats(log, 4, 4)
    key(log, b'quote')
    expect_stats(log, 4, 1)
    key(log, b'\x16')
    until(lambda: len(list((box / 'state').rglob('*.viewed'))) == 1, 'viewed key failed')
    mark = next((box / 'state').rglob('*.viewed'))
    assert mark.with_suffix('.path').read_bytes() == os.fsencode(odd) + b'\0'
    key(log, b'\x05')
    until(lambda: (box / 'editor').exists(), 'editor did not run')
    assert (box / 'editor').read_bytes() == b'+1\0' + os.fsencode(odd) + b'\0'
    key(log, b'\x7f' * len('quote') + b'NO_MATCH_AT_ALL')
    expect_stats(log, 4, 0)
    key(log, b'\r\x16\x05')
    level(log, 2, 'log')
    expect_stats(log, 4, 0)
    key(log, b'\x1b')
    level(log, 3, 'log-list')
    expect_stats(log, 1, 1)
    key(log, b'NO_MATCH_AT_ALL')
    expect_stats(log, 1, 0)
    key(log, b'\r')
    level(log, 3, 'log-list')
    key(log, b'\x7f' * len('NO_MATCH_AT_ALL'))
    expect_stats(log, 1, 1)
    key(log, b'\r')
    level(log, 4, 'log')
    expect_stats(log, 4, 4)
    if watch:
        assert watch['p'].poll() is None, 'log transition stopped watch'
        with (Path(repo) / 'f.txt').open('a') as f:
            f.write('WATCH WHILE LOG OPEN\n')
        until(lambda: (watch_state / 'watch-hash').read_bytes() != watch_hash,
              'concurrent watch did not refresh')
        expect_stats(watch, 2, 2)
    finish(log, b'\x03')
    empty_log = spawn('empty', ['log', empty + '^!'])
    expect_stats(empty_log, 1, 1)
    key(empty_log, b'\r')
    level(empty_log, 2, 'log')
    expect_stats(empty_log, 0, 0)
    key(empty_log, b'\r\x16\x05')
    expect_stats(empty_log, 0, 0)
    key(empty_log, b'\x1b')
    level(empty_log, 3, 'log-list')
    finish(empty_log, b'\x1b')
    top = spawn('top', ['log', sha + '^!'])
    expect_stats(top, 1, 1)
    finish(top, b'\x03')
    if watch:
        finish(watch, b'\x03')
except BaseException:
    for child in children:
        print(child['slot'].name + ' terminal tail: ' + repr(bytes(child['output'][-3000:])), file=sys.stderr)
    raise
finally:
    for child in children:
        (child['slot'] / 'terminal.log').write_bytes(child['output'])
        if child['p'].poll() is None:
            try:
                os.write(child['fd'], b'\x03')
            except OSError:
                pass
            end = time.monotonic() + 3
            while child['p'].poll() is None and time.monotonic() < end:
                pump()
        if child['p'].poll() is None:
            try:
                os.killpg(child['p'].pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            os.close(child['fd'])
            try:
                child['p'].wait(timeout=3)
            except subprocess.TimeoutExpired:
                child['p'].kill()
                child['p'].wait()
            continue
        os.close(child['fd'])
