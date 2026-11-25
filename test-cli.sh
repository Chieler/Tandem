#!/bin/bash
set -euo pipefail
export MallocNanoZone=0  # ASan on macOS: silences "nano zone abandoned"; sanitizers stay on
root=$(cd "$(dirname "$0")" && pwd)
BIN=${BIN:-$root/cntctr-test}
case $BIN in /*) ;; *) BIN="$root/$BIN" ;; esac
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
mkdir -p "$d/bin" "$d/home/.claude/projects" "$d/home/.codex/sessions/2026/01/01" "$d/repo.with_dot/.worktrees"
git -C "$d/repo.with_dot" init -q
git -C "$d/repo.with_dot" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm fixture
git -C "$d/repo.with_dot" worktree add -qb worker "$d/repo.with_dot/.worktrees/worker"
git -C "$d/repo.with_dot" worktree add -qb external "$d/elsewhere"
mkdir -p "$d/nongit"
repo=$(cd "$d/repo.with_dot" && pwd -P)
sqlite3 "$d/db" "create table projects(root text,key text); create table entries(layer text,scope text,title text,created integer); insert into projects values ('$repo','fixture-scope'); insert into entries values ('history','fixture-scope','task 12345678 caller→worker→name',4102444800),('history','fixture-scope','reply 12345678 worker→caller',4102445400),('history','fixture-scope','reply 12345678 worker→caller',4102446000),('history','fixture-scope','task 87654321 caller→worker→name',4102444800),('history','other','task 00000000 caller→other',4102444800),('history','fixture-scope','task 11111111 caller→old',1000);"
out=$(cd "$repo" && CNTCTR_DB="$d/db" "$BIN" stats --since 1)
printf '%s\n' "$out" | grep -Eq 'worker→name +2 +1 +1 +10.0 +10.0'
if printf '%s\n' "$out" | grep -Eq '^other|^old'; then
    echo "FAIL: unexpected ^other|^old"
    exit 1
fi
out=$(cd "$repo" && CNTCTR_DB="$d/db" "$BIN" stats --all)
printf '%s\n' "$out" | grep -q 'other'
python3 - "$d" "$repo" <<'PY'
import datetime,json,os,sys
base,repo=sys.argv[1:]
enc=lambda s: "".join(c if c.isascii() and c.isalnum() else "-" for c in s)
projects=os.path.join(base,"home/.claude/projects")
worker=repo+"/.worktrees/worker"
elsewhere=os.path.realpath(base+"/elsewhere")
nongit=os.path.realpath(base+"/nongit")
for path,mid,model in [(repo,"m1","claude-main"),(worker,"m2","claude-worktree"),(elsewhere,"m3","claude-external"),(repo+"-web","m4","claude-sibling"),(nongit,"m5","claude-nongit"),(nongit+"-web","m6","claude-nongit-sibling")]:
 d=os.path.join(projects,enc(path)); os.makedirs(os.path.join(d,"session/subagents"))
 line={"type":"assistant","timestamp":"2099-01-01T00:00:00Z","message":{"id":mid,"model":model,"usage":{"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":30,"output_tokens":40}}}
 with open(os.path.join(d,"session.jsonl"),"w") as f: f.write((json.dumps(line)+"\n")*2)
 if mid=="m1":
  line["message"]["id"]="sub"; line["message"]["usage"]["input_tokens"]=5
  with open(os.path.join(d,"session/subagents/sub.jsonl"),"w") as f: f.write(json.dumps(line)+"\n")
for path,model in [(elsewhere,"codex-external"),(nongit,"codex-nongit"),(nongit+"-web","codex-nongit-sibling")]:
 lines=[{"type":"session_meta","payload":{"cwd":path}},{"type":"turn_context","payload":{"model":model}},{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":7}}}}]
 with open(os.path.join(base,"home/.codex/sessions/2026/01/01/rollout-"+model+".jsonl"),"w") as f:
  for line in lines: f.write(json.dumps(line)+"\n")
now=datetime.datetime.now(datetime.timezone.utc)
lines=[{"type":"session_meta","payload":{"cwd":worker}}, {"type":"turn_context","payload":{"model":"codex-window"}}]
for delta,inp,cache,out in [(-7200,10,3,2),(-30,100,30,20)]:
 lines.append({"timestamp":(now+datetime.timedelta(seconds=delta)).isoformat(),"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":inp,"cached_input_tokens":cache,"output_tokens":out}}}})
with open(os.path.join(base,"home/.codex/sessions/2026/01/01/rollout-fixture.jsonl"),"w") as f:
 for line in lines: f.write(json.dumps(line)+"\n")
PY
out=$(cd "$repo/.worktrees/worker" && HOME="$d/home" "$BIN" usage --since 1)
printf '%s\n' "$out"
printf '%s\n' "$out" | grep -Eq 'claude-main +15 +40 +60 +80'
printf '%s\n' "$out" | grep -Eq 'claude-worktree +10 +20 +30 +40'
printf '%s\n' "$out" | grep -q 'claude-external'
printf '%s\n' "$out" | grep -q 'codex-external'
if printf '%s\n' "$out" | grep -q 'claude-sibling'; then
    echo "FAIL: unexpected claude-sibling"
    exit 1
fi
nongit_out=$(cd "$d/nongit" && HOME="$d/home" "$BIN" usage --since 1)
printf '%s\n' "$nongit_out" | grep -q 'claude-nongit '
printf '%s\n' "$nongit_out" | grep -q 'codex-nongit '
if printf '%s\n' "$nongit_out" | grep -q 'nongit-sibling'; then
    echo "FAIL: unexpected nongit-sibling"
    exit 1
fi
printf '%s\n' "$out" | grep -Eq 'codex-window +90 +27 +0 +18 +30.0%'
printf '%s\n' "$out" | grep -q 'agy: not counted'
fixture=$(CNTCTR_USAGE_CLAUDE_DIR="$root/fixtures/usage/claude" CNTCTR_USAGE_CODEX_DIR="$root/fixtures/usage/codex" CNTCTR_USAGE_CWD=/fixture/project "$BIN" usage --since 500000)
printf '%s\n' "$fixture" | grep -Eq 'claude-fixture +10 +20 +30 +40'
printf '%s\n' "$fixture" | grep -Eq 'codex-fixture +100 +30 +0 +20 +30.0%'
"$BIN" --help | grep -q 'stats.*usage'
if [ "$(basename "$BIN")" = cntctr-test ]; then
 cat > "$d/bin/tmux" <<'SCRIPT'
#!/bin/sh
case "$1" in
 show) [ ! -f "$STATE" ] || cat "$STATE" ;;
 set) printf '%s\n' "$6" > "$STATE" ;;
 display) echo 0 ;;
esac
SCRIPT
 cat > "$d/bin/notifier" <<'SCRIPT'
#!/bin/sh
printf '%s %s %s\n' "$1" "$2" "$3" >> "$LOG"
SCRIPT
 chmod +x "$d/bin/tmux" "$d/bin/notifier"
 export PATH="$d/bin:$PATH" STATE="$d/state" LOG="$d/log" CNTCTR_NOTIFY_COMMAND="$d/bin/notifier"
 env -u CNTCTR_NOTIFY "$BIN" _test-notify
 [ ! -e "$LOG" ]
 CNTCTR_NOTIFY=1 "$BIN" _test-notify
 for i in $(seq 1 100); do [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -eq 3 ] && break; sleep 0.02; done
 [ "$(wc -l < "$LOG")" -eq 3 ]
 [ "$(grep -c '^permission test-agent %42$' "$LOG")" -eq 2 ]
 [ "$(grep -c '^reply test-worker %42$' "$LOG")" -eq 1 ]
else
 echo 'notification test skipped: requires cntctr-test'
fi
printf 'CLI standalone checks passed\n'
