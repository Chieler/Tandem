"""U28: cntctr hooks install / remove / status. Every run uses a temporary HOME under root."""
import json, os, pathlib, shlex, shutil, sqlite3, subprocess, sys, threading

binary, root = sys.argv[1:]
root = pathlib.Path(root).resolve()
passes = failures = 0
count = 0

def check(label, condition):
    global passes, failures
    if condition: passes += 1
    else: failures += 1; print('FAIL:', label, flush=True)

HARNESS = {
    'claude': ('.claude/settings.json', ['SessionStart', 'UserPromptSubmit', 'Stop', 'PermissionRequest', 'PostToolUse']),
    'agy': ('.gemini/config/hooks.json', ['PreInvocation', 'Stop']),
}

def new_home(exe_dir='bin'):
    """A fresh HOME with a copy of the binary named cntctr (the entry rule needs that name)."""
    global count
    count += 1
    home = root / f'u28-{count}'
    exe = home / exe_dir / 'cntctr'
    exe.parent.mkdir(parents=True)
    shutil.copy(binary, exe)
    return home, str(exe)

def env_for(home, extra=None):
    assert str(home).startswith(str(root)), 'test would leave its temporary HOME'
    e = os.environ.copy()
    e.update({'HOME': str(home), 'CNTCTR_DB': str(home / 'kb.db')})
    for k in ('CNTCTR_HOOKS_PAUSE_MS',): e.pop(k, None)
    e.update(extra or {})
    return e

def run(home, exe, *args, extra=None):
    return subprocess.run([exe, 'hooks', *args], env=env_for(home, extra), capture_output=True, text=True, timeout=20)

def commands(data, harness):
    """Every command string found under an event array, with its event."""
    out = []
    def entries(arr):
        for e in arr:
            if isinstance(e, dict) and isinstance(e.get('hooks'), list):
                for c in e['hooks']: yield c
            else: yield e
    if harness == 'claude':
        for ev, arr in (data.get('hooks') or {}).items():
            out += [(ev, c.get('command')) for c in entries(arr) if isinstance(c, dict)]
    else:
        for name, cfg in data.items():
            if not isinstance(cfg, dict): continue
            for ev, arr in cfg.items():
                if isinstance(arr, list): out += [(ev, c.get('command')) for c in entries(arr) if isinstance(c, dict)]
    return out

def ours(data, harness, exe):
    found = []
    for ev, cmd in commands(data, harness):
        try: words = shlex.split(cmd or '')
        except ValueError: continue
        if words == [exe, 'hook', harness, ev]: found.append(ev)
    return found

def text_of(p):
    return p.read_text() if p.exists() else None

def listing(path):
    return sorted(str(p.relative_to(path)) for p in path.rglob('*'))

