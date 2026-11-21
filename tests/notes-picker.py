#!/usr/bin/env python3
"""Exercise note actions in real fzf, including empty matches and watch races."""
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import termios
import time

repo, box = map(Path, sys.argv[1:3])
mode = sys.argv[3]
box.mkdir(parents=True)
editor = box / 'editor'
editor.write_text('''#!/bin/sh
printf '%s' "$1" > "$NOTE_PTY/editor-buffer"
cat "$1" > "$NOTE_PTY/before"
touch "$NOTE_PTY/entered"
while [ -f "$NOTE_PTY/hold" ] && [ ! -f "$NOTE_PTY/release" ]; do sleep 0.02; done
cat "$NOTE_PTY/text" > "$1"
''')
editor.chmod(0o755)
(box / 'text').write_text('PTY feedback.\n')
# Append the observer after production bindings so load:+ preserves the real
# load actions and signals their completion rather than an editor side effect.
real_fzf = shutil.which('fzf')
assert real_fzf, 'fzf is not installed'
observer = box / 'fzf'
observer.write_text('''#!/bin/bash
exec -a fzf "$NOTE_PTY_REAL_FZF" "$@" \
  --bind 'load:+execute-silent(printf . >> "$NOTE_PTY/loads")' \
  --bind 'result:+execute-silent(printf "%s\\000%s\\000%s\\000" {q} "$FZF_TOTAL_COUNT" "$FZF_MATCH_COUNT" > "$NOTE_PTY/result.next"; mv "$NOTE_PTY/result.next" "$NOTE_PTY/result")' \
  --bind 'ctrl-g:execute-silent(printf "%s\\000%s\\000" {1} {q} > "$NOTE_PTY/selected.next"; mv "$NOTE_PTY/selected.next" "$NOTE_PTY/selected")'
''')
observer.chmod(0o755)
env = dict(os.environ, TERM='xterm-256color', SHELL='/bin/bash',
           XDG_STATE_HOME=str(box / 'state'), EDITOR=str(editor), NOTE_PTY=str(box),
           NOTE_PTY_REAL_FZF=real_fzf, PATH=str(box) + ':' + os.environ['PATH'],
           FZF_DEFAULT_OPTS='', FZF_DEFAULT_OPTS_FILE='')


