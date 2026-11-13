#!/bin/bash
# End-to-end tests for cntctr. Runs against a private tmux server, never yours.
set -u
BIN=$(cd "$(dirname "${BIN:-./cntctr}")" && pwd)/$(basename "${BIN:-./cntctr}")
TMPD=$(mktemp -d)
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"test"}}}'
mkdir "$TMPD/bin" "$TMPD/home"
# Fake agents are `cat` on a terminal. Real harnesses (Claude Code, codex, agy) turn bracketed
# paste on, which the H7 paste guard needs; so a cat that reads a terminal turns it on first.
# Plain `cat` in pipes and heredocs is untouched. U25, U26 and the plain shells keep their own programs.
cat > "$TMPD/bin/cat" <<'EOF'
#!/bin/sh
[ -t 0 ] && printf '\033[?2004h'
exec /bin/cat "$@"
EOF
chmod +x "$TMPD/bin/cat"
REAL_TMUX=$(command -v tmux)
cat > "$TMPD/bin/tmux" <<EOF
#!/bin/sh
if [ -n "\$U24_CAPTURE_LOG" ]; then
    for a in "\$@"; do
        if [ "\$a" = "capture-pane" ]; then
            echo "\$@" >> "\$U24_CAPTURE_LOG"
            break
        fi
    done
fi
exec "$REAL_TMUX" "\$@"
EOF
chmod +x "$TMPD/bin/tmux"
FSH='printf "\033[?2004h"; exec sh'   # a fake agent that is a shell, same reason
export HOME="$TMPD/home"   # fleet tools keep their cache under ~/.cache
export BIN INIT CNTCTR_ENTER_DELAY_MS=50 LC_ALL=en_US.UTF-8 PATH="$TMPD/bin:$PATH" CNTCTR_DB="$TMPD/kb.db" CNTCTR_MEM_URL=
export CNTCTR_MAX_AGENTS=${CNTCTR_MAX_AGENTS:-256}
unset TMUX_PANE

SOCKET="cntctr-test-$$"
t() { tmux -L "$SOCKET" -f /dev/null "$@"; }
trap 't kill-server 2>/dev/null; sq "$CNTCTR_DB" "select review_root from tools where review_root > \"\"" 2>/dev/null | xargs rm -rf; rm -rf "$TMPD"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
t kill-server 2>/dev/null
t new-session -d -s test -x 200 -y 50 cat
export TMUX="$(t display -p '#{socket_path}'),0,0"

pass=0 fail=0
ok_() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$@"; }
same() { [ "$2" = "$3" ] && ok_ || bad "$1" "  want: $3" "  got:  $2"; }
sq() { sqlite3 -cmd '.timeout 5000' "$@" || { echo "FATAL: sqlite3 failed: $*" >&2; exit 1; }; }
check() { case $2 in *"$3"*) ok_ ;; *) bad "$1" "  want substring: $3" "  got: $2" ;; esac; }
refute() { case $2 in *"$3"*) bad "$1" "  unexpected: $3" ;; *) ok_ ;; esac; }

# rpc <line>...: feed raw JSON-RPC lines to one cntctr process, print its output
rpc() { printf '%s\n' "$@" | "$BIN"; }
# call <pane> <tool> <args-json>: run one tool as the agent in <pane>, print the response line
# session <pane> <n> <line>...: run one cntctr as <pane>'s agent and keep its stdin
# open until it has printed <n> lines, like a harness that waits for its answers
session() {
    local pane=$1 n=$2 fifo
    shift 2
    fifo=$(mktemp -u "$TMPD/fifo.XXXXXX")
    mkfifo "$fifo"
    TMUX_PANE=$pane "$BIN" < "$fifo" | {
        exec 3> "$fifo"
        printf '%s\n' "$@" >&3
        while [ "$n" -gt 0 ] && IFS= read -r l; do
            case ${SKIP:+$l} in '{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}') ;; *) printf '%s\n' "$l"; n=$((n - 1)) ;; esac
        done
        exec 3>&-
    }
    rm -f "$fifo"
}
# Since F9 the shared call lists with all=true: the tests are about something else. STRICT=1 (see scall) sends the arguments as given; the F9 tests use it.
call_args() {
    [ -n "${STRICT:-}" ] && { printf '%s' "$2"; return; }
    printf '%s' "$2" | jq -c --arg tool "$1" '
        if $tool == "list" then . + {all: true}
        else . end' 2>/dev/null || printf '%s' "$2"
}
call_raw() {
    SKIP=1 session "$1" 2 "$INIT" "$(printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$2" "$(call_args "$2" "$3")")" | tail -n 1
}
scall() { STRICT=1 call "$@"; }
call() {
    # a one-call session stands in for the agent's long-lived MCP server: it sets @cntctr_srv to its own pid and exits, so the pane is put back to the test shell's pid
    local out
    out=$(call_raw "$@")
    case $1 in %*) t set -p -t "$1" @cntctr_srv $$ 2>/dev/null ;; esac
    printf '%s\n' "$out"
}
rawtxt() { printf '%s' "$1" | jq -r '.result.content[0].text'; }
notice() { printf '%s' "$1" | jq -r '.result.content[1].text // empty'; }
txt() { printf '%s' "$1" | jq -r '.result.content[0].text'; }
iserr() { printf '%s' "$1" | jq -r '.result.isError'; }

screen() { t capture-pane -p -J -t "$1"; }
# expect_screen <description> <pane> <text>: pass once the pane shows <text> (waits up to 5 s)
expect_screen() {
    for _ in $(seq 50); do screen "$2" | grep -qF -- "$3" && { ok_; return; }; sleep 0.1; done
    bad "$1" "  pane $2 never showed: $3"
}
# daemon_start <pane>: a long-lived cntctr as <pane>'s agent; daemon_send <line>; daemon_stop
daemon_start() {
    DFIFO=$(mktemp -u "$TMPD/dfifo.XXXXXX"); mkfifo "$DFIFO"
    DOUT=$(mktemp "$TMPD/dout.XXXXXX")
    TMUX_PANE=$1 "$BIN" < "$DFIFO" > "$DOUT" & DPID=$!
    exec 4> "$DFIFO"
    printf '%s\n' "$INIT" >&4
}
daemon_send() { printf '%s\n' "$1" >&4; }
daemon_stop() { exec 4>&-; wait "$DPID" 2>/dev/null; rm -f "$DFIFO"; }

# lastid <pane>: id of the newest message envelope shown in the pane
lastid() { screen "$1" | sed -n 's/.*\[cntctr from=[^ ]* id=\([0-9a-f]\{8\}\)\].*/\1/p' | tail -n 1; }
# newpane <name> [command...]: open a tagged window running cat (or <command>), print its pane id
newpane() {
    local name=$1 pane; shift
    [ $# -gt 0 ] || set -- cat
    pane=$(t new-window -d -n "$name" -P -F '#{pane_id}' "$@")
    t set -p -t "$pane" @cntctr_name "$name"
    t set -p -t "$pane" @cntctr_harness test
    t set -p -t "$pane" @cntctr_srv $$   # a live pid: as if a 0.4.0 server served the pane (f7_1 unsets it)
    echo "$pane"
}

# Isolated 0.4.0 tests can run while another worktree runs the full suite.
if [ "${ONLY:-}" = hooks ]; then
    python3 tests/hooks_step2.py "$BIN" "$TMPD"
    exit $?
fi

# U28 (hooks install/remove/status) and the gather wait=false board wording: run alone with ONLY=u28 or ONLY=gboard, and in the full suite
u28_run() {
    local out p=0 f=0
    out=$(python3 tests/hooks_step3.py "$BIN" "$TMPD" 2>&1)
    printf '%s\n' "$out" | grep -v ' passed, '
    case $out in *' passed, '*) p=$(printf '%s\n' "$out" | sed -n 's/^\([0-9]*\) passed.*/\1/p'); f=$(printf '%s\n' "$out" | sed -n 's/.* \([0-9]*\) failed$/\1/p') ;; *) f=1 ;; esac
    pass=$((pass + p)); fail=$((fail + f))
}
# F9: agents only task agents they own. list shows owner and directory, and by default only the caller, its workers, parent and siblings;
# Run alone with ONLY=f9.
has_pane() { t list-panes -a -F '#{pane_id}' | grep -qx "$1"; }
f9_run() {
    local C W PAR SIB USR OW dirs out txt_ before after n all_n vis_n
    dirs="$(realpath "$TMPD")"; mkdir -p "$HOME/proj" "$dirs/elsewhere"
    PAR=$(newpane f9_par -c "$dirs/elsewhere"); C=$(newpane f9_me -c "$HOME"); W=$(newpane f9_w -c "$HOME/proj")
    SIB=$(newpane f9_sib); USR=$(newpane f9_user -c "$dirs/elsewhere"); OW=$(newpane f9_ow)
    t set -p -t "$C" @cntctr_parent "$PAR"; t set -p -t "$W" @cntctr_parent "$C"
    t set -p -t "$SIB" @cntctr_parent "$PAR"; t set -p -t "$OW" @cntctr_parent "$USR"
    # list: scope and fields
    out=$(txt "$(scall "$C" list '{}')")
    check "F9.1 list shows the caller, owned by its parent" "$(printf '%s\n' "$out" | grep '^f9_me ')" "owner=f9_par"
    check "F9.1 list shows a worker as owner=you" "$(printf '%s\n' "$out" | grep '^f9_w ')" "owner=you"
    check "F9.1 a worker's dir shows \$HOME as ~" "$(printf '%s\n' "$out" | grep '^f9_w ')" " dir=~/proj"
    check "F9.1 list shows the parent as owner=parent" "$(printf '%s\n' "$out" | grep '^f9_par ')" "owner=parent"
    check "F9.1 the parent's dir" "$(printf '%s\n' "$out" | grep '^f9_par ')" " dir=$dirs/elsewhere"
    check "F9.1 list shows a sibling owned by the parent's name" "$(printf '%s\n' "$out" | grep '^f9_sib ')" "owner=f9_par"
    refute "F9.1 list hides a user session" "$out" "f9_user "
    refute "F9.1 list hides another agent's worker" "$out" "f9_ow "
    all_n=$(txt "$(scall "$C" list '{"all":true}')" | grep -c ' alive \| dead ')
    vis_n=$(printf '%s\n' "$out" | grep -c ' alive \| dead ')
    check "F9.1 the last line counts the hidden agents" "$(printf '%s\n' "$out" | tail -n 1)" "+$((all_n - vis_n)) other agents (list all=true shows them)"
    out=$(txt "$(scall "$C" list '{"all":true}')")
    check "F9.2 all=true shows a user session as owner=user" "$(printf '%s\n' "$out" | grep '^f9_user ')" "owner=user"
    check "F9.2 all=true shows another agent's worker owned by its parent's name" "$(printf '%s\n' "$out" | grep '^f9_ow ')" "owner=f9_user"
    refute "F9.2 all=true has no count line" "$out" "other agents"
    out=$(txt "$(scall "$USR" list '{}')")
    check "F9.3 a user session sees itself as owner=user" "$(printf '%s\n' "$out" | grep '^f9_user ')" "owner=user"
    check "F9.3 and its worker as owner=you" "$(printf '%s\n' "$out" | grep '^f9_ow ')" "owner=you"
    refute "F9.3 and not the other session's workers" "$out" "f9_w "
    out=$(txt "$(scall "" list '{}')")
    refute "F9.4 a caller without a pane sees no agents by default" "$out" "f9_w "
    check "F9.4 and the count line" "$out" "other agents (list all=true shows them)"
    out=$(txt "$(scall "" list "{\"from\":\"f9_me\"}")")
    check "F9.4 list from= a pane works from that pane" "$out" "f9_w "
}
gboard_run() {
    local sender target r
    sender=$(newpane gb_sender); target=$(newpane gb_off)
    t select-pane -d -t "$target"
    r=$(txt "$(call "$sender" gather '{"tasks":[{"kind":"send","to":"gb_off","text":"gather input off"}],"wait":false}')")
    same "gather wait=false names the board fallback" "$(printf '%s' "$r" | jq -r '.results[0].status')" "sent on board"
    check "gather wait=false board send is stored" "$(txt "$(call "$target" board '{}')")" "gather input off"
}
if [ "${ONLY:-}" = u28 ] || [ "${ONLY:-}" = gboard ] || [ "${ONLY:-}" = f9 ]; then
    export CNTCTR_PASTE_WAIT_MS=100
    case $ONLY in u28) u28_run ;; f9) f9_run ;; *) gboard_run ;; esac
    printf '%d passed, %d failed\n' "$pass" "$fail"
    [ "$fail" -eq 0 ]; exit $?
fi

if [ "${ONLY:-}" = u1 ]; then
    t set-environment -g U1_DIR "$TMPD"
    cat > "$TMPD/bin/headroom" <<'EOF'
#!/bin/sh
tool=$2; shift 2
[ "$1" = -- ] && shift
exec "$tool" "$@"
EOF
    cat > "$TMPD/bin/claude" <<'EOF'
#!/usr/bin/env python3
import json, os, subprocess, time
root=os.environ['U1_DIR']
with open(root+'/u1.env','w') as f: json.dump({k:os.environ.get(k) for k in ('CNTCTR_PANE','CNTCTR_TMUX','CNTCTR_NAME')},f)
p=subprocess.Popen([os.environ['BIN']],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
def call(i, method, params):
    p.stdin.write(json.dumps({'jsonrpc':'2.0','id':i,'method':method,'params':params})+'\n'); p.stdin.flush()
    while True:
        row=json.loads(p.stdout.readline())
        if row.get('id')==i: return row
init={'protocolVersion':'2025-06-18','clientInfo':{'name':'fake'}}
call(1,'initialize',init)
with open(root+'/u1.first','w') as f: json.dump(call(2,'tools/call',{'name':'list','arguments':{}}),f)
while not os.path.exists(root+'/u1.go'): time.sleep(.05)
with open(root+'/u1.post','w') as f: json.dump(call(3,'tools/call',{'name':'post','arguments':{'text':'identity after rename'}}),f)
with open(root+'/u1.second','w') as f: json.dump(call(4,'tools/call',{'name':'list','arguments':{}}),f)
p.stdin.close(); p.wait()
EOF
    chmod +x "$TMPD/bin/headroom" "$TMPD/bin/claude"
    U_P=$(newpane u1_parent)
    spawn1=$(txt "$(call "$U_P" spawn '{"harness":"claude","name":"u1_worker","task":"identity test"}')")
    U_A=$(printf '%s' "$spawn1" | sed -n 's/.* in \(%[0-9]*\) .*/\1/p')
    for _ in $(seq 100); do [ -s "$TMPD/u1.first" ] && break; sleep 0.1; done
    same "U1 pane is supplied at spawn" "$(jq -r '.CNTCTR_PANE // ""' "$TMPD/u1.env")" "$U_A"
    same "U1 socket is supplied at spawn" "$(jq -r '.CNTCTR_TMUX // ""' "$TMPD/u1.env")" "$(t display -p '#{socket_path}')"
    same "U1 name is supplied at spawn" "$(jq -r '.CNTCTR_NAME // ""' "$TMPD/u1.env")" u1_worker
    check "U1 spawned server lists agent without from" "$(jq -r '.result.content[0].text' "$TMPD/u1.first")" "u1_worker"
    t set -p -t "$U_A" @cntctr_name u1_renamed
    touch "$TMPD/u1.go"
    for _ in $(seq 100); do [ -s "$TMPD/u1.second" ] && break; sleep 0.1; done
    check "U1 renamed agent listed" "$(jq -r '.result.content[0].text' "$TMPD/u1.second")" "u1_renamed"
    check "U1 posts under current pane name" "$(txt "$(call "$U_P" board '{}')")" "u1_renamed: identity after rename"
    cat > "$TMPD/bin/codex" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$U1_DIR/u1.codex"
exec cat
EOF
    chmod +x "$TMPD/bin/codex"
    call "$U_P" spawn '{"harness":"codex","name":"u1_codex","task":"identity test"}' >/dev/null
    for _ in $(seq 100); do [ -s "$TMPD/u1.codex" ] && break; sleep 0.1; done
    check "U1 codex forwards identity to its MCP server" "$(cat "$TMPD/u1.codex")" 'mcp_servers.cntctr.env_vars=["CNTCTR_PANE","CNTCTR_TMUX","CNTCTR_NAME"]'
    printf '%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]; exit $?
fi

if [ "${ONLY:-}" = u2 ]; then
    mkdir -p "$TMPD/sessions"
    export CNTCTR_CLAUDE_SESSIONS_DIR="$TMPD/sessions"
    cat > "$TMPD/claude.c" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>
int main(int argc, char **argv) {
    char path[4096];
    snprintf(path, sizeof path, "%s/%ld.json", argv[1], argc > 3 ? 99999999L : (long)getpid());
    FILE *f = fopen(path, "w");
    if (!f) return 2;
    fprintf(f, "{\"tmux\":\"cntctr:@1.%s\"}", argv[2]); fclose(f);
    pid_t child = fork();
    if (!child) { unsetenv("TMUX_PANE"); unsetenv("CNTCTR_PANE"); unsetenv("CNTCTR_NAME"); execl(getenv("BIN"), getenv("BIN"), (char *)0); _exit(127); }
    int status; waitpid(child, &status, 0); return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
EOF
    cc -o "$TMPD/bin/claude" "$TMPD/claude.c"
    U_A=$(newpane u2_agent)
    python3 - "$TMPD/bin/claude" "$TMPD/sessions" "$U_A" "$TMPD" <<'EOF'
import json, subprocess, sys
exe, directory, pane, root = sys.argv[1:]
def probe(dead):
    p=subprocess.Popen([exe,directory,pane]+(['dead'] if dead else []),stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
    def call(i,method,params):
        p.stdin.write(json.dumps({'jsonrpc':'2.0','id':i,'method':method,'params':params})+'\n');p.stdin.flush()
        while True:
            v=json.loads(p.stdout.readline())
            if v.get('id')==i:return v
    call(1,'initialize',{'protocolVersion':'2025-06-18','clientInfo':{'name':'fake'}})
    result=call(2,'tools/call',{'name':'post','arguments':{'text':'session ancestor'}})
    p.stdin.close();p.wait()
    return result
open(root+'/u2.live','w').write(json.dumps(probe(False)))
open(root+'/u2.dead','w').write(json.dumps(probe(True)))
EOF
    same "U2 live claude ancestor identifies pane" "$(jq -r '.result.isError' "$TMPD/u2.live")" false
    same "U2 dead session cannot identify pane" "$(jq -r '.result.isError' "$TMPD/u2.dead")" true
    check "U2 live session posted as agent" "$(txt "$(call "$U_A" board '{}')")" "u2_agent: session ancestor"
    printf '%d passed, %d failed\n' "$pass" "$fail"; [ "$fail" -eq 0 ]; exit $?
fi

if [ "${ONLY:-}" = u25 ] || [ "${ONLY:-}" = u26 ]; then
    export CNTCTR_PASTE_WAIT_MS=100
    U_P=$(newpane u_sender)
    if [ "$ONLY" = u25 ]; then
        U_A=$(newpane u_off)
        t select-pane -d -t "$U_A"
        r=$(call "$U_P" send '{"to":"u_off","text":"input off text"}')
        check "U25 disabled input falls back to board" "$(txt "$r")" "board"
        check "U25 fallback stored" "$(txt "$(call "$U_A" board '{}')")" "input off text"
        refute "U25 no text typed" "$(screen "$U_A")" "input off text"
    else
        cat > "$TMPD/reader.py" <<'EOF'
import os, signal, sys, termios, tty
log = sys.argv[1]
tty.setraw(0)
def enable(sig, frame): os.write(1, b'\x1b[?2004h')
signal.signal(signal.SIGUSR1, enable)
open(log, 'wb').close()
while True:
    data = os.read(0, 4096)
    if not data: break
    with open(log, 'ab') as f: f.write(data)
EOF
        U_A=$(newpane u_raw python3 "$TMPD/reader.py" "$TMPD/u26.log")
        for _ in $(seq 50); do [ -e "$TMPD/u26.log" ] && break; sleep 0.1; done
        r=$(call "$U_P" send '{"to":"u_raw","text":"first line\nsecond line"}')
        check "U26 unbracketed multiline falls back" "$(txt "$r")" "board"
        check "U26 fallback stored" "$(txt "$(call "$U_A" board '{}')")" "first line"
        same "U26 unbracketed text not typed" "$(wc -c < "$TMPD/u26.log" | tr -d ' ')" 0
        kill -USR1 "$(t display -p -t "$U_A" '#{pane_pid}')"
        for _ in $(seq 50); do [ "$(t display -p -t "$U_A" '#{bracket_paste_flag}')" = 1 ] && break; sleep 0.1; done
        r=$(call "$U_P" send '{"to":"u_raw","text":"safe first\nsafe second"}')
        check "U26 bracketed send succeeds" "$(txt "$r")" "sent id="
        sleep 0.2
        python3 - "$TMPD/u26.log" <<'EOF' && ok_ || bad "U26 received one bracketed message"
import sys
s = open(sys.argv[1], 'rb').read()
assert s.count(b'\x1b[200~') == 1 and s.count(b'\x1b[201~') == 1 and b'safe first\rsafe second' in s
EOF
    fi
    printf '%d passed, %d failed\n' "$pass" "$fail"
    [ "$fail" -eq 0 ]; exit $?
fi

if [ "${ONLY:-}" = u27 ]; then
    cat > "$TMPD/bin/headroom" <<'EOF'
#!/bin/sh
tool=$2; shift 2
[ "$1" = -- ] && shift
exec "$tool" "$@"
EOF
    cat > "$TMPD/bin/codex" <<'EOF'
#!/bin/sh
exec cat
EOF
    chmod +x "$TMPD/bin/headroom" "$TMPD/bin/codex"
    U27_P=$(newpane u27_parent)
    u27=$(txt "$(call "$U27_P" spawn '{"harness":"codex","name":"u27_hard","task":"implement the migration design"}')")
    check "U27 hard codex routes terra high" "$u27" "gpt-6.1-terra high"
    u27=$(txt "$(call "$U27_P" spawn '{"harness":"codex","name":"u27_review","task":"adversarial review"}')")
    check "U27 review codex routes sol high" "$u27" "gpt-6.1-sol high"
    u27=$(txt "$(call "$U27_P" spawn '{"harness":"codex","name":"u27_adversarial","task":"adversarial"}')")
    check "U27 adversarial whole word routes review" "$u27" "review: gpt-6.1-sol high"
    u27=$(txt "$(call "$U27_P" spawn '{"harness":"codex","name":"u27_redteam","task":"red team"}')")
    check "U27 red team whole words route review" "$u27" "review: gpt-6.1-sol high"
    u27=$(txt "$(call "$U27_P" spawn '{"harness":"codex","name":"u27_partial","task":"misadversarially"}')")
    check "U27 partial adversarial does not route review" "$u27" "standard: gpt-6.1-terra medium"
    u27=$(txt "$(call "$U27_P" spawn '{"harness":"codex","name":"u27_model","task":"adversarial","model":"chosen-model"}')")
    check "U27 explicit model wins" "$u27" "chosen-model"
    u27=$(txt "$(call "$U27_P" spawn '{"harness":"codex","name":"u27_tier","task":"adversarial","tier":"light"}')")
    check "U27 explicit tier wins" "$u27" "light: gpt-6.1-terra low"
    printf '%d passed, %d failed\n' "$pass" "$fail"
    [ "$fail" -eq 0 ]; exit $?
fi

ensure_hook_launchers() {
    mkdir -p "$TMPD/hook_harness"
    if [ ! -x "$TMPD/hook_harness/claude" ]; then
        cat > "$TMPD/hook_launcher.c" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc < 2) return 1;
    const char *bin = argv[1];
    const char *harness = argv[2] ? argv[2] : "claude";
    char line[4096];
    setvbuf(stdout, NULL, _IOLBF, 0);
    puts("READY");
    while (fgets(line, sizeof line, stdin)) {
        char event[128] = "", path[2048] = "", pane[64] = "", answer[2048] = "";
        int n = sscanf(line, "%127s %2047s %63s %2047s", event, path, pane, answer);
        if (n < 2) continue;
        pid_t child = fork();
        if (!child) {
            if (*pane) setenv("CNTCTR_PANE", pane, 1);
            if (freopen(path, "r", stdin) == NULL) _exit(2);
            if (freopen(*answer ? answer : "/dev/null", "w", stdout) == NULL) _exit(3);
            execl(bin, bin, "hook", harness, event, (char *)0);
            _exit(127);
        }
        int st;
        waitpid(child, &st, 0);
        puts("DONE");
    }
    return 0;
}
EOF
        cc -o "$TMPD/hook_harness/claude" "$TMPD/hook_launcher.c"
        cc -o "$TMPD/hook_harness/agy" "$TMPD/hook_launcher.c"
    fi
}

u22_run() {
    ensure_hook_launchers
    local c_in="$TMPD/u22_c_in" c_out="$TMPD/u22_c_out"
    rm -f "$c_in" "$c_out"
    mkfifo "$c_in" "$c_out"
    "$TMPD/hook_harness/claude" "$BIN" claude < "$c_in" > "$c_out" &
    local c_pid=$!
    exec 7> "$c_in"
    exec 8< "$c_out"
    local ready; read -r ready <&8

    local emit_c
    emit_c() {
        local ev=$1 fix=$2 p=$3
        printf '%s %s %s\n' "$ev" "$(realpath "fixtures/hooks/$fix")" "$p" >&7
        local d; read -r d <&8
    }

    local P; P=$(newpane u22_claude sh -c "$FSH")
    t set -p -t "$P" @cntctr_harness claude
    emit_c SessionStart claude-SessionStart.json "$P"
    emit_c UserPromptSubmit claude-UserPromptSubmit-mail.json "$P"
    emit_c Stop claude-Stop.json "$P"

    # Part 1: prompt submitted makes list show busy when screen is idle
    emit_c UserPromptSubmit claude-UserPromptSubmit-mail.json "$P"
    local out; out=$(call "$P" list '{}')
    check "U22 prompt event makes list show busy when screen is idle" "$(txt "$out")" "u22_claude claude $P alive busy"

    # Part 2: passing Stop makes list show idle when screen is busy
    t send-keys -t "$P" "printf '* Working (12s * esc to interrupt)\n'" Enter
    expect_screen "U22 screen shows busy" "$P" "esc to interrupt"
    emit_c Stop claude-Stop.json "$P"
    out=$(call "$P" list '{}')
    check "U22 passing Stop makes list show idle when screen is busy" "$(txt "$out")" "u22_claude claude $P alive idle"

    # Part 3: Claude Code permission event makes list show permission when screen says otherwise
    emit_c PermissionRequest claude-PermissionRequest.json "$P"
    out=$(call "$P" list '{}')
    check "U22 PermissionRequest makes list show permission when screen is busy" "$(txt "$out")" "u22_claude claude $P alive permission"

    # Part 4: a Stop that cntctr blocked: busy
    t send-keys -t "$P" C-c clear Enter
    sleep 0.2
    if ! sqlite3 -cmd '.timeout 5000' "$CNTCTR_DB" "UPDATE hook_sessions SET last_event='Stop', stop_blocked=1 WHERE pane='$P'" 2>/dev/null; then
        bad "U22 blocked Stop shows busy when screen is idle" "  want: u22_claude claude $P alive busy" "  got:  schema missing stop_blocked"
    else
        out=$(call "$P" list '{}')
        check "U22 blocked Stop shows busy when screen is idle" "$(txt "$out")" "u22_claude claude $P alive busy"
    fi

    exec 7>&-
    exec 8<&-
    kill $c_pid 2>/dev/null; wait $c_pid 2>/dev/null
    t kill-window -t "$P" 2>/dev/null
}

u23_run() {
    ensure_hook_launchers
    local c_in="$TMPD/u23_c_in" c_out="$TMPD/u23_c_out"
    rm -f "$c_in" "$c_out"
    mkfifo "$c_in" "$c_out"
    "$TMPD/hook_harness/claude" "$BIN" claude < "$c_in" > "$c_out" &
    local c_pid=$!
    exec 7> "$c_in"
    exec 8< "$c_out"
    local ready; read -r ready <&8

    local emit_c
    emit_c() {
        local ev=$1 fix=$2 p=$3
        printf '%s %s %s\n' "$ev" "$(realpath "fixtures/hooks/$fix")" "$p" >&7
        local d; read -r d <&8
    }

    local REF; REF=$(newpane u23_ref)

    # 1. Events say busy and the pane is dead: dead.
    local P_DEAD; P_DEAD=$(newpane u23_dead sh -c "$FSH")
    t set -p -t "$P_DEAD" @cntctr_harness claude
    t set -p -t "$P_DEAD" remain-on-exit on
    emit_c SessionStart claude-SessionStart.json "$P_DEAD"
    emit_c UserPromptSubmit claude-UserPromptSubmit-mail.json "$P_DEAD"
    emit_c Stop claude-Stop.json "$P_DEAD"
    emit_c UserPromptSubmit claude-UserPromptSubmit-mail.json "$P_DEAD"
    kill -9 "$(t display -p -t "$P_DEAD" '#{pane_pid}')" 2>/dev/null
    for _ in $(seq 20); do [ "$(t display -p -t "$P_DEAD" '#{pane_dead}')" = "1" ] && break; sleep 0.05; done
    local out; out=$(call "$REF" list '{}')
    check "U23 dead pane with busy event shows dead" "$(txt "$out")" "u23_dead claude $P_DEAD dead"
    refute "U23 dead pane does not show busy" "$(txt "$out")" "u23_dead claude $P_DEAD dead busy"
    t kill-window -t "$P_DEAD" 2>/dev/null

    # 2. Events say busy and recorded harness process is gone (shell is left): screen state
    local g_in="$TMPD/u23_g_in" g_out="$TMPD/u23_g_out"
    rm -f "$g_in" "$g_out"
    mkfifo "$g_in" "$g_out"
    "$TMPD/hook_harness/claude" "$BIN" claude < "$g_in" > "$g_out" &
    local g_pid=$!
    exec 5> "$g_in"
    exec 6< "$g_out"
    read -r ready <&6
    local P_GONE; P_GONE=$(newpane u23_gone sh -c "$FSH")
    t set -p -t "$P_GONE" @cntctr_harness claude
    printf '%s %s %s\n' "SessionStart" "$(realpath fixtures/hooks/claude-SessionStart.json)" "$P_GONE" >&5
    read -r ready <&6
    printf '%s %s %s\n' "UserPromptSubmit" "$(realpath fixtures/hooks/claude-UserPromptSubmit-mail.json)" "$P_GONE" >&5
    read -r ready <&6
    printf '%s %s %s\n' "Stop" "$(realpath fixtures/hooks/claude-Stop.json)" "$P_GONE" >&5
    read -r ready <&6
    printf '%s %s %s\n' "UserPromptSubmit" "$(realpath fixtures/hooks/claude-UserPromptSubmit-mail.json)" "$P_GONE" >&5
    read -r ready <&6
    exec 5>&-
    exec 6<&-
    kill $g_pid 2>/dev/null; wait $g_pid 2>/dev/null
    out=$(call "$REF" list '{}')
    check "U23 gone harness process falls back to screen state idle" "$(txt "$out")" "u23_gone claude $P_GONE alive idle"
    t kill-window -t "$P_GONE" 2>/dev/null

    # 3. A busy event older than 2 minutes on a pane that shows a usage limit: limited
    local P_LIM; P_LIM=$(newpane u23_lim sh -c "$FSH")
    t set -p -t "$P_LIM" @cntctr_harness claude
    emit_c SessionStart claude-SessionStart.json "$P_LIM"
    emit_c UserPromptSubmit claude-UserPromptSubmit-mail.json "$P_LIM"
    emit_c Stop claude-Stop.json "$P_LIM"
    emit_c UserPromptSubmit claude-UserPromptSubmit-mail.json "$P_LIM"
    t send-keys -t "$P_LIM" "printf 'Usage limit reached * continuing automatically at 10:40pm * esc to cancel\n'" Enter
    expect_screen "U23 screen shows limit" "$P_LIM" "continuing automatically at 10:40pm"
    out=$(call "$REF" list '{}')
    check "U23 fresh busy event ignores limit screen" "$(txt "$out")" "u23_lim claude $P_LIM alive busy"
    sq "$CNTCTR_DB" "UPDATE hook_sessions SET at=strftime('%s','now') - 130 WHERE pane='$P_LIM'"
    out=$(call "$REF" list '{}')
    check "U23 busy event older than 2 min reads limit screen" "$(txt "$out")" "u23_lim claude $P_LIM alive limited"
    check "U23 resets parsed from limit screen" "$(txt "$out")" 'resets="10:40pm"'
    t kill-window -t "$P_LIM" 2>/dev/null

    # 4. Agy non-idle reads screen; agy idle does not read screen
    local a_in="$TMPD/u23_a_in" a_out="$TMPD/u23_a_out"
    rm -f "$a_in" "$a_out"
    mkfifo "$a_in" "$a_out"
    "$TMPD/hook_harness/agy" "$BIN" agy < "$a_in" > "$a_out" &
    local a_pid=$!
    exec 5> "$a_in"
    exec 6< "$a_out"
    read -r ready <&6
    local P_AGY; P_AGY=$(newpane u23_agy sh -c "$FSH")
    t set -p -t "$P_AGY" @cntctr_harness agy
    printf '%s %s %s\n' "PreInvocation" "$(realpath fixtures/hooks/agy-PreInvocation-first.json)" "$P_AGY" >&5
    read -r ready <&6
    printf '%s %s %s\n' "Stop" "$(realpath fixtures/hooks/agy-Stop.json)" "$P_AGY" >&5
    read -r ready <&6

    # Test agy idle: screen says busy (esc to cancel), event says Stop passed -> idle
    t send-keys -t "$P_AGY" "printf '* Working (12s * esc to cancel)\n'" Enter
    expect_screen "U23 agy screen shows busy" "$P_AGY" "esc to cancel"
    out=$(call "$REF" list '{}')
    check "U23 agy idle ignores busy screen" "$(txt "$out")" "u23_agy agy $P_AGY alive idle"

    # Test agy non-idle: screen says permission prompt, event says PreInvocation -> reads screen -> permission
    t send-keys -t "$P_AGY" C-c clear Enter
    sleep 0.1
    t send-keys -t "$P_AGY" "printf 'Do you want to proceed?\n'" Enter
    expect_screen "U23 agy screen shows permission" "$P_AGY" "Do you want to proceed?"
    printf '%s %s %s\n' "PreInvocation" "$(realpath fixtures/hooks/agy-PreInvocation-first.json)" "$P_AGY" >&5
    read -r ready <&6
    out=$(call "$REF" list '{}')
    check "U23 agy non-idle reads screen permission" "$(txt "$out")" "u23_agy agy $P_AGY alive permission"

    exec 5>&-
    exec 6<&-
    kill $a_pid 2>/dev/null; wait $a_pid 2>/dev/null
    t kill-window -t "$P_AGY" 2>/dev/null

    exec 7>&-
    exec 8<&-
    kill $c_pid 2>/dev/null; wait $c_pid 2>/dev/null
    t kill-window -t "$REF" 2>/dev/null
}

u24_run() {
    ensure_hook_launchers
    local c_in="$TMPD/u24_c_in" c_out="$TMPD/u24_c_out"
    rm -f "$c_in" "$c_out"
    mkfifo "$c_in" "$c_out"
    "$TMPD/hook_harness/claude" "$BIN" claude < "$c_in" > "$c_out" &
    local c_pid=$!
    exec 7> "$c_in"
    exec 8< "$c_out"
    local ready; read -r ready <&8

    local emit_c
    emit_c() {
        local ev=$1 fix=$2 p=$3
        printf '%s %s %s\n' "$ev" "$(realpath "fixtures/hooks/$fix")" "$p" >&7
        local d; read -r d <&8
    }

    local panes=""
    for i in $(seq 1 32); do
        local p; p=$(newpane "u24_$i")
        t set -p -t "$p" @cntctr_harness claude
        emit_c SessionStart claude-SessionStart.json "$p"
        emit_c UserPromptSubmit claude-UserPromptSubmit-mail.json "$p"
        emit_c Stop claude-Stop.json "$p"
        panes="$panes $p"
    done

    export U24_CAPTURE_LOG="$TMPD/u24_capture.log"
    rm -f "$U24_CAPTURE_LOG"

    local first_pane; first_pane=$(echo "$panes" | awk '{print $1}')
    local start_ms end_ms elapsed out
    start_ms=$(python3 -c "import time; print(int(time.time()*1000))")
    out=$(call_raw "$first_pane" list '{}')   # not call: its restore of @cntctr_srv is test bookkeeping, not part of the answer time
    end_ms=$(python3 -c "import time; print(int(time.time()*1000))")
    elapsed=$((end_ms - start_ms))

    check "U24 list answers in under 1 s" "$((elapsed < 1000))" 1
    local captures=0
    [ -f "$U24_CAPTURE_LOG" ] && captures=$(wc -l < "$U24_CAPTURE_LOG" | tr -d ' ')
    same "U24 zero capture-pane calls for 32 hook agents" "$captures" 0
    same "U24 32 fake agents listed" "$(printf '%s' "$(txt "$out")" | grep -c '^u24_')" 32

    unset U24_CAPTURE_LOG
    for p in $panes; do
        t kill-window -t "$p" 2>/dev/null
    done
    exec 7>&-
    exec 8<&-
    kill $c_pid 2>/dev/null; wait $c_pid 2>/dev/null
}

# ---- step 5: mail by reference and the Stop gate (U6 to U21) ----
# Fake claude and agy processes run `cntctr hook` for fake agents (shell panes on the private socket); the
# agents are `cat` panes, so what cntctr types shows on their screen. Nothing here touches a real ~/.claude.
sqx() { sqlite3 -cmd '.timeout 5000' "$@" 2>/dev/null; }   # like sq, but a missing column is a failed check, not an abort
hk_boot() {
    ensure_hook_launchers
    local h
    for h in claude agy; do
        rm -f "$TMPD/hk_${h}_in" "$TMPD/hk_${h}_out"
        mkfifo "$TMPD/hk_${h}_in" "$TMPD/hk_${h}_out"
        "$TMPD/hook_harness/$h" "$BIN" "$h" < "$TMPD/hk_${h}_in" > "$TMPD/hk_${h}_out" &
        eval "HK_PID_$h=$!"
    done
    exec 20> "$TMPD/hk_claude_in" 21< "$TMPD/hk_claude_out" 22> "$TMPD/hk_agy_in" 23< "$TMPD/hk_agy_out"
    local ready
    read -r ready <&21; read -r ready <&23
    sleep 1   # mail counts only when posted after the tmux server's start second
    local p0
    p0=$(newpane u5_scope)
    U5_SCOPE=$(txt "$(call "$p0" project '{}')" | sed -n 's/^project \(.*\) (root .*/\1/p')   # the board scope of every fake agent here
    t kill-window -t "$p0"
}
hk_stop() {
    exec 20>&- 21<&- 22>&- 23<&-
    kill "$HK_PID_claude" "$HK_PID_agy" 2>/dev/null
    wait "$HK_PID_claude" "$HK_PID_agy" 2>/dev/null
}
# hk <harness> <event> <pane> <json>: run one hook call as that harness's process, print the answer
hk() {
    local ev="$TMPD/hk_event" out="$TMPD/hk_answer" ready
    printf '%s' "$4" > "$ev"
    rm -f "$out"
    if [ "$1" = claude ]; then printf '%s %s %s %s\n' "$2" "$ev" "$3" "$out" >&20; read -r ready <&21
    elif [ "$1" = claude2 ]; then printf '%s %s %s %s\n' "$2" "$ev" "$3" "$out" >&24; read -r ready <&25   # a claude on the second private tmux server (f6_1)
    else printf '%s %s %s %s\n' "$2" "$ev" "$3" "$out" >&22; read -r ready <&23; fi
    cat "$out" 2>/dev/null
}
c_start() { hk claude SessionStart "$1" '{"session_id":"S1","hook_event_name":"SessionStart","source":"startup"}'; }
c_prompt() { hk claude UserPromptSubmit "$1" "$(jq -nc --arg p "$2" '{session_id:"S1",hook_event_name:"UserPromptSubmit",prompt:$p}')"; }
c_stop() { hk claude Stop "$1" "{\"session_id\":\"S1\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":${2:-false}}"; }
c_perm() { hk claude PermissionRequest "$1" '{"session_id":"S1","hook_event_name":"PermissionRequest","tool_name":"Bash"}'; }
a_start() { hk agy SessionStart "$1" '{"conversationId":"S1","hookEventName":"SessionStart"}'; }
a_pre() { hk agy PreInvocation "$1" "$(jq -nc --arg p "$3" --argjson n "${2:-0}" '{conversationId:"S1",executionNum:0,invocationNum:$n,hookEventName:"PreInvocation",lastUserInput:$p}')"; }
a_stop() { hk agy Stop "$1" "{\"conversationId\":\"S1\",\"executionNum\":${3:-0},\"fullyIdle\":true,\"terminationReason\":\"${2:-NO_TOOL_CALL}\"}"; }
# hk_agent <claude|agy> <name>: a fake agent pane whose hook events are on record and whose last event is a passing Stop
hk_agent() {
    local p h=$1 n=$2
    shift 2
    p=$(newpane "$n" "$@")
    set -- "$h"
    t set -p -t "$p" @cntctr_harness "$1"
    if [ "$1" = claude ]; then c_start "$p"; c_prompt "$p" hello; c_stop "$p"
    else a_start "$p"; a_pre "$p" 0 hello; a_stop "$p"; fi >/dev/null
    echo "$p"
}
# mail_text <task> <body>: an envelope as send stores it
mail_text() { printf '[cntctr from=sender id=%s]\n%s\n[when done: call the reply tool of the cntctr MCP server with id=%s and your answer]\n[cntctr end id=%s]' "$1" "$2" "$1" "$1"; }
# mailput <pane> <task> <text> [presentations] [at]: store a pending mail for <pane> the way send does (with its tmux socket); prints its id
mailput() {
    local f="$TMPD/mail_text" name
    name=$(t display -p -t "$1" '#{@cntctr_name}')
    printf '%s' "$3" > "$f"
    sqx "$CNTCTR_DB" "INSERT INTO posts(scope,sender,text,at) VALUES('$U5_SCOPE','sender',CAST(readfile('$f') AS TEXT),${5:-strftime('%s','now')}); INSERT INTO mail(post,name,pane,task,hooked,presentations,socket) VALUES(last_insert_rowid(),'$name','$1','$2',1,${4:-0},'$(t display -p '#{socket_path}')'); SELECT last_insert_rowid();"
}
mstate() { sqx "$CNTCTR_DB" "SELECT state||'/'||presentations||'/'||delivered FROM mail WHERE post=$1"; }
pointer() { printf '[cntctr mail id=%s] body attached; if you see none, call board' "$1"; }
ctx_c() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // empty'; }
ctx_a() { printf '%s' "$1" | jq -r '.injectSteps[0].systemMessage.systemMessage // empty'; }
emptyans() { [ "$(printf '%s' "$1" | jq -c . 2>/dev/null)" = '{}' ]; }

u5p1_run() {
    local P Q m1 m2 m3 ans ctx body path i
    P=$(hk_agent claude u5_c1)
    m1=$(mailput "$P" a0000001 "$(mail_text a0000001 'please build the thing')" 1)
    m2=$(mailput "$P" a0000002 "$(mail_text a0000002 'second request about docs')" 0)
    ans=$(c_prompt "$P" "$(pointer "$m1")")
    ctx=$(ctx_c "$ans")
    same "U6 prompt hook answers in the UserPromptSubmit format" "$(printf '%s' "$ans" | jq -r '.hookSpecificOutput.hookEventName')" UserPromptSubmit
    check "U6 prompt hook attaches the full envelope" "$ctx" "please build the thing"
    check "U6 attached envelope keeps its reply instruction" "$ctx" "call the reply tool of the cntctr MCP server with id=a0000001"
    check "U6 attached envelope keeps its end line" "$ctx" "[cntctr end id=a0000001]"
    check "U6 the same prompt also attaches the other pending mail" "$ctx" "second request about docs"
    case $ctx in *"please build the thing"*"second request about docs"*) ok_ ;; *) bad "U6 oldest mail comes first" "  got: $ctx" ;; esac
    refute "U6 a first presentation is not marked as a repeat" "$ctx" "may be a repeat"
    same "U6 the mail named by the line is staged and not delivered; its typed line already counted" "$(mstate "$m1")" "staged/1/0"
    same "U6 a mail that rode along is staged and counts one presentation" "$(mstate "$m2")" "staged/1/0"

    # U14: a line inside other text, a trailing text, leading zeros, an unknown id, another agent's mail id: nothing attached
    Q=$(hk_agent claude u5_c2)
    m3=$(mailput "$Q" a0000003 "$(mail_text a0000003 'mail for the other agent')" 1)
    ans=$(c_prompt "$Q" "please look at $(pointer "$m3")")
    emptyans "$ans" && ok_ || bad "U14 a line inside other text attaches nothing" "  got: $ans"
    ans=$(c_prompt "$Q" "$(pointer "$m3") now")
    emptyans "$ans" && ok_ || bad "U14 a line with text after it attaches nothing" "  got: $ans"
    ans=$(c_prompt "$Q" "$(pointer "0$m3")")
    emptyans "$ans" && ok_ || bad "U14 a line with a padded id attaches nothing" "  got: $ans"
    ans=$(c_prompt "$Q" "$(pointer 99999999)")
    emptyans "$ans" && ok_ || bad "U14 an unknown id attaches nothing" "  got: $ans"
    ans=$(c_prompt "$Q" "$(pointer "$m1")")
    emptyans "$ans" && ok_ || bad "U14 another agent's mail id attaches nothing" "  got: $ans"
    same "U14 the mail stays pending after refused lines" "$(mstate "$m3")" "pending/1/0"
    ans=$(hk claude UserPromptSubmit "$Q" "$(cat fixtures/hooks/claude-UserPromptSubmit-other.json)")
    emptyans "$ans" && ok_ || bad "U14 the recorded fixture with the line inside text attaches nothing" "  got: $ans"
    ans=$(c_prompt "$Q" "$(pointer "$m3")")
    check "U14 the exact line still attaches afterwards" "$(ctx_c "$ans")" "mail for the other agent"

    # U13: one 100 KB body for Claude Code goes to a file; the context holds head, tail and the path
    P=$(hk_agent claude u5_c3)
    body=$(printf 'HEADMARK\n'; head -c 50000 /dev/zero | tr '\0' x; printf '\nMIDMARK\n'; head -c 50000 /dev/zero | tr '\0' y; printf '\nTAILMARK')
    m1=$(mailput "$P" b0000001 "$(mail_text b0000001 "$body")" 1)
    ans=$(c_prompt "$P" "$(pointer "$m1")")
    ctx=$(ctx_c "$ans")
    check "U13 Claude Code answer for 100 KB stays within 8 KB" "$((${#ans} <= 8192))" 1
    check "U13 the context holds the head of the body" "$ctx" HEADMARK
    check "U13 the context holds the tail of the body" "$ctx" TAILMARK
    check "U13 the context holds the reply instruction in the tail" "$ctx" "[cntctr end id=b0000001]"
    refute "U13 the middle of the body is not in the context" "$ctx" MIDMARK
    path=$(printf '%s' "$ctx" | grep -o "$HOME/[^ ]*" | head -1)
    check "U13 the context names a file under the cache directory" "$path" "/.cache/cntctr/"
    check "U13 the file holds the whole body" "$(cat "$path" 2>/dev/null | grep -c MIDMARK)" 1
    same "U13 the file holds the whole envelope" "$(wc -c < "$path" 2>/dev/null | tr -d ' ')" "$(mail_text b0000001 "$body" | wc -c | tr -d ' ')"
    same "U13 the file has private permissions" "$(ls -l "$path" 2>/dev/null | cut -c1-10)" "-rw-------"
    same "U13 the big mail is staged" "$(mstate "$m1")" "staged/1/0"
    # five 3 KB bodies: as many as fit, oldest first, the rest stays pending
    P=$(hk_agent claude u5_c4)
    local ids=""
    for i in 1 2 3 4 5; do
        body=$(printf 'BODY%s ' "$i"; head -c 3000 /dev/zero | tr '\0' z)
        ids="$ids $(mailput "$P" "c000000$i" "$(mail_text "c000000$i" "$body")" $((i == 1)))"
    done
    set -- $ids
    ans=$(c_prompt "$P" "$(pointer "$1")")
    ctx=$(ctx_c "$ans")
    check "U13 five 3 KB bodies for Claude Code stay within 8 KB" "$((${#ans} <= 8192))" 1
    check "U13 the oldest of five is attached" "$ctx" BODY1
    refute "U13 the newest of five is not attached" "$ctx" BODY5
    same "U13 the oldest of five is staged" "$(mstate "$1")" "staged/1/0"
    same "U13 the newest of five stays pending and uncounted" "$(mstate "$5")" "pending/0/0"
    # the same 100 KB body for agy has room for the 40 KB budget; the five bodies all fit
    Q=$(hk_agent agy u5_a1)
    body=$(printf 'HEADMARK\n'; head -c 50000 /dev/zero | tr '\0' x; printf '\nMIDMARK\n'; head -c 50000 /dev/zero | tr '\0' y; printf '\nTAILMARK')
    m1=$(mailput "$Q" d0000001 "$(mail_text d0000001 "$body")" 1)
    ans=$(a_pre "$Q" 0 "$(pointer "$m1")")
    ctx=$(ctx_a "$ans")
    check "U13 agy answer for 100 KB stays within 40 KB" "$((${#ans} <= 40960))" 1
    check "U13 agy gets the head" "$ctx" HEADMARK
    refute "U13 agy does not get the middle" "$ctx" MIDMARK
    check "U13 agy names a file" "$ctx" "$HOME/"
    Q=$(hk_agent agy u5_a2)
    ids=""
    for i in 1 2 3 4 5; do
        body=$(printf 'BODY%s ' "$i"; head -c 3000 /dev/zero | tr '\0' z)
        ids="$ids $(mailput "$Q" "e000000$i" "$(mail_text "e000000$i" "$body")" $((i == 1)))"
    done
    set -- $ids
    ans=$(a_pre "$Q" 0 "$(pointer "$1")")
    ctx=$(ctx_a "$ans")
    check "U13 agy takes all five 3 KB bodies" "$ctx" BODY5
    same "U13 agy stages all five" "$(sqx "$CNTCTR_DB" "SELECT count(*) FROM mail WHERE pane='$Q' AND state='staged'")" 5

    # U9: agy calls the hook before every model step; a second call of the turn attaches nothing
    Q=$(hk_agent agy u5_a3)
    m1=$(mailput "$Q" f0000001 "$(mail_text f0000001 'agy first mail')" 1)
    ans=$(a_pre "$Q" 0 "$(pointer "$m1")")
    check "U9 first PreInvocation attaches the mail as an injected step" "$(ctx_a "$ans")" "agy first mail"
    same "U9 agy mail is staged" "$(mstate "$m1")" "staged/1/0"
    m2=$(mailput "$Q" f0000002 "$(mail_text f0000002 'agy mail that arrived mid-turn')" 0)
    ans=$(a_pre "$Q" 1 "$(pointer "$m1")")
    emptyans "$ans" && ok_ || bad "U9 a second PreInvocation of the same turn attaches nothing" "  got: $ans"
    same "U9 the mid-turn mail stays pending" "$(mstate "$m2")" "pending/0/0"
    same "U9 the staged mail is not counted again" "$(mstate "$m1")" "staged/1/0"
}