for harness, (rel, events) in HARNESS.items():
    if harness == 'claude':
        original = {'model': 'x', 'other': {'n': [1, 2.5, 3]},
                    'hooks': {'Stop': [{'hooks': [{'type': 'command', 'command': '/usr/bin/true'}]}],
                              'PreToolUse': [{'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': 'echo hi'}]}]}}
        user = [('Stop', '/usr/bin/true'), ('PreToolUse', 'echo hi')]
    else:
        original = {'mine': {'Stop': [{'type': 'command', 'command': '/usr/bin/true'}],
                             'PreToolUse': [{'matcher': '.*', 'hooks': [{'type': 'command', 'command': 'echo hi'}]}]},
                    'extra': 1}
        user = [('Stop', '/usr/bin/true'), ('PreToolUse', 'echo hi')]
    others = {k: v for k, v in original.items() if k not in ('hooks', 'mine')}
    tag = f'U28 {harness}'

    # install keeps other hooks, adds cntctr's once, quotes a path with a space
    home, exe = new_home('dir with space')
    path = home / rel
    path.parent.mkdir(parents=True)
    text = json.dumps(original, indent=1)
    path.write_text(text)
    r = run(home, exe, 'install', harness)
    check(f'{tag} install exits 0', r.returncode == 0)
    data = json.loads(path.read_text())
    check(f'{tag} one entry per event', sorted(ours(data, harness, exe)) == sorted(events))
    check(f'{tag} user entries kept', all(u in commands(data, harness) for u in user))
    check(f'{tag} other keys kept', all(data.get(k) == v for k, v in others.items()))
    cmds = [c for ev, c in commands(data, harness) if c and c.endswith(f'hook {harness} {ev}') and 'cntctr' in c]
    check(f'{tag} path with a space is quoted', cmds and all(c.startswith("'") for c in cmds))
    backup = pathlib.Path(str(path) + '.cntctr-backup')
    check(f'{tag} first install makes the backup', text_of(backup) == text)
    # second install changes nothing, a hand edit in between does not replace the backup
    before = path.read_bytes()
    r = run(home, exe, 'install', harness)
    check(f'{tag} second install exits 0', r.returncode == 0)
    check(f'{tag} second install changes nothing', path.read_bytes() == before)
    data['late'] = 1
    path.write_text(json.dumps(data))
    r = run(home, exe, 'install', harness)
    check(f'{tag} third install keeps late edit', (json.loads(path.read_text()) or {}).get('late') == 1)
    check(f'{tag} backup is never overwritten', text_of(backup) == text)
    check(f'{tag} no temp file left', not [p for p in listing(path.parent) if 'tmp' in p])

    # remove takes out only cntctr's entries, keeps an entry edited into something else
    data = json.loads(path.read_text())
    edited = f'{exe} hook {harness} Stop --mine'
    if harness == 'claude': data['hooks']['Stop'].append({'hooks': [{'type': 'command', 'command': edited}]})
    else: data['mine']['Stop'].append({'type': 'command', 'command': edited})
    path.write_text(json.dumps(data))
    r = run(home, exe, 'remove', harness)
    check(f'{tag} remove exits 0', r.returncode == 0)
    data = json.loads(path.read_text())
    check(f'{tag} remove leaves no cntctr entry', ours(data, harness, exe) == [])
    check(f'{tag} remove keeps edited entry', ('Stop', edited) in commands(data, harness))
    check(f'{tag} remove keeps user entries', all(u in commands(data, harness) for u in user))
    check(f'{tag} remove keeps other keys', all(data.get(k) == v for k, v in others.items()) and data.get('late') == 1)

    # missing file is created (with its directory), nothing to back up; remove on a missing file creates nothing
    home, exe = new_home()
    path = home / rel
    r = run(home, exe, 'remove', harness)
    check(f'{tag} remove without file exits 0 and creates nothing', r.returncode == 0 and not path.exists())
    r = run(home, exe, 'install', harness)
    check(f'{tag} missing file is created', r.returncode == 0 and path.exists())
    data = json.loads(path.read_text())
    check(f'{tag} created file has the events', sorted(ours(data, harness, exe)) == sorted(events))
    check(f'{tag} created file needs no backup', not pathlib.Path(str(path) + '.cntctr-backup').exists())
    check(f'{tag} plain path needs no quotes', all(shlex.split(c)[0] == exe for ev, c in commands(data, harness)))

    # a file that is not strict JSON is not touched; the entries are printed
    for label, body in (('comment', '{ /* c */ "x": 1 }'), ('line comment', '// c\n{}'), ('empty', ''), ('array', '[]')):
        home, exe = new_home()
        path = home / rel
        path.parent.mkdir(parents=True)
        path.write_text(body)
        r = run(home, exe, 'install', harness)
        check(f'{tag} {label}: install exits non-zero', r.returncode != 0)
        check(f'{tag} {label}: file untouched', path.read_text() == body)
        check(f'{tag} {label}: no backup or temp file', listing(path.parent) == [path.name])
        check(f'{tag} {label}: entries printed', f'hook {harness} Stop' in r.stdout and 'cntctr' in r.stdout)
        r = run(home, exe, 'remove', harness)
        check(f'{tag} {label}: remove exits non-zero and leaves file', r.returncode != 0 and path.read_text() == body)

    # a file changed between read and write is not overwritten
    home, exe = new_home()
    path = home / rel
    path.parent.mkdir(parents=True)
    path.write_text('{"first": 1}')
    p = subprocess.Popen([exe, 'hooks', 'install', harness], env=env_for(home, {'CNTCTR_HOOKS_PAUSE_MS': '4000'}),
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    seen = threading.Event()
    lines = []
    def watch():
        for line in p.stderr:
            lines.append(line)
            if 'paused' in line: seen.set()
    threading.Thread(target=watch, daemon=True).start()
    if seen.wait(10):
        path.write_text('{"first": 1, "mid": 2}')
    else:
        p.kill()
    out, _ = p.communicate(timeout=20)
    check(f'{tag} install paused between read and write', seen.is_set())
    check(f'{tag} changed file: exits non-zero and says so', p.returncode != 0 and 'changed' in ''.join(lines) + out)
    check(f'{tag} changed file keeps the other writer\'s content', path.read_text() == '{"first": 1, "mid": 2}')
    check(f'{tag} changed file: no backup or temp file', listing(path.parent) == [path.name])

# agy gets no PreToolUse entry, ever; a stale cntctr one is removed by install
home, exe = new_home()
path = home / HARNESS['agy'][0]
path.parent.mkdir(parents=True)
path.write_text(json.dumps({'old': {'PreToolUse': [{'type': 'command', 'command': f'{exe} hook agy PreToolUse'}]}}))
r = run(home, exe, 'install', 'agy')
data = json.loads(path.read_text())
check('U28 agy: install writes no PreToolUse entry', r.returncode == 0 and not [1 for ev, c in commands(data, 'agy') if ev == 'PreToolUse'])
check('U28 agy: only PreInvocation and Stop', sorted(set(ev for ev, c in commands(data, 'agy'))) == ['PreInvocation', 'Stop'])

# codex is refused and nothing is written
home, exe = new_home()
before = listing(home)
for verb in ('install', 'remove'):
    r = run(home, exe, verb, 'codex')
    check(f'U28 codex {verb} refused', r.returncode != 0 and 'codex' in r.stderr + r.stdout)
check('U28 codex changes no file', listing(home) == before)
r = run(home, exe, 'install', 'nobody')
check('U28 unknown harness refused', r.returncode != 0 and listing(home) == before)

# a binary that is not named cntctr cannot make entries that remove would recognise
home, exe = new_home()
r = subprocess.run([binary, 'hooks', 'install', 'claude'], env=env_for(home), capture_output=True, text=True, timeout=20)
check('U28 binary not named cntctr is refused', r.returncode != 0 and not (home / HARNESS['claude'][0]).exists())

# status: installed, seen running, binary path, whether it is this binary
home, exe = new_home()
r = run(home, exe, 'status')
lines = {l.split(':')[0]: l for l in r.stdout.splitlines() if ':' in l}
check('U28 status before install', r.returncode == 0 and 'installed no' in lines.get('claude', '') and 'installed no' in lines.get('agy', ''))
run(home, exe, 'install', 'claude')
r = run(home, exe, 'status')
lines = {l.split(':')[0]: l for l in r.stdout.splitlines() if ':' in l}
check('U28 status installed yes with binary path', 'installed yes' in lines['claude'] and exe in lines['claude'])
check('U28 status says this binary', 'this binary' in lines['claude'] and 'not this binary' not in lines['claude'])
check('U28 status other harness not installed', 'installed no' in lines['agy'])
check('U28 status not seen running', 'seen running no' in lines['claude'])
db = sqlite3.connect(home / 'kb.db')
db.execute("INSERT INTO hook_sessions(socket,pane,harness,session_id,harness_pid,last_event,at) VALUES('s','%1','claude','x',1,'Stop',0)")
db.commit(); db.close()
r = run(home, exe, 'status')
lines = {l.split(':')[0]: l for l in r.stdout.splitlines() if ':' in l}
check('U28 status seen running from hook_sessions', 'seen running yes' in lines['claude'] and 'seen running no' in lines['agy'])
other = home / 'other' / 'cntctr'
other.parent.mkdir()
shutil.copy(binary, other)
r = run(home, str(other), 'status')
check('U28 status notices another binary', 'not this binary' in r.stdout and exe in r.stdout)
partial = home / HARNESS['claude'][0]
data = json.loads(partial.read_text())
del data['hooks']['Stop']
partial.write_text(json.dumps(data))
r = run(home, exe, 'status')
check('U28 status partial install is not installed', 'installed no' in [l for l in r.stdout.splitlines() if l.startswith('claude')][0])

print(f'{passes} passed, {failures} failed')
sys.exit(bool(failures))