def run(mode):
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(repo)
        argv = ['/bin/bash', os.environ['PREEN'], mode]
        if mode == 'log':
            argv.append(sys.argv[4] + '^!')
        os.execve('/bin/bash', argv, env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 36, 150, 0, 0))
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
            if not data:
                break
            output.extend(data)
            if b'\x1b[6n' in data:
                os.write(fd, b'\x1b[1;1R')

    def key(data, seconds=0.3):
        os.write(fd, data)
        pump(seconds)

    def wait(check, reason):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if check():
                return
            pump(0.1)
        raise AssertionError(reason)

    def loads():
        path = box / 'loads'
        return len(path.read_bytes()) if path.exists() else 0

    def wait_loaded(before, reason):
        wait(lambda: loads() > before, reason)

    def selected():
        path = box / 'selected'
        path.unlink(missing_ok=True)
        key(b'\x07')
        wait(path.exists, 'selection callback did not run')
        snapshot = path.read_bytes().split(b'\0')
        assert len(snapshot) == 3 and snapshot[2] == b'', 'incomplete selection snapshot'
        assert snapshot[1] == b'odd', 'selection callback observed wrong query: ' + repr(snapshot[1])
        return snapshot[0]

    def notes():
        return list((box / 'state').rglob('*.note'))

    def waiters():
        rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,command=']).decode().splitlines()
        table = [row.split(None, 2) for row in rows if len(row.split(None, 2)) == 3]
        finders = {int(child) for child, parent, command in table
                   if int(parent) == pid and command.startswith('fzf ')}
        return [int(child) for child, parent, command in table
                if int(parent) in finders and '--watch-await' in command]

    try:
        if mode == 'log':
            wait_loaded(0, 'commit list did not complete its initial load')
            before_enter = loads()
            key(b'\r')
            wait_loaded(before_enter, 'commit file picker did not complete its load')
        expected = b'0 of 0 viewed' if mode == 'watch' else b'0 of 2 viewed'
        wait(lambda: expected in output, 'initial picker did not render')
        wait_loaded(0, 'initial fzf load did not complete')
        if mode == 'watch':
            wait(lambda: len(waiters()) == 1, 'watch waiter did not start')
            original_waiter = waiters()
            # Empty ctrl-n must leave the polling callback alive.
            key(b'\x0e')
            assert not (box / 'entered').exists(), 'empty picker launched editor'
            assert waiters() == original_waiter, 'empty note action replaced or canceled waiter'
            before_membership = loads()
            (repo / 'aaa.txt').write_text('new first file\n')
            (repo / 'odd\x1fsep.txt').write_text('new selected file\n')
            wait(lambda: b'0 of 2 viewed' in output, 'empty note action stopped watch polling')
            wait_loaded(before_membership, 'first watch membership load did not complete')
        key(b'NO_MATCH_QUERY')
        key(b'\x0e')
        assert not (box / 'entered').exists(), 'no-match note launched editor'
        key(b'\x7f' * len('NO_MATCH_QUERY') + b'odd')
        initial = selected()
        assert initial, 'filtered selection empty'
        if mode == 'watch':
            (box / 'hold').touch()
        before_save = loads()
        key(b'\x0e')
        wait(lambda: (box / 'entered').exists(), 'note editor did not open')
        if mode == 'watch':
            assert not waiters(), 'note editor did not cancel watch before opening'
            # Change list membership and contents while editor holds the screen.
            (repo / 'aaa.txt').unlink()
            (repo / 'bbb.txt').write_text('inserted while editing\n')
            (repo / 'odd\x1fsep.txt').write_text('changed while editing\n')
            (box / 'release').touch()
        wait(lambda: len(notes()) == 1, 'note did not save')
        wait_loaded(before_save, 'save-note fzf reload did not complete')
        wait(lambda: '✎'.encode() in output, 'note marker did not render')
        assert selected() == initial, 'filtered selection changed after note reload'
        assert notes()[0].with_suffix('.path').read_bytes() == b'odd\x1fsep.txt\0', 'ID lost separator filename'
        assert notes()[0].read_text() == 'PTY feedback.\n', 'saved note bytes changed'
        if mode == 'log':
            before_back = loads()
            key(b'\x1b')
            wait_loaded(before_back, 'Escape did not reload commit list')
            before_enter = loads()
            key(b'\r')
            wait_loaded(before_enter, 're-enter did not load commit file picker')
            key(b'odd')
            assert selected() == initial, 're-entering commit changed selected file or query'
            assert len(notes()) == 1, 'commit note did not survive back and re-enter'
        if mode == 'watch':
            # Export sees live membership; watcher must also keep following changes.
            before_membership = loads()
            (repo / 'after-note.txt').write_text('poller still runs\n')
            start = len(output)
            wait(lambda: b'0 of 3 viewed' in output[start:], 'watch did not resume after note reload')
            wait_loaded(before_membership, 'watch membership reload did not complete')
            wait(lambda: len(waiters()) == 1, 'note reload left extra or missing watch waiters')
        (box / 'entered').unlink()
        (box / 'text').write_text('')
        before_clear = loads()
        key(b'\x0e')
        wait(lambda: not notes(), 'empty buffer did not clear note')
        wait_loaded(before_clear, 'clear-note fzf reload did not complete')
        assert (box / 'before').read_text() == 'PTY feedback.\n', 'editor did not receive saved note'
        assert selected() == initial, 'clearing note changed filtered selection'
        key(b'\x03')
    except BaseException:
        captures = {}
        for name in ('selected', 'result', 'loads', 'before', 'editor-buffer'):
            path = box / name
            captures[name] = repr(path.read_bytes()[:512]) if path.exists() else 'missing'
        sys.stderr.write('Note picker diagnostics: mode=' + mode + ' generation=' + str(loads()) + ' captures=' + repr(captures) + '\n')
        sys.stderr.write('Saved note paths: ' + repr([str(path) for path in notes()][:10]) + '\n')
        try:
            rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,command='], timeout=2).decode().splitlines()
            owned = {pid}
            for _ in range(4):
                owned.update(int(fields[0]) for row in rows
                             if len(fields := row.split(None, 2)) == 3 and int(fields[1]) in owned)
            relevant = [row[:300] for row in rows if int(row.split(None, 1)[0]) in owned][:15]
            sys.stderr.write('Picker process rows: ' + repr(relevant) + '\n')
        except (OSError, subprocess.TimeoutExpired):
            sys.stderr.write('Picker process rows unavailable\n')
        sys.stderr.write('Terminal tail: ' + repr(bytes(output[-1800:])) + '\n')
        raise
    finally:
        (box / f'{mode}-terminal.log').write_bytes(output)
        os.close(fd)
        done, _ = os.waitpid(pid, os.WNOHANG)
        if not done:
            try:
                os.killpg(pid, signal.SIGTERM)
            except (PermissionError, ProcessLookupError):
                try:
                    os.kill(pid, signal.SIGTERM)
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
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.waitpid(pid, 0)


# Each mode gets its own box and prepares only its disposable repository.
subprocess.run(['git', '-C', str(repo), 'checkout', '--', 'f.txt'], check=True)
if mode != 'log':
    for name in ('aaa.txt', 'bbb.txt', 'after-note.txt', 'odd\x1fsep.txt'):
        (repo / name).unlink(missing_ok=True)
if mode == 'diff':
    (repo / 'aaa.txt').write_text('first\n')
    (repo / 'odd\x1fsep.txt').write_text('selected\n')
run(mode)