# undelivered <mail id>: the mail is not delivered (it may be staged or pending)
undelivered() { [ "$(sqx "$CNTCTR_DB" "SELECT delivered FROM mail WHERE post=$1")" = 0 ]; }

u5p2_run() {
    local P S Q m m2 ans out
    P=$(hk_agent claude u5_d1)
    S=$(newpane u5_d1_sender)
    # U7: a normal Stop of the staging turn delivers
    m=$(mailput "$P" d1000001 "$(mail_text d1000001 'normal stop mail')" 1)
    c_prompt "$P" "$(pointer "$m")" >/dev/null
    same "U7 attached mail is staged first" "$(mstate "$m")" "staged/1/0"
    ans=$(c_stop "$P")
    emptyans "$ans" && ok_ || bad "U7 a normal Stop with nothing else pending passes" "  got: $ans"
    same "U7 a normal Stop of the staging turn delivers" "$(mstate "$m")" "delivered/1/1"
    # U7: reply to the mail's task id delivers
    t set -s @cntctr_from_d1000002 "$S"; t set -s @cntctr_to_d1000002 "$P"; t set -s @cntctr_sender_d1000002 u5_d1_sender
    m=$(mailput "$P" d1000002 "$(mail_text d1000002 'reply me')" 1)
    c_prompt "$P" "$(pointer "$m")" >/dev/null
    same "U7 mail to be answered is staged" "$(mstate "$m")" "staged/1/0"
    call "$P" reply '{"id":"d1000002","text":"my answer"}' >/dev/null
    same "U7 reply to the mail's id delivers" "$(mstate "$m")" "delivered/1/1"
    # U7: board returning the body delivers
    m=$(mailput "$P" d1000003 "$(mail_text d1000003 'board me')" 1)
    c_prompt "$P" "$(pointer "$m")" >/dev/null
    out=$(txt "$(call "$P" board '{}')")
    check "U7 board returns the body" "$out" "board me"
    same "U7 board returning the body delivers" "$(mstate "$m")" "delivered/1/1"
    # U7: list, recall, post, note and a send deliver nothing
    m=$(mailput "$P" d1000004 "$(mail_text d1000004 'not by other tools')" 1)
    c_prompt "$P" "$(pointer "$m")" >/dev/null
    call "$P" list '{}' >/dev/null
    call "$P" recall '{"query":"anything"}' >/dev/null
    call "$P" post '{"text":"news from u5_d1"}' >/dev/null
    call "$P" note '{"layer":"insight","title":"u5 note","summary":"u5 note"}' >/dev/null
    call "$P" send '{"to":"u5_d1_sender","text":"hello sender"}' >/dev/null
    same "U7 list, recall, post, note and send deliver nothing" "$(mstate "$m")" "staged/1/0"
    c_stop "$P" >/dev/null
    # U7: an agy Stop after an error or a cancel delivers nothing; a normal one does
    Q=$(hk_agent agy u5_d2)
    m=$(mailput "$Q" d2000001 "$(mail_text d2000001 'agy error mail')" 1)
    a_pre "$Q" 0 "$(pointer "$m")" >/dev/null
    same "U7 agy mail is staged" "$(mstate "$m")" "staged/1/0"
    a_stop "$Q" ERROR >/dev/null
    undelivered "$m" && ok_ || bad "U7 a Stop with terminationReason ERROR does not deliver" "  got: $(mstate "$m")"
    m2=$(mailput "$Q" d2000002 "$(mail_text d2000002 'agy cancel mail')" 1)
    a_pre "$Q" 0 "$(pointer "$m2")" >/dev/null
    a_stop "$Q" USER_CANCELED >/dev/null
    undelivered "$m2" && ok_ || bad "U7 a Stop with terminationReason USER_CANCELED does not deliver" "  got: $(mstate "$m2")"
    a_pre "$Q" 0 "$(pointer "$m2")" >/dev/null
    a_stop "$Q" NO_TOOL_CALL >/dev/null
    same "U7 an agy Stop that ends normally delivers" "$(mstate "$m2")" "delivered/1/1"

    # U8: staged mail and a new prompt with no Stop in between: pending again; shown again with a repeat note
    P=$(hk_agent claude u5_d3)
    m=$(mailput "$P" d3000001 "$(mail_text d3000001 'maybe seen mail')" 1)
    c_prompt "$P" "$(pointer "$m")" >/dev/null
    same "U8 mail is staged in the first turn" "$(mstate "$m")" "staged/1/0"
    c_prompt "$P" "an unrelated question" >/dev/null
    same "U8 a new turn with no delivery makes staged mail pending again" "$(mstate "$m")" "pending/1/0"
    sqx "$CNTCTR_DB" "UPDATE mail SET presentations=2 WHERE post=$m" # a second line was typed for it
    ans=$(c_prompt "$P" "$(pointer "$m")")
    check "U8 the mail comes again" "$(ctx_c "$ans")" "maybe seen mail"
    check "U8 and says it may be a repeat" "$(ctx_c "$ans")" "(may be a repeat)"
    same "U8 the repeat is staged, still counted twice" "$(mstate "$m")" "staged/2/0"
    c_stop "$P" >/dev/null
    same "U8 the repeat is delivered by the Stop" "$(mstate "$m")" "delivered/2/1"
    # U8: the same for agy
    Q=$(hk_agent agy u5_d4)
    m=$(mailput "$Q" d4000001 "$(mail_text d4000001 'agy maybe seen')" 1)
    a_pre "$Q" 0 "$(pointer "$m")" >/dev/null
    a_pre "$Q" 0 "an unrelated question" >/dev/null
    same "U8 agy: a new turn with no delivery makes staged mail pending again" "$(mstate "$m")" "pending/1/0"

    # U10: mail staged by the prompt hook is not presented again by the Stop of the same turn
    P=$(hk_agent claude u5_d5)
    m=$(mailput "$P" d5000001 "$(mail_text d5000001 'first in the turn')" 1)
    c_prompt "$P" "$(pointer "$m")" >/dev/null
    m2=$(mailput "$P" d5000002 "$(mail_text d5000002 'arrived during the turn')" 0)
    ans=$(c_stop "$P")
    same "U10 the Stop holds the agent for the mail that was not staged" "$(printf '%s' "$ans" | jq -r '.decision')" block
    check "U10 the hold carries the new mail" "$(printf '%s' "$ans" | jq -r '.reason')" "arrived during the turn"
    refute "U10 the hold does not repeat the staged mail" "$(printf '%s' "$ans" | jq -r '.reason')" "first in the turn"
    same "U10 the staged mail is delivered by that Stop" "$(mstate "$m")" "delivered/1/1"
    same "U10 the held mail is staged and counted once" "$(mstate "$m2")" "staged/1/0"
    ans=$(c_stop "$P" true)
    emptyans "$ans" && ok_ || bad "U10 the second Stop of the turn is never held" "  got: $ans"
    same "U10 the second Stop delivers the held mail" "$(mstate "$m2")" "delivered/1/1"
    # U10: a Stop of a turn that ended abnormally for agy does not hold either
    Q=$(hk_agent agy u5_d6)
    m=$(mailput "$Q" d6000001 "$(mail_text d6000001 'agy pending at error')" 0)
    ans=$(a_stop "$Q" ERROR)
    emptyans "$ans" && ok_ || bad "U10 a Stop after an error is never held" "  got: $ans"
    same "U10 the mail stays pending" "$(mstate "$m")" "pending/0/0"
}

# pointers <pane>: the distinct non-empty lines on the pane's screen, one per line (cat shows each typed line twice)
screen_lines() { screen "$1" | sed 's/\^\[\[20[01]~//g' | grep -v '^[[:space:]]*$' | sort -u; }
# wait_mstate <description> <mail id> <state/presentations/delivered>: pass once the mail has that state (waits up to 5 s)
wait_mstate() {
    for _ in $(seq 100); do [ "$(mstate "$2")" = "$3" ] && { ok_; return; }; sleep 0.1; done
    bad "$1" "  want: $3" "  got:  $(mstate "$2")"
}
# mailid <task>: the mail id stored for a task
mailid() { sqx "$CNTCTR_DB" "SELECT post FROM mail WHERE task='$1' ORDER BY post DESC LIMIT 1"; }

