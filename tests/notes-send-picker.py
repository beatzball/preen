#!/usr/bin/env python3
"""Drive worktree note delivery in real fzf, with roost calls recorded to disk."""
import errno
import fcntl
import json
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

repo, worktree, box, store = map(Path, sys.argv[1:])
box.mkdir()
shim = box / 'bin'
shim.mkdir()
roost = shim / 'roost'
roost.write_text(f'''#!{sys.executable}
import json, os, sys
from pathlib import Path
box = Path(os.environ["SEND_BOX"])
with (box / "calls").open("a") as log:
    print(json.dumps(sys.argv[1:]), file=log)
if sys.argv[1:] == ["status", "--json"]:
    recheck = box / "recheck.json"
    snapshot = recheck if recheck.exists() and len((box / "calls").read_text().splitlines()) == 2 else box / "status.json"
    sys.stdout.buffer.write(snapshot.read_bytes())
    sys.exit()
assert sys.argv[1] == "send" and len(sys.argv) == 4, sys.argv[1:]
sys.exit(int((box / "send-exit").read_text()))
''')
roost.chmod(0o755)
real_fzf = shutil.which('fzf')
observer = shim / 'fzf'
observer.write_text('''#!/bin/bash
exec -a fzf "$SEND_FZF" "$@" \\
  --bind 'load:+execute-silent(cat "$PREEN_STATE/kind" >> "$SEND_BOX/loads")'
''')
observer.chmod(0o755)
env = dict(os.environ, TERM='xterm-256color', SHELL='/bin/bash',
           SEND_BOX=str(box), SEND_FZF=real_fzf, PATH=str(shim) + ':' + os.environ['PATH'],
           FZF_DEFAULT_OPTS='', FZF_DEFAULT_OPTS_FILE='')
preen = os.environ['PREEN']
note = next((store / 'files').glob('*.note'))
saved_note_name = b'/files/' + os.fsencode(note.name)
original_note = note.read_bytes()
expected = subprocess.check_output(['/bin/bash', preen, 'notes', 'wt', worktree], cwd=repo, env=env)


