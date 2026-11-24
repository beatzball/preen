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
args = sys.argv[1:]
with (box / "calls").open("a") as log:
    print(json.dumps(args), file=log)
if args == ["--version"]:
    print((box / "version").read_text())
    sys.exit()
if args == ["status", "--json"]:
    count = sum(json.loads(line) == args for line in (box / "calls").read_text().splitlines())
    snapshot = box / ("status-%d.json" % count)
    sys.stdout.buffer.write((snapshot if snapshot.exists() else box / "status.json").read_bytes())
    sys.exit()
if len(args) == 3 and args[:2] == ["send", "--agent-token"]:
    seed = (box / "token-seed").read_text()
    if seed == "refuse":
        print("agent guard refused the pane or its alias", file=sys.stderr)
        sys.exit(7)
    print(seed + args[2] if seed else "")
    sys.exit()
assert len(args) == 5 and args[:2] == ["send", "--agent-only"], args
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
instruction = 'Review these worktree notes. Decode the following JSON string as Markdown: '
version_call = ['--version']
status_call = ['status', '--json']


def payload(markdown):
    return instruction + json.dumps(markdown.decode(), ensure_ascii=True)


def ready(target):
    return [version_call, status_call, ['send', '--agent-token', target], status_call]


def assert_delivery(target, markdown=expected):
    assert calls()[:-1] == ready(target) + [status_call, version_call], calls()
    call = calls()[-1]
    assert call[:4] == ['send', '--agent-only', 'token-for-' + target, target], call[:4]
    line = call[4]
    assert all(32 <= ord(char) <= 126 for char in line), line
    assert line == payload(markdown), line
    assert json.loads(line[len(instruction):]).encode() == markdown


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


def case(*panes, running=True, send_exit=0, version='0.13.0', token='token-for-'):
    for name in ('calls', 'loads', 'status-2.json', 'status-3.json'):
        (box / name).unlink(missing_ok=True)
    status(*panes, running=running)
    (box / 'send-exit').write_text(str(send_exit))
    (box / 'version').write_text(version)
    (box / 'token-seed').write_text(token)


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
complex_note = 'Check a tab\t, "quotes", \\path, café, 🪶, \u0085 and \u2028.\n\nEnd.\n'
complex_markdown = b'## f.txt\n' + complex_note.encode() + b'\n\n'
env['NOTE_TEXT'] = complex_note
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
    picker.expect(b'1) "review":2.1 "first \\"reviewer\\"" (%9)')
    picker.expect(b'2) "review":2.2 "second reviewer" (%10)')
    picker.expect(b'Pane number')
    assert b'unrelated reviewer' not in picker.output
    assert b'linked window' not in picker.output
    assert calls() == [version_call, status_call]
    picker.key(b'2\r')
    picker.expect(b'Review notes for "review":2.2 "second reviewer" (%10)')
    picker.expect(payload(complex_markdown).encode())
    picker.expect(b'Send to %10? Type yes to send:')
    assert calls() == ready('%10')
    try:
        note.write_bytes(b'A concurrent edit that was never confirmed.\n')
        picker.key(b'yes\r')
        picker.expect(b'without observing a new turn')
        picker.expect(b'Press Enter')
        assert_delivery('%10', complex_markdown)
    finally:
        note.write_bytes(original_note)
    picker.key(b'\r')
    picker.expect(b'ctrl-y send notes')
env['NOTE_TEXT'] = original_note.decode()

# Cancel the choice before token capture, then decline a confirmed target.
# Neither path can invoke guarded delivery.
case(first, second)
with Picker('wt') as picker:
    picker.visit_worktree()
    picker.key(b'\x19')
    picker.expect(b'Pane number')
    picker.key(b'\r')
    picker.expect(b'ctrl-y send notes')
    assert calls() == [version_call, status_call]
    status(first)
    picker.key(b'\x19')
    picker.expect(b'Send to %9? Type yes to send:')
    picker.key(b'y\r')
    picker.expect(b'ctrl-y send notes')
    assert calls() == [version_call, status_call] + ready('%9')