u5p3_run() {
    local S S2 P Q N R W id id2 task task2 ans before after lines ctx
    S=$(newpane u5_snd); S2=$(newpane u5_snd2)

    # U6 (pane half): send to an idle agent that has hooks types the one line and nothing else
    P=$(hk_agent claude u5_e1)
    out=$(txt "$(call "$S" send '{"to":"u5_e1","text":"build the widget"}')")
    check "U6 send reports an id" "$out" "sent id="
    refute "U6 send to a hook agent is not reported as board only" "$out" "on board"
    task=${out#sent id=}
    id=$(mailid "$task")
    expect_screen "U6 the pane gets the pointer line" "$P" "[cntctr mail id=$id] body attached; if you see none, call board"
    same "U6 the pane holds that one line and nothing else" "$(screen_lines "$P")" "$(pointer "$id")"
    same "U6 the stored mail is pending with one presentation" "$(mstate "$id")" "pending/1/0"
    same "U6 the wake is reserved" "$(sqx "$CNTCTR_DB" "SELECT wake_reserved FROM hook_sessions WHERE pane='$P'")" 1
    ans=$(c_prompt "$P" "$(pointer "$id")")
    ctx=$(ctx_c "$ans")
    check "U6 the prompt hook answer holds the full envelope" "$ctx" "build the widget"
    check "U6 with its header" "$ctx" "[cntctr from=u5_snd id=$task]"
    check "U6 with its end line" "$ctx" "[cntctr end id=$task]"
    check "U6 with the reply instruction" "$ctx" "call the reply tool of the cntctr MCP server with id=$task"
    same "U6 the mail is staged, not delivered" "$(mstate "$id")" "staged/1/0"
    same "U6 the hook event ends the wake reservation" "$(sqx "$CNTCTR_DB" "SELECT wake_reserved FROM hook_sessions WHERE pane='$P'")" 0
    c_stop "$P" >/dev/null

    # never more than the one line: three sends in a row to one idle agent type one line
    P=$(hk_agent claude u5_e2)
    for task in 1 2 3; do call "$S" send "{\"to\":\"u5_e2\",\"text\":\"burst $task\"}" >/dev/null; done
    sleep 1
    same "no more than the one line: three sends in a row type one line" "$(screen_lines "$P" | wc -l | tr -d ' ')" 1
    refute "the pane never shows an envelope" "$(screen "$P")" "[cntctr from="
    same "all three mails are stored" "$(sqx "$CNTCTR_DB" "SELECT count(*) FROM mail WHERE pane='$P' AND state='pending'")" 3
    id=$(sqx "$CNTCTR_DB" "SELECT min(post) FROM mail WHERE pane='$P'")
    ans=$(c_prompt "$P" "$(pointer "$id")")
    ctx=$(ctx_c "$ans")
    case $ctx in *"burst 1"*"burst 2"*"burst 3"*) ok_ ;; *) bad "one prompt answer holds all three envelopes, oldest first" "  got: $ctx" ;; esac
    c_stop "$P" >/dev/null

    # never more than the one line: a reply to an agent that has hooks, and a follow-up, type the one line
    P=$(hk_agent claude u5_e3); W=$(newpane u5_e3w)
    out=$(txt "$(call "$P" send '{"to":"u5_e3w","text":"work for the worker"}')")
    task=${out#sent id=}
    call "$W" reply "{\"id\":\"$task\",\"text\":\"worker answer\"}" >/dev/null
    id=$(mailid "$task")
    expect_screen "never more than the line: a reply to a hook agent types the pointer" "$P" "[cntctr mail id=$id] body attached"
    same "a reply to a hook agent types one line only" "$(screen_lines "$P")" "$(pointer "$id")"
    ans=$(c_prompt "$P" "$(pointer "$id")")
    check "the reply text arrives with the attached context" "$(ctx_c "$ans")" "worker answer"
    check "as a reply envelope" "$(ctx_c "$ans")" "[cntctr reply from=u5_e3w id=$task]"
    c_stop "$P" >/dev/null
    Q=$(hk_agent claude u5_e4); W=$(newpane u5_e4w)
    out=$(txt "$(call "$W" send '{"to":"u5_e4","text":"first task"}')")
    task=${out#sent id=}
    id=$(mailid "$task")
    c_prompt "$Q" "$(pointer "$id")" >/dev/null
    c_stop "$Q" >/dev/null
    call "$W" send "{\"to\":\"u5_e4\",\"text\":\"and one more thing\",\"re\":\"$task\"}" >/dev/null
    id2=$(sqx "$CNTCTR_DB" "SELECT max(post) FROM mail WHERE pane='$Q'")
    expect_screen "a follow-up to an agent that has hooks types a pointer" "$Q" "[cntctr mail id=$id2] body attached"
    refute "the follow-up text is not typed" "$(screen "$Q")" "and one more thing"
    ans=$(c_prompt "$Q" "$(pointer "$id2")")
    check "the follow-up arrives attached as an addendum" "$(ctx_c "$ans")" "addendum"
    c_stop "$Q" >/dev/null

    # U15: a busy agent that has hooks gets nothing typed; the Stop hook presents the mail
    P=$(hk_agent claude u5_f1)
    c_prompt "$P" "work on something long" >/dev/null
    before=$(screen "$P")
    out=$(txt "$(call "$S" send '{"to":"u5_f1","text":"mail for a busy agent"}')")
    check "U15 send to a busy agent is accepted" "$out" "sent id="
    task=${out#sent id=}; id=$(mailid "$task")
    sleep 0.5
    same "U15 nothing is typed into the pane of a busy agent" "$(screen "$P")" "$before"
    same "U15 the mail waits, uncounted" "$(mstate "$id")" "pending/0/0"
    ans=$(c_stop "$P")
    same "U15 the Stop hook blocks" "$(printf '%s' "$ans" | jq -r '.decision')" block
    check "U15 and holds the envelope" "$(printf '%s' "$ans" | jq -r '.reason')" "mail for a busy agent"
    check "U15 with its end line" "$(printf '%s' "$ans" | jq -r '.reason')" "[cntctr end id=$task]"
    same "U15 the held mail is staged and counted" "$(mstate "$id")" "staged/1/0"
    same "U15 still nothing typed after the Stop" "$(screen "$P")" "$before"
    c_stop "$P" true >/dev/null
    same "U15 the continuation's Stop delivers it" "$(mstate "$id")" "delivered/1/1"
    # U15: the same for agy
    Q=$(hk_agent agy u5_f2)
    a_pre "$Q" 0 "work on something long" >/dev/null
    before=$(screen "$Q")
    out=$(txt "$(call "$S" send '{"to":"u5_f2","text":"mail for a busy agy"}')")
    task=${out#sent id=}; id=$(mailid "$task")
    sleep 0.5
    same "U15 agy: nothing is typed into a busy agent" "$(screen "$Q")" "$before"
    ans=$(a_stop "$Q" NO_TOOL_CALL)
    same "U15 agy: the Stop hook continues the turn" "$(printf '%s' "$ans" | jq -r '.decision')" continue
    check "U15 agy: with the envelope as the reason" "$(printf '%s' "$ans" | jq -r '.reason')" "mail for a busy agy"
    # a permission prompt (Claude Code event) and a busy screen with an idle event: nothing typed either
    P=$(hk_agent claude u5_f3)
    c_perm "$P" >/dev/null
    before=$(screen "$P")
    call "$S" send '{"to":"u5_f3","text":"mail during a permission prompt"}' >/dev/null
    sleep 0.5
    same "U15 nothing is typed while a permission event is the last event" "$(screen "$P")" "$before"
    P=$(hk_agent claude u5_f4)
    t send-keys -t "$P" "* Working (12s * esc to interrupt)" Enter
    expect_screen "U15 the screen shows a busy marker" "$P" "esc to interrupt"
    before=$(screen "$P")
    out=$(txt "$(call "$S" send '{"to":"u5_f4","text":"mail for a screen that says busy"}')")
    task=${out#sent id=}; id=$(mailid "$task")
    sleep 0.5
    same "U15 nothing is typed when the screen says busy although the event says idle" "$(screen "$P")" "$before"
    same "U15 the wake is not left reserved" "$(sqx "$CNTCTR_DB" "SELECT wake_reserved FROM hook_sessions WHERE pane='$P'")" 0
    same "U15 the mail waits" "$(mstate "$id")" "pending/0/0"

    # U12: two sends at the same moment to one idle agent: one line; one answer holds both envelopes
    P=$(hk_agent claude u5_g1)
    local pa pb
    call "$S" send '{"to":"u5_g1","text":"race text one"}' > "$TMPD/u12_a" & pa=$!
    call "$S2" send '{"to":"u5_g1","text":"race text two"}' > "$TMPD/u12_b" & pb=$!
    wait $pa $pb
    sleep 0.5
    same "U12 both sends are accepted" "$(txt "$(cat "$TMPD/u12_a")" | grep -c 'sent id='),$(txt "$(cat "$TMPD/u12_b")" | grep -c 'sent id=')" "1,1"
    same "U12 one line in the pane" "$(screen_lines "$P" | wc -l | tr -d ' ')" 1
    id=$(sqx "$CNTCTR_DB" "SELECT post FROM mail WHERE pane='$P' AND presentations=1")
    same "U12 exactly one of the two mails has its own line" "$(echo "$id" | wc -w | tr -d ' ')" 1
    ans=$(c_prompt "$P" "$(pointer "$id")")
    ctx=$(ctx_c "$ans")
    check "U12 the answer holds the first envelope" "$ctx" "race text one"
    check "U12 and the second" "$ctx" "race text two"
    same "U12 both are staged with one presentation each" "$(sqx "$CNTCTR_DB" "SELECT group_concat(state||presentations) FROM mail WHERE pane='$P'" | tr ',' '\n' | sort -u | tr '\n' ' ')" "staged1 "
    c_stop "$P" >/dev/null

    # U16: the hook never runs; the line tells the agent to call board, which lists and delivers its mail
    P=$(hk_agent claude u5_h1); R=$(newpane u5_h1r)
    out=$(txt "$(call "$S" send '{"to":"u5_h1","text":"mail that no hook presents"}')")
    task=${out#sent id=}; id=$(mailid "$task")
    expect_screen "U16 the pane has the line" "$P" "[cntctr mail id=$id] body attached; if you see none, call board"
    same "U16 no hook event came; the mail is pending" "$(mstate "$id")" "pending/1/0"
    refute "U16 another agent's board does not list it" "$(txt "$(call "$R" board '{}')")" "mail that no hook presents"
    refute "U16 the sender's board does not list it" "$(txt "$(call "$S" board '{}')")" "mail that no hook presents"
    ans=$(txt "$(call "$P" board '{}')")
    check "U16 the addressee's board lists the mail" "$ans" "mail that no hook presents"
    same "U16 and delivers it" "$(mstate "$id")" "delivered/1/1"

    # U17: an agent without hooks gets the full envelope, as in 0.3.0
    N=$(newpane u5_i1)
    out=$(txt "$(call "$S" send '{"to":"u5_i1","text":"mail for an agent without hooks"}')")
    task=${out#sent id=}
    expect_screen "U17 the pane gets the full envelope" "$N" "[cntctr end id=$task]"
    check "U17 with the text" "$(screen "$N")" "mail for an agent without hooks"
    check "U17 and the header" "$(screen "$N")" "[cntctr from=u5_snd id=$task]"
    refute "U17 no pointer line is typed" "$(screen "$N")" "[cntctr mail id="
    same "U17 no mail row is kept for it" "$(sqx "$CNTCTR_DB" "SELECT count(*) FROM mail WHERE pane='$N'")" 0

    # the retry thread wakes an idle agent that has hooks and pending mail: one line
    P=$(hk_agent claude u5_j1)
    id=$(mailput "$P" j1000001 "$(mail_text j1000001 'mail found by the retry thread')" 0)
    daemon_start "$P"
    daemon_send '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list","arguments":{}}}'
    expect_screen "the retry thread types the pointer for an idle hook agent" "$P" "[cntctr mail id=$id] body attached"
    same "and nothing else" "$(screen_lines "$P")" "$(pointer "$id")"
    wait_mstate "and counts the presentation" "$id" "pending/1/0"
    daemon_stop
    # and types nothing for a busy one
    P=$(hk_agent claude u5_j2)
    c_prompt "$P" "work on something" >/dev/null
    before=$(screen "$P")
    id=$(mailput "$P" j2000001 "$(mail_text j2000001 'mail for a busy agent found by the retry thread')" 0)
    daemon_start "$P"
    daemon_send '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list","arguments":{}}}'
    sleep 2
    same "the retry thread types nothing into a busy hook agent" "$(screen "$P")" "$before"
    daemon_stop
}

# list_call: the long-lived server (daemon_start) learns its agent's identity, which starts its mail retry thread
daemon_hello() { daemon_send '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list","arguments":{}}}'; }
notices() { sqx "$CNTCTR_DB" "SELECT count(*) FROM posts WHERE text LIKE '%undelivered after 3 attempts: $1 to %'"; }

u5p4_run() {
    local S Q P id task out i before ans lines
    export CNTCTR_PASTE_WAIT_MS=100
    S=$(newpane u5_snd4)

    # U11: a mail presented three times without delivery is stalled, and its sender is told once
    Q=$(hk_agent agy u5_k1)
    daemon_start "$Q"
    daemon_hello
    out=$(txt "$(call "$S" send '{"to":"u5_k1","text":"mail that is never delivered"}')")
    task=${out#sent id=}; id=$(mailid "$task")
    wait_mstate "U11 the first line is typed and counted" "$id" "pending/1/0"
    for i in 1 2 3; do
        ans=$(a_pre "$Q" 0 "$(pointer "$id")")
        check "U11 presentation $i attaches the mail" "$(ctx_a "$ans")" "mail that is never delivered"
        same "U11 presentation $i is staged" "$(mstate "$id")" "staged/$i/0"
        a_stop "$Q" ERROR >/dev/null
        if [ "$i" -lt 3 ]; then wait_mstate "U11 after an error Stop the retry thread types the line again" "$id" "pending/$((i + 1))/0"; fi
    done
    wait_mstate "U11 the third presentation went unanswered: stalled" "$id" "stalled/3/0"
    before=$(screen "$Q")
    ans=$(a_pre "$Q" 0 "$(pointer "$id")")
    emptyans "$ans" && ok_ || bad "U11 the fourth event attaches nothing" "  got: $ans"
    sleep 3
    same "U11 the retry thread types nothing for a stalled mail" "$(screen "$Q")" "$before"
    same "U11 the sender has one undelivered mail" "$(notices "$id")" 1
    check "U11 it names the mail and the addressee" "$(txt "$(call "$S" board '{}')")" "undelivered after 3 attempts: $id to u5_k1"
    # a server restart does not reset the count and does not tell the sender again
    daemon_stop
    daemon_start "$Q"
    daemon_hello
    sleep 3
    same "U11 after a server restart the mail is still stalled" "$(mstate "$id")" "stalled/3/0"
    same "U11 after a server restart the sender is not told again" "$(notices "$id")" 1
    same "U11 after a server restart nothing is typed" "$(screen "$Q")" "$before"
    check "U11 the addressee's board lists the stalled mail" "$(txt "$(call "$Q" board '{}')")" "mail that is never delivered"
    check "U11 and its unread notice counted it before the read" "$(sqx "$CNTCTR_DB" "SELECT count(*) FROM mail WHERE pane='$Q'")" 1
    daemon_stop

    # U11b: the hook command stops running: after the wake window (1 s here, 30 s by default) the mail is pasted as a full envelope
    export CNTCTR_WAKE_SEC=1
    P=$(hk_agent claude u5_l1)
    daemon_start "$P"
    daemon_hello
    out=$(txt "$(call "$S" send '{"to":"u5_l1","text":"mail when the hook is gone"}')")
    task=${out#sent id=}; id=$(mailid "$task")
    expect_screen "U11b the pointer line is typed first" "$P" "[cntctr mail id=$id]"
    expect_screen "U11b with no hook event, the full envelope is pasted after the wake window" "$P" "[cntctr end id=$task]"
    check "U11b with the text" "$(screen "$P")" "mail when the hook is gone"
    wait_mstate "U11b that paste delivers the mail" "$id" "delivered/1/1"
    same "U11b the agent has no hooks until its next prompt event" "$(sqx "$CNTCTR_DB" "SELECT broken FROM hook_sessions WHERE pane='$P'")" 1
    out=$(txt "$(call "$S" send '{"to":"u5_l1","text":"second mail while the hook is gone"}')")
    task=${out#sent id=}
    expect_screen "U11b a send now pastes the full envelope at once" "$P" "[cntctr end id=$task]"
    c_prompt "$P" "I am back" >/dev/null
    same "U11b the next prompt event gives the hooks back" "$(sqx "$CNTCTR_DB" "SELECT broken FROM hook_sessions WHERE pane='$P'")" 0
    daemon_stop

    # U11b: with the full paste failing as well, the pointer is typed three times at most, then the mail is stalled
    P=$(hk_agent claude u5_l2 sh -c 'exec /bin/cat')   # no bracketed paste: a multi-line paste is refused, one line is not
    daemon_start "$P"
    daemon_hello
    out=$(txt "$(call "$S" send '{"to":"u5_l2","text":"mail that cannot be pasted"}')")
    task=${out#sent id=}; id=$(mailid "$task")
    wait_mstate "U11b the mail is stalled after three pointers" "$id" "stalled/3/0"
    lines=$(screen "$P" | grep -c '\[cntctr mail id=')   # cat shows each typed line twice
    same "U11b the pointer was typed three times" "$lines" 6
    refute "U11b the text itself was never typed" "$(screen "$P")" "mail that cannot be pasted"
    same "U11b the sender has the undelivered mail, once" "$(notices "$id")" 1
    daemon_stop
    unset CNTCTR_WAKE_SEC CNTCTR_PASTE_WAIT_MS
}

# stopped <task>: how many "stopped without a reply" mails exist for that task
stopped() { sqx "$CNTCTR_DB" "SELECT count(*) FROM posts WHERE text LIKE '%stopped without a reply to task $1 (%'"; }

u5p5_run() {
    local PAR OTH W AW NP OLD NEW out T id ans reason
    PAR=$(newpane u5_par1); OTH=$(newpane u5_oth1)

    # U18: a spawned worker with an open, unanswered task is held once; then it passes and the parent is told once
    W=$(hk_agent claude u5_w1); t set -p -t "$W" @cntctr_parent "$PAR"
    call "$W" board '{}' >/dev/null
    out=$(txt "$(call "$PAR" send '{"to":"u5_w1","text":"do the job"}')")
    T=${out#sent id=}; id=$(mailid "$T")
    call "$OTH" post '{"text":"news for the fleet"}' >/dev/null
    c_prompt "$W" "$(pointer "$id")" >/dev/null
    ans=$(c_stop "$W")
    same "U18 a Stop with an open unanswered task blocks" "$(printf '%s' "$ans" | jq -r '.decision')" block
    reason=$(printf '%s' "$ans" | jq -r '.reason')
    check "U18 the hold names the task id" "$reason" "$T"
    check "U18 and the sender" "$reason" "u5_par1"
    check "U18 and the unread count" "$reason" "1 unread"
    check "U18 and what to do" "$reason" "read the board, then reply"
    same "U18 the mail of that turn is delivered by the Stop" "$(mstate "$id")" "delivered/1/1"
    same "U18 the parent is not told at the hold" "$(stopped "$T")" 0
    ans=$(c_stop "$W" true)
    emptyans "$ans" && ok_ || bad "U18 the second Stop of the turn passes" "  got: $ans"
    same "U18 the parent has one stopped-without-a-reply mail" "$(stopped "$T")" 1
    check "U18 it names the worker and the task" "$(txt "$(call "$PAR" board '{}')")" "u5_w1 stopped without a reply to task $T ("
    c_prompt "$W" "carry on" >/dev/null
    ans=$(c_stop "$W")
    emptyans "$ans" && ok_ || bad "U18 a Stop in a later turn for the same task passes" "  got: $ans"
    same "U18 and adds no second mail" "$(stopped "$T")" 1
    # one message: mail and an open task together
    W=$(hk_agent claude u5_w5); t set -p -t "$W" @cntctr_parent "$PAR"
    out=$(txt "$(call "$PAR" send '{"to":"u5_w5","text":"task for the one-message case"}')")
    T=${out#sent id=}; id=$(mailid "$T")
    c_prompt "$W" "$(pointer "$id")" >/dev/null
    mailput "$W" m5000001 "$(mail_text m5000001 'extra mail during the turn')" 0 >/dev/null
    ans=$(c_stop "$W")
    reason=$(printf '%s' "$ans" | jq -r '.reason')
    check "U18 one message carries the mail" "$reason" "extra mail during the turn"
    check "U18 and the open task" "$reason" "$T"
    c_stop "$W" true >/dev/null

    # U19: a Stop after an error passes at once, and the parent gets the reason
    AW=$(hk_agent agy u5_w2); t set -p -t "$AW" @cntctr_parent "$PAR"
    out=$(txt "$(call "$PAR" send '{"to":"u5_w2","text":"a job that fails"}')")
    T=${out#sent id=}; id=$(mailid "$T")
    a_pre "$AW" 0 "$(pointer "$id")" >/dev/null
    ans=$(a_stop "$AW" ERROR)
    emptyans "$ans" && ok_ || bad "U19 a Stop with terminationReason ERROR passes" "  got: $ans"
    same "U19 the parent has one mail" "$(stopped "$T")" 1
    check "U19 with the reason" "$(txt "$(call "$PAR" board '{}')")" "u5_w2 stopped without a reply to task $T (ERROR)"
    # and a cancel is never held either
    AW=$(hk_agent agy u5_w6); t set -p -t "$AW" @cntctr_parent "$PAR"
    out=$(txt "$(call "$PAR" send '{"to":"u5_w6","text":"a job that is cancelled"}')")
    T=${out#sent id=}; id=$(mailid "$T")
    a_pre "$AW" 0 "$(pointer "$id")" >/dev/null
    ans=$(a_stop "$AW" USER_CANCELED)
    emptyans "$ans" && ok_ || bad "U19 a Stop with terminationReason USER_CANCELED passes" "  got: $ans"
    check "U19 the parent is told with that reason" "$(txt "$(call "$PAR" board '{}')")" "u5_w6 stopped without a reply to task $T (USER_CANCELED)"

    # U20: an agent without a parent is held for mail only, never for board news or an open task
    NP=$(hk_agent claude u5_np)
    call "$NP" board '{}' >/dev/null
    out=$(txt "$(call "$OTH" send '{"to":"u5_np","text":"a task for a user session"}')")
    T=${out#sent id=}; id=$(mailid "$T")
    c_prompt "$NP" "$(pointer "$id")" >/dev/null
    call "$OTH" post '{"text":"more news for the fleet"}' >/dev/null
    ans=$(c_stop "$NP")
    emptyans "$ans" && ok_ || bad "U20 a Stop for an agent without a parent, with unread posts and an open task, passes" "  got: $ans"
    same "U20 nobody is told" "$(stopped "$T")" 0
    mailput "$NP" n6000001 "$(mail_text n6000001 'mail for the user session')" 0 >/dev/null
    c_prompt "$NP" "next question" >/dev/null
    ans=$(c_stop "$NP")
    same "U20 but mail addressed to it still holds it" "$(printf '%s' "$ans" | jq -r '.decision')" block

    # U21: a worker respawned under the same name in a new pane is not held for the old pane's task
    OLD=$(hk_agent claude u5_w4); t set -p -t "$OLD" @cntctr_parent "$PAR"
    out=$(txt "$(call "$PAR" send '{"to":"u5_w4","text":"a task for the old pane"}')")
    T=${out#sent id=}
    t kill-window -t "$OLD"
    NEW=$(hk_agent claude u5_w4); t set -p -t "$NEW" @cntctr_parent "$PAR"
    ans=$(c_stop "$NEW")
    emptyans "$ans" && ok_ || bad "U21 a respawned worker is not held for the old pane's task" "  got: $ans"
    same "U21 and the parent is not told about it" "$(stopped "$T")" 0
}

# ---- fix round 6 (F1 to F9) ----
t2() { tmux -L "$SOCKET-2" -f /dev/null "$@"; }
# f6_1: mail matches a pane only on its own tmux server (and only when that server's start time is known)
f6_1() {
    local W S U U2 A m m2 ans sock2 n out task start
    S=$(newpane f6_snd)
    # (a) two private servers, the same pane id: the other server's session is not held with this worker's mail.
    # A real send records the mail's socket; the mail for the other server's pane is stored by hand, as a send to a worker
    # on this server whose pane id is the other server's first pane (%0) would store it.
    W=$(hk_agent claude f6_w1)
    out=$(txt "$(call "$S" send '{"to":"f6_w1","text":"mail for the worker on the first server"}')")
    task=${out#sent id=}; m=$(mailid "$task")
    same "F1a the mail records its tmux socket" "$(sqx "$CNTCTR_DB" "SELECT socket FROM mail WHERE post=$m")" "$(t display -p '#{socket_path}')"
    t2 kill-server 2>/dev/null
    t2 new-session -d -s two -x 200 -y 50 cat
    sock2=$(t2 display -p '#{socket_path}')
    U=$(t2 display -p '#{pane_id}')
    t2 set -p -t "$U" @cntctr_srv $$
    rm -f "$TMPD/hk_claude2_in" "$TMPD/hk_claude2_out"; mkfifo "$TMPD/hk_claude2_in" "$TMPD/hk_claude2_out"
    TMUX="$sock2,0,0" "$TMPD/hook_harness/claude" "$BIN" claude < "$TMPD/hk_claude2_in" > "$TMPD/hk_claude2_out" & HK_PID_c2=$!
    exec 24> "$TMPD/hk_claude2_in" 25< "$TMPD/hk_claude2_out"
    read -r n <&25
    hk claude2 SessionStart "$U" '{"session_id":"S1","hook_event_name":"SessionStart","source":"startup"}' >/dev/null
    sleep 1
    mail_text f6a00001 'mail for a pane of the first server that has the second server pane id' > "$TMPD/f6_a_text"
    sqx "$CNTCTR_DB" "INSERT INTO posts(scope,sender,text,at) VALUES('$U5_SCOPE','sender',CAST(readfile('$TMPD/f6_a_text') AS TEXT),strftime('%s','now')); INSERT INTO mail(post,name,pane,task,hooked,presentations,socket) VALUES(last_insert_rowid(),'f6_gone','$U','f6a00001',1,0,'$(t display -p '#{socket_path}')')"
    m=$(sqx "$CNTCTR_DB" "SELECT max(post) FROM mail")
    hk claude2 UserPromptSubmit "$U" '{"session_id":"S1","hook_event_name":"UserPromptSubmit","prompt":"my own question"}' >/dev/null
    ans=$(hk claude2 Stop "$U" '{"session_id":"S1","hook_event_name":"Stop","stop_hook_active":false}')
    emptyans "$ans" && ok_ || bad "F1a a session on another tmux server is not held with this worker's mail" "  got: $ans"
    refute "F1a and the mail is not shown to it" "$ans" "second server pane id"
    same "F1a the mail is untouched" "$(mstate "$m")" "pending/0/0"
    exec 24>&- 25<&-; kill "$HK_PID_c2" 2>/dev/null; wait "$HK_PID_c2" 2>/dev/null
    t2 kill-server 2>/dev/null

    # (b) a session whose SessionStart was never recorded, after a restart, with old mail for a dead agent
    U=$(newpane f6_user); t set -p -t "$U" @cntctr_harness claude
    sqx "$CNTCTR_DB" "INSERT INTO posts(scope,sender,text,at) VALUES('$U5_SCOPE','sender','for builder (reply id=b0ld0001):
old mail from 0.3.0',strftime('%s','now')-604800); INSERT INTO mail(post,name,pane) VALUES(last_insert_rowid(),'builder','$U')"
    m=$(sqx "$CNTCTR_DB" "SELECT max(post) FROM mail")
    c_prompt "$U" "a question" >/dev/null
    ans=$(c_stop "$U")
    emptyans "$ans" && ok_ || bad "F1b a row from before the migration (no socket) never holds a session" "  got: $ans"
    same "F1b and stays as it was" "$(mstate "$m")" "pending/0/0"
    # the same mail with a socket, stored before this server started: no SessionStart means no start time, so it is read once
    U2=$(newpane f6_user2); t set -p -t "$U2" @cntctr_harness claude
    start=$(t display -p '#{start_time}')
    m2=$(mailput "$U2" b0ld0002 "$(mail_text b0ld0002 'mail from before the restart')" 0 $((start - 3600)))
    c_prompt "$U2" "a question" >/dev/null
    ans=$(c_stop "$U2")
    emptyans "$ans" && ok_ || bad "F1b mail stored before the server started does not hold a session with no SessionStart" "  got: $ans"
    same "F1b and stays pending" "$(mstate "$m2")" "pending/0/0"
    same "F1b the start time is read once and kept" "$(sqx "$CNTCTR_DB" "SELECT server_start FROM hook_sessions WHERE pane='$U2'")" "$start"
    # and mail stored after the start still arrives for such a session
    m2=$(mailput "$U2" b0ld0003 "$(mail_text b0ld0003 'mail after the start')" 0)
    ans=$(c_stop "$U2")
    check "F1b mail stored after the start holds the session" "$(printf '%s' "$ans" | jq -r '.reason')" "mail after the start"

    # (c) an agy session (no SessionStart, ever) after a restart: the old row's start time is not kept
    A=$(hk_agent agy f6_a1)
    sqx "$CNTCTR_DB" "UPDATE hook_sessions SET server_start=1000 WHERE pane='$A'"   # what a row from the server before the restart holds
    m=$(mailput "$A" b0ld0004 "$(mail_text b0ld0004 'agy mail from before the restart')" 1 $((start - 3600)))
    ans=$(hk agy PreInvocation "$A" "$(jq -nc --arg p "$(pointer "$m")" '{conversationId:"S2",executionNum:0,invocationNum:0,hookEventName:"PreInvocation",lastUserInput:$p}')")
    emptyans "$ans" && ok_ || bad "F1c a new agy session after a restart does not get mail from before it" "  got: $ans"
    ans=$(hk agy Stop "$A" '{"conversationId":"S2","executionNum":0,"fullyIdle":true,"terminationReason":"NO_TOOL_CALL"}')
    emptyans "$ans" && ok_ || bad "F1c nor is it held by it" "  got: $ans"
    m=$(mailput "$A" b0ld0005 "$(mail_text b0ld0005 'agy mail after the restart')" 1)
    ans=$(hk agy PreInvocation "$A" "$(jq -nc --arg p "$(pointer "$m")" '{conversationId:"S3",executionNum:0,invocationNum:0,hookEventName:"PreInvocation",lastUserInput:$p}')")
    check "F1c mail from after the restart is attached" "$(ctx_a "$ans")" "agy mail after the restart"
}

# f6_2: a hook event from a harness another harness started inside the pane (claude -p run by an agent's shell tool) is not the pane agent's
f6_2() {
    local PAR N T id ans row gate rowq gateq out i
    mkdir -p "$TMPD/nest"
    cat > "$TMPD/nest/outer.c" << 'EOF'
#include <stdlib.h>
int main(int argc, char **argv) { return argc > 1 ? system(argv[1]) : 1; }
EOF
    cc -o "$TMPD/nest/claude" "$TMPD/nest/outer.c"   # the outer harness: runs the inner one as its child, inside the pane
    printf '#!/bin/sh\nexec "%s/hook_harness/claude" "%s" claude < "%s/nest_in" > "%s/nest_out"\n' "$TMPD" "$BIN" "$TMPD" "$TMPD" > "$TMPD/nest/inner.sh"
    chmod +x "$TMPD/nest/inner.sh"
    rm -f "$TMPD/nest_in" "$TMPD/nest_out"; mkfifo "$TMPD/nest_in" "$TMPD/nest_out"
    PAR=$(newpane f6_par2)
    N=$(hk_agent claude f6_nest "$TMPD/nest/claude $TMPD/nest/inner.sh")   # the pane's process is the outer harness; the pane's own agent talks through the shared launcher
    t set -p -t "$N" @cntctr_parent "$PAR"
    exec 26> "$TMPD/nest_in" 27< "$TMPD/nest_out"
    read -r i <&27
    call "$N" board '{}' >/dev/null
    out=$(txt "$(call "$PAR" send '{"to":"f6_nest","text":"do the nested job"}')")
    T=${out#sent id=}; id=$(mailid "$T")
    rowq="SELECT session_id||'|'||harness_pid||'|'||last_event||'|'||prompt_seen||'|'||stop_seen||'|'||wake_reserved||'|'||stop_blocked||'|'||turn||'|'||broken FROM hook_sessions WHERE pane='$N'"
    gateq="SELECT count(*)||'/'||coalesce(sum(reminded),0)||'/'||coalesce(sum(away),0) FROM task_gate WHERE task='$T'"
    row=$(sqx "$CNTCTR_DB" "$rowq"); gate=$(sqx "$CNTCTR_DB" "$gateq")
    nest() {   # nest <event> <json>: one hook call from the inner harness, which stands inside the pane under the outer one
        printf '%s' "$2" > "$TMPD/nest_event"; rm -f "$TMPD/nest_answer"
        printf '%s %s %s %s\n' "$1" "$TMPD/nest_event" "$N" "$TMPD/nest_answer" >&26; read -r i <&27
        cat "$TMPD/nest_answer" 2>/dev/null
    }
    ans=$(nest UserPromptSubmit "$(jq -nc --arg p "$(pointer "$id")" '{session_id:"NEST",hook_event_name:"UserPromptSubmit",prompt:$p}')")
    emptyans "$ans" && ok_ || bad "F2 a nested harness's prompt gets the neutral answer" "  got: $ans"
    same "F2 and attaches nothing: the mail stays pending" "$(mstate "$id" | cut -d/ -f1)" pending
    ans=$(nest Stop '{"session_id":"NEST","hook_event_name":"Stop","stop_hook_active":false}')
    emptyans "$ans" && ok_ || bad "F2 a nested harness's Stop gets the neutral answer, though the pane's task is open" "  got: $ans"
    same "F2 and the parent is not told" "$(stopped "$T")" 0
    ans=$(nest Stop '{"session_id":"NEST","hook_event_name":"Stop","stop_hook_active":true}')
    emptyans "$ans" && ok_ || bad "F2 nor by its second Stop" "  got: $ans"
    same "F2 and the parent is still not told" "$(stopped "$T")" 0
    same "F2 the pane's hook session is unchanged" "$(sqx "$CNTCTR_DB" "$rowq")" "$row"
    same "F2 the gate state of the task is unchanged" "$(sqx "$CNTCTR_DB" "$gateq")" "$gate"
    # the pane's own agent still works: its prompt attaches the mail and its Stop is held for the open task
    ans=$(c_prompt "$N" "$(pointer "$id")")
    check "F2 the pane's own agent still gets its mail" "$(ctx_c "$ans")" "do the nested job"
    ans=$(c_stop "$N")
    same "F2 and its Stop is held for the open task" "$(printf '%s' "$ans" | jq -r '.decision')" block
    exec 26>&- 27<&-
    t kill-window -t "$N" 2>/dev/null
}

# f6_3: a multi-line text sent to a pane in copy-mode arrives as one bracketed paste and one Enter
f6_3() {
    local S R r n got
    cat > "$TMPD/f6_reader.py" << 'EOF2'
import os, sys, tty
log = sys.argv[1]
tty.setraw(0)
os.write(1, b'\x1b[?2004h')
open(log, 'wb').close()
while True:
    data = os.read(0, 4096)
    if not data: break
    with open(log, 'ab') as f: f.write(data)
EOF2
    S=$(newpane f6_snd3)
    R=$(newpane f6_rd python3 "$TMPD/f6_reader.py" "$TMPD/f6_3.log")
    for n in $(seq 50); do [ "$(t display -p -t "$R" '#{bracket_paste_flag}')" = 1 ] && break; sleep 0.1; done
    t copy-mode -t "$R"
    same "F3 the receiver's pane is in copy-mode" "$(t display -p -t "$R" '#{pane_in_mode}')" 1
    r=$(call "$S" send '{"to":"f6_rd","text":"first line\nsecond line"}')
    check "F3 the send succeeds" "$(txt "$r")" "sent id="
    sleep 0.3
    same "F3 the pane left copy-mode" "$(t display -p -t "$R" '#{pane_in_mode}')" 0
    python3 - "$TMPD/f6_3.log" << 'EOF2' && ok_ || bad "F3 the whole text is inside one paste, followed by exactly one Enter"
import sys
s = open(sys.argv[1], 'rb').read()
a, b = s.find(b'\x1b[200~'), s.find(b'\x1b[201~')
assert s.count(b'\x1b[200~') == 1 and s.count(b'\x1b[201~') == 1 and 0 <= a < b
body = s[a + 6:b]
assert b'first line\rsecond line' in body and body.rstrip().endswith(b']'), body
assert s[:a] == b'' and s[b + 6:] == b'\r', s
EOF2
}

# f6_4: a reply while the sender still waits (gather) answers the task for the Stop gate
f6_4() {
    local PAR W W2 gp T T2 id id2 ans n res
    PAR=$(newpane f6_par4)
    W=$(hk_agent claude f6_w4); t set -p -t "$W" @cntctr_parent "$PAR"
    W2=$(hk_agent claude f6_w4b); t set -p -t "$W2" @cntctr_parent "$PAR"
    call "$W" board '{}' >/dev/null
    call "$PAR" gather '{"tasks":[{"kind":"send","to":"f6_w4","text":"job one"},{"kind":"send","to":"f6_w4b","text":"job two"}],"timeout":40}' > "$TMPD/f6_gather" & gp=$!
    for n in $(seq 100); do
        T=$(sqx "$CNTCTR_DB" "SELECT task FROM mail WHERE name='f6_w4' ORDER BY post DESC LIMIT 1")
        T2=$(sqx "$CNTCTR_DB" "SELECT task FROM mail WHERE name='f6_w4b' ORDER BY post DESC LIMIT 1")
        [ -n "$T" ] && [ -n "$T2" ] && break; sleep 0.1
    done
    id=$(mailid "$T"); id2=$(mailid "$T2")
    c_prompt "$W" "$(pointer "$id")" >/dev/null
    check "F4 the first worker's task is open before its reply" "$(t show -sqv "@cntctr_to_$T")" "$W"
    call "$W" reply "{\"id\":\"$T\",\"text\":\"done one\"}" >/dev/null
    check "F4 the sender still waits: the task option stays set" "$(t show -sqv "@cntctr_to_$T")" "$W"
    ans=$(c_stop "$W")
    emptyans "$ans" && ok_ || bad "F4 a Stop after the reply is not held for the answered task" "  got: $ans"
    same "F4 the parent is not told the worker stopped without a reply" "$(stopped "$T")" 0
    same "F4 the task is recorded as answered" "$(sqx "$CNTCTR_DB" "SELECT answered FROM task_gate WHERE task='$T'")" 1
    c_prompt "$W" "carry on" >/dev/null
    ans=$(c_stop "$W")
    emptyans "$ans" && ok_ || bad "F4 nor in a later turn" "  got: $ans"
    same "F4 and still no mail to the parent" "$(stopped "$T")" 0
    # the other worker never replies in time: its task is still held and told
    c_prompt "$W2" "$(pointer "$id2")" >/dev/null
    ans=$(c_stop "$W2")
    same "F4 an unanswered task is still held" "$(printf '%s' "$ans" | jq -r '.decision')" block
    call "$W2" reply "{\"id\":\"$T2\",\"text\":\"done two\"}" >/dev/null
    wait "$gp"
    res=$(txt "$(cat "$TMPD/f6_gather")")
    same "F4 gather reports both answered" "$(printf '%s' "$res" | jq -r '[.results[].text] | join(",")')" "done one,done two"
    same "F4 and is complete" "$(printf '%s' "$res" | jq -r '.complete')" true
}

# f6_5: mail staged in a turn that never ends with a Stop (cancel, API failure) is presented again; the third presentation stalls it
f6_5() {
    local S P out task id ans lines
    export CNTCTR_WAKE_SEC=3   # a prompt must follow each wake within it (a 2 s window expired under full-suite load); the release needs it short
    S=$(newpane f6_snd5)
    P=$(hk_agent claude f6_nostop); t set -p -t "$P" @cntctr_parent "$S"   # a spawned worker: only those are released
    daemon_start "$P"
    daemon_hello
    out=$(txt "$(call "$S" send '{"to":"f6_nostop","text":"mail whose turn is cancelled"}')")
    task=${out#sent id=}; id=$(mailid "$task")
    wait_mstate "F5 the first line is typed and counted" "$id" "pending/1/0"
    ans=$(c_prompt "$P" "$(pointer "$id")")
    check "F5 the prompt attaches the mail" "$(ctx_c "$ans")" "mail whose turn is cancelled"
    same "F5 the mail is staged" "$(mstate "$id")" "staged/1/0"
    # the user cancels: no Stop comes. The screen reads idle; after the wake window the mail is pending and the line is typed again
    wait_mstate "F5 with no Stop and an idle screen the mail is pending again and the line is typed a second time" "$id" "pending/2/0"
    lines=$(screen "$P" | grep -c '\[cntctr mail id=')   # cat shows each typed line twice
    same "F5 the pointer is on the screen twice, typed twice" "$lines" 4
    ans=$(c_prompt "$P" "$(pointer "$id")")
    check "F5 the second presentation attaches it again" "$(ctx_c "$ans")" "mail whose turn is cancelled"
    wait_mstate "F5 again no Stop: pending, typed a third time" "$id" "pending/3/0"
    ans=$(c_prompt "$P" "$(pointer "$id")")
    check "F5 the third presentation attaches it" "$(ctx_c "$ans")" "mail whose turn is cancelled"
    wait_mstate "F5 the third presentation ended without delivery: stalled" "$id" "stalled/3/0"
    same "F5 the sender is told once" "$(notices "$id")" 1
    sleep 3
    same "F5 and nothing is told again" "$(notices "$id")" 1
    daemon_stop
    unset CNTCTR_WAKE_SEC
}

# f6_8: an agy end of turn with a terminationReason this code does not know gave no reminder: the mail goes back to pending, the parent is told nothing
f6_8() {
    local PAR AW out T id ans
    PAR=$(newpane f6_par8)
    AW=$(hk_agent agy f6_w8); t set -p -t "$AW" @cntctr_parent "$PAR"
    out=$(txt "$(call "$PAR" send '{"to":"f6_w8","text":"a job that ends in a strange way"}')")
    T=${out#sent id=}; id=$(mailid "$T")
    ans=$(a_pre "$AW" 0 "$(pointer "$id")")
    check "F8 the mail is attached" "$(ctx_a "$ans")" "a job that ends in a strange way"
    ans=$(a_stop "$AW" MAX_STEPS)
    emptyans "$ans" && ok_ || bad "F8 a Stop with an unknown terminationReason passes" "  got: $ans"
    same "F8 its mail is back to pending" "$(mstate "$id")" "pending/1/0"
    same "F8 the parent is not told 'no reply after one reminder'" "$(stopped "$T")" 0
}

# f6_9: a database at the current schema version is opened without the schema script (user_version), an older one is migrated
f6_9() {
    local d="$TMPD/f6_9.db" sockpath
    sockpath=$(t display -p '#{socket_path}')
    rm -f "$d" "$d-wal" "$d-shm"
    CNTCTR_DB=$d TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    same "F9 a new database carries a schema version" "$(sqx "$d" 'PRAGMA user_version')" 1
    same "F9 and the machine row" "$(sqx "$d" "SELECT count(*) FROM meta WHERE k='machine'")" 1
    sqx "$d" "DELETE FROM meta WHERE k='machine'"
    CNTCTR_DB=$d TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    same "F9 opening a current database runs no schema script and writes no meta row" "$(sqx "$d" "SELECT count(*) FROM meta WHERE k='machine'")" 0
    sqx "$d" "ALTER TABLE mail DROP COLUMN socket; ALTER TABLE task_gate DROP COLUMN answered; PRAGMA user_version=0"
    CNTCTR_DB=$d TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    same "F9 an older database gets its columns back" "$(sqx "$d" "SELECT count(*) FROM pragma_table_info('mail') WHERE name='socket'")$(sqx "$d" "SELECT count(*) FROM pragma_table_info('task_gate') WHERE name='answered'")" 11
    same "F9 and the current version" "$(sqx "$d" 'PRAGMA user_version')" 1
}

# ---- fix round 7 (F7_1 to F7_6) ----
# f7_1: a pane no 0.4.0 server serves (no @cntctr_srv, or a dead pid) gets nothing from the hook paths and is mailed the 0.3.0 way
f7_1() {
    local S PAR P C kind dp out task id id2 ans scr n nc here
    S=$(newpane f7_snd1); PAR=$(newpane f7_par1)
    here="TMUX=$(t display -p '#{socket_path}'),0,0"
    P=$(hk_agent claude f7_w1); t set -p -t "$P" @cntctr_parent "$PAR"
    for kind in none dead; do
        if [ $kind = none ]; then t set -pu -t "$P" @cntctr_srv; else sleep 0 & dp=$!; wait $dp; t set -p -t "$P" @cntctr_srv "$dp"; fi
        same "F7.1 $kind: the pane has no hooks" "$(env "$here" "$BIN" hook status "$P")" no
        # a mail stored for it as hooked (by a sender that did not check) is not attached, and no Stop holds the agent or reminds it
        id=$(mailput "$P" f7a00001 "$(mail_text f7a00001 'mail for a pane no 0.4.0 server serves')" 0)
        t set -s @cntctr_to_f7a00001 "$P"; t set -s @cntctr_sender_f7a00001 f7_snd1
        ans=$(c_prompt "$P" "$(pointer "$id")")
        emptyans "$ans" && ok_ || bad "F7.1 $kind: the prompt attaches nothing" "  got: $ans"
        ans=$(c_stop "$P")
        emptyans "$ans" && ok_ || bad "F7.1 $kind: the Stop neither holds nor reminds" "  got: $ans"
        same "F7.1 $kind: the mail is untouched" "$(mstate "$id")" "pending/0/0"
        same "F7.1 $kind: the parent is told nothing" "$(stopped f7a00001)" 0
        t set -su @cntctr_to_f7a00001; t set -su @cntctr_sender_f7a00001
        sqx "$CNTCTR_DB" "UPDATE mail SET delivered=1 WHERE post=$id"
        # a send is pasted as the full envelope: the same text as to a pane that has no hooks at all, once, with no pointer line
        out=$(txt "$(call "$S" send '{"to":"f7_w1","text":"f7 full envelope text '"$kind"'"}')")
        task=${out#sent id=}
        C=$(newpane f7_ctl$kind)
        call "$S" send '{"to":"f7_ctl'"$kind"'","text":"f7 full envelope text '"$kind"'"}' >/dev/null
        sleep 1
        n=$(screen "$P" | grep -c "f7 full envelope text $kind"); nc=$(screen "$C" | grep -c "f7 full envelope text $kind")
        [ "$n" -gt 0 ] && [ "$n" = "$nc" ] && ok_ || bad "F7.1 $kind: the send is pasted once as for a pane without hooks" "  pane $n, control $nc"
        refute "F7.1 $kind: no pointer line" "$(screen "$P")" "[cntctr mail id="
        same "F7.1 $kind: the mail is not stored as hooked" "$(sqx "$CNTCTR_DB" "SELECT count(*) FROM mail WHERE task='$task' AND hooked=1")" 0
    done
    # the same pane with a live pid has the 0.4.0 behaviour
    t set -p -t "$P" @cntctr_srv $$
    same "F7.1 served: the pane has hooks" "$(env "$here" "$BIN" hook status "$P")" yes
    out=$(txt "$(call "$S" send '{"to":"f7_w1","text":"f7 served mail"}')")
    task=${out#sent id=}; id2=$(mailid "$task")
    expect_screen "F7.1 served: the pane gets the pointer line" "$P" "[cntctr mail id=$id2] body attached"
    ans=$(c_prompt "$P" "$(pointer "$id2")")
    check "F7.1 served: the prompt attaches the envelope" "$(ctx_c "$ans")" "f7 served mail"
    c_stop "$P" >/dev/null
    same "F7.1 served: the Stop delivers it" "$(mstate "$id2")" "delivered/1/1"
}

# f7_2: a database stamped at a higher schema version (a newer build wrote it) is opened as it is and never stamped down
f7_2() {
    local d="$TMPD/f7_2.db" sockpath
    sockpath=$(t display -p '#{socket_path}')
    rm -f "$d" "$d-wal" "$d-shm"
    CNTCTR_DB=$d TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    sqx "$d" "ALTER TABLE mail DROP COLUMN socket; PRAGMA user_version=7"
    CNTCTR_DB=$d TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    same "F7.2 a newer database keeps its higher stamp" "$(sqx "$d" 'PRAGMA user_version')" 7
    same "F7.2 and is not migrated by this build" "$(sqx "$d" "SELECT count(*) FROM pragma_table_info('mail') WHERE name='socket'")" 0
    sqx "$d" "PRAGMA user_version=0"
    CNTCTR_DB=$d TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    same "F7.2 an older database is migrated and stamped" "$(sqx "$d" "SELECT count(*) FROM pragma_table_info('mail') WHERE name='socket'")$(sqx "$d" 'PRAGMA user_version')" 11
}

# f7_3: staged mail is released after a cancelled turn only for a spawned worker; a user's own session is left to its next prompt event
f7_3() {
    local S P out task id ans
    S=$(newpane f7_snd3)
    P=$(hk_agent claude f7_user3)   # no @cntctr_parent
    daemon_start "$P"
    daemon_hello
    out=$(txt "$(call "$S" send '{"to":"f7_user3","text":"mail for a session of the user"}')")
    task=${out#sent id=}; id=$(mailid "$task")
    wait_mstate "F7.3 the first line is typed and counted" "$id" "pending/1/0"
    ans=$(c_prompt "$P" "$(pointer "$id")")
    check "F7.3 the prompt attaches the mail" "$(ctx_c "$ans")" "mail for a session of the user"
    same "F7.3 the mail is staged" "$(mstate "$id")" "staged/1/0"
    daemon_stop
    export CNTCTR_WAKE_SEC=2   # the short window is for the release below only: with it, a slow prompt under load would find the wake expired
    daemon_start "$P"
    daemon_hello
    sleep 7   # three wake windows, no event, an idle screen
    same "F7.3 with no Stop it stays staged for a session with no parent" "$(mstate "$id")" "staged/1/0"
    same "F7.3 and nothing more was typed" "$(screen "$P" | grep -c '\[cntctr mail id=')" 2   # cat shows each typed line twice
    ans=$(c_prompt "$P" "my next question")
    same "F7.3 the user's next prompt event makes it pending again" "$(mstate "$id")" "pending/1/0"
    daemon_stop
    unset CNTCTR_WAKE_SEC
}

# f7_6: a reply that could not be handed on does not mark its task answered; the retry that works does
f7_6() {
    local PAR W out T id ans res
    PAR=$(hk_agent claude f7_par6)
    W=$(hk_agent claude f7_w6); t set -p -t "$W" @cntctr_parent "$PAR"
    out=$(txt "$(call "$PAR" send '{"to":"f7_w6","text":"a job whose first reply fails"}')")
    T=${out#sent id=}; id=$(mailid "$T")
    c_prompt "$W" "$(pointer "$id")" >/dev/null
    sqx "$CNTCTR_DB" "CREATE TRIGGER f7_6_fail BEFORE INSERT ON posts BEGIN SELECT RAISE(ABORT, 'no posts'); END"   # the sender's mail cannot be stored
    res=$(call "$W" reply "{\"id\":\"$T\",\"text\":\"first try\"}"); res=$(txt "$res")   # (nested, bash 3.2 loses the escaped quotes)
    check "F7.6 the reply fails" "$res" "delivery failed"
    same "F7.6 and the task is not marked answered" "$(sqx "$CNTCTR_DB" "SELECT coalesce(max(answered),0) FROM task_gate WHERE task='$T'")" 0
    ans=$(c_stop "$W")
    same "F7.6 so the Stop still holds the worker for it" "$(printf '%s' "$ans" | jq -r '.decision')" block
    sqx "$CNTCTR_DB" "DROP TRIGGER f7_6_fail"
    res=$(call "$W" reply "{\"id\":\"$T\",\"text\":\"second try\"}"); res=$(txt "$res")   # (nested, bash 3.2 loses the escaped quotes)
    refute "F7.6 the retry works" "$res" "delivery failed"
    same "F7.6 and marks the task answered" "$(sqx "$CNTCTR_DB" "SELECT answered FROM task_gate WHERE task='$T'")" 1
}

# ---- fix round 8 (F8_1 to F8_4) ----
# f8_1: a short-lived server never takes over the pane marker; a server's marker is gone when it ends
f8_1() {
    local P first dp
    P=$(newpane f8_srv1)
    t set -pu -t "$P" @cntctr_srv
    daemon_start "$P"
    daemon_hello
    first=$DPID
    wait_opt() { for _ in $(seq 50); do [ "$(t show -pqv -t "$P" @cntctr_srv)" = "$1" ] && return 0; sleep 0.1; done; return 1; }
    wait_opt "$first" && ok_ || bad "F8.1 the first server marks its pane" "  want: $first" "  got:  $(t show -pqv -t "$P" @cntctr_srv)"
    printf '%s\n' "$INIT" | TMUX_PANE=$P "$BIN" >/dev/null   # a one-shot server in the same pane: starts, reads its name, exits
    same "F8.1 a one-shot server in the pane leaves the first server's marker alone" "$(t show -pqv -t "$P" @cntctr_srv)" "$first"
    daemon_stop
    same "F8.1 the marker is gone when its server ends" "$(t show -pqv -t "$P" @cntctr_srv)" ""
    sleep 0 & dp=$!; wait $dp
    t set -p -t "$P" @cntctr_srv "$dp"   # a marker naming a dead process
    printf '%s\n' "$INIT" | TMUX_PANE=$P "$BIN" >/dev/null
    same "F8.1 a server that took a dead marker removes it again when it ends" "$(t show -pqv -t "$P" @cntctr_srv)" ""
    t set -p -t "$P" @cntctr_srv $$   # as newpane left it
}

# f8_2: the Stop gate and the release stay neutral when tmux or the commit fails
f8_2() {
    local W PAR out T id ans sock2 U m n
    # (a) tmux cannot be read at the Stop: the pane is not known to be served, so mail is not held with the agent
    t2 kill-server 2>/dev/null
    t2 new-session -d -s two -x 200 -y 50 cat
    sock2=$(t2 display -p '#{socket_path}')
    U=$(t2 display -p '#{pane_id}')
    t2 set -p -t "$U" @cntctr_srv $$
    rm -f "$TMPD/hk_claude2_in" "$TMPD/hk_claude2_out"; mkfifo "$TMPD/hk_claude2_in" "$TMPD/hk_claude2_out"
    TMUX="$sock2,0,0" "$TMPD/hook_harness/claude" "$BIN" claude < "$TMPD/hk_claude2_in" > "$TMPD/hk_claude2_out" & HK_PID_c2=$!
    exec 24> "$TMPD/hk_claude2_in" 25< "$TMPD/hk_claude2_out"
    read -r n <&25
    hk claude2 SessionStart "$U" '{"session_id":"S1","hook_event_name":"SessionStart","source":"startup"}' >/dev/null
    sleep 1
    mail_text f8a00001 'mail for a pane whose tmux is gone' > "$TMPD/f8_a_text"
    sqx "$CNTCTR_DB" "INSERT INTO posts(scope,sender,text,at) VALUES('$U5_SCOPE','sender',CAST(readfile('$TMPD/f8_a_text') AS TEXT),strftime('%s','now')); INSERT INTO mail(post,name,pane,task,hooked,presentations,socket) VALUES(last_insert_rowid(),'f8_gone','$U','f8a00001',1,0,'$sock2')"
    m=$(sqx "$CNTCTR_DB" "SELECT max(post) FROM mail")
    t2 kill-server 2>/dev/null
    ans=$(hk claude2 Stop "$U" '{"session_id":"S1","hook_event_name":"Stop","stop_hook_active":false}')
    emptyans "$ans" && ok_ || bad "F8.2 a Stop that cannot read tmux holds nothing" "  got: $ans"
    same "F8.2 and the mail is untouched" "$(mstate "$m")" "pending/0/0"
    exec 24>&- 25<&-; kill "$HK_PID_c2" 2>/dev/null; wait "$HK_PID_c2" 2>/dev/null
    # (b) the commit of the reminder fails (a trigger that rolls the transaction back): no reminder was given, so the parent is told nothing
    PAR=$(hk_agent claude f8_par2)
    W=$(hk_agent claude f8_w2); t set -p -t "$W" @cntctr_parent "$PAR"
    out=$(txt "$(call "$PAR" send '{"to":"f8_w2","text":"a job whose reminder cannot be committed"}')")
    T=${out#sent id=}; id=$(mailid "$T")
    c_prompt "$W" "$(pointer "$id")" >/dev/null
    sqx "$CNTCTR_DB" "CREATE TRIGGER f8_2_fail BEFORE UPDATE ON hook_sessions BEGIN SELECT RAISE(ROLLBACK, 'no commit'); END"
    ans=$(c_stop "$W")
    emptyans "$ans" && ok_ || bad "F8.2 a Stop whose commit fails answers neutral" "  got: $ans"
    same "F8.2 and the parent is not told 'no reply after one reminder'" "$(stopped "$T")" 0
    sqx "$CNTCTR_DB" "DROP TRIGGER f8_2_fail"
    # ponytail: release_unended's COMMIT cannot be made to fail with the transaction still open from outside (a rolled-back one makes ROLLBACK a no-op), so that check has no test
}

# f8_4: a database from the oldest schema, migrated, and one stamped at an earlier schema version, opened, have the tables and columns of a new one
# (a column only in SCHEMA shows up in the first; a table added without raising KB_SCHEMA_VERSION shows up in the second)
f8_4() {
    local old="$TMPD/f8_4_old.db" stamped="$TMPD/f8_4_stamped.db" fresh="$TMPD/f8_4_new.db" sockpath cols='SELECT m.name||"."||p.name FROM sqlite_master m, pragma_table_info(m.name) p WHERE m.type="table" ORDER BY 1'
    sockpath=$(t display -p '#{socket_path}')
    rm -f "$old" "$old-wal" "$old-shm" "$stamped" "$stamped-wal" "$stamped-shm" "$fresh" "$fresh-wal" "$fresh-shm"
    sqlite3 "$old" < tests/schema_v0.1.0.sql   # what a 0.1.0 database holds
    CNTCTR_DB=$old TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null   # opening migrates it
    sqlite3 "$stamped" < tests/schema_stamp1.sql   # a database stamped version 1, the schema of that version
    CNTCTR_DB=$stamped TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    CNTCTR_DB=$fresh TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    same "F8.4 the stamped database has the tables and columns of a new one" "$(sqx "$stamped" "$cols")" "$(sqx "$fresh" "$cols")"
    same "F8.4 the migrated database has the tables and columns of a new one" "$(sqx "$old" "$cols")" "$(sqx "$fresh" "$cols")"
    check "F8.4 (and the list is not empty)" "$(sqx "$fresh" "$cols")" "mail.socket"
}

u5p6_run() {
    export CNTCTR_PASTE_WAIT_MS=100
    local f
    for f in ${F6:-1 2 3 4 5 6 7 8 9}; do declare -F "f6_$f" >/dev/null && "f6_$f"; done
    for f in ${F7:-1 2 3 4 5 6}; do declare -F "f7_$f" >/dev/null && "f7_$f"; done
    for f in ${F8:-1 2 3 4}; do declare -F "f8_$f" >/dev/null && "f8_$f"; done
    unset CNTCTR_PASTE_WAIT_MS
}

u5_run() {   # U5PARTS="p3 p4" runs just those parts, in that order
    hk_boot
    local part
    for part in ${U5PARTS:-p1 p2 p3 p4 p5 p6}; do "u5${part}_run"; done
    hk_stop
}
if [ "${ONLY:-}" = u5 ] || [ "${ONLY:-}" = u5p1 ] || [ "${ONLY:-}" = u5p2 ] || [ "${ONLY:-}" = u5p3 ] || [ "${ONLY:-}" = u5p4 ] || [ "${ONLY:-}" = u5p5 ] || [ "${ONLY:-}" = u5p6 ]; then
    case $ONLY in
        u5) u5_run ;;
        u5p1) hk_boot; u5p1_run; hk_stop ;;
        u5p2) hk_boot; u5p2_run; hk_stop ;;
        u5p3) hk_boot; u5p3_run; hk_stop ;;
        u5p4) hk_boot; u5p4_run; hk_stop ;;
        u5p5) hk_boot; u5p5_run; hk_stop ;;
        u5p6) hk_boot; u5p6_run; hk_stop ;;
    esac
    printf '%d passed, %d failed\n' "$pass" "$fail"
    [ "$fail" -eq 0 ]; exit $?
fi
if [ "${ONLY:-}" = u22 ] || [ "${ONLY:-}" = u23 ] || [ "${ONLY:-}" = u24 ] || [ "${ONLY:-}" = u22-u24 ]; then
    case $ONLY in
        u22) u22_run ;;
        u23) u23_run ;;
        u24) u24_run ;;
        u22-u24) u22_run; u23_run; u24_run ;;
    esac
    printf '%d passed, %d failed\n' "$pass" "$fail"
    [ "$fail" -eq 0 ]; exit $?
fi

if [ "${ONLY:-}" != "m3" ]; then

u28_run
u22_run
u23_run
u24_run

# ---- MCP protocol ----
out=$(rpc "$INIT")
check "initialize echoes protocol version" "$out" '"protocolVersion":"2025-06-18"'
check "initialize names the server" "$out" '"serverInfo":{"name":"cntctr"'
out=$(rpc '{"jsonrpc":"2.0","id":7,"method":"ping"}')
same "ping" "$out" '{"jsonrpc":"2.0","id":7,"result":{}}'
out=$(rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
for tool in spawn send gather reply list kill note recall read forget project distill post board tool_define tool_verdict tool_revoke use; do
    if [ "$tool" = tool_verdict ]; then refute "tools/list hides reviewer-only tool_verdict" "$out" "\"name\":\"$tool\""
    else check "tools/list has $tool" "$out" "\"name\":\"$tool\""; fi
done
out=$(rpc '{"jsonrpc":"2.0","id":3,"method":"nope"}')
check "unknown method" "$out" '"code":-32601'
out=$(rpc 'not json')
check "malformed JSON" "$out" '"code":-32700'
out=$(rpc '{"jsonrpc":"2.0","method":"notifications/initialized"}')
same "notifications get no response" "$out" ""
out=$(rpc '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nope","arguments":{}}}')
same "unknown tool is a tool error" "$(iserr "$out")" true
same "unknown tool message" "$(txt "$out")" "unknown tool nope"

# ---- identity and list ----
A=$(newpane a)
B=$(newpane b)
out=$(call "$A" list '{}')
check "list shows a" "$(txt "$out")" "a test $A alive"
check "list shows b" "$(txt "$out")" "b test $B alive"
U=$(t new-window -d -P -F '#{pane_id}' cat)
out=$(call "$U" list '{}')
check "untagged caller tags itself <client>-<pane number>" "$(txt "$out")" "test-${U#%} test $U alive"
cat > "$TMPD/bin/probe" <<'EOF'
#!/bin/sh
# Start cntctr without TMUX_PANE, as Codex does; it must find its pane by process ancestry.
printf '%s\n' "$INIT" | env -u TMUX_PANE "$BIN" >/dev/null
exec cat
EOF
chmod +x "$TMPD/bin/probe"
P=$(t new-window -d -P -F '#{pane_id}' probe)
for _ in $(seq 50); do [ -n "$(t show -pqv -t "$P" @cntctr_name)" ] && break; sleep 0.1; done
same "pane found by process ancestry without TMUX_PANE" "$(t show -pqv -t "$P" @cntctr_name)" "test-${P#%}"
out=$(printf '%s\n%s\n' "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list","arguments":{}}}' |
    TMUX=/nonexistent/sock,0,0 "$BIN" | tail -n 1)
same "list without a tmux server is a tool error" "$(iserr "$out")" true

# ---- status ----
BUSY=$(newpane st-busy sh -c 'printf "%s\n" "* Working (12s * esc to interrupt)"; exec cat')
LIM=$(newpane st-lim sh -c 'printf "%s\n" "Usage limit reached * continuing automatically at 10:40pm * esc to cancel"; exec cat')
AGYQ=$(newpane st-agyq sh -c 'printf "%s\n" "Individual quota reached. Resets in 143h57m55s."; exec cat')
AGYT=$(newpane st-agyt sh -c 'printf "%s\n" "? for shortcuts     Gemini 3.8 Flash * high * 1 task(s) * /tasks"; exec cat')
OLD=$(newpane st-old sh -c 'printf "%s\n" "Usage limit reached"; seq 1 30; exec cat')
IDLE=$(newpane st-idle)
sleep 0.5
out=$(txt "$(call "$IDLE" list '{}')")
check "list shows busy" "$out" "st-busy test $BUSY alive busy"
check "list shows limited" "$out" "st-lim test $LIM alive limited"
check "list shows reset time" "$out" 'resets="10:40pm"'
check "agy quota is limited" "$out" "st-agyq test $AGYQ alive limited"
check "agy quota reset" "$out" 'resets="143h57m55s"'
check "agy background task is busy" "$out" "st-agyt test $AGYT alive busy"
check "limit text above the last 15 lines is ignored" "$out" "st-old test $OLD alive idle"
check "list shows idle time" "$out" "st-idle test $IDLE alive idle idle="
PERM=$(newpane st-perm sh -c 'printf "%s\n" "Do you want to proceed?"; exec cat')
PEND=$(newpane st-pend 'stty -echo; cat')
sleep 0.5
pid=$(txt "$(call "$IDLE" send '{"to":"st-pend","text":"pending"}')" | sed 's/sent id=//')
out=$(txt "$(call "$IDLE" list '{}')")
check "list shows permission" "$out" "st-perm test $PERM alive permission"
check "list shows open task id" "$out" "st-pend test $PEND alive"
check "open task listed" "$out" "tasks=$pid"
t kill-pane -t "$PERM"; t kill-pane -t "$PEND"

# ---- send ----
out=$(call "$A" send '{"to":"b","text":"hello from a"}')
check "send returns an id" "$(txt "$out")" "sent id="
id=$(txt "$out" | sed 's/sent id=//')
expect_screen "envelope header" "$B" "[cntctr from=a id=$id]"
expect_screen "message text" "$B" "hello from a"
expect_screen "reply hint" "$B" "[when done: call the reply tool of the cntctr MCP server with id=$id and your answer, plus insights=[...] with durable facts other agents should know; it is an MCP tool, not a shell command. Your agent name is b: pass from=b on every cntctr call]"
call "$A" send '{"to":"b","text":"line one\nline two ünï"}' >/dev/null
expect_screen "multiline unicode text arrives" "$B" "line two ünï"
call "$A" send "$(jq -nc --arg t "\$(touch $TMPD/pwned) \`touch $TMPD/pwned\`" '{to:"b",text:$t}')" >/dev/null
expect_screen "shell syntax arrives literally" "$B" "\$(touch $TMPD/pwned)"
if [ -e "$TMPD/pwned" ]; then bad "send text was run by a shell"; else ok_; fi
# Two senders to one pane must submit two separate inputs.
RACE=$(newpane race 'stty -echo; cat')
CNTCTR_ENTER_DELAY_MS=1500 call "$A" send '{"to":"race","text":"race first"}' > "$TMPD/race-a" & race_a=$!
expect_screen "first concurrent message pasted" "$RACE" "race first"
CNTCTR_ENTER_DELAY_MS=1500 call "$B" send '{"to":"race","text":"race second"}' > "$TMPD/race-b" & race_b=$!
wait "$race_a" "$race_b"
check "first concurrent send succeeded" "$(txt "$(cat "$TMPD/race-a")")" "sent id="
check "second concurrent send succeeded" "$(txt "$(cat "$TMPD/race-b")")" "sent id="
same "concurrent messages submitted separately" "$(screen "$RACE" | grep -c '^\[cntctr from=')" 2

C=$(newpane cm)
t copy-mode -t "$C"   # the user scrolled back in the receiver's pane
call "$A" send '{"to":"cm","text":"sent while scrolled"}' >/dev/null
t send-keys -t "$C" -X cancel
for _ in $(seq 50); do [ "$(screen "$C" | grep -c 'when done')" -ge 2 ] && break; sleep 0.1; done
same "Enter reaches a pane in copy-mode" "$(screen "$C" | grep -c 'when done')" 2
# read without -r, like Claude's input box, treats a trailing backslash as "continue on the next line"
K=$(newpane bs sh -c 'printf "\033[?2004h"; while read l; do echo "GOT:$l"; done')
id=$(txt "$(call "$K" send '{"to":"b","text":"ask"}')" | sed 's/sent id=//')
call "$B" reply "{\"id\":\"$id\",\"text\":\"ends in \\\\\"}" >/dev/null
expect_screen "reply ending in a backslash is still submitted" "$K" "GOT:ends in"
G=$(newpane g sh -c 'echo "Do you want to proceed?"; exec cat')
expect_screen "guard pane ready" "$G" "Do you want to proceed?"
out=$(call "$A" send '{"to":"g","text":"sneaky"}')
same "send refused during permission prompt" "$(txt "$out")" "g awaiting permission prompt; retry later"
same "refusal is a tool error" "$(iserr "$out")" true
sleep 0.3
refute "nothing pasted into prompt pane" "$(screen "$G")" "sneaky"
out=$(call "$A" send '{"to":"nope","text":"x"}')
same "send to missing agent" "$(txt "$out")" "agent nope not found; list shows agents, spawn starts one"
out=$(rpc "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send","arguments":{"to":"b","text":"x"}}}' | tail -n 1)
check "send outside tmux says to pass from" "$(txt "$out")" "pass from="

# ---- from: a shared server (Codex) names its caller ----
# nopane <tool> <args-json>: run a tool from a process that is in no pane
nopane() { rpc "$INIT" "$(printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$(call_args "$1" "$2")")" | tail -n 1; }
F=$(newpane fromer)
out=$(nopane send '{"to":"b","text":"via name","from":"fromer"}')
check "send with from=<agent name> succeeds" "$(txt "$out")" "sent id="
id=$(txt "$out" | sed 's/sent id=//')
expect_screen "envelope names the from agent" "$B" "[cntctr from=fromer id=$id]"
expect_screen "envelope tells receiver its own name" "$B" "Your agent name is b: pass from=b"
call "$B" reply "{\"id\":\"$id\",\"text\":\"back\"}" >/dev/null
expect_screen "reply routes to the from agent's pane" "$F" "[cntctr reply from=b id=$id]"
H=$(t new-window -d -n hand -P -F '#{pane_id}' cat)   # untagged, like a hand-started leader
out=$(nopane send "{\"to\":\"b\",\"text\":\"via pane\",\"from\":\"$H\"}")
check "send with from=<pane id> succeeds" "$(txt "$out")" "sent id="
id=$(txt "$out" | sed 's/sent id=//')
same "untagged from pane gets tagged" "$(t show -pqv -t "$H" @cntctr_name)" "agent-${H#%}"
expect_screen "envelope names the tagged leader" "$B" "[cntctr from=agent-${H#%} id=$id]"
out=$(nopane send '{"to":"b","text":"x","from":"ghost"}')
same "from an unknown agent refused" "$(txt "$out")" "from=ghost is not a live agent or pane"

# ---- reply and blocking send ----
S=$(newpane s)   # fresh sender, so screen checks only see this section's traffic
out=$(call "$S" send '{"to":"b","text":"async question"}')
id=$(txt "$out" | sed 's/sent id=//')
out=$(call "$B" reply "{\"id\":\"$id\",\"text\":\"async answer\"}")
same "reply ok" "$(txt "$out")" ok
expect_screen "reply header lands in sender pane" "$S" "[cntctr reply from=b id=$id]"
expect_screen "reply text lands in sender pane" "$S" "async answer"
out=$(call "$B" reply "{\"id\":\"$id\",\"text\":\"again\"}")
same "second reply to same id rejected" "$(txt "$out")" "unknown id $id"

call "$S" send '{"to":"b","text":"blocking question","wait":true,"timeout":10}' > "$TMPD/block" &
expect_screen "blocking send delivered" "$B" "blocking question"
want=$'multi\nline "quoted" back\\slash ünï'
call "$B" reply "$(jq -nc --arg id "$(lastid "$B")" --arg text "$want" '{id:$id,text:$text}')" >/dev/null
wait
same "blocking send returns the exact reply" "$(txt "$(cat "$TMPD/block")")" "$want"
refute "blocking reply not also typed into sender" "$(screen "$S")" "back\\slash"

call "$S" send '{"to":"b","text":"send me a lot","wait":true,"timeout":10}' > "$TMPD/big" &
expect_screen "big request delivered" "$B" "send me a lot"
big=$(head -c 100000 /dev/zero | tr '\0' x)
call "$B" reply "$(jq -nc --arg id "$(lastid "$B")" --arg text "$big" '{id:$id,text:$text}')" >/dev/null
wait
got=$(txt "$(cat "$TMPD/big")")
same "100 KB reply round-trips" "${#got}" 100000

out=$(call "$S" send '{"to":"b","text":"slow question","wait":true,"timeout":1}')
check "blocking send times out" "$(txt "$out")" "timed out; reply will arrive in your pane (id="
id=$(txt "$out" | sed 's/.*id=\([0-9a-f]*\))$/\1/')
out=$(call "$B" reply "{\"id\":\"$id\",\"text\":\"late answer\"}")
same "late reply ok" "$(txt "$out")" ok
expect_screen "late reply typed into sender pane" "$S" "[cntctr reply from=b id=$id]"
expect_screen "late reply text" "$S" "late answer"

C=$(newpane c)
session "$S" 3 "$INIT" \
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send","arguments":{"to":"b","text":"first of two","wait":true,"timeout":10}}}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"send","arguments":{"to":"c","text":"second of two","wait":true,"timeout":10}}}' \
    > "$TMPD/pair" &
expect_screen "first concurrent send delivered" "$B" "first of two"
expect_screen "second concurrent send delivered" "$C" "second of two"
call "$C" reply "{\"id\":\"$(lastid "$C")\",\"text\":\"answer two\"}" >/dev/null
call "$B" reply "{\"id\":\"$(lastid "$B")\",\"text\":\"answer one\"}" >/dev/null
wait
same "concurrent call 2" "$(jq -r 'select(.id==2) | .result.content[0].text' "$TMPD/pair")" "answer one"
same "concurrent call 3" "$(jq -r 'select(.id==3) | .result.content[0].text' "$TMPD/pair")" "answer two"

# ---- gather: one decision boundary for delegated work ----
GA=$(newpane ga)
GB=$(newpane gb)
call "$S" gather '{"tasks":[{"kind":"send","to":"ga","text":"first report"},{"kind":"send","to":"gb","text":"second report"}],"timeout":10}' > "$TMPD/gather" & gather_pid=$!
expect_screen "gather dispatched first task" "$GA" "first report"
expect_screen "gather dispatched second task" "$GB" "second report"
call "$GB" reply "{\"id\":\"$(lastid "$GB")\",\"text\":\"second answer\"}" >/dev/null
if [ ! -s "$TMPD/gather" ]; then ok_; else bad "gather returned before both answers"; fi
call "$GA" reply "{\"id\":\"$(lastid "$GA")\",\"text\":\"first answer\"}" >/dev/null
wait "$gather_pid"
gather=$(txt "$(cat "$TMPD/gather")")
same "gather complete" "$(printf '%s' "$gather" | jq -r '.complete')" true
same "gather preserves task order" "$(printf '%s' "$gather" | jq -r '[.results[].text] | join(",")')" "first answer,second answer"
same "gather reports both ids" "$(printf '%s' "$gather" | jq -r '[.results[].id | test("^[0-9a-f]{8}$")] | all')" true

call "$S" gather '{"tasks":[{"kind":"send","to":"ga","text":"short reply"},{"kind":"send","to":"gb","text":"slow reply"}],"timeout":8}' > "$TMPD/gather-timeout" & gather_pid=$!
expect_screen "timeout gather dispatched quick task" "$GA" "short reply"
expect_screen "timeout gather dispatched slow task" "$GB" "slow reply"
call "$GA" reply "{\"id\":\"$(lastid "$GA")\",\"text\":\"quick answer\"}" >/dev/null
wait "$gather_pid"
gather=$(txt "$(cat "$TMPD/gather-timeout")")
same "gather timeout is incomplete" "$(printf '%s' "$gather" | jq -r '.complete')" false
same "gather keeps answered task" "$(printf '%s' "$gather" | jq -r '.results[0].text')" "quick answer"
same "gather marks missing task" "$(printf '%s' "$gather" | jq -r '.results[1].status')" timed_out
call "$GB" reply "{\"id\":\"$(lastid "$GB")\",\"text\":\"late gather answer\"}" >/dev/null
expect_screen "late gather reply reaches leader" "$S" "late gather answer"

call "$S" gather '{"tasks":[{"kind":"send","to":"missing-gather-agent","text":"unavailable"},{"kind":"send","to":"ga","text":"still run"}],"timeout":10}' > "$TMPD/gather-failed" & gather_pid=$!
expect_screen "gather continues after failed dispatch" "$GA" "still run"
call "$GA" reply "{\"id\":\"$(lastid "$GA")\",\"text\":\"good answer\"}" >/dev/null
wait "$gather_pid"
gather=$(txt "$(cat "$TMPD/gather-failed")")
same "gather failure is incomplete" "$(printf '%s' "$gather" | jq -r '.complete')" false
same "gather records dispatch failure" "$(printf '%s' "$gather" | jq -r '.results[0].status')" failed
same "gather keeps later answer" "$(printf '%s' "$gather" | jq -r '.results[1].text')" "good answer"

# answers arrive out of order; each lands on its own task
call "$S" gather '{"tasks":[{"kind":"send","to":"ga","text":"order one"},{"kind":"send","to":"gb","text":"order two"}],"timeout":10}' > "$TMPD/gather-order" & gather_pid=$!
expect_screen "order gather sent to ga" "$GA" "order one"
expect_screen "order gather sent to gb" "$GB" "order two"
call "$GB" reply "{\"id\":\"$(lastid "$GB")\",\"text\":\"b first\"}" >/dev/null
call "$GA" reply "{\"id\":\"$(lastid "$GA")\",\"text\":\"a second\"}" >/dev/null
wait "$gather_pid"
gather=$(txt "$(cat "$TMPD/gather-order")")
same "out-of-order answers map to tasks" "$(printf '%s' "$gather" | jq -r '[.results[].text] | join(",")')" "a second,b first"

# a limited worker ends its task at once; its later reply still reaches the caller
GL=$(newpane gl sh -c 'printf "%s\n" "Usage limit reached * resets 3:00am"; exec cat')
start=$(date +%s)
gather=$(txt "$(call "$S" gather '{"tasks":[{"kind":"send","to":"gl","text":"never"}],"timeout":30}')")
same "limited task status" "$(printf '%s' "$gather" | jq -r '.results[0].status')" limited
same "limited task reset" "$(printf '%s' "$gather" | jq -r '.results[0].resets')" "3:00am"
[ $(( $(date +%s) - start )) -lt 10 ] && ok_ || bad "limited task returned before the timeout"
call "$GL" reply "{\"id\":\"$(printf '%s' "$gather" | jq -r '.results[0].id')\",\"text\":\"after reset\"}" >/dev/null
expect_screen "limited worker's late reply reaches caller" "$S" "after reset"
t kill-pane -t "$GL"

# cancel: an answer claimed before the cancel and one arriving after both reach the caller's pane
daemon_start "$S"
daemon_send '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"gather","arguments":{"tasks":[{"kind":"send","to":"ga","text":"cancel one"},{"kind":"send","to":"gb","text":"cancel two"}],"timeout":30}}}'
expect_screen "cancel gather sent to ga" "$GA" "cancel one"
expect_screen "cancel gather sent to gb" "$GB" "cancel two"
call "$GA" reply "{\"id\":\"$(lastid "$GA")\",\"text\":\"before cancel\"}" >/dev/null
sleep 1.5
daemon_send '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5}}'
sleep 1.5
call "$GB" reply "{\"id\":\"$(lastid "$GB")\",\"text\":\"after cancel\"}" >/dev/null
daemon_stop
expect_screen "answer claimed before cancel reaches pane" "$S" "before cancel"
expect_screen "answer after cancel reaches pane" "$S" "after cancel"

# wait=false returns ids at once; replies arrive in the pane
start=$(date +%s)
gather=$(txt "$(call "$S" gather '{"tasks":[{"kind":"send","to":"ga","text":"async one"}],"wait":false,"timeout":5}')")
[ $(( $(date +%s) - start )) -lt 3 ] && ok_ || bad "async gather returns at once"
same "async gather status" "$(printf '%s' "$gather" | jq -r '.results[0].status')" sent
same "async gather is not complete" "$(printf '%s' "$gather" | jq -r '.complete')" false
expect_screen "async gather dispatched" "$GA" "async one"
call "$GA" reply "{\"id\":\"$(lastid "$GA")\",\"text\":\"async answer\"}" >/dev/null
expect_screen "async gather answer reaches pane" "$S" "async answer"
gboard_run
f9_run

# a worker that dies ends its task as dead
GD=$(newpane gd sh -c 'sleep 6')
t set -p -t "$GD" remain-on-exit on
gather=$(txt "$(call "$S" gather '{"tasks":[{"kind":"send","to":"gd","text":"die"}],"timeout":30}')")
same "dead task status" "$(printf '%s' "$gather" | jq -r '.results[0].status')" dead

# blocking send to a limited worker says so
GL=$(newpane gl sh -c 'printf "%s\n" "Usage limit reached * resets 3:00am"; exec cat')
out=$(txt "$(call "$S" send '{"to":"gl","text":"blocked","wait":true,"timeout":30}')")
check "blocking send reports limit" "$out" "hit its usage limit (resets 3:00am)"
t kill-pane -t "$GL"
t kill-pane -t "$GD"

R=$(newpane r)
{ printf '%s\n' "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send","arguments":{"to":"b","text":"cancel me","wait":true,"timeout":30}}}'
  sleep 1
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}'
  sleep 1
} | TMUX_PANE=$R "$BIN" >/dev/null &
expect_screen "cancellable send delivered" "$B" "cancel me"
sleep 1.5
call "$B" reply "{\"id\":\"$(lastid "$B")\",\"text\":\"answer after cancel\"}" >/dev/null
wait
expect_screen "reply to cancelled send lands in sender pane" "$R" "answer after cancel"

printf '%s\n' "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send","arguments":{"to":"b","text":"leader leaves","wait":true,"timeout":30}}}' |
    TMUX_PANE=$R "$BIN" >/dev/null &
expect_screen "send before leader exit delivered" "$B" "leader leaves"
start=$SECONDS
wait   # stdin is closed: cntctr must give up the wait, not block for the full timeout
[ $((SECONDS - start)) -le 7 ] && ok_ || bad "server with closed stdin still blocked $((SECONDS - start))s"
call "$B" reply "{\"id\":\"$(lastid "$B")\",\"text\":\"answer after exit\"}" >/dev/null
expect_screen "reply after leader's server exits lands in its pane" "$R" "answer after exit"

D=$(newpane d)
call "$S" send '{"to":"d","text":"never answered","wait":true,"timeout":30}' > "$TMPD/dead" &
expect_screen "delivered to d" "$D" "never answered"
# the paste echoes before Enter is sent; cat printing the hint line again means Enter landed
for _ in $(seq 50); do [ "$(screen "$D" | grep -c 'when done')" -ge 2 ] && break; sleep 0.1; done
t kill-pane -t "$D"
wait
out=$(cat "$TMPD/dead")
check "worker exit ends blocking send" "$(txt "$out")" "agent d exited before replying (id="
same "worker exit is a tool error" "$(iserr "$out")" true

Z=$(newpane z)
out=$(call "$Z" send '{"to":"b","text":"from a pane about to close"}')
id=$(txt "$out" | sed 's/sent id=//')
t kill-pane -t "$Z"
out=$(call "$B" reply "{\"id\":\"$id\",\"text\":\"too late\"}")
same "reply to closed sender" "$(txt "$out")" "reply is on the board"
out=$(call "$B" reply '{"id":"deadbeef","text":"x"}')
same "reply to unknown id" "$(txt "$out")" "unknown id deadbeef"
out=$(call "$B" reply '{"id":"../../x","text":"x"}')
same "reply rejects malformed id" "$(txt "$out")" "unknown id ../../x"

# Codex runs one shared MCP server outside any pane: reply must work without knowing its own pane
out=$(call "$S" send '{"to":"b","text":"answer me from nowhere"}')
id=$(txt "$out" | sed 's/sent id=//')
out=$(session "" 2 "$INIT" "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"reply\",\"arguments\":{\"id\":\"$id\",\"text\":\"paneless answer\"}}}" | tail -n 1)
same "reply from a server outside any pane" "$(txt "$out")" ok
expect_screen "paneless reply is signed with the receiver's name" "$S" "[cntctr reply from=b id=$id]"
expect_screen "paneless reply text" "$S" "paneless answer"

# ---- spawn and kill ----
cat > "$TMPD/bin/claude" <<'EOF'
#!/bin/sh
# Fake harness: show the task, then answer it through cntctr like a worker would.
for a; do flags="${flags-} ${task-}"; task=$a; done    # the task is the last argument
[ "$(basename "$0")" = codex ] && unset TMUX_PANE    # Codex hides TMUX_PANE from MCP servers
printf 'flags:%s\n%s\n' "$flags" "$task"
case $task in *toolcheck*)
    # Fleet tool reviewer: use the tool, then give a verdict. CNTCTR_TEST_VERDICT: approve (default), reject,
    # escalate or none; CNTCTR_TEST_FAST: ask for a verdict before the review is bound. Notes go to $D/rev-<tool>.*
    D=$(dirname "$CNTCTR_DB")
    tn=$(printf '%s\n' "$task" | sed -n 's/^Tool: \([a-z0-9_]*\) version \([0-9]*\)$/\1/p')
    tv=$(printf '%s\n' "$task" | sed -n 's/^Tool: \([a-z0-9_]*\) version \([0-9]*\)$/\2/p')
    mode=${CNTCTR_TEST_VERDICT-approve}
    # ask <tool> <args>: sets R to the reply text. The cntctr keeps running on fd 4, so its cleanup thread can finish.
    ask() {
        exec 4>&-
        f=$(mktemp -u "$D/rv.XXXXXX"); mkfifo "$f"
        "$BIN" < "$f" > "$f.out" &
        exec 4> "$f"
        printf '%s\n{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$INIT" "$1" "$2" >&4
        for _ in $(seq 100); do jq -e 'select(.id == 2)' "$f.out" >/dev/null 2>&1 && break; sleep 0.1; done
        R=$(jq -r 'select(.id == 2) | .result.content[0].text' "$f.out")
    }
    [ -n "${CNTCTR_TEST_FAST-}" ] || sleep 0.5
    [ "$mode" = none ] && exec cat
    vargs="{\"name\":\"$tn\",\"version\":$tv,\"verdict\":\"$mode\",\"reason\":\"reviewer says $mode\"}"
    if [ -n "${CNTCTR_TEST_FAST-}" ]; then
        ask tool_verdict "$vargs"; printf '%s\n' "$R" > "$D/rev-$tn.first"
    fi
    for _ in $(seq 30); do
        ask use "{\"tool\":\"$tn\",\"args\":{}}"
        case $R in *"not bound yet"*) sleep 1 ;; *) break ;; esac
    done
    printf '%s\n' "$R" > "$D/rev-$tn.use"
    for _ in $(seq 30); do
        ask tool_verdict "$vargs"
        case $R in *"not bound yet"*) sleep 1 ;; *) break ;; esac
    done
    printf '%s\n' "$R" > "$D/rev-$tn.last"
    exec cat ;;
esac
id=$(printf '%s\n' "$task" | sed -n 's/^\[cntctr from=[^ ]* id=\([0-9a-f]\{8\}\)\]$/\1/p')
sleep 0.5                                            # real harnesses take seconds to start
printf '%s\n{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"reply","arguments":{"id":"%s","text":"done %s"}}}\n' \
    "$INIT" "$id" "$id" | "$BIN" >/dev/null
exec cat
EOF
chmod +x "$TMPD/bin/claude"
ln -s claude "$TMPD/bin/codex"
ln -s claude "$TMPD/bin/agy"
cat > "$TMPD/bin/headroom" <<'EOF'
#!/bin/sh
# Fake headroom: headroom wrap <tool> -- <args>
echo "wrapped:$2"
tool=$2; shift 2; [ "$1" = -- ] && shift
exec "$tool" "$@"
EOF
chmod +x "$TMPD/bin/headroom"

L=$(newpane lead)
gather=$(txt "$(call "$L" gather '{"tasks":[{"kind":"spawn","harness":"claude","name":"wg","task":"gather spawn"}],"timeout":10}')")
same "gather spawn completes" "$(printf '%s' "$gather" | jq -r '.complete')" true
same "gather spawn identifies worker" "$(printf '%s' "$gather" | jq -r '.results[0].agent')" wg
check "gather spawn returns worker answer" "$(printf '%s' "$gather" | jq -r '.results[0].text')" "done "
out=$(call "$L" spawn '{"harness":"claude","name":"w1","task":"build it","wait":true,"timeout":10}')
check "spawn wait=true returns the worker's reply" "$(txt "$out")" "done "
check "list shows spawned worker" "$(txt "$(call "$L" list '{}')")" "w1 claude %"
out=$(call "$L" spawn '{"harness":"agy","name":"w2","task":"async job"}')
check "spawn returns at once" "$(txt "$out")" "spawned w2 in %"
id=$(txt "$out" | sed 's/.*id=\([0-9a-f]*\).*/\1/')
expect_screen "agy worker (-i prompt) replies into leader pane" "$L" "[cntctr reply from=w2 id=$id]"
out=$(call "$L" spawn '{"harness":"codex","name":"w3","task":"codex job"}')
id=$(txt "$out" | sed 's/.*id=\([0-9a-f]*\).*/\1/')
expect_screen "codex worker finds its name without TMUX_PANE" "$L" "[cntctr reply from=w3 id=$id]"
out=$(call "$L" spawn "$(jq -nc --arg t "\$(touch $TMPD/pwned)" '{harness:"claude",name:"w4",task:$t}')")
W4=$(txt "$out" | sed 's/.* in \(%[0-9]*\) .*/\1/')
expect_screen "task text reaches the worker literally" "$W4" "\$(touch $TMPD/pwned)"
if [ -e "$TMPD/pwned" ]; then bad "spawn task was run by a shell"; else ok_; fi
out=$(call "$L" spawn '{"harness":"claude","name":"m1","task":"x","model":"claude-sonnet-5","effort":"low"}')
expect_screen "claude gets model and effort" "$(txt "$out" | sed 's/.* in \(%[0-9]*\) .*/\1/')" "flags:  --model claude-sonnet-5 --effort low"
out=$(call "$L" spawn '{"harness":"codex","name":"m2","task":"x","model":"gpt-6-luna","effort":"high"}')
expect_screen "codex gets model and effort" "$(txt "$out" | sed 's/.* in \(%[0-9]*\) .*/\1/')" "flags:  -m gpt-6-luna -c model_reasoning_effort=\"high\""
out=$(call "$L" spawn '{"harness":"agy","name":"m3","task":"x","model":"gemini-3.8-flash-high","effort":"high"}')
expect_screen "agy gets model and effort" "$(txt "$out" | sed 's/.* in \(%[0-9]*\) .*/\1/')" "flags:  --model gemini-3.8-flash-high --effort high --settings"
# agy gets a session-only trustedWorkspaces for its cwd
mkdir -p "$TMPD/agywork"
call "$L" spawn "{\"harness\":\"agy\",\"name\":\"agyt\",\"task\":\"trust\",\"cwd\":\"$TMPD/agywork\"}" >/dev/null
AGT=$(t list-panes -a -F '#{pane_id} #{@cntctr_name}' | awk '$2=="agyt"{print $1}')
real=$(cd "$TMPD/agywork" && pwd -P)
expect_screen "agy gets --settings" "$AGT" "--settings"
expect_screen "agy trusts its real cwd" "$AGT" "{\"trustedWorkspaces\":[\"$real\"]}"
expect_screen "claude runs under headroom wrap" "$(txt "$(call "$L" list '{}')" | sed -n 's/^m1 claude \(%[0-9]*\).*/\1/p')" "wrapped:claude"
expect_screen "codex runs under headroom wrap" "$(txt "$(call "$L" list '{}')" | sed -n 's/^m2 codex \(%[0-9]*\).*/\1/p')" "wrapped:codex"
if t capture-pane -p -t "$(txt "$(call "$L" list '{}')" | sed -n 's/^m3 agy \(%[0-9]*\).*/\1/p')" | grep -q wrapped; then bad "agy is not wrapped"; else ok_; fi
pane_of() { txt "$1" | sed 's/.* in \(%[0-9]*\) .*/\1/'; }
out=$(call "$L" spawn '{"harness":"claude","name":"r1","task":"smoke test: run make test, report the count"}')
check "router names its choice" "$(txt "$out")" "(light: claude-haiku-5-5 medium)"
expect_screen "light task gets the small model" "$(pane_of "$out")" "flags:  --model claude-haiku-5-5 --effort medium"
out=$(call "$L" spawn '{"harness":"claude","name":"r2","task":"Implement the retry loop in cntctr.c:inject so a busy pane is retried twice, with a test in test.sh."}')
expect_screen "ordinary task gets the standard model" "$(pane_of "$out")" "flags:  --model claude-sonnet-5-5 --effort medium"
out=$(call "$L" spawn '{"harness":"claude","name":"r3","task":"Review the diff in /tmp/x.diff against the spec; list issues."}')
expect_screen "review gets the review model" "$(pane_of "$out")" "flags:  --model claude-opus-4-7 --effort high"
out=$(call "$L" spawn '{"harness":"claude","name":"r4","task":"Design the architecture for cross-machine sync; find the race conditions."}')
expect_screen "hard task gets the strongest model" "$(pane_of "$out")" "flags:  --model claude-opus-5-5 --effort high"
out=$(call "$L" spawn '{"harness":"codex","name":"r5","task":"rename foo to bar in kb.c"}')
expect_screen "codex light task" "$(pane_of "$out")" "flags:  -m gpt-6.1-terra -c model_reasoning_effort=\"low\""
out=$(call "$L" spawn '{"harness":"codex","name":"r5s","task":"Implement the retry loop."}')
expect_screen "codex standard task" "$(pane_of "$out")" "flags:  -m gpt-6.1-terra -c model_reasoning_effort=\"medium\""
out=$(call "$L" spawn '{"harness":"codex","name":"r5r","task":"Review the retry loop."}')
expect_screen "codex review task" "$(pane_of "$out")" "flags:  -m gpt-6.1-sol -c model_reasoning_effort=\"high\""
out=$(call "$L" spawn '{"harness":"codex","name":"r5h","task":"Design the architecture for cross-machine sync."}')
expect_screen "codex hard task" "$(pane_of "$out")" "flags:  -m gpt-6.1-terra -c model_reasoning_effort=\"high\""
out=$(call "$L" spawn '{"harness":"agy","name":"r6b","task":"rename foo to bar"}')
expect_screen "agy light task stays on medium" "$(pane_of "$out")" "flags:  --model gemini-3.8-flash-medium --effort medium"
out=$(call "$L" spawn '{"harness":"agy","name":"r6","task":"Design the architecture for the new sync layer."}')
expect_screen "agy always uses Gemini 3.8" "$(pane_of "$out")" "flags:  --model gemini-3.8-flash-high --effort high --settings"
out=$(call "$L" spawn '{"harness":"claude","name":"r7","task":"Design everything","tier":"light"}')
expect_screen "tier overrides the router" "$(pane_of "$out")" "flags:  --model claude-haiku-5-5 --effort medium"
out=$(call "$L" spawn '{"harness":"claude","name":"r8","task":"Design everything","effort":"low"}')
expect_screen "explicit effort wins, model still routed" "$(pane_of "$out")" "flags:  --model claude-opus-5-5 --effort low"
same "unknown tier" "$(txt "$(call "$L" spawn '{"harness":"claude","name":"r9","task":"x","tier":"huge"}')")" "bad tier huge"
same "model cannot be a flag" "$(txt "$(call "$L" spawn '{"harness":"claude","name":"m4","task":"x","model":"--danger"}')")" "bad model --danger"
same "effort must be a level" "$(txt "$(call "$L" spawn '{"harness":"claude","name":"m4","task":"x","effort":"turbo"}')")" "bad effort turbo"
out=$(call "$L" spawn '{"harness":"claude","name":"w1","task":"x"}')
same "duplicate spawn name" "$(txt "$out")" "agent w1 already exists"
out=$(call "$L" spawn '{"harness":"vim","name":"w9","task":"x"}')
same "unknown harness" "$(txt "$out")" "unknown harness vim"

# to: "parent"
call "$L" spawn '{"harness":"claude","name":"kid","task":"hello"}' >/dev/null
KID=$(t list-panes -a -F '#{pane_id} #{@cntctr_name}' | awk '$2=="kid"{print $1}')
same "spawn records parent" "$(t show -pqv -t "$KID" @cntctr_parent)" "$L"
call "$KID" send '{"to":"parent","text":"to my parent"}' >/dev/null
expect_screen "to:parent reaches the spawner" "$L" "to my parent"
expect_screen "to:parent envelope names the spawner's real name" "$L" "Your agent name is lead"
refute "to:parent envelope never says parent" "$(screen "$L")" "Your agent name is parent"
gp=$(txt "$(call "$KID" gather '{"tasks":[{"kind":"send","to":"parent","text":"gather to parent"}],"timeout":2}')")
expect_screen "gather to:parent reaches the spawner" "$L" "gather to parent"
out=$(session "" 2 "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send","arguments":{"from":"kid","to":"parent","text":"via shared server"}}}' | tail -n 1)
expect_screen "to:parent works through from= (Codex)" "$L" "via shared server"
out=$(call "$S" send '{"to":"parent","text":"orphan"}')
same "no parent is an error" "$(iserr "$out")" true
check "no parent message" "$(txt "$out")" "you have no parent"

same "kill worker" "$(txt "$(call "$L" kill '{"name":"w1"}')")" ok
refute "killed worker gone from list" "$(txt "$(call "$L" list '{}')")" "w1 claude"
same "kill self refused" "$(txt "$(call "$L" kill '{"name":"lead"}')")" "cannot kill yourself"
same "kill missing agent" "$(txt "$(call "$L" kill '{"name":"nope"}')")" "agent nope not found"

# ---- knowledge ----
KA=$(newpane ka)
out=$(call "$KA" note '{"layer":"insight","title":"Enter in copy-mode","summary":"send-keys Enter goes to copy-mode; paste a CR instead","body":"Seen with Claude 2.1.287.","tags":"scrollback","refs":"cntctr.c:inject"}')
check "note returns an id" "$(txt "$out")" "noted "
nid=$(txt "$out" | sed 's/noted //')
same "entry id is <machine>-<ms>-<rand>" "$(printf '%s' "$nid" | grep -cE '^[0-9a-f]{8}-[0-9a-f]+-[0-9a-f]{4}$')" 1
out=$(txt "$(call "$KA" read "{\"id\":\"$nid\"}")")
check "read shows layer" "$out" "layer: insight"
check "read shows summary" "$out" "summary: send-keys Enter goes to copy-mode; paste a CR instead"
check "read shows tags" "$out" "tags: scrollback"
check "read shows refs" "$out" "refs: cntctr.c:inject"
check "read shows the agent" "$out" "(agent ka)"
check "read shows visibility" "$out" "visibility: shared"
check "read shows body" "$out" "Seen with Claude 2.1.287."
same "read unknown id" "$(txt "$(call "$KA" read '{"id":"nope"}')")" "entry nope not found"
check "note without summary" "$(txt "$(call "$KA" note '{"layer":"insight","title":"x"}')")" "note needs 'layer', 'title', 'summary' (missing: summary)."
check "note cannot write history" "$(txt "$(call "$KA" note '{"layer":"history","title":"x","summary":"y"}')")" "note layer must be insight, skill or doc"

mkdir "$TMPD/repo" "$TMPD/plain"
git -C "$TMPD/repo" init -q
git -C "$TMPD/repo" remote add origin git@GitHub.com:X/y.git
KR=$(t new-window -d -n kr -c "$TMPD/repo" -P -F '#{pane_id}' cat)
t set -p -t "$KR" @cntctr_name kr
check "project key from the origin remote" "$(txt "$(call "$KR" project '{}')")" "project github.com/X/y (root "
git -C "$TMPD/repo" remote set-url origin https://github.com/X/y.git/
check "https remote normalizes the same" "$(txt "$(call "$KR" project '{}')")" "project github.com/X/y (root "
same "project override" "$(txt "$(call "$KR" project '{"key":"foo"}')" | cut -d' ' -f1-2)" "project foo"
same "override persists" "$(txt "$(call "$KR" project '{}')" | cut -d' ' -f1-2)" "project foo"
call "$KR" project '{"key":""}' >/dev/null
check "empty key removes the override" "$(txt "$(call "$KR" project '{}')")" "project github.com/X/y"
KP=$(t new-window -d -n kp -c "$TMPD/plain" -P -F '#{pane_id}' cat)
t set -p -t "$KP" @cntctr_name kp
check "outside git the key is the directory" "$(txt "$(call "$KP" project '{}')")" "/plain (root "

call "$KA" note '{"layer":"skill","title":"Run the tests","summary":"make test runs test.sh under ASan","scope":"global"}' >/dev/null
call "$KR" note '{"layer":"insight","title":"Other repo fact","summary":"only in the other repo"}' >/dev/null
idx=$(txt "$(call "$KA" recall '{}')")
check "index lists the project insight" "$idx" "$nid [insight] Enter in copy-mode — send-keys Enter goes to copy-mode; paste a CR instead"
check "index lists the global skill" "$idx" "[skill] Run the tests — make test runs test.sh under ASan"
same "project entries come before global ones" "$(printf '%s\n' "$idx" | head -n 1 | cut -d' ' -f1)" "$nid"
refute "index leaves out other projects" "$idx" "only in the other repo"
check "other projects see global entries" "$(txt "$(call "$KR" recall '{}')")" "Run the tests"
refute "scope=global leaves out the project" "$(txt "$(call "$KA" recall '{"scope":"global"}')")" "$nid"
check "search finds a body word" "$(txt "$(call "$KA" recall '{"query":"Seen"}')")" "$nid"
check "search finds a tag" "$(txt "$(call "$KA" recall '{"query":"scrollback"}')")" "$nid"
same "search with no hits" "$(txt "$(call "$KA" recall '{"query":"zebra"}')")" "no entries"
same "search text is never FTS syntax" "$(txt "$(call "$KA" recall '{"query":"\"AND ( NEAR"}')")" "no entries"
out=$(call "$KA" note "{\"layer\":\"insight\",\"title\":\"Enter fix\",\"summary\":\"inject pastes a raw CR so copy-mode cannot eat Enter\",\"supersedes\":[\"$nid\"]}")
nid2=$(txt "$out" | sed 's/noted //')
refute "superseded entry leaves the index" "$(txt "$(call "$KA" recall '{}')")" "$nid "
refute "superseded entry leaves search" "$(txt "$(call "$KA" recall '{"query":"scrollback"}')")" "$nid"
check "superseded entry is still readable" "$(txt "$(call "$KA" read "{\"id\":\"$nid\"}")")" "superseded_by: $nid2"
same "supersedes an unknown id" "$(txt "$(call "$KA" note '{"layer":"insight","title":"x","summary":"y","supersedes":["nope"]}')")" "entry nope not found"
fid=$(txt "$(call "$KA" note '{"layer":"doc","title":"Stale","summary":"soon gone"}')" | sed 's/noted //')
same "forget" "$(txt "$(call "$KA" forget "{\"id\":\"$fid\"}")")" "forgot $fid"
refute "forgotten entry leaves the index" "$(txt "$(call "$KA" recall '{}')")" "soon gone"
same "forget an unknown id" "$(txt "$(call "$KA" forget '{"id":"nope"}')")" "entry nope not found"

KB=$(newpane kb)
hid=$(txt "$(call "$KA" send '{"to":"kb","text":"measure the paste delay"}')" | sed 's/sent id=//')
call "$KB" reply "{\"id\":\"$hid\",\"text\":\"150 ms is enough\",\"insights\":[\"Claude submits pasted text with no delay before Enter\"]}" >/dev/null
hist=$(txt "$(call "$KA" recall '{"layer":"history"}')")
check "send is logged as history" "$hist" "[history] task $hid ka→kb — measure the paste delay"
check "reply is logged as history" "$hist" "[history] reply $hid kb→ka — 150 ms is enough"
refute "history stays out of the index" "$(txt "$(call "$KA" recall '{}')")" "[history]"
ins=$(txt "$(call "$KA" recall '{"query":"delay before Enter"}')")
check "reply insight is stored" "$ins" "[insight] Claude submits pasted text with no delay before Enter"
iid=$(printf '%s\n' "$ins" | grep '\[insight\] Claude submits' | cut -d' ' -f1)
check "insight refs its message" "$(txt "$(call "$KA" read "{\"id\":\"$iid\"}")")" "refs: $hid"
hent=$(printf '%s\n' "$hist" | grep "task $hid" | cut -d' ' -f1)
check "history is private" "$(txt "$(call "$KA" read "{\"id\":\"$hent\"}")")" "visibility: private"
same "history cannot be forgotten" "$(txt "$(call "$KA" forget "{\"id\":\"$hent\"}")")" "history entries cannot be forgotten"
out=$(call "$KA" note "{\"layer\":\"insight\",\"title\":\"x\",\"summary\":\"y\",\"supersedes\":[\"$hent\"]}")
same "history cannot be superseded" "$(txt "$out")" "history entries cannot be superseded"
long="x$(printf 'é%.0s' $(seq 60))"   # 121 bytes: byte 80 is inside an é, so the 80-byte title cut must back off
hid=$(txt "$(call "$KA" send '{"to":"kb","text":"unicode"}')" | sed 's/sent id=//')
call "$KB" reply "{\"id\":\"$hid\",\"text\":\"ok\",\"insights\":[\"$long\"]}" >/dev/null
out=$(txt "$(call "$KA" recall '{}')")
check "long unicode insight is listed" "$out" "[insight] xéé"
refute "titles are cut on a character boundary" "$out" "�"
out=$(CNTCTR_DB=/nonexistent/x.db call "$KA" send '{"to":"kb","text":"still delivered"}')
check "send works without a knowledge store" "$(txt "$out")" "sent id="
same "note reports a missing store" "$(txt "$(CNTCTR_DB=/nonexistent/x.db call "$KA" note '{"layer":"insight","title":"x","summary":"y"}')" | cut -c1-30)" "knowledge store unavailable: u"
call "$KA" send '{"to":"kb","text":"why does Enter get lost in copy-mode?"}' >/dev/null
expect_screen "envelope points at recall" "$KB" "[cntctr knowledge: call recall for more]"
expect_screen "envelope lists matching knowledge" "$KB" "$nid2 [insight] Enter fix — inject pastes a raw CR so copy-mode cannot eat Enter"
words=$(printf 'word%d ' $(seq 3000))
out=$(call "$KA" send "{\"to\":\"kb\",\"text\":\"$words\"}")
check "a 3000-word task is still sent" "$(txt "$out")" "sent id="
ins=$(session "$KA" 1 "$INIT" | jq -r .result.instructions)
check "initialize explains the knowledge tools" "$ins" "call recall"
check "initialize carries the project index" "$ins" "Enter fix — inject pastes a raw CR so copy-mode cannot eat Enter"
ins=$(session "" 1 "$INIT" | jq -r .result.instructions)
check "paneless instructions ask for from" "$ins" "pass from="
check "paneless index shows global entries" "$ins" "Run the tests"
refute "paneless index leaves out project entries" "$ins" "Enter fix"

cat > "$TMPD/mem.py" <<'EOF'
# Fake claude-mem worker: logs every request, answers like claude-mem 13.15.
import http.server, json, sys
log = open(sys.argv[1], "a")
class H(http.server.BaseHTTPRequestHandler):
    def answer(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        log.write("POST %s %s\n" % (self.path, body)); log.flush()
        self.answer({"success": True, "id": 7})
    def do_GET(self):
        log.write("GET %s\n" % self.path); log.flush()
        self.answer({"content": [{"type": "text", "text": "| ID | Time | T | Title | Read |\n|----|------|---|-------|------|\n"
                                  "| #7 | 1:00 PM | o | Mirror me | ~10 |\n| #9 | 1:00 PM | o | Claude saw this | ~10 |"}]})
    def do_DELETE(self):
        log.write("DELETE %s\n" % self.path); log.flush()
        self.answer({"success": True})
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
print(s.server_port, flush=True)
s.serve_forever()
EOF
python3 "$TMPD/mem.py" "$TMPD/mem.log" > "$TMPD/mem.port" &
MEMPID=$!
for _ in $(seq 50); do [ -s "$TMPD/mem.port" ] && break; sleep 0.1; done
MEM=http://127.0.0.1:$(cat "$TMPD/mem.port")
base=$(basename "$(git -C "$(t display -p -t "$KA" '#{pane_current_path}')" rev-parse --show-toplevel 2>/dev/null || t display -p -t "$KA" '#{pane_current_path}')")
mid=$(txt "$(CNTCTR_MEM_URL=$MEM call "$KA" note '{"layer":"doc","title":"Mirror me","summary":"mirrored doc","body":"long text"}')" | sed 's/noted //')
check "note posts to claude-mem" "$(cat "$TMPD/mem.log")" "POST /api/memory/save"
check "mirror files under the repo basename" "$(cat "$TMPD/mem.log")" "\"project\":\"$base\""
check "mirror carries the cntctr id" "$(cat "$TMPD/mem.log")" "\"cntctr_id\":\"$mid\""
out=$(txt "$(CNTCTR_MEM_URL=$MEM call "$KA" recall '{"query":"zzz"}')")
check "search asks for observations only" "$(cat "$TMPD/mem.log")" "GET /api/search/observations?query=zzz&project=$base"
check "claude-mem hit maps to the cntctr entry" "$out" "$mid [doc] Mirror me — mirrored doc"
check "other claude-mem hits are shown" "$out" "claude-mem #9 Claude saw this"
CNTCTR_MEM_URL=$MEM call "$KA" forget "{\"id\":\"$mid\"}" >/dev/null
check "forget deletes the claude-mem copy" "$(cat "$TMPD/mem.log")" "DELETE /api/observation/7"
kill "$MEMPID"
wait "$MEMPID" 2>/dev/null
check "note works with claude-mem down" "$(txt "$(CNTCTR_MEM_URL=$MEM call "$KA" note '{"layer":"insight","title":"t","summary":"s"}')")" "noted "
out=$(call "$KA" distill '{"harness":"vim"}')
check "failed distill reports the spawn error" "$(txt "$out")" "unknown harness vim"
out=$(call "$KA" distill '{}')
check "distill spawns a librarian" "$(txt "$out")" "spawned librarian-1 in %"
LB=$(txt "$out" | sed 's/.* in \(%[0-9]*\) .*/\1/')
expect_screen "librarian gets its task" "$LB" "You are the cntctr librarian for project"
expect_screen "first librarian reads all history" "$LB" 'since="1970-01-01 00:00:00"'
expect_screen "librarian is routed as standard" "$LB" "flags:  --model claude-sonnet-5-5 --effort medium"
out=$(call "$KA" distill '{"model":"claude-sonnet-5","effort":"medium"}')
check "next librarian gets a new name" "$(txt "$out")" "spawned librarian-2 in %"
LB2=$(txt "$out" | sed 's/.* in \(%[0-9]*\) .*/\1/')
expect_screen "next librarian starts at the last distill" "$LB2" 'since="20'
expect_screen "distill passes model and effort" "$LB2" "flags:  --model claude-sonnet-5 --effort medium"
for i in $(seq 20); do
    call "$KA" note "{\"layer\":\"insight\",\"title\":\"par $i\",\"summary\":\"parallel note $i\"}" > "$TMPD/par.$i" &
done
wait
same "20 parallel notes all succeed" "$(cat "$TMPD"/par.* | jq -r '.result.content[0].text' | grep -c '^noted ')" 20

# ---- board ----
PB=$(newpane pb)
out=$(call "$KA" post '{"text":"heads up: main is broken","urgent":true}')
check "post reaches agents in the project" "$(txt "$out")" "posted to "
check "post names who it reached" "$(txt "$out")" "pb"
check "post reports agents it could not reach" "$(txt "$out")" "skipped g (g awaiting permission prompt"
expect_screen "post arrives in another agent's pane" "$PB" "[cntctr board from=ka] heads up: main is broken"
refute "post never reaches another project" "$(screen "$KR")" "heads up"
sleep 0.3
refute "post is not echoed to the poster" "$(screen "$KA")" "heads up"
call "$PB" post '{"text":"fixed in abc123","urgent":true}' >/dev/null
out=$(txt "$(call "$KA" board '{}')")
check "board shows posts" "$out" "ka: heads up: main is broken"
same "board is oldest first" "$(printf '%s\n' "$out" | tail -n 1 | cut -d' ' -f3-)" "pb: fixed in abc123"
same "board limit" "$(txt "$(call "$KA" board '{"limit":1}')" | cut -d' ' -f3-)" "pb: fixed in abc123"
refute "board of another project" "$(txt "$(call "$KR" board '{}')")" "heads up"
refute "board of another project does not contain first project post" "$(txt "$(call "$KR" board '{}')")" "fixed in abc123"
check "post needs text" "$(txt "$(call "$KA" post '{}')")" "post needs 'text' (missing: text). Example: post {\"text\":\"...\"}"
# errors name the missing field and give an example
out=$(txt "$(call "$KA" reply '{"text":"x"}')")
check "reply error names id" "$out" "reply needs 'id', 'text' (missing: id)."
check "reply error has example" "$out" 'Example: reply {"id":"1a2b3c4d","text":"done"}'
out=$(txt "$(call "$KA" send '{"to":"b"}')")
check "send error names text" "$out" "(missing: text)"
check "send error has example" "$out" 'Example: send {"to":"codex-2","text":"..."}'
out=$(txt "$(call "$KA" spawn '{"harness":"claude"}')")
check "spawn error names both" "$out" "(missing: name, task)"
out=$(txt "$(call "$KA" post '{}')")
check "post error has example" "$out" 'Example: post {"text":"..."}'
out=$(txt "$(call "$KA" note '{"layer":"insight"}')")
check "note error names fields" "$out" "(missing: title, summary). Example: note {"
out=$(txt "$(call "$KA" gather '{}')")
check "gather error has example" "$out" 'Example: gather {"tasks":[{"kind":"send"'
out=$(txt "$(call "$KA" kill '{}')")
check "kill error names name" "$out" "kill needs 'name' (missing: name). Example: kill {"
out=$(rpc "$INIT")
check "instructions explain supersedes" "$out" "supersedes=[old id]"
check "instructions explain parent" "$out" 'to=\"parent\"'
check "instructions explain urgent" "$out" "urgent=true"
out=$(rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
check "note description explains stale notes" "$out" "recall hides"
out=$(bash "$(dirname "$BIN")/watch.sh" --once)
check "dashboard lists agents" "$out" "librarian-1"
check "dashboard shows the board" "$out" "pb: fixed in abc123"
check "dashboard shows knowledge" "$out" " — parallel note "
check "dashboard shows history" "$out" "reply $(lastid "$LB2") librarian-2→ka"
check "dashboard shows the distill cursor" "$out" "last distill"

# ---- fleet tools ----
FA=$(newpane fa)
FB=$(newpane fb)
def='{"name":"hello","description":"Say hello","input_schema":{"type":"object","properties":{"who":{"type":"string"}},"required":["who"]},"interpreter":"sh","script":"read a; echo \"hi $a\""}'
same "define saves a draft" "$(txt "$(call "$FA" tool_define "$def")")" "saved draft hello"
lst() { SKIP=1 session "$1" 2 "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | tail -n 1; }
check "draft listed for its author" "$(lst "$FA")" '"name":"hello"'
check "fleet tool is marked" "$(lst "$FA")" '[fleet] Say hello'
refute "draft hidden from others" "$(lst "$FB")" '"name":"hello"'
bad_def() { jq -c "$1" <<<"$def"; }
same "required must name a property" "$(txt "$(call "$FA" tool_define "$(bad_def '.input_schema.required=["x"]')")")" "input_schema: required names missing property x"
same "built-in names are reserved" "$(txt "$(call "$FA" tool_define "$(bad_def '.name="send"')")")" "send is a built-in tool"
same "name must match the pattern" "$(txt "$(call "$FA" tool_define "$(bad_def '.name="Bad-Name"')")")" "name must match ^[a-z][a-z0-9_]{1,40}\$"
same "description cap" "$(txt "$(call "$FA" tool_define "$(bad_def ".description=\"$(printf 'x%.0s' $(seq 501))\"")")")" "description is over 500 characters"
same "unknown interpreter" "$(txt "$(call "$FA" tool_define "$(bad_def '.interpreter="ruby"')")")" "interpreter must be sh, bash, python3 or node"
same "timeout cap" "$(txt "$(call "$FA" tool_define "$(bad_def '.timeout=601')")")" "timeout must be 1..600"

# interpreter must resolve on PATH: a PATH with the usual tools but no node
mkdir "$TMPD/nonode"
for c in tmux git jq mktemp mkfifo head tail rm sh bash env cat; do ln -s "$(command -v "$c")" "$TMPD/nonode/$c"; done
same "interpreter must be on PATH" "$(txt "$(PATH="$TMPD/nonode" call "$FA" tool_define "$(bad_def '.interpreter="node"')")")" "interpreter node not found on PATH"
# resolver precedence, with rows inserted directly
PK=$(txt "$(call "$FA" project '{}')" | sed 's/^project \(.*\) (root .*/\1/')
row() { sq "$CNTCTR_DB" "INSERT INTO tools(project,name,version,status,author,description,input_schema,interpreter,script,reviewer_pane) VALUES ('$1','$2',$3,'$4','$5','$6','{\"type\":\"object\"}','sh','true','$7')"; }
dnamed() { bad_def ".name=\"$1\" | .description=\"$2\""; }
call "$FA" tool_define "$(dnamed dup "Desc A")" > /dev/null
call "$FB" tool_define "$(dnamed dup "Desc B")" > /dev/null
check "author sees its own draft" "$(lst "$FA")" '[fleet] Desc A'
refute "author does not see the other draft" "$(lst "$FA")" 'Desc B'
check "the other author sees theirs" "$(lst "$FB")" '[fleet] Desc B'
refute "the other author does not see the first" "$(lst "$FB")" 'Desc A'
call "$FA" tool_define "$(dnamed dup "Desc A2")" > /dev/null
check "a redefined draft replaces the old one" "$(lst "$FA")" '[fleet] Desc A2'
refute "the old draft text is gone" "$(lst "$FA")" '[fleet] Desc A"'
same "one draft per author and name" "$(sq "$CNTCTR_DB" "SELECT count(*) FROM tools WHERE name='dup' AND author='fa'")" "1"
row "$PK" prec 1 active fc "project active" ""
call "$FA" tool_define "$(dnamed prec "my draft")" > /dev/null
check "own draft beats the project active row" "$(lst "$FA")" '[fleet] my draft'
refute "the active row is hidden behind the draft" "$(lst "$FA")" 'project active'
check "others see the active row" "$(lst "$FB")" '[fleet] project active'
row global mask 1 active fc "global mask" ""
row "$PK" mask 1 revoked fc "revoked here" ""
refute "a project revoked row masks the global tool" "$(lst "$FA")" '"name":"mask"'
row global glob 1 active fc "global tool" ""
check "a global tool is listed in any project" "$(lst "$FA")" '[fleet] global tool'
row "$PK" pend 1 pending fc "under review" "$FA"
check "the reviewer sees the pending version" "$(lst "$FA")" '[fleet] under review'
refute "others do not see the pending version" "$(lst "$FB")" 'under review'
same "published versions are unique" "$(row "$PK" prec 1 active fc dup "" 2>&1 | grep -c UNIQUE)" "1"

# one name, five competing rows: pending (reviewer) > own draft > newest project active > global
FR=$(newpane fr)
FU=$(newpane fu)
row global ord 1 active x "g-desc" ""
row "$PK" ord 1 active x "p1-desc" ""
row "$PK" ord 2 active x "p2-desc" ""
call "$FU" tool_define "$(dnamed ord "d-desc")" > /dev/null
row "$PK" ord 3 pending x "r-desc" "$FR"
check "the reviewer sees the pending row" "$(lst "$FR")" '[fleet] r-desc'
refute "the pending row beats the draft" "$(lst "$FR")" 'd-desc'
check "the author sees its own draft" "$(lst "$FU")" '[fleet] d-desc'
refute "the draft beats the project rows" "$(lst "$FU")" 'p2-desc'
refute "the draft is private" "$(lst "$FB")" 'd-desc'
refute "pending is private" "$(lst "$FB")" 'r-desc'
check "others see the newest project version" "$(lst "$FB")" '[fleet] p2-desc'
refute "the older project version is hidden" "$(lst "$FB")" 'p1-desc'
refute "the project row beats the global one" "$(lst "$FB")" 'g-desc'
row "$PK" ord 4 revoked x "v4-desc" ""
refute "a revoked newest row hides the name from others" "$(lst "$FB")" '"name":"ord"'
sq "$CNTCTR_DB" "DELETE FROM tools WHERE project='$PK' AND name='ord'"
check "the global row shows once the project rows are gone" "$(lst "$FB")" '[fleet] g-desc'

# ---- fleet tool runner ----
t set -p -t "$FR" @cntctr_name fr-old   # one pane per agent name from here on
FR=$(t new-window -d -n fr -c "$TMPD/repo" -P -F '#{pane_id}' cat); t set -p -t "$FR" @cntctr_name fr
none='{}'
deft() { call "$FR" tool_define "$(jq -nc --arg s "$2" --arg n "$1" '{name:$n,description:"t",input_schema:{type:"object"},interpreter:"sh",script:$s}' | jq -c ". + ${3:-$none}")" >/dev/null; }
use() { call "$FR" use "$(jq -nc --arg t "$1" --argjson a "${2:-$none}" '{tool:$t,args:$a}')"; }
RK=$(txt "$(call "$FR" project '{}')" | sed 's/^project \(.*\) (root .*/\1/')
same "unknown tool" "$(iserr "$(use nope)")" true
check "unknown tool text" "$(txt "$(use nope)")" "unknown tool"
check "unknown name through dispatch" "$(txt "$(call "$FR" nope '{}')")" "unknown tool"
row "$RK" rv 1 revoked fc "was bad" ""
sq "$CNTCTR_DB" "UPDATE tools SET verdict_reason='bad idea' WHERE name='rv' AND project='$RK'"
same "revoked tool says why" "$(txt "$(use rv)")" "tool rv was revoked: bad idea"
same "revoked tool through dispatch" "$(txt "$(call "$FR" rv '{}')")" "tool rv was revoked: bad idea"
deft hello 'read a; echo "hi $a"'
same "draft is not callable by others" "$(txt "$(call "$FB" use '{"tool":"hello","args":{}}')")" "unknown tool hello"
if ! command -v sandbox-exec >/dev/null && ! command -v bwrap >/dev/null; then
    echo "SKIP: fleet tool runner tests need sandbox-exec or bwrap"
    check "no sandbox fails closed" "$(txt "$(use hello)")" "fleet tools need sandbox-exec or bwrap; neither found"
elif ! command -v sandbox-exec >/dev/null; then
    echo "SKIP: bwrap runner tests are untested here (no sandbox-exec)"
else
same "use runs the draft with args on stdin" "$(txt "$(use hello '{"who":"x"}')")" 'hi {"who":"x"}'
same "direct call works too" "$(txt "$(call "$FR" hello '{}')")" 'hi {}'
mkdir -p "$TMPD/fakebin"
printf '#!/bin/sh\ntouch "%s/marker"\nexit 1\n' "$TMPD" > "$TMPD/fakebin/sandbox-exec"; cp "$TMPD/fakebin/sandbox-exec" "$TMPD/fakebin/bwrap"; chmod +x "$TMPD/fakebin/"*
same "PATH cannot shadow the sandbox" "$(PATH="$TMPD/fakebin:$PATH" txt "$(PATH="$TMPD/fakebin:$PATH" use hello)")" 'hi {}'
[ -e "$TMPD/marker" ] && bad "fake sandbox ran" || ok_
deft wfile 'echo data > made.txt; mkdir -p sub; echo ok'
same "tool writes in the project" "$(txt "$(use wfile)")" ok; [ -f "$TMPD/repo/made.txt" ] && ok_ || bad "made.txt missing"
deft wgit 'echo x > .git/evil'
same "tool cannot write .git" "$(iserr "$(use wgit)")" true
[ -e "$TMPD/repo/.git/evil" ] && bad ".git/evil exists" || ok_
deft wout "echo x > $TMPD/outside"
same "tool cannot write outside" "$(iserr "$(use wout)")" true
ln -s "$TMPD/plain" "$TMPD/repo/link"
deft wlink 'echo x > link/evil'
same "symlink out is not writable" "$(iserr "$(use wlink)")" true
[ -e "$TMPD/plain/evil" ] && bad "wrote through the symlink" || ok_
deft cache 'echo x > "$TMPDIR/a" && echo y > "$XDG_CACHE_HOME/b" && cat "$TMPDIR/a"'
same "temp and cache are writable" "$(txt "$(use cache)")" x
deft envt 'env'
out=$(export FOO_TOKEN=s OPENAI_API_KEY=s MY_SECRET=s; txt "$(use envt)")
check "env reaches the tool" "$out" "CNTCTR_FD=3"
refute "no tokens" "$out" FOO_TOKEN; refute "no keys" "$out" API_KEY; refute "no secrets" "$out" MY_SECRET; refute "no TMUX" "$out" "TMUX="
python3 -c "import socket,time;s=socket.socket();s.bind(('127.0.0.1',47124));s.listen();time.sleep(8)" & LP=$!
sleep 0.5
deft neto 'nc -z -w1 127.0.0.1 47124 && echo open'
same "network denied by default" "$(iserr "$(use neto)")" true
deft neta 'nc -z -w1 127.0.0.1 47124 && echo open' '{"net":true}'
same "declared net works" "$(txt "$(use neta)")" open; kill $LP
deft big 'yes | head -c 400000'
big_out=$(txt "$(use big)")
[ "${#big_out}" -lt 16384 ] && ok_ || bad "stdout cap returns a preview under 16 KB"
big_path=$(printf '%s\n' "$big_out" | grep -o '/[^ "]*cntctr[^ "]*/[^ "]*')
[ -f "$big_path" ] && [ "$(wc -c < "$big_path")" -eq 262144 ] && ok_ || bad "stdout capture keeps all 256 KB"
deft slow 'sleep 30 & sleep 30' '{"timeout":2}'
check "timeout honored" "$(txt "$(use slow)")" "tool slow timed out after 2 s"
deft first 'echo early; cat >/dev/null; echo late'
check "write-before-read does not deadlock" "$(txt "$(use first "$(jq -nc --arg x "$(head -c 200000 /dev/zero | tr '\0' a)" '{x:$x}')")")" late
deft empty 'true'
same "empty output is fine" "$(iserr "$(use empty)")" false
same "empty output is an empty string" "$(txt "$(use empty)")" ""
deft bin 'printf "\377\376ab\000cd"'
same "invalid utf-8 is replaced" "$(iserr "$(use bin)")" false
check "valid bytes survive" "$(txt "$(use bin)")" ab
deft fails 'echo boom >&2; exit 3'
check "non-zero exit is an error with stderr" "$(txt "$(use fails)")" boom
same "non-zero exit sets isError" "$(iserr "$(use fails)")" true
deft fd3 'echo "{}" >&3; read -r r <&3; echo "$r"'
check "fd 3 rejects a request without a tool" "$(txt "$(use fd3)")" '"isError":true'
deft cw 'sleep 1; echo done'
call "$FR" cw '{}' > "$TMPD/cw1" & call "$FR" cw '{}' > "$TMPD/cw2" & wait
check "concurrent call one finishes" "$(txt "$(cat "$TMPD/cw1")")" done
check "concurrent call two finishes" "$(txt "$(cat "$TMPD/cw2")")" done
for i in sh bash python3 node; do
  call "$FR" tool_define "$(jq -nc --arg i $i '{name:("i_"+$i),description:"t",input_schema:{type:"object"},interpreter:$i,script:(if $i=="python3" then "print(1)" elif $i=="node" then "console.log(1)" else "echo 1" end)}')" >/dev/null
  same "$i runs sandboxed" "$(txt "$(use i_$i)")" 1
done
check "DB under the project root disables fleet tools" "$(CNTCTR_DB="$TMPD/repo/kb2.db"; export CNTCTR_DB; deft dbin 'echo hi'; txt "$(use dbin)")" "fleet tools are disabled here because the knowledge DB is inside this project; move CNTCTR_DB"
row "$RK" cnt 1 active fc "counts" ""
row "$RK" cntf 1 active fc "counts" ""
sq "$CNTCTR_DB" "UPDATE tools SET script='exit 3' WHERE name='cntf' AND project='$RK'"
use cnt >/dev/null; use cntf >/dev/null
same "good calls are counted" "$(sq "$CNTCTR_DB" "SELECT calls || '/' || failures FROM tools WHERE name='cnt' AND project='$RK'")" "1/0"
same "failed calls are counted" "$(sq "$CNTCTR_DB" "SELECT calls || '/' || failures FROM tools WHERE name='cntf' AND project='$RK'")" "1/1"
same "draft calls are not counted" "$(sq "$CNTCTR_DB" "SELECT sum(calls) FROM tools WHERE name='fails' AND project='$RK'")" 0
# .git as a symlink to a directory inside the root: the target must be read-only too
mkdir "$TMPD/gl"
git -C "$TMPD/gl" init -q
mv "$TMPD/gl/.git" "$TMPD/gl/realgit"; ln -s realgit "$TMPD/gl/.git"
FG=$(t new-window -d -n fg -c "$TMPD/gl" -P -F '#{pane_id}' cat); t set -p -t "$FG" @cntctr_name fg
call "$FG" tool_define '{"name":"gitlink","description":"t","input_schema":{"type":"object"},"interpreter":"sh","script":"echo x > realgit/evil"}' >/dev/null
same "tool cannot write through a .git symlink" "$(iserr "$(call "$FG" use '{"tool":"gitlink"}')")" true

# ---- fleet tool lifecycle: publish, review copy, reviewer, verdict, expiry ----
RV="$(realpath /tmp)/cntctr-$(id -u)/review"
tenv() { t set-environment -g "$1" "$2"; }
tunset() { t set-environment -gu "$1"; }
waitfor() { local d=$1; shift; for _ in $(seq 150); do eval "$@" && { ok_; return; }; sleep 0.1; done; bad "$d"; }
st() { sq "$CNTCTR_DB" "select status from tools where name='$1' and version=${2:-1}"; }
hasdir() { ls "$RV" 2>/dev/null | grep -qF -- "$1"; }
haspane() { t list-panes -a -F '#{@cntctr_name}' | grep -qF -- "$1"; }
nmap() { sq "$CNTCTR_DB" "select count(*) from projects where root like '%/review/%'"; }
pubdef() { jq -nc --arg n "$1" --arg s "$2" --arg d "${3:-desc of $1}" '{name:$n,description:$d,input_schema:{type:"object"},interpreter:"sh",script:$s,publish:true}'; }
publish() { txt "$(call "$1" tool_define "$(pubdef "${@:2}")")"; }
board() { txt "$(call "${1:-$FR}" board '{"limit":200}')"; }
t set -p -t "$FR" @cntctr_harness claude

same "the gate runs before publishing" "$(publish "$FR" Bad_Name 'true')" "name must match ^[a-z][a-z0-9_]{1,40}\$"
same "a failed gate stores nothing" "$(sq "$CNTCTR_DB" "select count(*) from tools where name='Bad_Name'")" 0

# approve: the review copy has the untracked file; the tool runs there, not on the real tree
echo untracked > "$TMPD/repo/u.txt"
same "publish returns version and status" "$(publish "$FR" pw 'cat u.txt; echo touched > u.txt; pwd')" "pw v1 pending"
expect_screen "approval reaches the author" "$FR" "new fleet tool pw v1 by fr; see tools/list"
same "the reviewer ran on the copy, not the real tree" "$(cat "$TMPD/repo/u.txt")" untracked
check "the copy includes the untracked file" "$(cat "$TMPD/rev-pw.use")" untracked
check "the copy lives under the review dir" "$(cat "$TMPD/rev-pw.use")" "/cntctr-$(id -u)/review/"
check "the copy is named by project, tool and version" "$(cat "$TMPD/rev-pw.use")" "-pw-v1"
same "approved status" "$(st pw)" active
same "the draft was consumed by publishing" "$(sq "$CNTCTR_DB" "select count(*) from tools where name='pw' and status='draft'")" 0
check "the reviewer ran on a different harness's model" "$(sq "$CNTCTR_DB" "select reviewer_model from tools where name='pw'")" gemini
same "the reviewer was deadline-bound" "$(sq "$CNTCTR_DB" "select deadline - created from tools where name='pw'")" 1200
check "other agent in project sees it" "$(lst "$KR")" '"name":"pw"'
refute "an agent in another project does not" "$(lst "$FG")" '"name":"pw"'
waitfor "review copy removed" '! hasdir -pw-v1'
waitfor "copy mapping removed" '[ "$(nmap)" = 0 ]'
waitfor "reviewer pane closed" '! haspane -pw-v1'

# a reviewer that asks for a verdict before the review is bound is told to retry
tenv CNTCTR_TEST_FAST 1
CNTCTR_TEST_HOLD_BIND=1 call "$FR" tool_define "$(pubdef pf 'echo fast')" >/dev/null
waitfor "pf approved after retrying" '[ "$(st pf)" = active ]'
same "an early verdict is refused" "$(cat "$TMPD/rev-pf.first")" "review not bound yet; retry in a few seconds"
tunset CNTCTR_TEST_FAST

# reject and escalate
tenv CNTCTR_TEST_VERDICT reject
publish "$FR" pr 'echo r' >/dev/null
waitfor "pr rejected" '[ "$(st pr)" = rejected ]'
same "the reject reason is stored" "$(sq "$CNTCTR_DB" "select verdict_reason from tools where name='pr'")" "reviewer says reject"
expect_screen "the reason reaches the author" "$FR" "fleet tool pr v1 was rejected: reviewer says reject"
check "the reject reason is on the board" "$(txt "$(call "$FR" board '{}')")" "fleet tool pr v1 was rejected: reviewer says reject"
refute "a rejected tool is not listed" "$(lst "$KR")" '"name":"pr"'
tenv CNTCTR_TEST_VERDICT escalate
publish "$FR" pe 'echo e' >/dev/null
waitfor "pe escalated" '[ "$(st pe)" = escalated ]'
same "escalating clears the reviewer's authority" "$(sq "$CNTCTR_DB" "select reviewer_pane is null from tools where name='pe'")" 1
check "the board asks for a human" "$(board)" "fleet tool pe v1 needs a human"
expect_screen "the author sees the request" "$FR" "fleet tool pe v1 needs a human"
refute "an escalated tool is not listed" "$(lst "$KR")" '"name":"pe"'
tunset CNTCTR_TEST_VERDICT

# verdict guards, with rows inserted directly
same "a verdict needs a valid verdict" "$(txt "$(call "$FB" tool_verdict '{"name":"x","version":1,"verdict":"maybe"}')")" "verdict must be approve, reject or escalate"
row "$PK" nv 1 pending fc "not yours" "$FA"
same "a verdict from a non-reviewer is refused" "$(txt "$(call "$FB" tool_verdict '{"name":"nv","version":1,"verdict":"approve","reason":"x"}')")" "only the assigned reviewer can give a verdict"
same "from= does not make a reviewer" "$(txt "$(call "$FB" tool_verdict '{"name":"nv","version":1,"verdict":"approve","from":"fa"}')")" "only the assigned reviewer can give a verdict"
same "the row is still pending" "$(st nv)" pending
same "use from= cannot reach a pending version" "$(txt "$(call "$FB" use '{"tool":"nv","from":"fa"}')")" "unknown tool nv"
same "a pending tool is callable by its reviewer" "$(iserr "$(call "$FA" use '{"tool":"nv"}')")" false
ER=$(t new-window -d -n er -c "$TMPD/repo" -P -F '#{pane_id}' cat); t set -p -t "$ER" @cntctr_name er   # a verdict closes the reviewer pane
row "$RK" ea 1 pending fc "esc" "$ER"
check "the reviewer can escalate" "$(txt "$(call "$ER" tool_verdict '{"name":"ea","version":1,"verdict":"escalate","reason":"unsure"}')")" ok
same "escalate sets the status" "$(st ea)" escalated
same "approve after escalate is refused" "$(txt "$(call "$ER" tool_verdict '{"name":"ea","version":1,"verdict":"approve","reason":"x"}')")" "version 1 is escalated"
same "the refused approval changed nothing" "$(st ea)" escalated
same "a verdict on an unknown version" "$(txt "$(call "$ER" tool_verdict '{"name":"ea","version":9,"verdict":"approve"}')")" "unknown tool ea version 9"
sq "$CNTCTR_DB" "insert into tools(project,name,version,status,author,description,input_schema,interpreter,script) values ('$RK','ub',1,'pending','fc','unbound','{\"type\":\"object\"}','sh','true')"
UB=$(t new-window -d -n ub -c "$TMPD/repo" -P -F '#{pane_id}' cat); t set -p -t "$UB" @cntctr_name toolcheck-aaaaaaaa-ub-v1
same "use before binding says to retry" "$(txt "$(call "$UB" use '{"tool":"ub"}')")" "review not bound yet; retry in a few seconds"
same "a verdict before binding says to retry" "$(txt "$(call "$UB" tool_verdict '{"name":"ub","version":1,"verdict":"approve"}')")" "review not bound yet; retry in a few seconds"

# supersede: v2 rejects the pending v1, and v1's late verdict is refused
tenv CNTCTR_TEST_VERDICT none
SR=$(newpane sr)   # superseding closes the old reviewer's pane
row "$RK" sv 1 pending fc "old" "$SR"
sq "$CNTCTR_DB" "update tools set deadline=strftime('%s','now')+1200 where name='sv'"
same "v2 is published over a pending v1" "$(publish "$FR" sv 'echo 2')" "sv v2 pending"
same "v1 was superseded" "$(st sv 1)" rejected
same "the supersede reason is stored" "$(sq "$CNTCTR_DB" "select verdict_reason from tools where name='sv' and version=1")" superseded
same "a late verdict on v1 is refused" "$(txt "$(call "$FR" tool_verdict '{"name":"sv","version":1,"verdict":"approve"}')")" "version 1 is rejected"
same "v2 is pending" "$(st sv 2)" pending

# resolution: while v2 is pending over an active v1 the reviewer gets v2 and everyone else v1
tenv CNTCTR_TEST_VERDICT approve
publish "$FR" rs 'echo 1' "rs one" >/dev/null
waitfor "rs v1 active" '[ "$(st rs 1)" = active ]'
tenv CNTCTR_TEST_VERDICT none
publish "$FR" rs 'echo 2' "rs two" >/dev/null
RP=$(sq "$CNTCTR_DB" "select reviewer_pane from tools where name='rs' and version=2")
check "the reviewer has a pane" "$RP" "%"
check "the reviewer gets the pending version" "$(lst "$RP")" "[fleet] rs two"
check "everyone else keeps v1" "$(lst "$KR")" "[fleet] rs one"
refute "others do not see the pending version" "$(lst "$KR")" "rs two"
tenv CNTCTR_TEST_VERDICT approve
publish "$FR" rs 'echo 3' "rs three" >/dev/null
waitfor "rs v3 active" '[ "$(st rs 3)" = active ]'
same "approving v3 revoked v1" "$(st rs 1)" revoked
same "v2 was superseded" "$(st rs 2)" rejected
check "others see v3" "$(lst "$KR")" "[fleet] rs three"

# bind race: a supersede or revoke while the reviewer spawn is held before binding
tenv CNTCTR_TEST_VERDICT none
CNTCTR_TEST_HOLD_BIND=2 call "$FR" tool_define "$(pubdef br 'echo 1')" > "$TMPD/br1.out" & bgp=$!
waitfor "br v1's reviewer is spawned" 'haspane -br-v1'
publish "$FR" br 'echo 2' >/dev/null
wait $bgp
same "a supersede during the bind leaves v1 rejected" "$(st br 1)" rejected
check "the publisher is told" "$(txt "$(cat "$TMPD/br1.out")")" "was superseded or revoked before its review started"
waitfor "the held review's copy is cleaned up" '! hasdir -br-v1'
waitfor "the held review's pane is closed" '! haspane -br-v1'
CNTCTR_TEST_HOLD_BIND=2 call "$FR" tool_define "$(pubdef bq 'echo 1')" > "$TMPD/bq1.out" & bgp=$!
waitfor "bq v1's reviewer is spawned" 'haspane -bq-v1'
sq "$CNTCTR_DB" "update tools set status='revoked', verdict_reason='gone' where name='bq' and version=1"
wait $bgp
same "a revoke during the bind leaves v1 revoked" "$(st bq 1)" revoked
waitfor "the revoked review's copy is cleaned up" '! hasdir -bq-v1'
waitfor "the revoked review's pane is closed" '! haspane -bq-v1'
same "no copy mapping is left" "$(sq "$CNTCTR_DB" "select count(*) from projects where root like '%-bq-v1' or root like '%-br-v1'")" 0

# expiry: after the publisher is gone, the next tool_* call escalates once and cleans up
publish "$FR" px 'echo x' >/dev/null
same "px is pending" "$(st px)" pending
check "px has a review copy" "$(ls "$RV")" "-px-v1"
sq "$CNTCTR_DB" "update tools set deadline=0 where name='px' and status='pending'"
deft trig 'true'
same "an expired review is escalated" "$(st px)" escalated
waitfor "the expired review's copy is removed" '! hasdir -px-v1'
waitfor "the expired review's pane is closed" '! haspane -px-v1'
same "expiry posted once" "$(board | grep -c 'fleet tool px v1 needs a human')" 1
deft trig2 'true'
call "$FR" use '{"tool":"trig2"}' >/dev/null
same "a second expiry run posts nothing" "$(board | grep -c 'fleet tool px v1 needs a human')" 1
mkdir -p "$RV/deadbeef-stray-v9" "$RV/deadbeef-young-v9"
touch -t "$(date -v-31M +%Y%m%d%H%M.%S 2>/dev/null || date -d '31 minutes ago' +%Y%m%d%H%M.%S)" "$RV/deadbeef-stray-v9"
call "$FR" use '{"tool":"hello","args":{}}' >/dev/null
[ ! -d "$RV/deadbeef-stray-v9" ] && ok_ || bad "an old stray review dir is swept"
[ -d "$RV/deadbeef-young-v9" ] && ok_ || bad "a young stray review dir survives the sweep"
rmdir "$RV/deadbeef-young-v9"

# publishing never clobbers what is already under the final name, empty directory or not
HK=$(python3 -c 'import sys;h=2166136261
for c in sys.argv[1].encode(): h=((h^c)*16777619)&0xffffffff
print("%08x"%h)' "$RK")
for kind in full empty; do
    d="$RV/$HK-cl$kind-v1"
    mkdir -p "$d"
    [ $kind = full ] && echo marker > "$d/marker"
    check "publishing over an existing $kind copy dir fails" "$(publish "$FR" cl$kind 'true')" "already exists"
    same "the existing $kind copy dir is left as it was" "$(ls -A "$d")" "$([ $kind = full ] && echo marker)"
    rm -rf "$d"
done
tunset CNTCTR_TEST_VERDICT

# a project without git
FP=$(t new-window -d -n fp -c "$TMPD/plain" -P -F '#{pane_id}' cat); t set -p -t "$FP" @cntctr_name fp; t set -p -t "$FP" @cntctr_harness claude
same "a plain directory can publish" "$(publish "$FP" np 'pwd; ls')" "np v1 pending"
waitfor "np approved" '[ "$(st np)" = active ]'
check "the plain copy ran under the review dir" "$(cat "$TMPD/rev-np.use")" "/review/"

# a linked worktree: the copy gets its own .git directory
git -C "$TMPD" init -q wtmain
git -C "$TMPD/wtmain" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
git -C "$TMPD/wtmain" worktree add -q "$TMPD/wtlinked" -b wtb
FW=$(t new-window -d -n fw -c "$TMPD/wtlinked" -P -F '#{pane_id}' cat); t set -p -t "$FW" @cntctr_name fw; t set -p -t "$FW" @cntctr_harness claude
[ -f "$TMPD/wtlinked/.git" ] && ok_ || bad "wtlinked/.git should be a file"
same "a worktree can publish" "$(publish "$FW" wt 'test -d .git && echo gitdir; git rev-parse --show-toplevel')" "wt v1 pending"
waitfor "wt approved" '[ "$(st wt)" = active ]'
check "the worktree copy has its own .git directory" "$(cat "$TMPD/rev-wt.use")" gitdir
check "git resolves the copy as its own toplevel" "$(cat "$TMPD/rev-wt.use")" "/review/"
same "the real worktree is unchanged" "$([ -f "$TMPD/wtlinked/.git" ] && echo file)" file

# a .git symlink to a directory outside the project: the copy gets that directory's contents, not the link
git -C "$TMPD" init -q slgit
git -C "$TMPD/slgit" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
mkdir "$TMPD/slproj" && echo 1 > "$TMPD/slproj/f" && ln -s "$TMPD/slgit/.git" "$TMPD/slproj/.git"
FL=$(t new-window -d -n fl -c "$TMPD/slproj" -P -F '#{pane_id}' cat); t set -p -t "$FL" @cntctr_name fl; t set -p -t "$FL" @cntctr_harness claude
same "a symlinked .git can publish" "$(publish "$FL" sl 'git branch evil; git rev-parse --absolute-git-dir')" "sl v1 pending"
waitfor "sl approved" '[ "$(st sl)" = active ]'
check "the copy's git dir is inside the review dir" "$(cat "$TMPD/rev-sl.use")" "/review/"
refute "the tool did not reach the real repo's git dir" "$(cat "$TMPD/rev-sl.use")" "slgit"
same "the real repo has no new branch" "$(git -C "$TMPD/slgit" branch --list evil)" ""

# the author's model
L2=$(newpane lead2)
out=$(call "$L2" spawn '{"harness":"claude","name":"am","task":"x","model":"claude-sonnet-5","effort":"low"}')
AM=$(pane_of "$out")
same "spawn tags the pane with the model" "$(t show -pqv -t "$AM" @cntctr_model)" claude-sonnet-5
same "a model-less spawn tags the routed model" "$(t show -pqv -t "$(pane_of "$(call "$L2" spawn '{"harness":"claude","name":"am2","task":"x"}')")" @cntctr_model)" claude-sonnet-5-5
publish "$AM" ma 'echo m' >/dev/null
same "the author's model is recorded" "$(sq "$CNTCTR_DB" "select author_model from tools where name='ma'")" claude-sonnet-5
waitfor "ma approved" '[ "$(st ma)" = active ]'

# no agy on PATH: a hand-started author escalates; a known model falls back to claude with another model
mkdir "$TMPD/noagy"
for c in tmux git jq mktemp mkfifo head tail rm sh bash env cat cp sed basename dirname sleep seq wc sqlite3; do ln -s "$(command -v "$c")" "$TMPD/noagy/$c"; done
FH=$(newpane hand); t set -p -t "$FH" @cntctr_harness claude
out=$(PATH="$TMPD/noagy" publish "$FH" hs 'echo h')
check "no reviewer for an unknown model" "$out" "no reviewer on a different model"
same "an author with no model escalates" "$(st hs)" escalated
check "the board asks for a human" "$(board "$FH")" "fleet tool hs v1 needs a human"
same "the copy was cleaned up" "$(hasdir -hs-v1 && echo left)" ""
for c in claude headroom; do ln -s "$(command -v "$c")" "$TMPD/noagy/$c"; done   # start_spawn runs claude through headroom
FM=$(newpane known); t set -p -t "$FM" @cntctr_harness claude; t set -p -t "$FM" @cntctr_model claude-sonnet-5-5
same "a known model falls back to the same harness" "$(PATH="$TMPD/noagy" publish "$FM" fm 'echo f')" "fm v1 pending"
waitfor "fm approved" '[ "$(st fm)" = active ]'
same "the fallback reviewer uses another model" "$(sq "$CNTCTR_DB" "select reviewer_model from tools where name='fm'")" claude-opus-4-7
[ -e "$TMPD/gl/realgit/evil" ] && bad "wrote into the symlinked git dir" || ok_
call "$FG" tool_define '{"name":"gitok","description":"t","input_schema":{"type":"object"},"interpreter":"sh","script":"echo x > other.txt; echo fine"}' >/dev/null
same "that root is otherwise writable" "$(txt "$(call "$FG" use '{"tool":"gitok"}')")" fine
# composition: a tool calls back into cntctr as its caller
ln -s "$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")" "$TMPD/bin/cntctr"
call "$FR" note '{"layer":"insight","title":"Enter in copy-mode","summary":"paste a CR instead","tags":"scrollback"}' >/dev/null
deft rc 'cntctr call recall "{\"query\":\"copy-mode\"}"'
check "tool can recall" "$(txt "$(use rc)")" "Enter in copy-mode"
deft nt 'cntctr call note "{\"layer\":\"insight\",\"title\":\"from tool\",\"summary\":\"s\",\"from\":\"someone-else\"}"'
use nt >/dev/null
same "note from a tool is authored by the caller" "$(sq "$CNTCTR_DB" "select agent from entries where title='from tool'")" fr
deft sp 'cntctr call spawn "{}"'
check "spawn is not callable from a tool" "$(txt "$(use sp)")" "tool spawn is not callable from a fleet tool"
deft deep 'cntctr call use "{\"tool\":\"deep\",\"args\":{}}"'
check "nesting stops at 3" "$(txt "$(use deep)")" "fleet tools nested too deep"
deft inner 'echo inner-ok'
deft outer 'cntctr call use "{\"tool\":\"inner\"}"'
same "a tool can use another tool" "$(txt "$(use outer)")" inner-ok
check "a garbage CNTCTR_FD fails fast" "$(CNTCTR_FD=garbage "$BIN" call recall '{}' 2>&1)" "cntctr call works only inside a fleet tool"
check "a non-socket CNTCTR_FD fails fast" "$(CNTCTR_FD=1 "$BIN" call recall '{}' 2>&1)" "cntctr call works only inside a fleet tool"
deft slowin 'sleep 10'
deft slowout 'cntctr call use "{\"tool\":\"slowin\"}"' '{"timeout":2}'
t0=$SECONDS; out=$(use slowout); el=$((SECONDS - t0))
same "a nested run inherits the outer deadline" "$(iserr "$out")" true
[ "$el" -le 4 ] && ok_ || bad "nested slow tool took ${el}s, want <= 4"
deft kb10 'yes a | head -c 10000'
deft flood 'python3 -c "import socket,time;s=socket.socket(fileno=3);[s.sendall(b\"{\\\"tool\\\":\\\"use\\\",\\\"args\\\":{\\\"tool\\\":\\\"kb10\\\",\\\"args\\\":{}}}\\n\") for _ in range(100)];time.sleep(20)"' '{"timeout":30}'
out=$(use flood)
check "unread composition replies are capped" "$(txt "$out")" "unread"
same "cntctr survives the flood" "$(txt "$(use inner)")" inner-ok
check "call outside a tool fails" "$("$BIN" call recall '{}' 2>&1)" "cntctr call works only inside a fleet tool"
check "calls are logged as history" "$(sq "$CNTCTR_DB" "SELECT group_concat(title) FROM entries WHERE layer='history' AND title LIKE 'tool fails v0 fr %'")" "tool fails v0 fr fail"

# revoke: use refuses, the fleet is told, a later version lists, no older version comes back
tenv CNTCTR_TEST_VERDICT approve
publish "$FR" rvk 'echo one' "rvk one" >/dev/null
waitfor "rvk v1 active" '[ "$(st rvk 1)" = active ]'
same "revoke needs an active version" "$(txt "$(call "$KR" tool_revoke '{"name":"nope","reason":"x"}')")" "no active version of nope"
same "revoke answers" "$(txt "$(call "$KR" tool_revoke '{"name":"rvk","reason":"leaks keys"}')")" "revoked rvk"
same "v1 is revoked" "$(st rvk 1)" revoked
same "use says why" "$(txt "$(use rvk)")" "tool rvk was revoked: leaks keys"
refute "revoke does not type into the revoker pane" "$(screen "$KR")" "revoked fleet tool rvk"
refute "revoke does not type into the author pane" "$(screen "$FR")" "revoked fleet tool rvk"
check "the board keeps it" "$(txt "$(call "$KR" board '{}')")" "revoked fleet tool rvk"
refute "a revoked tool is not listed" "$(lst "$KR")" '"name":"rvk"'
same "revoking twice finds nothing" "$(txt "$(call "$KR" tool_revoke '{"name":"rvk","reason":"x"}')")" "no active version of rvk"
publish "$FR" rvk 'echo two' "rvk two" >/dev/null
waitfor "rvk v2 active" '[ "$(st rvk 2)" = active ]'
check "a version published after a revoke is listed" "$(lst "$KR")" "[fleet] rvk two"
publish "$FR" rnw 'echo 1' "rnw one" >/dev/null
waitfor "rnw v1 active" '[ "$(st rnw 1)" = active ]'
publish "$FR" rnw 'echo 2' "rnw two" >/dev/null
waitfor "rnw v2 active" '[ "$(st rnw 2)" = active ]'
call "$KR" tool_revoke '{"name":"rnw","reason":"bad"}' >/dev/null
same "revoking v2 does not bring v1 back" "$(txt "$(use rnw)")" "tool rnw was revoked: bad"
refute "v1 stays unlisted" "$(lst "$KR")" "rnw one"

# revoke also closes versions still under review
tenv CNTCTR_TEST_VERDICT approve
publish "$FR" rpa 'echo 1' "rpa one" >/dev/null
waitfor "rpa v1 active" '[ "$(st rpa 1)" = active ]'
tenv CNTCTR_TEST_VERDICT none
publish "$FR" rpa 'echo 2' "rpa two" >/dev/null
waitfor "rpa v2's reviewer is bound" 'haspane -rpa-v2'
call "$KR" tool_revoke '{"name":"rpa","reason":"unsafe"}' >/dev/null
same "revoke takes the pending version too" "$(st rpa 2)" revoked
same "revoke takes the active version" "$(st rpa 1)" revoked
same "a verdict on the revoked pending version is refused" "$(txt "$(call "$FR" tool_verdict '{"name":"rpa","version":2,"verdict":"approve"}')")" "version 2 is revoked"
same "use says revoked" "$(txt "$(use rpa)")" "tool rpa was revoked: unsafe"
waitfor "the revoked review's copy is cleaned up" '! hasdir -rpa-v2'
waitfor "the revoked review's pane is closed" '! haspane -rpa-v2'
publish "$FR" rpo 'echo 1' >/dev/null
waitfor "rpo v1's reviewer is bound" 'haspane -rpo-v1'
call "$KR" tool_revoke '{"name":"rpo","reason":"no"}' >/dev/null
same "a name with only a pending version can be revoked" "$(st rpo 1)" revoked
waitfor "its review pane is closed" '! haspane -rpo-v1'
CNTCTR_TEST_HOLD_BIND=2 call "$FR" tool_define "$(pubdef rpb 'echo 1')" > "$TMPD/rpb.out" & bgp=$!
waitfor "rpb v1's reviewer is spawned" 'haspane -rpb-v1'
call "$KR" tool_revoke '{"name":"rpb","reason":"early"}' >/dev/null
wait $bgp
same "a revoke before the bind leaves v1 revoked" "$(st rpb 1)" revoked
waitfor "the unbound review's copy is cleaned up" '! hasdir -rpb-v1'
waitfor "the unbound review's pane is closed" '! haspane -rpb-v1'

# propagation: list_changed through per-process FIFOs in the real, private tools dir
TD="$(realpath "${TMPDIR:-/tmp}")/cntctr-$(id -u)/tools"
LC='{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}'
LIST='{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
revcall() { printf '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"tool_revoke","arguments":{"name":"%s","reason":"t"}}}' "$1"; }
check "initialize advertises listChanged" "$(rpc "$INIT")" '"listChanged":true'
tenv CNTCTR_TEST_VERDICT approve
daemon_start "$KA"
lc1_out=$DOUT
daemon_send "$LIST"
waitfor "the listener registered a FIFO" 'jq -e "select(.id == 2)" "$lc1_out" >/dev/null 2>&1 && ls "$TD" | grep -q "\.fifo$"'
same "the tools dir is private" "$(stat -f %Lp "$TD" 2>/dev/null || stat -c %a "$TD")" 700
publish "$FR" lcn 'echo 1' >/dev/null
waitfor "lcn approved" '[ "$(st lcn)" = active ]'
waitfor "an approval notifies another cntctr" 'grep -qxF "$LC" "$lc1_out"'
sleep 1
lc_before_revoke=$(grep -cxF "$LC" "$lc1_out")
[ "$lc_before_revoke" -ge 1 ] && ok_ || bad "visibility changes send list_changed"
own=$(session "$KR" 3 "$INIT" "$(revcall lcn)")
check "the revoker's own cntctr is notified" "$own" "$LC"
waitfor "a revoke notifies too" '[ "$(grep -cxF "$LC" "$lc1_out")" -gt "$lc_before_revoke" ]'
daemon_stop
session "$KA" 3 "$INIT" "$LIST" | while read -r l; do echo "$l" >> "$TMPD/lc2"; done & lc2=$!
waitfor "the second listener registered" '[ "$(grep -c . "$TMPD/lc2")" = 2 ]'
for n in lcb1 lcb2 lcb3; do publish "$FR" $n 'echo b' >/dev/null; done
waitfor "the burst is approved" '[ "$(st lcb1)$(st lcb2)$(st lcb3)" = activeactiveactive ]'
wait $lc2
check "a burst notifies after the last commit" "$(cat "$TMPD/lc2")" "$LC"
mkfifo "$TD/999999.fifo"
call "$KR" tool_revoke '{"name":"lcb1","reason":"t"}' >/dev/null
waitfor "a FIFO with no reader is unlinked" '[ ! -e "$TD/999999.fifo" ]'
chmod 755 "$TD"
daemon_start "$KR" 2>"$TMPD/lc.err"
daemon_send "$(revcall lcb2)"
waitfor "an owned loose tools dir still notifies" 'grep -qxF "$LC" "$DOUT"'
fixed_mode=$(stat -f %Lp "$TD" 2>/dev/null || stat -c %a "$TD")
daemon_stop
chmod 700 "$TD"
same "an owned loose tools dir logs no error" "$(grep -c 'notifications disabled' "$TMPD/lc.err")" 0
same "the owned tools dir was repaired" "$fixed_mode" 700

# human CLI: list, show, approve, reject, revoke, promote
cli() { (cd "${CLID:-$TMPD/repo}" && "$BIN" tools "$@" 2>&1); }
GK=$(txt "$(call "$FG" project '{}')" | sed 's/^project \(.*\) (root .*/\1/')
HQ=$(t new-window -d -n hq -c "$TMPD/repo" -P -F '#{pane_id}' cat); t set -p -t "$HQ" @cntctr_name hq
check "tools needs a known command" "$(cli bogus)" "usage: cntctr tools"
tenv CNTCTR_TEST_VERDICT approve
publish "$FR" hp 'echo one' "hp one" >/dev/null
waitfor "hp v1 active" '[ "$(st hp 1)" = active ]'
publish "$FR" hp 'echo two' "hp two" >/dev/null
waitfor "hp v2 active" '[ "$(st hp 2)" = active ]'
sq "$CNTCTR_DB" "update tools set calls=0 where name='hp'"   # the reviewer's trial run counted one
same "list shows the live version" "$(cli list | grep '^hp ')" "hp v2 active net=0 calls=0 failures=0 promote?=no"
out=$(cli show hp)
check "show lists an older version" "$out" "v1 revoked"
check "show lists the live version" "$out" "v2 active"
check "show prints the script" "$out" "echo two"
check "show names the models" "$out" "author model unknown, reviewer model gemini"
check "show gives the verdict" "$out" "verdict: superseded"
sq "$CNTCTR_DB" "update tools set calls=17 where name='hp' and version=2"
call "$FR" use '{"tool":"hp"}' >/dev/null
call "$KR" use '{"tool":"hp"}' >/dev/null
check "promote? stays off with two agents" "$(cli list | grep '^hp ')" "promote?=no"
call "$HQ" use '{"tool":"hp"}' >/dev/null
check "promote? turns on at 20 calls from 3 agents" "$(cli list | grep '^hp ')" "calls=20 failures=0 promote?=yes"
sq "$CNTCTR_DB" "update tools set failures=1 where name='hp' and version=2"
check "promote? needs a failure rate under 5%" "$(cli list | grep '^hp ')" "promote?=no"
sq "$CNTCTR_DB" "update tools set failures=0 where name='hp' and version=2"

# promote? counts the current version only: three agents used v1, one agent makes 20 calls of v2
publish "$FR" pc 'echo 1' >/dev/null
waitfor "pc v1 active" '[ "$(st pc 1)" = active ]'
for p in "$FR" "$KR" "$HQ"; do call "$p" use '{"tool":"pc"}' >/dev/null; done
publish "$FR" pc 'echo 2' >/dev/null
waitfor "pc v2 active" '[ "$(st pc 2)" = active ]'
call "$FR" use '{"tool":"pc"}' >/dev/null
sq "$CNTCTR_DB" "update tools set calls=20 where name='pc' and version=2"
check "promote? ignores the agents of older versions" "$(cli list | grep '^pc ')" "calls=20 failures=0 promote?=no"

same "promote copies the live version to global" "$(cli promote hp)" "promoted hp v2 to global v1"
same "promote records its source" "$(sq "$CNTCTR_DB" "select source from tools where project='global' and name='hp'")" "$RK/hp/v2"
check "a promoted tool is visible in another project" "$(lst "$FG")" "[fleet] hp two"
row "$GK" hp 1 active fc "gl hp" ""
check "a project tool shadows the global one" "$(lst "$FG")" "[fleet] gl hp"
same "promote from a second project" "$(CLID="$TMPD/gl" cli promote hp)" "promoted hp v1 to global v2"
same "promote revokes the previous global version" "$(sq "$CNTCTR_DB" "select group_concat(version || status) from (select * from tools where project='global' and name='hp' order by version)")" "1revoked,2active"
same "promote needs a live version" "$(cli promote nolive)" "no active version of nolive in this project"
sq "$CNTCTR_DB" "update tools set status='revoked', verdict_reason='x' where project='$GK' and name='hp'"
refute "a project revoke masks the global tool" "$(lst "$FG")" '"name":"hp"'

# approve and promote notify; approve resolves an escalated row and tells the project
tenv CNTCTR_TEST_VERDICT escalate
publish "$FR" he 'echo e' >/dev/null
waitfor "he escalated" '[ "$(st he)" = escalated ]'
touch "$TMPD/lc3"
session "$KA" 4 "$INIT" "$LIST" | while read -r l; do echo "$l" >> "$TMPD/lc3"; done & lc3=$!
waitfor "the listener registered" '[ "$(grep -c . "$TMPD/lc3")" = 2 ]'
same "approve resolves an escalated version" "$(cli approve he)" "approved he v1"
same "the approved tool is active" "$(st he)" active
same "the approved tool runs" "$(txt "$(use he)")" e
check "approve tells the project" "$(board)" "new fleet tool he v1 by fr; see tools/list"
sleep 1
same "promote of the approved tool" "$(cli promote he)" "promoted he v1 to global v1"
wait $lc3
same "approve and promote each notify" "$(grep -cxF "$LC" "$TMPD/lc3")" 2
check "promote tells the project" "$(board)" "promoted fleet tool he to global"
tunset CNTCTR_TEST_VERDICT
HP=$(newpane hrp)
row "$RK" hpd 1 pending fc "pend" "$HP"
same "approve resolves a pending version" "$(cli approve hpd)" "approved hpd v1; verdict is on the board"
same "a pending version became active" "$(st hpd)" active
waitfor "approving closes the reviewer's pane" '! haspane hrp'
row "$RK" hrj 1 escalated fc "esc" ""
same "reject resolves an escalated version" "$(cli reject hrj)" "rejected hrj v1; verdict is on the board"
same "the rejected status" "$(st hrj)" rejected
same "approve finds nothing to resolve" "$(cli approve hrj)" "no pending or escalated version of hrj"

# revoke: project, then global; a global revoke reaches git projects that have no override and no tools
same "revoke the project copy" "$(cli revoke he)" "revoked he"
same "use says why" "$(txt "$(use he)")" "tool he was revoked: revoked by a human"
same "a project revoke needs a live version" "$(cli revoke he)" "no active version of he"
check "the global copy is still listed elsewhere" "$(lst "$FG")" '"name":"he"'
for d in long:foo/bar short:bar; do
    git init -q "$TMPD/sfx-${d%%:*}"
    git -C "$TMPD/sfx-${d%%:*}" remote add origin "https://x.test/${d#*:}"
    p=$(t new-window -d -n "sfx-${d%%:*}" -c "$TMPD/sfx-${d%%:*}" -P -F '#{pane_id}' cat); t set -p -t "$p" @cntctr_name "sfx-${d%%:*}"
    eval "SFX_${d%%:*}=$p"
done
same "a global revoke" "$(cli revoke --global he)" "revoked he"
refute "a global revoke hides the tool elsewhere" "$(lst "$FG")" '"name":"he"'
check "a global announce posts for a git project with no override" "$(txt "$(call "$SFX_short" board '{}')")" "revoked global fleet tool he"
check "and for a project whose key ends in the other's" "$(txt "$(call "$SFX_long" board '{}')")" "revoked global fleet tool he"
same "a global revoke needs a global version" "$(cli revoke --global he)" "no active version of he"

# the dashboard shows the tools of its directory's project
out=$(cd "$TMPD/repo" && bash "$(dirname "$BIN")/watch.sh" --once)
check "dashboard has a fleet tools block" "$out" "== fleet tools ("
check "dashboard lists the tools" "$out" "hp v2 active"
# skills announce, recall finds tools, the guide teaches both
SK=$(t new-window -d -n sk -c "$TMPD/repo" -P -F '#{pane_id}' cat); t set -p -t "$SK" @cntctr_name sk
call "$FR" note '{"layer":"skill","title":"Ship it","summary":"how to ship"}' >/dev/null
refute "a skill note tells the project only through the board" "$(screen "$SK")" "new skill Ship it ("
check "a skill note tells the project on the board" "$(txt "$(call "$SK" board '{}')")" "new skill Ship it ("
refute "the author's own pane is skipped" "$(screen "$FR")" "new skill Ship it"
call "$FR" note '{"layer":"insight","title":"Plain insight","summary":"no announce"}' >/dev/null
call "$FR" note '{"layer":"doc","title":"Plain doc","summary":"no announce","body":"x"}' >/dev/null
sleep 1
refute "an insight does not announce" "$(screen "$SK")" "Plain insight"
refute "a doc does not announce" "$(screen "$SK")" "Plain doc"
call "$FR" note '{"layer":"skill","title":"Global way","summary":"for all","scope":"global"}' >/dev/null
refute "a global skill reaches the project only through the board" "$(screen "$SK")" "new skill Global way ("
check "a global skill reaches the project on the board" "$(txt "$(call "$SK" board '{}')")" "new skill Global way ("
refute "a global skill reaches other projects only through the board" "$(screen "$FG")" "new skill Global way ("
check "a global skill reaches other projects on the board" "$(txt "$(call "$FG" board '{}')")" "new skill Global way ("
row "$RK" rcl 1 active fc "Say hello" ""
row "$RK" rcp 1 pending fc "Say hello pending" "$FR"
row "$RK" rcv 1 revoked fc "Say hello revoked" ""
row global rcg 1 active fc "Say hello global" ""
row global rcm 1 active fc "Say hello masked" ""
row "$RK" rcm 1 revoked fc "Say hello masking" ""
out=$(txt "$(call "$SK" recall '{"query":"say hello"}')")
check "recall lists a fleet tool" "$out" "[tool] rcl: Say hello"
check "recall lists a global tool" "$out" "[tool] rcg: Say hello global"
refute "recall hides another's pending tool" "$out" "rcp"
refute "recall hides a revoked project tool" "$out" "rcv"
refute "a revoked project tool masks the global one" "$out" "rcm"
check "recall matches by name" "$(txt "$(call "$SK" recall '{"query":"rcl"}')")" "[tool] rcl:"
check "initialize teaches fleet tools" "$(rpc "$INIT")" "make it a fleet tool with tool_define"
fi
# quiet posts: stored, not typed; counted on tool results
QW=$(newpane qw)
call "$S" board '{}' >/dev/null   # earlier posts in this project count as seen
call "$QW" board '{}' >/dev/null
out=$(txt "$(call "$S" post '{"text":"quiet news"}')")
check "quiet post is stored" "$out" "posted to the board"
sleep 0.5
refute "quiet post is not typed" "$(screen "$QW")" "quiet news"
out=$(notice "$(call "$QW" list '{}')")
check "tool results count unread posts" "$out" "(1 unread board post; read them with board before your final reply)"
out=$(notice "$(call "$S" list '{}')")
refute "own posts are not unread" "$out" "unread board post"
out=$(txt "$(call "$QW" gather '{"tasks":[{"kind":"send","to":"missing-x","text":"y"}],"timeout":1}')")
printf '%s' "$out" | jq -e . >/dev/null && ok_ || bad "JSON results get no unread line"
board_raw=$(call "$QW" board '{}')
out=$(txt "$board_raw")
check "board shows the post" "$out" "quiet news"
refute "board result has no unread line" "$(notice "$board_raw")" "unread board post"
out=$(notice "$(call "$QW" list '{}')")
refute "board marks posts seen" "$out" "unread board post"
call "$S" post '{"text":"urgent news","urgent":true}' >/dev/null
expect_screen "urgent post is typed at once" "$QW" "urgent news"

fi

# ---- 0.3.0 merge ----
if [ ! -x "$TMPD/bin/claude" ]; then
    cat > "$TMPD/bin/claude" <<'EOF'
#!/bin/sh
for a; do flags="${flags-} ${task-}"; task=$a; done
[ "$(basename "$0")" = codex ] && unset TMUX_PANE
printf 'flags:%s\n%s\n' "$flags" "$task"
case $task in *toolcheck*)
    D=$(dirname "$CNTCTR_DB")
    tn=$(printf '%s\n' "$task" | sed -n 's/^Tool: \([a-z0-9_]*\) version \([0-9]*\)$/\1/p')
    tv=$(printf '%s\n' "$task" | sed -n 's/^Tool: \([a-z0-9_]*\) version \([0-9]*\)$/\2/p')
    mode=${CNTCTR_TEST_VERDICT-approve}
    ask() {
        exec 4>&-
        f=$(mktemp -u "$D/rv.XXXXXX"); mkfifo "$f"
        "$BIN" < "$f" > "$f.out" &
        exec 4> "$f"
        printf '%s\n{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' "$INIT" "$1" "$2" >&4
        for _ in $(seq 100); do jq -e 'select(.id == 2)' "$f.out" >/dev/null 2>&1 && break; sleep 0.1; done
        R=$(jq -r 'select(.id == 2) | .result.content[0].text' "$f.out")
    }
    [ -n "${CNTCTR_TEST_FAST-}" ] || sleep 0.5
    [ "$mode" = none ] && exec cat
    vargs="{\"name\":\"$tn\",\"version\":$tv,\"verdict\":\"$mode\",\"reason\":\"reviewer says $mode\"}"
    if [ -n "${CNTCTR_TEST_FAST-}" ]; then
        ask tool_verdict "$vargs"; printf '%s\n' "$R" > "$D/rev-$tn.first"
    fi
    for _ in $(seq 30); do
        ask use "{\"tool\":\"$tn\",\"args\":{}}"
        case $R in *"not bound yet"*) sleep 1 ;; *) break ;; esac
    done
    printf '%s\n' "$R" > "$D/rev-$tn.use"
    for _ in $(seq 30); do
        ask tool_verdict "$vargs"
        case $R in *"not bound yet"*) sleep 1 ;; *) break ;; esac
    done
    printf '%s\n' "$R" > "$D/rev-$tn.last"
    exec cat ;;
esac
id=$(printf '%s\n' "$task" | sed -n 's/^\[cntctr from=[^ ]* id=\([0-9a-f]\{8\}\)\]$/\1/p')
sleep 0.5
printf '%s\n{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"reply","arguments":{"id":"%s","text":"done %s"}}}\n' \
    "$INIT" "$id" "$id" | "$BIN" >/dev/null
exec cat
EOF
    chmod +x "$TMPD/bin/claude"
    ln -s claude "$TMPD/bin/codex"
    ln -s claude "$TMPD/bin/agy"
    cat > "$TMPD/bin/headroom" <<'EOF'
#!/bin/sh
echo "wrapped:$2"
tool=$2; shift 2; [ "$1" = -- ] && shift
exec "$tool" "$@"
EOF
    chmod +x "$TMPD/bin/headroom"
fi

type tenv >/dev/null 2>&1 || tenv() { t set-environment -g "$1" "$2"; }
type tunset >/dev/null 2>&1 || tunset() { t set-environment -gu "$1"; }
txt() { printf '%s' "$1" | jq -r '(.result.content[0].text // "")'; }

M3_DIR="$(realpath "$TMPD")/m3_repo"
mkdir -p "$M3_DIR"
ln -sf "$BIN" "$TMPD/bin/cntctr"
m3_newpane() {
    local name=$1; shift
    [ $# -gt 0 ] || set -- "$FSH"
    local p; p=$(newpane "$name" -c "$M3_DIR" "$@")
    t set -p -t "$p" @cntctr_harness claude
    echo "$p"
}
M3_P=$(m3_newpane m3_leader)

# T1: tools/list has use, tool_define, tool_revoke and properties post.urgent, gather.wait
out=$(rpc "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | tail -n 1)
for t in use tool_define tool_revoke; do
    check "T1 tools/list has $t" "$out" "\"name\":\"$t\""
done
check "T1 tools/list has post.urgent" "$out" '"urgent":{"type":"boolean"}'
check "T1 tools/list has gather.wait" "$out" '"wait":{"type":"boolean"'

# T2: initialize reports serverInfo.version 0.3.0; --version prints the same
out=$(rpc "$INIT" | tail -n 1)
check "T2 initialize reports serverInfo.version 0.3.0" "$out" '"serverInfo":{"name":"cntctr","version":"0.3.0"}'
ver=$("$BIN" --version 2>&1)
check "T2 --version prints 0.3.0" "$ver" "cntctr 0.3.0"

# T3: two test.sh runs use different tmux socket names
s1=$(t display -p '#{socket_path}')
s2=$(bash -c 'printf "cntctr-test-%s" "$$"')
case $s1 in *"/$SOCKET") [ "$SOCKET" != "$s2" ] && ok_ || bad "T3 two test.sh runs use different tmux socket names" ;; *) bad "T3 current run uses its unique tmux socket" ;; esac

# T4: approve a tool: an unrelated agent's screen is unchanged; its unread count rises
M3_TA4=$(m3_newpane m3_ta4)
M3_UNR4=$(m3_newpane m3_unr4)
call "$M3_UNR4" board '{}' >/dev/null
call "$M3_TA4" tool_define '{"name":"m3_t4","description":"t4 desc","input_schema":{"type":"object"},"interpreter":"sh","script":"true"}' >/dev/null
sq "$CNTCTR_DB" "UPDATE tools SET version=1, status='escalated' WHERE name='m3_t4' AND project='$M3_DIR'"
(cd "$M3_DIR" && "$BIN" tools approve m3_t4 >/dev/null 2>&1)
sleep 0.5
refute "T4 unrelated agent screen unchanged after approve" "$(screen "$M3_UNR4")" "m3_t4"
unr_res=$(notice "$(call "$M3_UNR4" list '{}')")
check "T4 approve raises unread count" "$unr_res" "unread board post"

# T5: revoke a tool: no pane gets text; the board has the notice
M3_TA5=$(m3_newpane m3_ta5)
M3_P5=$(m3_newpane m3_p5)
call "$M3_TA5" tool_define '{"name":"m3_t5","description":"t5 desc","input_schema":{"type":"object"},"interpreter":"sh","script":"true"}' >/dev/null
sq "$CNTCTR_DB" "UPDATE tools SET version=1, status='escalated' WHERE name='m3_t5' AND project='$M3_DIR'"
(cd "$M3_DIR" && "$BIN" tools approve m3_t5 >/dev/null 2>&1)
sleep 0.3
call "$M3_TA5" tool_revoke '{"name":"m3_t5","reason":"obsolete"}' >/dev/null
sleep 0.5
refute "T5 revoke does not type into author pane" "$(screen "$M3_TA5")" "revoked fleet tool m3_t5"
refute "T5 revoke does not type into peer pane" "$(screen "$M3_P5")" "revoked fleet tool m3_t5"
b5=$(txt "$(call "$M3_P5" board '{}')")
check "T5 board has revoke notice" "$b5" "revoked fleet tool m3_t5"

# T6: note layer=skill: a peer's screen is unchanged; the board has the notice
M3_NOTER=$(m3_newpane m3_noter)
M3_PEER6=$(m3_newpane m3_peer6)
call "$M3_PEER6" board '{}' >/dev/null
call "$M3_NOTER" note '{"layer":"skill","title":"M3 Skill","summary":"m3 howto"}' >/dev/null
sleep 0.5
refute "T6 skill note does not type into peer pane" "$(screen "$M3_PEER6")" "new skill M3 Skill"
b6=$(txt "$(call "$M3_PEER6" board '{}')")
check "T6 board has skill notice" "$b6" "new skill M3 Skill"

# T7: reject verdict: the author's screen shows it; a third agent's screen does not
M3_AUTH7=$(m3_newpane m3_auth7)
M3_THIRD7=$(m3_newpane m3_third7)
tenv CNTCTR_TEST_VERDICT reject
call "$M3_AUTH7" tool_define '{"name":"m3_t7","description":"t7 desc","input_schema":{"type":"object"},"interpreter":"sh","script":"true","publish":true}' >/dev/null
expect_screen "T7 reject verdict reaches author" "$M3_AUTH7" "fleet tool m3_t7 v1 was rejected: reviewer says reject"
for _ in $(seq 100); do [ -f "$TMPD/rev-m3_t7.last" ] && break; sleep 0.1; done
refute "T7 third agent does not get reject verdict" "$(screen "$M3_THIRD7")" "was rejected"
tunset CNTCTR_TEST_VERDICT

# T8: cntctr tools promote: no pane gets text; each project board has the notice
M3_DIR8_2="$(realpath "$TMPD")/m3_repo8_2"; mkdir -p "$M3_DIR8_2"
M3_P8_1=$(m3_newpane m3_p8_1)
M3_P8_2=$(newpane m3_p8_2 -c "$M3_DIR8_2" "$FSH")
call "$M3_P8_1" tool_define '{"name":"m3_t8","description":"t8","input_schema":{"type":"object"},"interpreter":"sh","script":"true"}' >/dev/null
sq "$CNTCTR_DB" "UPDATE tools SET version=1, status='escalated' WHERE name='m3_t8' AND project='$M3_DIR'"
(cd "$M3_DIR" && "$BIN" tools approve m3_t8 >/dev/null 2>&1)
call "$M3_P8_1" board '{}' >/dev/null
call "$M3_P8_2" board '{}' >/dev/null
(cd "$M3_DIR" && "$BIN" tools promote m3_t8 >/dev/null 2>&1)
sleep 0.5
refute "T8 promote does not type into project 1 pane" "$(screen "$M3_P8_1")" "promoted fleet tool m3_t8"
refute "T8 promote does not type into project 2 pane" "$(screen "$M3_P8_2")" "promoted fleet tool m3_t8"
b8_1=$(txt "$(call "$M3_P8_1" board '{}')")
b8_2=$(txt "$(call "$M3_P8_2" board '{}')")
check "T8 project 1 board has promote notice" "$b8_1" "promoted fleet tool m3_t8"
check "T8 project 2 board has promote notice" "$b8_2" "promoted fleet tool m3_t8"

# T9: post urgent=true still types into every pane of the project
M3_POST9=$(m3_newpane m3_post9)
M3_PEER9=$(m3_newpane m3_peer9)
call "$M3_POST9" post '{"text":"m3 urgent test 9","urgent":true}' >/dev/null
expect_screen "T9 urgent post types into peer pane" "$M3_PEER9" "m3 urgent test 9"

# T10: post, then gather: content[0] parses as JSON and content[1] holds unread notice
M3_G10_A=$(m3_newpane m3_g10_a)
M3_G10_B=$(m3_newpane m3_g10_b)
call "$M3_G10_A" board '{}' >/dev/null
call "$M3_G10_B" board '{}' >/dev/null
call "$M3_G10_A" post '{"text":"post for t10"}' >/dev/null
raw_g10=$(call "$M3_G10_B" gather '{"tasks":[{"kind":"send","to":"m3_g10_a","text":"t10 ping"}],"timeout":1}')
c0_10=$(printf '%s' "$raw_g10" | jq -r '.result.content[0].text')
c1_10=$(printf '%s' "$raw_g10" | jq -r '.result.content[1].text // empty')
printf '%s' "$c0_10" | jq -e . >/dev/null && ok_ || bad "T10 gather content[0] is valid JSON"
check "T10 gather content[1] holds unread notice" "$c1_10" "unread board post"

# T11: two calls with no new post: the second result has no unread notice; list still has it
M3_P11_A=$(m3_newpane m3_p11_a)
M3_P11_B=$(m3_newpane m3_p11_b)
call "$M3_P11_A" board '{}' >/dev/null
call "$M3_P11_B" board '{}' >/dev/null
call "$M3_P11_A" post '{"text":"post for t11"}' >/dev/null
daemon_start "$M3_P11_B"
for id11 in 2 3 4; do
    tool11=project
    [ "$id11" -eq 4 ] && tool11=list
    daemon_send "$(printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"%s","arguments":{}}}' "$id11" "$tool11")"
    for _ in $(seq 600); do jq -e "select(.id == $id11)" "$DOUT" >/dev/null 2>&1 && break; sleep 0.1; done
done
res11_1=$(jq -c 'select(.id == 2)' "$DOUT")
res11_2=$(jq -c 'select(.id == 3)' "$DOUT")
res11_3=$(jq -c 'select(.id == 4)' "$DOUT")
daemon_stop
check "T11 first call gets unread notice" "$(notice "$res11_1")" "unread board post"
refute "T11 second call has no unread notice" "$(notice "$res11_2")" "unread board post"
check "T11 list still has unread notice" "$(notice "$res11_3")" "unread board post"

# T12: a fleet tool that calls cntctr call board: fd 3 reply has no notice; outer use result has it
M3_P12_A=$(m3_newpane m3_p12_a)
M3_P12_B=$(m3_newpane m3_p12_b)
call "$M3_P12_A" board '{}' >/dev/null
call "$M3_P12_B" board '{}' >/dev/null
m3_def12='{"name":"m3_t12","description":"calls board","input_schema":{"type":"object"},"interpreter":"sh","script":"cntctr call board \"{}\""}'
call "$M3_P12_B" tool_define "$m3_def12" >/dev/null
call "$M3_P12_A" post '{"text":"post for t12"}' >/dev/null
raw_u12=$(call "$M3_P12_B" use '{"tool":"m3_t12"}')
c0_12=$(printf '%s' "$raw_u12" | jq -r '.result.content[0].text // empty')
c1_12=$(printf '%s' "$raw_u12" | jq -r '.result.content[1].text // empty')
check "T12 fd 3 board call returned the post" "$c0_12" "post for t12"
refute "T12 fd 3 reply has no notice" "$c0_12" "unread board post"
check "T12 outer use result has unread notice" "$c1_12" "unread board post"

# T13: reply while sender shows permission prompt falls back to board
M3_S13=$(m3_newpane m3_s13 "$FSH")
M3_W13=$(m3_newpane m3_w13)
tid13=$(txt "$(call "$M3_S13" send '{"to":"m3_w13","text":"task 13"}')" | sed 's/sent id=//')
t send-keys -t "$M3_S13" "printf 'Do you want to proceed?'" Enter
expect_screen "T13 sender prompt visible" "$M3_S13" "Do you want to proceed?"
rep13_raw=$(call "$M3_W13" reply "{\"id\":\"$tid13\",\"text\":\"done 13\"}")
rep13=$(txt "$rep13_raw")
same "T13 board fallback is a successful reply" "$(iserr "$rep13_raw")" "false"
check "T13 reply result says on the board" "$rep13" "on the board"
b13=$(sq "$CNTCTR_DB" "SELECT text FROM posts WHERE scope='$M3_DIR' AND text LIKE '%reply id=$tid13%'")
check "T13 sender project board has fallback" "$b13" "for m3_s13 (reply id=$tid13):"
t send-keys -t "$M3_S13" C-c Enter
s13_next=$(call "$M3_S13" project '{}')
check "T13 sender next result says reply waiting" "$s13_next" "reply is waiting"

# T14: kill sender pane, then reply from another project: board post and history in sender project
M3_DIR14_1="$(realpath "$TMPD")/m3_repo14_1"; mkdir -p "$M3_DIR14_1"
M3_DIR14_2="$(realpath "$TMPD")/m3_repo14_2"; mkdir -p "$M3_DIR14_2"
M3_S14=$(newpane m3_s14 -c "$M3_DIR14_1" "$FSH")
M3_W14=$(newpane m3_w14 -c "$M3_DIR14_2" "$FSH")
tid14=$(txt "$(call "$M3_S14" send '{"to":"m3_w14","text":"task 14"}')" | sed 's/sent id=//')
t kill-pane -t "$M3_S14"
call "$M3_W14" reply "{\"id\":\"$tid14\",\"text\":\"done 14\"}" >/dev/null
b14=$(sq "$CNTCTR_DB" "SELECT text FROM posts WHERE scope='$M3_DIR14_1' AND text LIKE '%reply id=$tid14%'")
check "T14 board post is in sender project" "$b14" "for m3_s14 (reply id=$tid14):"
h14=$(sq "$CNTCTR_DB" "SELECT body FROM entries WHERE scope='$M3_DIR14_1' AND layer='history' AND body LIKE '%done 14%'")
check "T14 history entry is in sender project" "$h14" "done 14"

# T15: gather times out, caller at permission prompt, worker replies late: text on board
M3_C15=$(m3_newpane m3_c15 "$FSH")
M3_W15=$(m3_newpane m3_w15)
call "$M3_C15" gather '{"tasks":[{"kind":"send","to":"m3_w15","text":"slow task 15"}],"timeout":1}' >/dev/null
tid15=$(lastid "$M3_W15")
t send-keys -t "$M3_C15" "printf 'Do you want to proceed?'" Enter
expect_screen "T15 caller in prompt" "$M3_C15" "Do you want to proceed?"
call "$M3_W15" reply "{\"id\":\"$tid15\",\"text\":\"late answer 15\"}" >/dev/null
b15=$(sq "$CNTCTR_DB" "SELECT text FROM posts WHERE scope='$M3_DIR' AND text LIKE '%late answer 15%'")
check "T15 late gather reply is on the board" "$b15" "late answer 15"
t send-keys -t "$M3_C15" C-c Enter

# T16: author pane dead at verdict: verdict is on board with for <author>
M3_A16=$(m3_newpane m3_a16)
call "$M3_A16" tool_define '{"name":"m3_t16","description":"t16 desc","input_schema":{"type":"object"},"interpreter":"sh","script":"true"}' >/dev/null
sq "$CNTCTR_DB" "UPDATE tools SET version=1, status='escalated' WHERE name='m3_t16' AND project='$M3_DIR'"
t kill-pane -t "$M3_A16"
(cd "$M3_DIR" && "$BIN" tools reject m3_t16 >/dev/null 2>&1)
b16=$(sq "$CNTCTR_DB" "SELECT text FROM posts WHERE scope='$M3_DIR' AND text LIKE '%for m3_a16%'")
check "T16 verdict on board for author" "$b16" "for m3_a16"

# T17: injected send ends with [cntctr end id=<id>]
M3_S17=$(m3_newpane m3_s17)
M3_R17=$(m3_newpane m3_r17)
tid17=$(txt "$(call "$M3_S17" send '{"to":"m3_r17","text":"t17 msg"}')" | sed 's/sent id=//')
expect_screen "T17 header received" "$M3_R17" "[cntctr from=m3_s17 id=$tid17]"
expect_screen "T17 envelope ends with end tag" "$M3_R17" "[cntctr end id=$tid17]"
guide17=$(rpc "$INIT" | tail -n 1 | jq -r '.result.instructions')
check "T17 instructions explain the end marker" "$guide17" "cntctr end id="
check "T17 instructions tell agent to ask for resend" "$guide17" "resend"

# T18: send re=<open id> adds to task
M3_S18=$(m3_newpane m3_s18)
M3_W18=$(m3_newpane m3_w18)
call "$M3_S18" gather '{"tasks":[{"kind":"send","to":"m3_w18","text":"t18 initial"}],"timeout":30}' > "$TMPD/m3-gather18" & gather18_pid=$!
expect_screen "T18 gather dispatched original task" "$M3_W18" "t18 initial"
tid18=$(lastid "$M3_W18")
call "$M3_S18" send "{\"to\":\"m3_w18\",\"text\":\"t18 follow up\",\"re\":\"$tid18\"}" >/dev/null
tasks18=$(txt "$(call "$M3_S18" list '{}')" | grep "m3_w18" | grep -o 'tasks=[^ ]*' | tr ',' '\n' | wc -l | tr -d ' ')
same "T18a list shows one open task for worker" "$tasks18" "1"
call "$M3_W18" reply "{\"id\":\"$tid18\",\"text\":\"t18 answer\"}" >/dev/null
expect_screen "T18b envelope has original id and addendum" "$M3_W18" "[cntctr from=m3_s18 id=$tid18 addendum]"
wait "$gather18_pid"
gather18=$(txt "$(cat "$TMPD/m3-gather18")")
same "T18c one reply completes gather" "$(printf '%s' "$gather18" | jq -r '.complete')" "true"
same "T18c gather completes original id" "$(printf '%s' "$gather18" | jq -r '.results[0].id')" "$tid18"
same "T18c gather records answer" "$(printf '%s' "$gather18" | jq -r '.results[0].text')" "t18 answer"

# T19: send re=<unknown id> errors
M3_S19=$(m3_newpane m3_s19)
M3_W19=$(m3_newpane m3_w19)
err19_raw=$(call "$M3_S19" send '{"to":"m3_w19","text":"hello","re":"deadbeef"}')
err19=$(txt "$err19_raw")
same "T19 unknown re is an error" "$(iserr "$err19_raw")" "true"
check "T19 error names id" "$err19" "deadbeef"
check "T19 error says to omit re" "$err19" "omit 're'"

# T20: tool prints 20 KB ending FINAL
M3_P20=$(m3_newpane m3_p20)
m3_def20='{"name":"m3_t20","description":"prints 20k","input_schema":{"type":"object"},"interpreter":"sh","script":"python3 -c \"print(\\\"START\\\" + \\\"A\\\"*20000 + \\\"FINAL\\\")\""}'
call "$M3_P20" tool_define "$m3_def20" >/dev/null
res20_raw=$(call "$M3_P20" use '{"tool":"m3_t20"}')
res20=$(txt "$res20_raw")
len20=${#res20}
[ "$len20" -lt 16384 ] && ok_ || bad "T20 result under 16 KB" "got $len20 bytes"
check "T20 result contains FINAL" "$res20" "FINAL"
check "T20 result keeps first 8 KB" "$res20" "START"
fpath20=$(printf '%s\n' "$res20" | grep -o '/[^ "]*cntctr[^ "]*/[^ "]*')
[ -n "$fpath20" ] && [ -f "$fpath20" ] && [ "$(wc -c < "$fpath20")" -ge 20005 ] && ok_ || bad "T20 file holds all 20 KB"
if [ -n "$fpath20" ] && [ -f "$fpath20" ]; then
    touch -t 202001010000 "$fpath20"
    call "$M3_P20" use '{"tool":"m3_t20"}' >/dev/null
    [ ! -e "$fpath20" ] && ok_ || bad "T20 output file older than 24 h is removed on next output"
fi

# T21: tool prints 300 KB: error names file holding output
M3_P21=$(m3_newpane m3_p21)
m3_def21='{"name":"m3_t21","description":"prints 300k","input_schema":{"type":"object"},"interpreter":"sh","script":"python3 -c \"print(\\\"B\\\"*300000)\""}'
call "$M3_P21" tool_define "$m3_def21" >/dev/null
res21_raw=$(call "$M3_P21" use '{"tool":"m3_t21"}')
same "T21 hard cap returns an error" "$(iserr "$res21_raw")" "true"
err21=$(txt "$res21_raw")
fpath21=$(printf '%s\n' "$err21" | grep -o '/[^ "]*cntctr[^ "]*/[^ "]*')
[ -n "$fpath21" ] && [ -f "$fpath21" ] && [ "$(wc -c < "$fpath21")" -ge 262144 ] && ok_ || bad "T21 captured file holds 300 KB output"

# T22: tool writes 20 KB then FINAL ERROR to stderr and exits 1
M3_P22=$(m3_newpane m3_p22)
m3_def22='{"name":"m3_t22","description":"stderr 20k","input_schema":{"type":"object"},"interpreter":"sh","script":"python3 -c \"import sys; sys.stderr.write(\\\"E\\\"*20000 + \\\"FINAL ERROR\\\"); sys.exit(1)\""}'
call "$M3_P22" tool_define "$m3_def22" >/dev/null
res22_raw=$(call "$M3_P22" use '{"tool":"m3_t22"}')
err22=$(txt "$res22_raw")
same "T22 failed tool reports an error" "$(iserr "$res22_raw")" "true"
check "T22 error contains FINAL ERROR" "$err22" "FINAL ERROR"

# T23: a tool calling a 20 KB tool over fd 3 receives all 20 KB
M3_P23=$(m3_newpane m3_p23)
m3_def23_sub='{"name":"m3_t23_sub","description":"sub 20k","input_schema":{"type":"object"},"interpreter":"sh","script":"python3 -c \"print(\\\"C\\\"*20000 + \\\"CALLEE_DONE\\\")\""}'
call "$M3_P23" tool_define "$m3_def23_sub" >/dev/null
script23='out=$(cntctr call use "{\"tool\":\"m3_t23_sub\"}"); printf "FD3_C_COUNT=%s\n" "$(printf %s "$out" | tr -cd C | wc -c | tr -d " ")"; case "$out" in *CALLEE_DONE*) echo CALLEE_DONE;; esac'
m3_def23_main=$(jq -nc --arg s "$script23" '{name:"m3_t23_main",description:"calls sub",input_schema:{type:"object"},interpreter:"sh",script:$s}')
call "$M3_P23" tool_define "$m3_def23_main" >/dev/null
res23_raw=$(call "$M3_P23" use '{"tool":"m3_t23_main"}')
res23=$(txt "$res23_raw")
check "T23 fd 3 receives all 20 KB" "$res23" "FD3_C_COUNT=20001"
check "T23 fd 3 includes end marker" "$res23" "CALLEE_DONE"

# T24: send to unknown agent mentions list and spawn
M3_P24=$(m3_newpane m3_p24)
err24=$(txt "$(call "$M3_P24" send '{"to":"m3_unknown_xyz","text":"hi"}')")
check "T24 send to unknown agent mentions list" "$err24" "list"
check "T24 send to unknown agent mentions spawn" "$err24" "spawn"

# T25: tools/list descriptions and list.from
out25=$(rpc "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | tail -n 1)
has_from=$(printf '%s' "$out25" | jq -r '.result.tools[] | select(.name=="list") | .inputSchema.properties.from.type // empty')
check "T25 list has from" "$has_from" "string"
td_desc=$(printf '%s' "$out25" | jq -r '.result.tools[] | select(.name=="tool_define") | .description')
check "T25 tool_define mentions stdin" "$td_desc" "stdin"
check "T25 tool_define mentions stdout" "$td_desc" "stdout"
check "T25 tool_define mentions cntctr call" "$td_desc" "cntctr call"
gather_desc=$(printf '%s' "$out25" | jq -r '.result.tools[] | select(.name=="gather") | .description')
for field in kind to text wait timeout; do check "T25 gather describes $field" "$gather_desc" "$field"; done
gather_schema=$(printf '%s' "$out25" | jq -c '.result.tools[] | select(.name=="gather") | .inputSchema')
check "T25 gather has top-level timeout" "$gather_schema" '"timeout":'
use_from=$(printf '%s' "$out25" | jq -r '.result.tools[] | select(.name=="use") | .inputSchema.properties.from.type // empty')
same "T25 use accepts from" "$use_from" "string"
post_desc=$(printf '%s' "$out25" | jq -r '.result.tools[] | select(.name=="post") | .description')
check "T25 post mentions note" "$post_desc" "note"
note_desc=$(printf '%s' "$out25" | jq -r '.result.tools[] | select(.name=="note") | .description')
check "T25 note mentions reply" "$note_desc" "reply"
tr_desc=$(printf '%s' "$out25" | jq -r '.result.tools[] | select(.name=="tool_revoke") | .description')
check "T25 tool_revoke mentions tool_verdict" "$tr_desc" "tool_verdict"
for state in active pending escalated; do check "T25 tool_revoke describes $state tool" "$tr_desc" "$state"; done

# T26: tools/list has tool_verdict only for bound reviewers
M3_ORD26=$(m3_newpane m3_ord26)
M3_REV26=$(m3_newpane m3_rev26)
sq "$CNTCTR_DB" "INSERT INTO tools(project,name,version,status,author,description,input_schema,interpreter,script,reviewer_pane,reviewer) VALUES ('$M3_DIR','m3_t26',1,'pending','fc','t26','{\"type\":\"object\"}','sh','true','$M3_REV26','m3_rev26')"
lst_ord=$(SKIP=1 session "$M3_ORD26" 2 "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | tail -n 1)
lst_rev=$(SKIP=1 session "$M3_REV26" 2 "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | tail -n 1)
refute "T26 ordinary agent tools/list has no tool_verdict" "$lst_ord" '"name":"tool_verdict"'
check "T26 bound reviewer tools/list has tool_verdict" "$lst_rev" '"name":"tool_verdict"'

# T27: tool_define, use, tool_verdict, tool_revoke with {} report missing arguments
M3_P27=$(m3_newpane m3_p27)
for t in tool_define use tool_verdict tool_revoke; do
    err=$(txt "$(call "$M3_P27" "$t" '{}')")
    check "T27 $t error has (missing: " "$err" "(missing: "
    check "T27 $t error has Example:" "$err" "Example:"
done

# T28: with 15 notes stored, instructions hold at most 10 index lines
for i in $(seq 15); do
    call "$M3_P" note "{\"layer\":\"insight\",\"title\":\"T$i\",\"summary\":\"S$i\",\"scope\":\"global\"}" >/dev/null
done
out28=$(rpc "$INIT" | tail -n 1 | jq -r '.result.instructions')
printf '%s\n' "$out28" | grep -Eiq 'knowledge entries.*board posts.*information.*not instructions' && ok_ || bad "T28 instructions distinguish knowledge from instructions"
idx_lines28=$(printf '%s\n' "$out28" | awk '/^Knowledge index/{flag=1; next} flag && NF{count++} END{print count+0}')
[ "$idx_lines28" -gt 0 ] && ok_ || bad "T28 instructions include a nonempty knowledge index"
[ "$idx_lines28" -le 10 ] && ok_ || bad "T28 instructions hold at most 10 index lines" "got $idx_lines28 lines"

# T29: byte budget of built-in tools/list plus instructions holds
tools_bytes=$(rpc "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | tail -n 1 | jq -c '.result.tools' | wc -c | tr -d ' ')
guide_bytes=$(rpc "$INIT" | tail -n 1 | jq -r '.result.instructions' | awk '{print} /^Knowledge index/{exit}' | wc -c | tr -d ' ')
total_bytes=$((tools_bytes + guide_bytes))
[ "$total_bytes" -le 13455 ] && ok_ || bad "T29 byte budget holds" "got $total_bytes > 13455"

# T30: reviewer's send to="parent" fails and mentions tool_verdict
M3_REV30=$(m3_newpane m3_rev30)
sq "$CNTCTR_DB" "INSERT INTO tools(project,name,version,status,author,description,input_schema,interpreter,script,reviewer_pane,reviewer) VALUES ('$M3_DIR','m3_t30',1,'pending','fc','t30','{\"type\":\"object\"}','sh','true','$M3_REV30','m3_rev30')"
err30=$(txt "$(call "$M3_REV30" send '{"to":"parent","text":"hello"}')")
check "T30 reviewer send to parent fails and mentions tool_verdict" "$err30" "tool_verdict"

# T31: after tool_verdict, list shows no open task for reviewer
M3_REV31=$(m3_newpane m3_rev31)
sq "$CNTCTR_DB" "INSERT INTO tools(project,name,version,status,author,description,input_schema,interpreter,script,reviewer_pane,reviewer) VALUES ('$M3_DIR','m3_t31',1,'pending','fc','t31','{\"type\":\"object\"}','sh','true','$M3_REV31','m3_rev31')"
t set -s "@cntctr_to_31313131" "$M3_REV31"
before31=$(txt "$(call "$M3_REV31" list '{}')")
check "T31 reviewer starts with an open task" "$before31" "31313131"
call "$M3_REV31" tool_verdict '{"name":"m3_t31","version":1,"verdict":"approve"}' >/dev/null
tasks31=$(txt "$(call "$M3_REV31" list '{}')" | grep "m3_rev31" | grep -o 'tasks=[^ ]*')
same "T31 after tool_verdict list shows no open task for reviewer" "$tasks31" ""

# T32: reviewer task fences script with longer backtick fence
M3_A32=$(m3_newpane m3_a32)
tenv CNTCTR_TEST_VERDICT none
s32=$(printf 'echo "``````"\necho "```````"\necho INSTRUCTION_LINE')
m3_def32=$(jq -nc --arg s "$s32" '{name:"m3_t32",description:"t32",input_schema:{type:"object"},interpreter:"sh",script:$s,publish:true}')
call "$M3_A32" tool_define "$m3_def32" >/dev/null
tunset CNTCTR_TEST_VERDICT
rev32=$(sq "$CNTCTR_DB" "SELECT reviewer_pane FROM tools WHERE name='m3_t32' AND project='$M3_DIR'")
task32=""
[ -n "$rev32" ] && task32=$(screen "$rev32")
check "T32 reviewer task uses fence longer than script backticks" "$task32" '````````'
check "T32 reviewer task keeps instruction inside fence" "$task32" 'echo INSTRUCTION_LINE'
fenced32=$(printf '%s\n' "$task32" | python3 -c 'import re,sys; s=sys.stdin.read(); m=re.search(r"(?ms)^[ \t]*(`{8,})(?:sh|bash)?[ \t]*\n(.*?)^[ \t]*\1[ \t]*$",s); print("yes" if m and "echo INSTRUCTION_LINE" in m.group(2) else "no")')
same "T32 instruction line lies between matching fences" "$fenced32" "yes"

# T33: list_changed arrives on draft define, publish, and expiry
M3_P33=$(m3_newpane m3_p33)
daemon_start "$M3_P33"
sleep 0.2
call "$M3_P33" tool_define '{"name":"m3_t33_d","description":"d","input_schema":{"type":"object"},"interpreter":"sh","script":"true"}' >/dev/null
sleep 0.3
lc_draft=$(grep -c 'notifications/tools/list_changed' "$DOUT" 2>/dev/null || true)
[ "${lc_draft:-0}" -ge 1 ] && ok_ || bad "T33a draft define sends list_changed"
tenv CNTCTR_TEST_VERDICT none
call "$M3_P33" tool_define '{"name":"m3_t33_p","description":"p","input_schema":{"type":"object"},"interpreter":"sh","script":"true","publish":true}' >/dev/null
tunset CNTCTR_TEST_VERDICT
sleep 0.3
lc_pub=$(grep -c 'notifications/tools/list_changed' "$DOUT" 2>/dev/null || true)
[ "${lc_pub:-0}" -gt "${lc_draft:-0}" ] && ok_ || bad "T33b publish sends list_changed"
sq "$CNTCTR_DB" "INSERT INTO tools(project,name,version,status,author,description,input_schema,interpreter,script,deadline) VALUES ('$M3_DIR','m3_t33_exp',1,'pending','fc','exp','{\"type\":\"object\"}','sh','true',strftime('%s','now') - 100)"
(cd "$M3_DIR" && "$BIN" tools list >/dev/null 2>&1)
sleep 0.3
lc_exp=$(grep -c 'notifications/tools/list_changed' "$DOUT" 2>/dev/null || true)
[ "${lc_exp:-0}" -gt "${lc_pub:-0}" ] && ok_ || bad "T33c expiry sends list_changed"
daemon_stop

# T34: pending review with past deadline escalated in cntctr tools list
sq "$CNTCTR_DB" "INSERT INTO tools(project,name,version,status,author,description,input_schema,interpreter,script,deadline) VALUES ('$M3_DIR','m3_overdue34',1,'pending','fc','overdue','{\"type\":\"object\"}','sh','true',strftime('%s','now') - 100)"
out34=$(cd "$M3_DIR" && "$BIN" tools list 2>&1)
check "T34 tools list shows escalated" "$out34" "m3_overdue34 v1 escalated"

# T35: failed tool history entry contains stderr
M3_P35=$(m3_newpane m3_p35)
script35="python3 -c 'import sys; sys.stderr.write(\"E\"*1000 + \"boom\"); sys.exit(3)'"
m3_def35=$(jq -nc --arg s "$script35" '{name:"m3_fail35",description:"fails",input_schema:{type:"object"},interpreter:"sh",script:$s}')
call "$M3_P35" tool_define "$m3_def35" >/dev/null
call "$M3_P35" use '{"tool":"m3_fail35"}' >/dev/null
hist35=$(sq "$CNTCTR_DB" "SELECT body FROM entries WHERE scope='$M3_DIR' AND layer='history' AND title LIKE '%tool m3_fail35%'")
check "T35 history contains boom" "$hist35" "boom"
count35=$(printf '%s' "$hist35" | tr -cd E | wc -c | tr -d ' ')
case $hist35 in *boom*) [ "$count35" -le 200 ] && ok_ || bad "T35 history reason stays within 200 bytes" "got $count35 stderr bytes" ;; *) bad "T35 cannot measure reason cap without recorded reason" ;; esac

# T36: three posts, board limit=1 says 2 older unread posts were not shown
M3_P36_A=$(m3_newpane m3_p36_a)
M3_P36_B=$(m3_newpane m3_p36_b)
call "$M3_P36_A" board '{}' >/dev/null
call "$M3_P36_B" board '{}' >/dev/null
call "$M3_P36_A" post '{"text":"post 1 for t36"}' >/dev/null
call "$M3_P36_A" post '{"text":"post 2 for t36"}' >/dev/null
call "$M3_P36_A" post '{"text":"post 3 for t36"}' >/dev/null
b36=$(txt "$(call "$M3_P36_B" board '{"limit":1}')")
check "T36 board limit shows newest post" "$b36" "post 3 for t36"
refute "T36 board limit hides first older post" "$b36" "post 1 for t36"
refute "T36 board limit hides second older post" "$b36" "post 2 for t36"
check "T36 board result mentions 2 older unread posts" "$b36" "2 older unread post"

# T37a: list with from=%pane of an untagged live pane shows it alive
U37=$(t new-window -d -c "$M3_DIR" -P -F '#{pane_id}' sh)
out37a=$(txt "$(call "$M3_P" list "{\"from\":\"$U37\"}")")
check "T37a untagged live pane shows alive" "$out37a" "$U37 alive idle"
t kill-pane -t "$U37" 2>/dev/null

# T37b: a 0755 temp dir still delivers list_changed
DIR755="$(mktemp -d /tmp/cntctr-test755.XXXXXX)"
chmod 0755 "$DIR755"
mkdir -m 0755 "$DIR755/cntctr-$(id -u)"
M3_P37B=$(m3_newpane m3_p37b)
TMPDIR="$DIR755" daemon_start "$M3_P37B"
sleep 0.2
TMPDIR="$DIR755" call "$M3_P37B" tool_define '{"name":"m3_t37b","description":"notify through repaired directory","input_schema":{"type":"object"},"interpreter":"sh","script":"true"}' >/dev/null
sleep 0.5
out37b=$(cat "$DOUT")
mode37b=$(stat -f '%Lp' "$DIR755/cntctr-$(id -u)" 2>/dev/null || stat -c '%a' "$DIR755/cntctr-$(id -u)")
TMPDIR="$DIR755" daemon_stop
rm -rf "$DIR755"
check "T37b 0755 temp dir still delivers list_changed" "$out37b" "notifications/tools/list_changed"
same "T37b stale temp directory is private" "$mode37b" "700"

# T37c: EXPLAIN QUERY PLAN of board query uses an index
plan37c=$(sq "$CNTCTR_DB" "EXPLAIN QUERY PLAN SELECT text FROM posts WHERE scope='test' ORDER BY at ASC")
check "T37c board query uses index" "$plan37c" "USING INDEX"

# T37d: task "preview the UI" routes standard
out37d=$(txt "$(call "$M3_P" spawn '{"harness":"claude","name":"m3_prev37","task":"preview the UI"}')")
check "T37d preview task routes standard" "$out37d" "claude-sonnet-5-5"

# T37e: with CNTCTR_MAX_AGENTS=2 the third spawn fails and names the variable
limit37e=$(t list-panes -a -F '#{@cntctr_name}' | grep -c . || true)
limit37e=$((limit37e + 2))
first37e=$(CNTCTR_MAX_AGENTS=$limit37e call "$M3_P" spawn '{"harness":"claude","name":"m3_ma1","task":"t1"}')
second37e=$(CNTCTR_MAX_AGENTS=$limit37e call "$M3_P" spawn '{"harness":"claude","name":"m3_ma2","task":"t2"}')
same "T37e first spawn below limit succeeds" "$(iserr "$first37e")" "false"
same "T37e second spawn at limit succeeds" "$(iserr "$second37e")" "false"
res37e=$(CNTCTR_MAX_AGENTS=$limit37e call "$M3_P" spawn '{"harness":"claude","name":"m3_ma3","task":"t3"}')
err37e=$(txt "$res37e")
same "T37e third spawn is an error" "$(iserr "$res37e")" "true"
check "T37e third spawn fails and names CNTCTR_MAX_AGENTS" "$err37e" "CNTCTR_MAX_AGENTS"
check "T37e limit error suggests killing idle agents" "$err37e" "kill idle"
check "T37e limit error suggests raising the limit" "$err37e" "raise"

# T38: macOS sandbox hardlinks and unix sockets
if [ "$(uname)" = "Darwin" ]; then
    echo "ORIGINAL_38" > "$TMPD/outside38.txt"
    m3_def38a=$(jq -nc --arg f "$TMPD/outside38.txt" '{name:"m3_t38a",description:"hl test",input_schema:{type:"object"},interpreter:"sh",script:("ln " + $f + " ./link.txt && echo OVERWRITTEN > ./link.txt")}')
res38a_def=$(call "$M3_P" tool_define "$m3_def38a")
same "T38a hardlink tool is defined" "$(iserr "$res38a_def")" "false"
res38a_raw=$(call "$M3_P" use '{"tool":"m3_t38a"}')
same "T38a hardlink attempt is rejected" "$(iserr "$res38a_raw")" "true"
[ ! -e "$M3_DIR/link.txt" ] && ok_ || bad "T38a hardlink was created inside tool root"
    outside38=$(cat "$TMPD/outside38.txt")
    same "T38a hardlink write leaves outside file unchanged" "$outside38" "ORIGINAL_38"

    sock38="$TMPD/outside38.sock"
    rm -f "$sock38"
python3 -c "import socket,time; s = socket.socket(socket.AF_UNIX); s.bind('$sock38'); s.listen(2); time.sleep(30)" &
    py_sock_pid=$!
for _ in $(seq 30); do [ -S "$sock38" ] && break; sleep 0.1; done
python3 -c "import socket; s = socket.socket(socket.AF_UNIX); s.connect('$sock38'); s.close()" && ok_ || bad "T38b outside Unix socket is reachable before sandbox test"
    m3_def38b=$(jq -nc --arg s "$sock38" '{name:"m3_t38b",description:"sock test",net:false,input_schema:{type:"object"},interpreter:"sh",script:("python3 -c \"import socket; s = socket.socket(socket.AF_UNIX); s.connect('"'"'" + $s + "'"'"'); print('"'"'CONNECTED'"'"')\"")}')
res38b_def=$(call "$M3_P" tool_define "$m3_def38b")
same "T38b socket tool is defined" "$(iserr "$res38b_def")" "false"
res38b_raw=$(call "$M3_P" use '{"tool":"m3_t38b"}')
out38b=$(txt "$res38b_raw")
same "T38b outside Unix socket connection is rejected" "$(iserr "$res38b_raw")" "true"
    check "T38b net=false tool cannot connect to outside unix socket" "$out38b" "PermissionError: [Errno 1] Operation not permitted"
    kill $py_sock_pid 2>/dev/null; rm -f "$sock38"
fi

# T39: redelivery of addressed text
M3_S39=$(m3_newpane m3_s39 "$FSH")
M3_W39=$(m3_newpane m3_w39)
tid39=$(txt "$(call "$M3_S39" send '{"to":"m3_w39","text":"task 39"}')" | sed 's/sent id=//')
daemon_start "$M3_S39"
sleep 0.2
t send-keys -t "$M3_S39" "printf 'Do you want to proceed?'" Enter
expect_screen "T39 sender prompt" "$M3_S39" "Do you want to proceed?"
# Record every delivered=1 update, so a repeated delivery mark cannot hide behind the final boolean.
sq "$CNTCTR_DB" "CREATE TABLE m3_deliveries39(post INTEGER); CREATE TRIGGER m3_deliveries39 AFTER UPDATE OF delivered ON mail WHEN NEW.delivered=1 BEGIN INSERT INTO m3_deliveries39 VALUES(NEW.post); END"
call "$M3_W39" reply "{\"id\":\"$tid39\",\"text\":\"reply 39 text\"}" >/dev/null
call "$M3_W39" post '{"text":"ordinary unaddressed post 39"}' >/dev/null
t send-keys -t "$M3_S39" C-c
t send-keys -t "$M3_S39" clear Enter
# A raw receiver prints each paste once; interactive sh redraws its multiline input.
t send-keys -t "$M3_S39" 'stty -echo; exec cat' Enter
post39=$(sq "$CNTCTR_DB" "SELECT rowid FROM posts WHERE scope='$M3_DIR' AND text LIKE 'for m3_s39 (reply id=$tid39):%'")
mail39() {
    sq "$CNTCTR_DB" "SELECT count(*) FROM mail WHERE post=$post39 AND delivered=1; SELECT count(*) FROM m3_deliveries39 WHERE post=$post39" | tr '\n' ':'
    screen "$M3_S39" | grep -cxF "[cntctr end id=$tid39]" || true
}
delivered39=0
for _ in $(seq 600); do
    delivered39=$(mail39)
    [ "$delivered39" = "1:1:1" ] && break
    sleep 0.1
done
same "T39 reply is redelivered exactly once" "$delivered39" "1:1:1"
# T44: delivered mail no longer counts as unread
sq "$CNTCTR_DB" "UPDATE posts SET at=at-90000 WHERE scope='$M3_DIR' AND rowid != $post39"
refute "T44 delivered fallback is not unread" "$(notice "$(call "$M3_S39" list '{}')")" "unread board post"
call "$M3_S39" board '{}' >/dev/null
sleep 0.5
same "T39 later board call does not redeliver" "$(mail39)" "1:1:1"
refute "T39 ordinary post is not typed" "$(screen "$M3_S39")" "ordinary unaddressed post 39"

# T40-T43: digest, age, post limit, and private fallback mail
M3_DIR40="$(realpath "$TMPD")/m3_repo40"; mkdir -p "$M3_DIR40"
M3_A40=$(newpane m3_a40 -c "$M3_DIR40" "$FSH")
M3_B40=$(newpane m3_b40 -c "$M3_DIR40" "$FSH")
guide40=$(printf '%s\n' "$INIT" | "$BIN" | tail -n 1 | jq -r '.result.instructions')
check "T40 instructions request board before final" "$guide40" "before your final reply"
check "T42 post description directs one agent to send" "$post_desc" "use send"
call "$M3_A40" post '{"text":"old news 41"}' >/dev/null
check "T40 notice requests board before final" "$(notice "$(call "$M3_B40" list '{}')")" "before your final reply"
sq "$CNTCTR_DB" "UPDATE posts SET at=at-90000 WHERE scope='$M3_DIR40'"
refute "T41 old post is not unread" "$(notice "$(call "$M3_B40" list '{}')")" "unread board post"
check "T41 board still lists old post" "$(txt "$(call "$M3_B40" board '{}')")" "old news 41"
call "$M3_A40" post '{"text":"new news 41"}' >/dev/null
check "T41 new post is unread" "$(notice "$(call "$M3_B40" list '{}')")" "1 unread board post"
text501=$(printf '%0501d' 0)
text500=$(printf '%0500d' 0)
count42=$(sq "$CNTCTR_DB" "SELECT count(*) FROM posts WHERE scope='$M3_DIR40'")
res42=$(call "$M3_A40" post "$(jq -nc --arg text "$text501" '{text:$text}')")
same "T42 501 bytes rejected" "$(iserr "$res42")" "true"
check "T42 error says note" "$(txt "$res42")" "note"
check "T42 error says send" "$(txt "$res42")" "send"
same "T42 rejected post stores nothing" "$(sq "$CNTCTR_DB" "SELECT count(*) FROM posts WHERE scope='$M3_DIR40'")" "$count42"
same "T42 500 bytes accepted" "$(iserr "$(call "$M3_A40" post "$(jq -nc --arg text "$text500" '{text:$text}')")")" "false"
count42u=$(sq "$CNTCTR_DB" "SELECT count(*) FROM posts WHERE scope='$M3_DIR40'")
res42u=$(call "$M3_A40" post "$(jq -nc --arg text "$text501" '{text:$text,urgent:true}')")
same "T42 urgent 501 bytes rejected" "$(iserr "$res42u")" "true"
same "T42 rejected urgent post stores nothing" "$(sq "$CNTCTR_DB" "SELECT count(*) FROM posts WHERE scope='$M3_DIR40'")" "$count42u"
refute "T42 urgent rejected text not typed" "$(screen "$M3_B40")" "$text501"
M3_DIR43="$(realpath "$TMPD")/m3_repo43"; mkdir -p "$M3_DIR43"
M3_A43=$(newpane m3_a43 -c "$M3_DIR43" "$FSH")
M3_B43=$(newpane m3_b43 -c "$M3_DIR43" "$FSH")
M3_W43=$(newpane m3_w43 -c "$M3_DIR43" "$FSH")
tid43=$(txt "$(call "$M3_A43" send '{"to":"m3_w43","text":"task 43"}')" | sed 's/sent id=//')
t send-keys -t "$M3_A43" "printf 'Do you want to proceed?'" Enter
expect_screen "T43 sender prompt visible" "$M3_A43" "Do you want to proceed?"
call "$M3_W43" reply "{\"id\":\"$tid43\",\"text\":\"private reply 43\"}" >/dev/null
refute "T43 other agent has no unread mail" "$(notice "$(call "$M3_B43" list '{}')")" "unread board post"
refute "T43 other agent board hides mail" "$(txt "$(call "$M3_B43" board '{}')")" "private reply 43"
check "T43 addressee board lists mail" "$(txt "$(call "$M3_A43" board '{}')")" "private reply 43"


# T45: a renamed pane still owns its undelivered fallback mail.
M3_DIR45="$(realpath "$TMPD")/m3_repo45"; mkdir -p "$M3_DIR45"
M3_A45=$(newpane m3_old45 -c "$M3_DIR45" "$FSH")
M3_W45=$(newpane m3_w45 -c "$M3_DIR45" "$FSH")
tid45=$(txt "$(call "$M3_A45" send '{"to":"m3_w45","text":"task 45"}')" | sed 's/sent id=//')
t send-keys -t "$M3_A45" "printf 'Do you want to proceed?'" Enter
expect_screen "T45 sender prompt" "$M3_A45" "Do you want to proceed?"
call "$M3_W45" reply "{\"id\":\"$tid45\",\"text\":\"reply 45\"}" >/dev/null
t set -p -t "$M3_A45" @cntctr_name m3_new45
check "T45 renamed agent sees unread reply" "$(notice "$(call "$M3_A45" list '{}')")" "a reply is waiting"
check "T45 renamed agent board lists reply" "$(txt "$(call "$M3_A45" board '{}')")" "reply 45"

# T46: old undelivered mail counts, old ordinary news does not.
M3_DIR46="$(realpath "$TMPD")/m3_repo46"; mkdir -p "$M3_DIR46"
M3_A46=$(newpane m3_a46 -c "$M3_DIR46" "$FSH")
M3_W46=$(newpane m3_w46 -c "$M3_DIR46" "$FSH")
tid46=$(txt "$(call "$M3_A46" send '{"to":"m3_w46","text":"task 46"}')" | sed 's/sent id=//')
t send-keys -t "$M3_A46" "printf 'Do you want to proceed?'" Enter
expect_screen "T46 sender prompt" "$M3_A46" "Do you want to proceed?"
call "$M3_W46" reply "{\"id\":\"$tid46\",\"text\":\"reply 46\"}" >/dev/null
call "$M3_W46" post '{"text":"old ordinary news 46"}' >/dev/null
sq "$CNTCTR_DB" "UPDATE posts SET at=at-90000 WHERE scope='$M3_DIR46'"
n46=$(notice "$(call "$M3_A46" list '{}')")
check "T46 old mail remains unread" "$n46" "1 unread board post"
check "T46 old mail says reply waiting" "$n46" "a reply is waiting"

# T47: own posts fill the board window but do not hide an unread omission.
M3_DIR47="$(realpath "$TMPD")/m3_repo47"; mkdir -p "$M3_DIR47"
M3_X47=$(newpane m3_x47 -c "$M3_DIR47" "$FSH")
M3_Y47=$(newpane m3_y47 -c "$M3_DIR47" "$FSH")
call "$M3_Y47" post '{"text":"IMPORTANT 47"}' >/dev/null
for i47 in $(seq 21); do call "$M3_X47" post "{\"text\":\"own post $i47\"}" >/dev/null; done
check "T47 unread before board" "$(notice "$(call "$M3_X47" list '{}')")" "1 unread board post"
b47=$(txt "$(call "$M3_X47" board '{}')")
refute "T47 old unread outside window" "$b47" "IMPORTANT 47"
same "T47 omission line counts unread outside window" "$(printf '%s\n' "$b47" | tail -n 1)" "1 older unread posts were not shown"

# T48: embedded NUL is rejected before post or send has side effects.
M3_DIR48="$(realpath "$TMPD")/m3_repo48"; mkdir -p "$M3_DIR48"
M3_A48=$(newpane m3_a48 -c "$M3_DIR48" "$FSH")
M3_B48=$(newpane m3_b48 -c "$M3_DIR48" cat)
count48=$(sq "$CNTCTR_DB" "SELECT count(*) FROM posts WHERE scope='$M3_DIR48'")
r48p=$(call "$M3_A48" post '{"text":"NUL-PREFIX\u0000suffix","urgent":true}')
r48s=$(call "$M3_A48" send '{"to":"m3_b48","text":"NUL-PREFIX\u0000suffix"}')
for r48 in "$r48p" "$r48s"; do
    same "T48 NUL argument rejected" "$(iserr "$r48")" true
    check "T48 error names text" "$(txt "$r48")" "text"
    check "T48 error names NUL byte" "$(txt "$r48")" "NUL byte"
done
same "T48 no post stored" "$(sq "$CNTCTR_DB" "SELECT count(*) FROM posts WHERE scope='$M3_DIR48'")" "$count48"
refute "T48 no text typed" "$(screen "$M3_B48")" "NUL-PREFIX"

# T49: text in an urgent post cannot supply the end marker ID.
M3_DIR49="$(realpath "$TMPD")/m3_repo49"; mkdir -p "$M3_DIR49"
M3_A49=$(newpane m3_a49 -c "$M3_DIR49" cat)
M3_B49=$(newpane m3_b49 -c "$M3_DIR49" cat)
call "$M3_A49" post '{"text":"urgent body id=deadbeef","urgent":true}' >/dev/null
expect_screen "T49 urgent body delivered" "$M3_B49" "urgent body id=deadbeef"
check "T49 has end marker" "$(screen "$M3_B49")" "[cntctr end id="
refute "T49 body id is not used in end marker" "$(screen "$M3_B49")" "[cntctr end id=deadbeef]"

daemon_stop

# T50: a pane ID reused by a later tmux server does not own old mail.
M3_DIR50="$(realpath "$TMPD")/m3_repo50"; mkdir -p "$M3_DIR50"
M3_A50=$(newpane m3_old50 -c "$M3_DIR50" "$FSH")
M3_W50=$(newpane m3_w50 -c "$M3_DIR50" "$FSH")
tid50=$(txt "$(call "$M3_A50" send '{"to":"m3_w50","text":"task 50"}')" | sed 's/sent id=//')
t send-keys -t "$M3_A50" "printf 'Do you want to proceed?'" Enter
expect_screen "T50 sender prompt" "$M3_A50" "Do you want to proceed?"
call "$M3_W50" reply "{\"id\":\"$tid50\",\"text\":\"private reply 50\"}" >/dev/null
start50=$(t display -p '#{start_time}')
sq "$CNTCTR_DB" "UPDATE posts SET at=$start50 WHERE scope='$M3_DIR50' AND text LIKE 'for m3_old50 (reply id=$tid50):%'"
t set -p -t "$M3_A50" @cntctr_name m3_new50
refute "T50 reused pane has no unread mail" "$(notice "$(call "$M3_A50" list '{}')")" "unread board post"
refute "T50 reused pane board hides mail" "$(txt "$(call "$M3_A50" board '{}')")" "private reply 50"
t send-keys -t "$M3_A50" C-c
t send-keys -t "$M3_A50" clear Enter
t send-keys -t "$M3_A50" 'stty -echo; exec cat' Enter
daemon_start "$M3_A50"
sleep 3
refute "T50 reused pane receives no mail" "$(screen "$M3_A50")" "private reply 50"
same "T50 mail remains undelivered" "$(sq "$CNTCTR_DB" "SELECT delivered FROM mail JOIN posts ON posts.rowid=mail.post WHERE scope='$M3_DIR50' AND text LIKE 'for m3_old50 (reply id=$tid50):%'")" 0
daemon_stop

# T51: an empty pane ID matches no stored mail.
M3_DIR51="$(realpath "$TMPD")/m3_repo51"; mkdir -p "$M3_DIR51"
M3_A51=$(newpane m3_a51 -c "$M3_DIR51" sh)
start51=$(t display -p '#{start_time}')
sq "$CNTCTR_DB" "INSERT INTO posts(scope, sender, text, at) VALUES('$M3_DIR51', 'sender51', 'for m3_a51 (reply id=t51):\nprivate mail 51', $((start51 + 5))); INSERT INTO mail(post, name, pane) VALUES(last_insert_rowid(), 'm3_a51', '')"
call "$M3_A51" post '{"text":"ordinary post 51"}' >/dev/null
res51=$(cd "$M3_DIR51" && call "" board '{}')
res51_1=$(cd "$M3_DIR51" && call "" board '{"limit":1}')
refute "T51 paneless board hides mail" "$(txt "$res51")" "private mail 51"
refute "T51 paneless board has no unread notice" "$(txt "$res51_1")" "older unread posts were not shown"
check "T51 addressee board lists mail" "$(txt "$(call "$M3_A51" board '{}')")" "private mail 51"

# U6 to U21 run last: their agents, posts and history stay behind and would change what the older checks count
[ "${ONLY:-}" = m3 ] || u5_run

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