class Picker:
    def __init__(self, mode, cwd=repo, path=None):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            os.execve('/bin/bash', ['/bin/bash', preen, mode], env if path is None else dict(env, PATH=path))
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack('HHHH', 34, 150, 0, 0))
        self.output = bytearray()
        self.start = 0

    def wait(self, condition, reason):
        deadline = time.monotonic() + 12
        while not condition():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f'{reason}; screen tail {self.output[-2000:]!r}')
            self.pump(min(remaining, 0.1))

    def pump(self, timeout):
        if not select.select([self.fd], [], [], timeout)[0]:
            return
        try:
            chunk = os.read(self.fd, 65536)
        except OSError as error:
            if error.errno != errno.EIO:
                raise
            return
        self.output.extend(chunk)
        if b'\x1b[6n' in chunk:
            self.key(b'\x1b[1;1R')

    def key(self, data):
        os.write(self.fd, data)

    def expect(self, text):
        self.wait(lambda: text in self.output[self.start:], f'waiting for {text!r}')
        self.start = self.output.index(text, self.start) + len(text)

    def visit_worktree(self):
        self.expect(b'worktree')
        self.wait(lambda: 'wt' in lines('loads'), 'worktree list did not load')
        self.key(b'\r')
        self.expect(b'ctrl-y send notes')

    def __enter__(self):
        return self

    def __exit__(self, kind, *_):
        try:
            if kind is None:
                self.key(b'\x03')
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    pid, status_code = os.waitpid(self.pid, os.WNOHANG)
                    if pid:
                        self.pid = 0
                        assert status_code == 0, status_code
                        return
                    self.pump(0.05)
                raise AssertionError(f'preen did not quit; screen tail {self.output[-1000:]!r}')
        finally:
            os.close(self.fd)
            if self.pid:
                try:
                    os.killpg(self.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                deadline = time.monotonic() + 3
                while time.monotonic() < deadline:
                    if os.waitpid(self.pid, os.WNOHANG)[0]:
                        break
                    time.sleep(0.02)


def lines(name):
    path = box / name
    return path.read_text().splitlines() if path.exists() else []


def calls():
    return [json.loads(line) for line in lines('calls')]


def status(*panes, running=True, file='status.json'):
    (box / file).write_text(json.dumps({
        'panes': panes, 'schema': 1, 'command': 'status', 'running': running, 'sessions': [],
    }, indent=2))


def pane(pane_id, cwd, label, index):
    return dict(id=f'%{pane_id}', cwd=str(cwd), name=label, session='review', window_id='@22',
                window_index=2, pane_index=index, session_id=f'agent-{pane_id}',
                harness='codex', command='codex', state='idle')


def case(*panes, running=True, send_exit=0):
    for name in ('calls', 'loads', 'recheck.json'):
        (box / name).unlink(missing_ok=True)
    status(*panes, running=running)
    (box / 'send-exit').write_text(str(send_exit))


alias = box / 'worktree-alias'
alias.symlink_to(worktree, target_is_directory=True)
first = pane(9, alias, 'first "reviewer"', 1)
second = dict(pane(10, worktree, 'second reviewer', 2), harness='claude', command='2.1.322', state='done')
unrelated_path = box / 'other' / worktree.name
unrelated_path.mkdir(parents=True)
unrelated = dict(pane(90, unrelated_path, 'unrelated reviewer', 3), was='%9',
                 dialog={'cwd': str(worktree), 'id': '%9'})
query = b'NO_MATCH_QUERY'

# The send is worktree-wide even while no file matches. Choosing the second
# split sends once and with the unchanged snapshot, even on roost exit 4.
case(unrelated, first, second, dict(second, session='linked window'), send_exit=4)
with Picker('wt') as picker:
    picker.visit_worktree()
    picker.wait(lambda: 'diff' in lines('loads'), 'file picker did not load')
    generation = lines('loads').count('diff')
    picker.key(b'\x0e')
    picker.wait(lambda: lines('loads').count('diff') > generation, 'note edit did not reload the picker')
    picker.start = len(picker.output)
    picker.key(query)
    picker.expect(b'0/1')
    picker.key(b'\x19')
    picker.expect(b'Choose a roost pane')
    picker.expect(b'1) "review":2.1 "first \\"reviewer\\"" (:@22.%9)')
    picker.expect(b'2) "review":2.2 "second reviewer" (:@22.%10)')
    picker.expect(b'Pane number')
    assert b'unrelated reviewer' not in picker.output
    assert b'linked window' not in picker.output
    assert calls() == [['status', '--json']]
    picker.key(b'2\r')
    picker.expect(b'Review notes for "review":2.2 "second reviewer" (:@22.%10)')
    picker.expect(expected.replace(b'\n', b'\r\n'))
    picker.expect(b'Send to :@22.%10? Type yes to send:')
    assert calls() == [['status', '--json']]
    try:
        note.write_bytes(b'A concurrent edit that was never confirmed.\n')
        picker.key(b'yes\r')
        picker.expect(b'without observing a new turn')
        picker.expect(b'Press Enter')
        assert calls() == [['status', '--json'], ['status', '--json'],
                           ['send', ':@22.%10', expected.decode()]]
    finally:
        note.write_bytes(original_note)
    picker.key(b'\r')
    picker.expect(b'ctrl-y send notes')

# Escape the choice, then decline the single-target confirmation. Neither
# path may cause a second status read or a send.
case(first, second)
with Picker('wt') as picker:
    picker.visit_worktree()
    picker.key(b'\x19')
    picker.expect(b'Pane number')
    picker.key(b'\r')
    picker.expect(b'ctrl-y send notes')
    assert calls() == [['status', '--json']]
    status(first)
    picker.key(b'\x19')
    picker.expect(b'Send to :@22.%9? Type yes to send:')
    picker.key(b'y\r')
    picker.expect(b'ctrl-y send notes')
    assert calls() == [['status', '--json'], ['status', '--json']]

shell = dict(first, command='bash')
for changed in (dict(first, session_id='another-agent'), shell, dict(shell, state=None)):
    case(first)
    # Fake roost exposes the changed pane only when called after the user
    # confirms. The shell keeps the original cwd, harness, and session ID.
    status(changed, file='recheck.json')
    with Picker('wt') as picker:
        picker.visit_worktree()
        picker.key(b'\x19')
        picker.expect(b'Type yes to send:')
        assert calls() == [['status', '--json']]
        picker.key(b'yes\r')
        picker.expect(b'The selected roost pane changed or is unavailable.')
        picker.expect(saved_note_name)
        picker.expect(b'Press Enter')
        assert calls() == [['status', '--json'], ['status', '--json']]
        picker.key(b'\r')
        picker.expect(b'ctrl-y send notes')

no_agent = b'No active, identified roost agent is available on this worktree.'
ineligible = (
    shell,
    dict(shell, id='%11', state=None),
    dict(first, id='%12', session_id=''),
    dict(first, id='%13', harness=None),
    dict(first, id='%14', state=None),
    dict(first, id='%15', harness='pi', command='node'),
    dict(first, id='%16', harness='unknown', command='unknown'),
    dict(first, id='%17', harness='codex', command='claude'),
    dict(first, id='%18', state='blocked'),
)

for panes, running, message in (
    ((unrelated,), True, no_agent),
    (ineligible, True, no_agent),
    ((), False, b'roost is not running.'),
):
    case(*panes, running=running)
    with Picker('wt') as picker:
        picker.visit_worktree()
        picker.key(b'\x19')
        picker.expect(message)
        picker.expect(saved_note_name)
        picker.expect(b'Export them with preen notes wt')
        picker.expect(b'Press Enter')
        assert calls() == [['status', '--json']]
        picker.key(b'\r')
        picker.expect(b'ctrl-y send notes')

# Exercise the optional dependency with a PATH containing only the tools
# needed to open the picker and read the notes.
bare_path = box / 'without-roost'
bare_path.mkdir()
for tool in ('awk', 'basename', 'bash', 'cat', 'cmp', 'cut', 'delta', 'dirname',
             'git', 'glow', 'grep', 'head', 'mkdir', 'mktemp', 'mv', 'ps', 'readlink',
             'rm', 'sed', 'sort', 'stty', 'tail', 'touch', 'tr', 'wc'):
    if resolved := shutil.which(tool):
        (bare_path / tool).symlink_to(resolved)
(bare_path / 'fzf').symlink_to(observer)
case(first)
with Picker('wt', path=str(bare_path)) as picker:
    picker.visit_worktree()
    picker.key(b'\x19')
    picker.expect(b'roost is not installed.')
    picker.expect(saved_note_name)
    picker.expect(b'Press Enter')
    assert not calls(), calls()
    picker.key(b'\r')
    picker.expect(b'ctrl-y send notes')

# The export is too large for one argv entry. Fall back before opening a
# confirmation or starting roost.
case(first)
try:
    note.write_bytes('é'.encode() * 1100000)
    with Picker('wt') as picker:
        picker.visit_worktree()
        picker.key(b'\x19')
        picker.expect(b'Review notes exceed the 64 KiB roost send limit')
        picker.expect(saved_note_name)
        picker.expect(b'Export them with preen notes wt')
        picker.expect(b'Press Enter')
        assert not calls(), calls()
        assert b'Type yes to send:' not in picker.output
        picker.key(b'\r')
        picker.expect(b'ctrl-y send notes')
finally:
    note.write_bytes(original_note)

# A command that actually ran can also exit 126. Keep that outcome ambiguous
# and offer the export fallback without attempting a second send.
case(first, send_exit=126)
with Picker('wt') as picker:
    picker.visit_worktree()
    picker.key(b'\x19')
    picker.expect(b'Type yes to send:')
    picker.key(b'yes\r')
    picker.expect(b'roost exited 126. Check pane :@22.%9 before sending manually.')
    picker.expect(saved_note_name)
    picker.expect(b'Press Enter')
    assert calls() == [['status', '--json'], ['status', '--json'],
                       ['send', ':@22.%9', expected.decode()]]
    picker.key(b'\r')
    picker.expect(b'ctrl-y send notes')

# Once the worktree becomes clean its saved feedback remains available.
case(first)
tracked = worktree / 'f.txt'
dirty_text = tracked.read_bytes()
try:
    tracked.write_bytes(subprocess.check_output(['git', 'show', 'HEAD:f.txt'], cwd=worktree))
    with Picker('wt') as picker:
        picker.visit_worktree()
        picker.wait(lambda: b'has changed nothing' in picker.output, 'clean worktree row did not render')
        picker.key(b'\x19')
        picker.expect(b'Send to :@22.%9? Type yes to send:')
        picker.key(b'yes\r')
        picker.expect(b'Review notes sent to :@22.%9.')
        picker.expect(b'Press Enter')
        assert calls() == [['status', '--json'], ['status', '--json'],
                           ['send', ':@22.%9', expected.decode()]]
        picker.key(b'\r')
        picker.expect(b'ctrl-y send notes')
finally:
    tracked.write_bytes(dirty_text)

# watch uses the diff picker even when invoked inside the reviewed worktree.
if subprocess.run([preen, '--watch-check'], env=env).returncode == 0:
    case(first)
    new_file = worktree / 'watch-new.txt'
    try:
        with Picker('watch', cwd=worktree) as picker:
            picker.expect(b'0 of 1 viewed')
            picker.key(b'\x19')
            new_file.touch()
            picker.expect(b'0 of 2 viewed')
            assert not calls(), calls()
    finally:
        new_file.unlink(missing_ok=True)