shell = dict(first, command='bash')
for changed in (dict(first, session_id='another-agent'), shell,
                dict(first, window_id='@23'), dict(first, cwd=str(unrelated_path))):
    case(first)
    # Fake roost exposes the changed pane only when called after the user
    # confirms. The shell keeps the original cwd, harness, and session ID.
    status(changed, file='status-3.json')
    with Picker('wt') as picker:
        picker.visit_worktree()
        picker.key(b'\x19')
        picker.expect(b'Type yes to send:')
        assert calls() == ready('%9')
        picker.key(b'yes\r')
        picker.expect(b'The selected roost pane changed or is unavailable.')
        picker.expect(saved_note_name)
        picker.expect(b'Press Enter')
        assert calls() == ready('%9') + [status_call]
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
        assert calls() == [version_call, status_call]
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


def expect_fallback(picker, message, expected_calls):
    picker.expect(message)
    picker.expect(saved_note_name)
    picker.expect(b'Export them with preen notes wt')
    picker.expect(b'Press Enter')
    if expected_calls is not None:
        assert calls() == expected_calls, calls()
    picker.key(b'\r')
    picker.expect(b'ctrl-y send notes')


requires_version = b'Sending review notes requires roost 0.13.0 or newer.'
for version in ('0.12.99', 'unidentified', '0.13.0-rc.1'):
    case(first, version=version)
    with Picker('wt') as picker:
        picker.visit_worktree()
        picker.key(b'\x19')
        expect_fallback(picker, requires_version, [version_call])

case(first)
with Picker('wt') as picker:
    picker.visit_worktree()
    picker.key(b'\x19')
    picker.expect(b'Type yes to send:')
    (box / 'version').write_text('0.12.99')
    picker.key(b'yes\r')
    expect_fallback(picker, requires_version, ready('%9') + [status_call, version_call])

for token, message in (
    ('refuse', b'Could not confirm a dedicated roost agent in pane %9.'),
    ('', b'Could not read a guarded roost token for pane %9.'),
):
    case(first, token=token)
    with Picker('wt') as picker:
        picker.visit_worktree()
        picker.key(b'\x19')
        expect_fallback(picker, message, ready('%9')[:-1])
        assert b'Type yes to send:' not in picker.output

# Catch identity changes while obtaining the token, before showing a prompt.
case(first)
status(dict(first, session_id='another-agent'), file='status-2.json')
with Picker('wt') as picker:
    picker.visit_worktree()
    picker.key(b'\x19')
    expect_fallback(picker, b'The selected roost pane changed or is unavailable.', ready('%9'))
    assert b'Type yes to send:' not in picker.output

# Invalid content and both size limits fail before opening a confirmation or
# starting roost. The second note fits as Markdown but not as escaped JSON.
for content, message in (
    ('é'.encode() * 1100000, b'Review notes exceed the 64 KiB roost send limit'),
    ('é'.encode() * 12000, b'Encoded review notes exceed the 64 KiB roost send limit'),
    (b'bad utf-8 \xf0\x80\x80\x80', b'Could not encode the review notes as UTF-8.'),
    (b'unsafe \x1b[31m text', b'The notes contain terminal control bytes.'),
):
    case(first)
    try:
        note.write_bytes(content)
        with Picker('wt') as picker:
            picker.visit_worktree()
            picker.key(b'\x19')
            expect_fallback(picker, message, [])
            assert b'Type yes to send:' not in picker.output
    finally:
        note.write_bytes(original_note)

# A replacement process can retain the same public status. The old token is
# the one confirmed, and roost decides whether input ever reached the pane.
for send_exit, message in (
    (7, b'roost refused guarded delivery to %9. No input was delivered.'),
    (8, b'Input may have reached %9. Inspect the pane before sending manually.'),
    (126, b'roost exited 126. Check pane %9 before sending manually.'),
):
    case(first, send_exit=send_exit)
    with Picker('wt') as picker:
        picker.visit_worktree()
        picker.key(b'\x19')
        picker.expect(b'Type yes to send:')
        (box / 'token-seed').write_text('replacement-token-')
        picker.key(b'yes\r')
        expect_fallback(picker, message, None)
        assert_delivery('%9')

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
        picker.expect(b'Send to %9? Type yes to send:')
        picker.key(b'yes\r')
        picker.expect(b'Review notes sent to %9.')
        picker.expect(b'Press Enter')
        assert_delivery('%9')
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
