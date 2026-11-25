#!/usr/bin/env python3
"""Run a command on a PTY from a plain shell and answer its [y/N] prompt.
usage: pty_answer.py <answer|none> <cwd> <db> <stop_pid> <cmd> [args...]; prints RC=<n> PROMPTED=<prompts answered> then the output."""
import os, pty, select, subprocess, sys, time

ans, cwd, db, stop_pid = sys.argv[1:5]
cmd = sys.argv[5:]
m, s = pty.openpty()
env = dict(os.environ)
env["CNTCTR_DB"] = db
env["CNTCTR_TEST_ANCESTOR_STOP_PID"] = stop_pid
for k in ("TMUX_PANE", "CNTCTR_PANE", "CNTCTR_ROOT", "CNTCTR_CODE_SOCK"):
    env.pop(k, None)
p = subprocess.Popen(cmd, stdin=s, stdout=s, stderr=s, cwd=cwd, env=env)
os.close(s)
buf = bytearray()
sent = 0   # prompts answered
end = time.time() + 30
while time.time() < end:
    r, _, _ = select.select([m], [], [], 0.2)
    if r:
        try:
            chunk = os.read(m, 4096)
        except OSError:
            break
        if not chunk:
            break
        buf.extend(chunk)
        n = buf.count(b"[y/N]")
        while ans != "none" and sent < n:
            os.write(m, (ans + "\n").encode())
            sent += 1
    elif p.poll() is not None:
        break
if p.poll() is None:
    p.kill()
rc = p.wait()
os.close(m)
print(f"RC={rc} PROMPTED={sent}")
print(buf.decode("utf-8", "replace"))
