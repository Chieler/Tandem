#!/bin/bash
# End-to-end tests for cntctr. Runs against a private tmux server, never yours.
set -u
BIN=$(cd "$(dirname "${BIN:-./cntctr}")" && pwd)/$(basename "${BIN:-./cntctr}")
if [ "${ONLY:-}" = cli ]; then BIN="$BIN" exec bash "$(dirname "$0")/test-cli.sh"; fi
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
if [ -n "\${CNTCTR_TEST_MAIL_ENTER:-}" ]; then
    case " \$* " in
        *" paste-buffer -d "*)
            if [ "\$CNTCTR_TEST_MAIL_WHEN" = after ]; then "$REAL_TMUX" "\$@" || exit \$?; fi
            printf 'ready\n' > "\$CNTCTR_TEST_MAIL_ENTER.ready"
            n=0
            while [ -e "\$CNTCTR_TEST_MAIL_ENTER" ] && [ "\$n" -lt 500 ]; do
                sleep 0.01
                n=\$((n+1))
            done
            if [ "\$CNTCTR_TEST_MAIL_WHEN" = after ]; then exit 0; fi
            ;;
    esac
fi
if [ -n "\${CNTCTR_TEST_IDLE_LOG:-}" ]; then
    printf '%s\n' "\$*" >> "\$CNTCTR_TEST_IDLE_LOG"
fi
if [ -n "\$HOOK_GATE_BARRIER" ]; then
    for a in "\$@"; do
        if [ "\$a" = "list-panes" ]; then
            : > "\$HOOK_GATE_BARRIER.ready"
            for i in \$(seq 1 500); do
                [ -e "\$HOOK_GATE_BARRIER.go" ] && break
                sleep 0.01
            done
            break
        fi
    done
fi
exec "$REAL_TMUX" "\$@"
EOF
chmod +x "$TMPD/bin/tmux"
FSH='printf "\033[?2004h"; exec sh'   # a fake agent that is a shell, same reason
export HOME="$TMPD/home"   # fleet tools keep their cache under ~/.cache
export CNTCTR_TEST_ANCESTOR_STOP_PID=$$   # cli_admin_guard stops its ancestor walk at the test shell
export BIN INIT CNTCTR_ENTER_DELAY_MS=50 LC_ALL=en_US.UTF-8 PATH="$TMPD/bin:$PATH" CNTCTR_DB="$TMPD/kb.db" CNTCTR_MEM_URL=
export CNTCTR_MAX_AGENTS=${CNTCTR_MAX_AGENTS:-256}
unset TMUX_PANE CNTCTR_PANE CNTCTR_TMUX CNTCTR_NAME   # a cntctr-spawned agent has these; they would aim the tests at its real tmux server

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
# Fixture panes mostly have no parent, so since F9 the shared call sends with cross=true and lists with all=true: the tests are about
# something else. STRICT=1 (see scall) sends the arguments as given; the F9 tests use it.
call_args() {
    [ -n "${STRICT:-}" ] && { printf '%s' "$2"; return; }
    printf '%s' "$2" | jq -c --arg tool "$1" '
        if $tool == "list" then . + {all: true}
        elif $tool == "send" or $tool == "kill" then . + {cross: true}
        elif $tool == "gather" and (.tasks | type) == "array" then .tasks |= map(if type == "object" and .kind == "send" then . + {cross: true} else . end)
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
# F9: agents only task agents they own. list shows owner and directory, and by default only the caller's own spawn tree (root);
# send, gather and kill refuse any other agent unless cross=true. Run alone with ONLY=f9.
has_pane() { t list-panes -a -F '#{pane_id}' | grep -qx "$1"; }
f9_run() {
    local C W PAR SIB USR OW dirs out txt_ before after n all_n vis_n
    dirs="$(realpath "$TMPD")"; mkdir -p "$HOME/proj" "$dirs/elsewhere"
    PAR=$(newpane f9_par -c "$dirs/elsewhere"); C=$(newpane f9_me -c "$HOME"); W=$(newpane f9_w -c "$HOME/proj")
    SIB=$(newpane f9_sib); USR=$(newpane f9_user -c "$dirs/elsewhere"); OW=$(newpane f9_ow)
    t set -p -t "$C" @cntctr_parent "$PAR"; t set -p -t "$W" @cntctr_parent "$C"
    t set -p -t "$SIB" @cntctr_parent "$PAR"; t set -p -t "$OW" @cntctr_parent "$USR"
    # a spawn also sets the tree's root (see F10); scope is the same root
    t set -p -t "$C" @cntctr_root "$PAR"; t set -p -t "$W" @cntctr_root "$PAR"; t set -p -t "$SIB" @cntctr_root "$PAR"; t set -p -t "$OW" @cntctr_root "$USR"
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
    # send, gather and kill refused outside the caller's own agents
    stored() { sq "$CNTCTR_DB" "SELECT (SELECT count(*) FROM mail)||'/'||(SELECT count(*) FROM posts)||'/'||(SELECT count(*) FROM entries)"; }
    stored_opts() { t show -s | grep -c '@cntctr_to_'; }
    before="$(stored) $(stored_opts)"
    for n in f9_user f9_ow; do
        out=$(scall "$C" send "{\"to\":\"$n\",\"text\":\"f9 refused send $n\"}")
        same "F9.5 send to $n is an error" "$(iserr "$out")" true
        check "F9.5 send to $n says why" "$(txt "$out")" "$n is not yours: owner="
        check "F9.5 and tells what to do" "$(txt "$out")" "Spawn your own agent with spawn cwd=<your dir>, or use post for the board. Pass cross=true only if the user asked you to message this agent."
    done
    check "F9.5 the error names the owner and directory" "$(txt "$(scall "$C" send '{"to":"f9_user","text":"f9 refused send"}')")" "f9_user is not yours: owner=user dir=$dirs/elsewhere. Spawn"
    out=$(scall "$C" gather '{"wait":false,"tasks":[{"kind":"send","to":"f9_user","text":"f9 refused gather"},{"kind":"send","to":"f9_ow","text":"f9 refused gather"}]}')
    check "F9.6 gather refuses a user session" "$(txt "$out")" "f9_user is not yours"
    check "F9.6 gather refuses another agent's worker" "$(txt "$out")" "f9_ow is not yours"
    out=$(scall "$C" kill '{"name":"f9_user"}'); same "F9.7 kill of a user session is an error" "$(iserr "$out")" true
    check "F9.7 kill says why" "$(txt "$out")" "f9_user is not yours"
    out=$(scall "$C" kill '{"name":"f9_ow"}'); same "F9.7 kill of another agent's worker is an error" "$(iserr "$out")" true
    has_pane "$USR" && ok_ || bad "F9.7 the user session pane is still there"
    has_pane "$OW" && ok_ || bad "F9.7 the other worker's pane is still there"
    sleep 0.3
    refute "F9.5 nothing was typed into the user session" "$(screen "$USR")" "f9 refused"
    refute "F9.5 nothing was typed into the other worker" "$(screen "$OW")" "f9 refused"
    same "F9.5 nothing was stored" "$(stored) $(stored_opts)" "$before"
    # in scope: worker, parent (and the alias), sibling
    for n in f9_w f9_par f9_sib parent; do
        out=$(scall "$C" send "{\"to\":\"$n\",\"text\":\"f9 ok send $n\"}")
        same "F9.8 send to $n works" "$(iserr "$out")" false
    done
    expect_screen "F9.8 the worker got it" "$W" "f9 ok send f9_w"
    expect_screen "F9.8 the parent got it" "$PAR" "f9 ok send f9_par"
    expect_screen "F9.8 the sibling got it" "$SIB" "f9 ok send f9_sib"
    expect_screen "F9.8 parent alias reached the parent" "$PAR" "f9 ok send parent"
    out=$(scall "$C" gather '{"wait":false,"tasks":[{"kind":"send","to":"f9_w","text":"f9 ok gather"}]}')
    check "F9.8 gather to a worker works" "$(txt "$out")" '"status":"sent"'
    # cross=true goes through
    out=$(scall "$C" send '{"to":"f9_user","text":"f9 cross send","cross":true}')
    same "F9.9 send with cross=true works" "$(iserr "$out")" false
    expect_screen "F9.9 and is typed" "$USR" "f9 cross send"
    out=$(scall "$C" gather '{"wait":false,"tasks":[{"kind":"send","to":"f9_ow","text":"f9 cross gather","cross":true},{"kind":"send","to":"f9_user","text":"f9 no cross gather"}]}')
    expect_screen "F9.9 gather cross=true on one task works" "$OW" "f9 cross gather"
    check "F9.9 and the task without cross is refused" "$(txt "$out")" "f9_user is not yours"
    refute "F9.9 and not typed" "$(screen "$USR")" "f9 no cross gather"
    out=$(scall "$C" kill '{"name":"f9_ow","cross":true}'); same "F9.9 kill with cross=true works" "$(iserr "$out")" false
    for _ in $(seq 30); do has_pane "$OW" || break; sleep 0.1; done
    has_pane "$OW" && bad "F9.9 the pane is gone" || ok_
    # the Codex path: no pane, `from` names one
    out=$(scall "" send "{\"from\":\"f9_me\",\"to\":\"f9_user\",\"text\":\"f9 codex refused\"}")
    check "F9.10 from= send to a user session is refused" "$(txt "$out")" "f9_user is not yours"
    out=$(scall "" send "{\"from\":\"f9_me\",\"to\":\"f9_w\",\"text\":\"f9 codex ok\"}")
    same "F9.10 from= send to its worker works" "$(iserr "$out")" false
    out=$(scall "" send "{\"from\":\"$USR\",\"to\":\"f9_sib\",\"text\":\"f9 codex user refused\"}")
    check "F9.10 from= a user session pane id is refused for another agent" "$(txt "$out")" "f9_sib is not yours"
    sleep 0.3
    refute "F9.10 nothing was typed for the refused one" "$(screen "$USR")" "f9 codex refused"
    out=$(rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
    check "F9.11 list says idle is not free to use" "$out" "idle does not mean free to use"
    check "F9.11 spawn says to spawn fresh with a cwd" "$out" "Spawn a fresh agent with an explicit cwd instead of reusing an agent from list all=true"
}
# F10: agent scope is the spawn tree. Real spawns with a fake harness, and no cross/all rewrite (scall). Run alone with ONLY=f10.
f10_run() {
    local UA UB L W G K BW out id id2 n bg
    pane_of() { t list-panes -a -F '#{pane_id} #{@cntctr_name}' | awk -v n="$1" '$2 == n {print $1}'; }
    popt() { t show -pqv -t "$1" "$2"; }
    gone() { for _ in $(seq 30); do has_pane "$1" || break; sleep 0.1; done; has_pane "$1" && bad "$2" || ok_; }
    printf '#!/bin/sh\ntmux show -pqv -t "$TMUX_PANE" @cntctr_root > "%s/start-""$CNTCTR_NAME"\nexec cat\n' "$TMPD" > "$TMPD/bin/claude"
    printf '#!/bin/sh\ntool=$2; shift 2; [ "$1" = -- ] && shift\nexec "$tool" "$@"\n' > "$TMPD/bin/headroom"
    chmod +x "$TMPD/bin/claude" "$TMPD/bin/headroom"
    UA=$(newpane f10_ua); UB=$(newpane f10_ub)
    # spawn tree of session A: ua -> l -> w -> g, and l -> k; session B: ub -> bw
    out=$(scall "$UA" spawn '{"harness":"claude","name":"f10_l","task":"f10 lead"}'); check "F10.1 spawn from a session works" "$(txt "$out")" "spawned f10_l"
    L=$(pane_of f10_l)
    out=$(scall "$L" spawn '{"harness":"claude","name":"f10_w","task":"f10 worker"}'); W=$(pane_of f10_w)
    out=$(scall "$W" spawn '{"harness":"claude","name":"f10_g","task":"f10 grandchild"}'); G=$(pane_of f10_g)
    out=$(scall "$L" spawn '{"harness":"claude","name":"f10_k","task":"f10 to kill"}'); K=$(pane_of f10_k)
    out=$(scall "$UB" spawn '{"harness":"claude","name":"f10_bw","task":"f10 other tree"}'); BW=$(pane_of f10_bw)
    same "F10.1 a spawn from a session has the session as parent" "$(popt "$L" @cntctr_parent)" "$UA"
    same "F10.1 and the session as root" "$(popt "$L" @cntctr_root)" "$UA"
    same "F10.1 a worker's parent is its spawner" "$(popt "$W" @cntctr_parent)" "$L"
    same "F10.1 and its root is the session" "$(popt "$W" @cntctr_root)" "$UA"
    same "F10.1 a grandchild's parent is its spawner" "$(popt "$G" @cntctr_parent)" "$W"
    same "F10.1 and its root is still the session" "$(popt "$G" @cntctr_root)" "$UA"
    same "F10.1 the other session's worker has its own root" "$(popt "$BW" @cntctr_root)" "$UB"
    same "F10.1 a session by hand has no root option" "$(popt "$UA" @cntctr_root)" ""
    for _ in $(seq 30); do [ -f "$TMPD/start-f10_w" ] && break; sleep 0.1; done
    same "S4 harness observes root at startup" "$(cat "$TMPD/start-f10_w" 2>/dev/null)" "$UA"
    # Pending reviewers are outside the tree until cross is explicit.
    sq "$CNTCTR_DB" "INSERT INTO tools(project,name,version,status,author,description,input_schema,interpreter,script,reviewer_pane) VALUES ('tree-test','tree_review',1,'pending','author','test','{}','sh','true','$K')"
    out=$(scall "$L" send '{"to":"f10_k","text":"review"}'); same "S1 reviewer send refused" "$(iserr "$out")" true
    out=$(scall "$L" send '{"to":"f10_k","text":"review allowed","cross":true}'); same "S1 reviewer send with cross" "$(iserr "$out")" false
    out=$(scall "$L" kill '{"name":"f10_k"}'); same "S1 reviewer kill refused" "$(iserr "$out")" true
    out=$(scall "$L" kill '{"name":"f10_k","cross":true}'); same "S1 reviewer kill with cross" "$(iserr "$out")" false
    sq "$CNTCTR_DB" "DELETE FROM tools WHERE project='tree-test'"
    out=$(scall "$L" spawn '{"harness":"claude","name":"f10_k","task":"replacement"}'); K=$(pane_of f10_k)
    out=$(scall "$L" kill '{"name":"f10_ua"}'); check "S2 hand-started root protected" "$(txt "$out")" "started by hand"
    local TR TC
    TR=$(newpane f10_temp_root)
    out=$(scall "$TR" spawn '{"harness":"claude","name":"f10_temp_child","task":"temporary"}'); TC=$(pane_of f10_temp_child)
    out=$(scall "$TC" kill '{"name":"f10_temp_root","cross":true}'); same "S2 root kill with cross" "$(iserr "$out")" false
    t kill-pane -t "$TC"
    # (a) kill of your own worker, no cross
    out=$(scall "$L" kill '{"name":"f10_k"}'); same "F10.2 kill of your own worker needs no cross" "$(iserr "$out")" false
    gone "$K" "F10.2 the killed worker's pane is gone"
    # (b) a scoped send and a gather wait=true to a spawned worker
    out=$(scall "$L" send '{"to":"f10_w","text":"f10 scoped send"}'); same "F10.3 send to a spawned worker needs no cross" "$(iserr "$out")" false
    expect_screen "F10.3 the worker got it" "$W" "f10 scoped send"
    ( scall "$L" gather '{"tasks":[{"kind":"send","to":"f10_w","text":"f10 scoped gather"}],"timeout":20}' > "$TMPD/f10.gather" ) & bg=$!
    expect_screen "F10.3 the worker got the gather task" "$W" "f10 scoped gather"
    scall "$W" reply "{\"id\":\"$(lastid "$W")\",\"text\":\"f10 gather answer\"}" > /dev/null
    wait $bg
    same "F10.3 gather wait=true to a spawned worker completes" "$(txt "$(cat "$TMPD/f10.gather")" | jq -r '.results[0].status')" answered
    # (d) a worker's send to parent wait=true round trip
    ( scall "$W" send '{"to":"parent","text":"f10 up","wait":true,"timeout":20}' > "$TMPD/f10.up" ) & bg=$!
    expect_screen "F10.4 the parent got the worker's task" "$L" "f10 up"
    scall "$L" reply "{\"id\":\"$(lastid "$L")\",\"text\":\"f10 down\"}" > /dev/null
    wait $bg
    check "F10.4 the worker's wait returns the answer" "$(txt "$(cat "$TMPD/f10.up")")" "f10 down"
    # (c) a re follow-up: in scope, and to an agent outside the tree after a cross=true task
    out=$(scall "$L" send '{"to":"f10_w","text":"f10 open task"}'); id=$(txt "$out" | sed -n 's/.*id=\([0-9a-f]\{8\}\).*/\1/p')
    out=$(scall "$L" send "{\"to\":\"f10_w\",\"text\":\"f10 follow-up\",\"re\":\"$id\"}"); same "F10.5 re follow-up to a worker works" "$(iserr "$out")" false
    expect_screen "F10.5 and is typed" "$W" "f10 follow-up"
    out=$(scall "$L" send '{"to":"f10_ub","text":"f10 cross open","cross":true}'); id2=$(txt "$out" | sed -n 's/.*id=\([0-9a-f]\{8\}\).*/\1/p')
    out=$(scall "$L" send "{\"to\":\"f10_ub\",\"text\":\"f10 addendum no cross\",\"re\":\"$id2\"}")
    same "F10.5 re follow-up to an open cross task needs no cross" "$(iserr "$out")" false
    expect_screen "F10.5 and is typed to the other session" "$UB" "f10 addendum no cross"
    out=$(scall "$L" send '{"to":"f10_ub","text":"f10 new no cross"}'); check "F10.5 a new task to it is still refused" "$(txt "$out")" "f10_ub is not yours"
    out=$(scall "$W" send "{\"to\":\"f10_ub\",\"text\":\"f10 stolen re\",\"re\":\"$id2\"}"); same "F10.5 another sender cannot use the task id" "$(iserr "$out")" true
    # (e) grandchild and orphan, both ways
    out=$(txt "$(scall "$L" list '{}')")
    check "F10.6 list shows a grandchild by default" "$(printf '%s\n' "$out" | grep '^f10_g ')" "owner=f10_w"
    check "F10.6 list from the grandchild shows the lead" "$(txt "$(scall "$G" list '{}')" | grep '^f10_l ')" "owner=f10_ua"
    out=$(scall "$L" send '{"to":"f10_g","text":"f10 down to g"}'); same "F10.6 lead to grandchild works" "$(iserr "$out")" false
    expect_screen "F10.6 the grandchild got it" "$G" "f10 down to g"
    out=$(scall "$G" send '{"to":"f10_l","text":"f10 up from g"}'); same "F10.6 grandchild to lead works" "$(iserr "$out")" false
    expect_screen "F10.6 the lead got it" "$L" "f10 up from g"
    out=$(scall "$L" kill '{"name":"f10_w"}'); same "F10.7 the lead kills the worker" "$(iserr "$out")" false
    gone "$W" "F10.7 the worker's pane is gone"
    check "F10.7 the orphan shows its dead parent" "$(txt "$(scall "$L" list '{}')" | grep '^f10_g ')" "owner=$W (gone)"
    out=$(scall "$L" send '{"to":"f10_g","text":"f10 down to orphan"}'); same "F10.7 lead to orphan works" "$(iserr "$out")" false
    expect_screen "F10.7 the orphan got it" "$G" "f10 down to orphan"
    out=$(scall "$G" send '{"to":"f10_l","text":"f10 up from orphan"}'); same "F10.7 orphan to lead works" "$(iserr "$out")" false
    expect_screen "F10.7 the lead got it from the orphan" "$L" "f10 up from orphan"
    out=$(scall "$G" send '{"to":"parent","text":"orphan"}'); check "S3 orphan names dead parent" "$(txt "$out")" "your parent $W is gone; your root is f10_ua (send to=\"f10_ua\")"
    out=$(scall "$L" kill '{"name":"f10_g"}'); same "F10.7 the lead kills the orphan" "$(iserr "$out")" false
    gone "$G" "F10.7 the orphan's pane is gone"
    # (f) two separate sessions with their own trees cannot reach each other
    for n in f10_ub f10_bw; do
        out=$(scall "$L" send "{\"to\":\"$n\",\"text\":\"f10 refused to $n\"}"); check "F10.8 the lead cannot send to $n" "$(txt "$out")" "$n is not yours"
        out=$(scall "$L" kill "{\"name\":\"$n\"}"); check "F10.8 the lead cannot kill $n" "$(txt "$out")" "$n is not yours"
    done
    for n in f10_l f10_ua; do
        out=$(scall "$UB" send "{\"to\":\"$n\",\"text\":\"f10 refused to $n\"}"); check "F10.8 the other session cannot send to $n" "$(txt "$out")" "$n is not yours"
    done
    out=$(scall "$BW" send '{"to":"f10_l","text":"f10 refused from bw"}'); check "F10.8 the other tree's worker cannot send to the lead" "$(txt "$out")" "f10_l is not yours"
    out=$(txt "$(scall "$UB" list '{}')")
    check "F10.8 a session lists its own worker" "$out" "f10_bw "
    refute "F10.8 and not the other tree" "$out" "f10_l "
    out=$(scall "$L" gather '{"wait":false,"tasks":[{"kind":"send","to":"f10_bw","text":"f10 refused gather"}]}'); check "F10.8 gather is refused across trees" "$(txt "$out")" "f10_bw is not yours"
    # from= never overrides a caller's own pane
    out=$(scall "$UB" send '{"from":"f10_l","to":"f10_l","text":"f10 spoof"}'); check "F10.9 from= naming another agent does not make it the caller" "$(txt "$out")" "f10_l is not yours"
    out=$(scall "$UB" send '{"from":"f10_ub","to":"f10_bw","text":"f10 from itself"}'); same "F10.9 from= naming itself is harmless" "$(iserr "$out")" false
    # gather: top-level cross covers every send
    out=$(scall "$UA" gather '{"wait":false,"tasks":[{"kind":"send","to":"f10_ub","text":"f10 no top cross"}]}'); check "F10.10 gather without cross is refused" "$(txt "$out")" "f10_ub is not yours"
    out=$(scall "$UA" gather '{"wait":false,"cross":true,"tasks":[{"kind":"send","to":"f10_ub","text":"f10 top cross"}]}'); check "F10.10 gather with top-level cross works" "$(txt "$out")" '"status":"sent"'
    expect_screen "F10.10 and is typed" "$UB" "f10 top cross"
    sleep 0.3
    for n in "refused to f10_ub" "refused to f10_l" "no top cross" "spoof" "new no cross" "stolen re"; do
        refute "F10.8 nothing typed for: $n" "$(screen "$UB")$(screen "$L")$(screen "$BW")" "f10 $n"
    done
    scall "$UB" kill '{"name":"f10_bw"}' > /dev/null; scall "$UA" kill '{"name":"f10_l"}' > /dev/null
}
gboard_run() {
    local sender target r
    sender=$(newpane gb_sender); target=$(newpane gb_off)
    t select-pane -d -t "$target"
    r=$(txt "$(call "$sender" gather '{"tasks":[{"kind":"send","to":"gb_off","text":"gather input off"}],"wait":false}')")
    same "gather wait=false names the board fallback" "$(printf '%s' "$r" | jq -r '.results[0].status')" "sent on board"
    check "gather wait=false board send is stored" "$(txt "$(call "$target" board '{}')")" "gather input off"
}
if [ "${ONLY:-}" = u28 ] || [ "${ONLY:-}" = gboard ] || [ "${ONLY:-}" = f9 ] || [ "${ONLY:-}" = f10 ]; then
    export CNTCTR_PASTE_WAIT_MS=100
    case $ONLY in u28) u28_run ;; f9) f9_run ;; f10) f10_run ;; *) gboard_run ;; esac
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
    check "U27 hard codex routes terra high" "$u27" "gpt-6.2-sol high"
    u27=$(txt "$(call "$U27_P" spawn '{"harness":"codex","name":"u27_review","task":"adversarial review"}')")
    check "U27 review codex routes sol high" "$u27" "gpt-6.2-sol high"
    u27=$(txt "$(call "$U27_P" spawn '{"harness":"codex","name":"u27_adversarial","task":"adversarial"}')")
    check "U27 adversarial whole word routes review" "$u27" "review: gpt-6.2-sol high"
    u27=$(txt "$(call "$U27_P" spawn '{"harness":"codex","name":"u27_redteam","task":"red team"}')")
    check "U27 red team whole words route review" "$u27" "review: gpt-6.2-sol high"
    u27=$(txt "$(call "$U27_P" spawn '{"harness":"codex","name":"u27_partial","task":"misadversarially"}')")
    check "U27 partial adversarial does not route review" "$u27" "standard: gpt-6.2-sol medium"
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
        char mode[16] = "";
        int n = sscanf(line, "%127s %2047s %63s %2047s %15s", event, path, pane, answer, mode);
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
        if (strcmp(mode, "async")) waitpid(child, &st, 0);
        while (waitpid(-1, &st, WNOHANG) > 0) {}
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
        CNTCTR_TEST_STOP_PAUSE="$TMPD/hold_stop" "$TMPD/hook_harness/$h" "$BIN" "$h" < "$TMPD/hk_${h}_in" > "$TMPD/hk_${h}_out" &
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
# Force the persisted deadline across expiry without sleeping for a production lease.
wait_shown() {
    local i
    for i in $(seq 80); do
        [ "$(sqx "$CNTCTR_DB" "SELECT shown FROM mail WHERE post=$1")" = "$2" ] && return
        sleep 0.1
    done
    bad "mail $1 did not charge body attempt $2"
}
expire_mail() { sqx "$CNTCTR_DB" "UPDATE mail SET lease_until=1 WHERE post=$1 AND state='staged'"; }
mstate() { sqx "$CNTCTR_DB" "SELECT state||'/'||presentations||'/'||delivered FROM mail WHERE post=$1"; }
pointer() { printf '[cntctr mail id=%s] body attached; if missing, call board id=%s' "$1" "$1"; }
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
    local P S Q m m2 ans out body
    P=$(hk_agent claude u5_d1)
    S=$(newpane u5_d1_sender)
    mkdir -p "$HOME/.local/share/cntctr"
    m=$(mailput "$P" d1000099 "$(mail_text d1000099 'trace-private-body')" 1)
    c_prompt "$P" "$(pointer "$m")" >/dev/null
    [ ! -e "$HOME/.local/share/cntctr/hook-trace.log" ] && ok_ || bad "trace is disabled without marker"
    c_stop "$P" >/dev/null
    : > "$HOME/.local/share/cntctr/hook-trace"
    m=$(mailput "$P" d1000098 "$(mail_text d1000098 'trace-private-body')" 1)
    c_prompt "$P" "$(pointer "$m")" >/dev/null
    c_stop "$P" >/dev/null
    local log="$HOME/.local/share/cntctr/hook-trace.log"
    same "trace writes one line per invocation" "$(wc -l < "$log" | tr -d ' ')" 2
    jq -e --argjson id "$m" 'select(.event == "UserPromptSubmit" and .attached == 1 and (.before.mail | any(.post == $id and .state == "pending")) and (.after.mail | any(.post == $id and .state == "staged")))' "$log" >/dev/null && ok_ || bad "trace records attachment and mail transition"
    jq -e 'select(.event == "Stop" and .delivered == 1 and .token != null and .after.session.last_event == "Stop")' "$log" >/dev/null && ok_ || bad "trace records delivery and token"
    m=$(mailput "$P" d1000097 "$(mail_text d1000097 'trace-stop-body')" 0)
    c_stop "$P" >/dev/null
    jq -e --argjson id "$m" 'select(.event == "Stop" and .re_presented == 1 and .action == "re-presented" and (.before.mail | any(.post == $id and .state == "pending")) and (.after.mail | any(.post == $id and .state == "staged")))' "$log" >/dev/null && ok_ || bad "trace records Stop presentation"
    c_stop "$P" true >/dev/null
    refute "trace excludes body" "$(cat "$log")" "trace-private-body"
    refute "trace excludes Stop body" "$(cat "$log")" "trace-stop-body"
    rm "$HOME/.local/share/cntctr/hook-trace"
    local lines
    lines=$(wc -l < "$log")
    c_prompt "$P" hello >/dev/null
    same "trace stops when marker is removed" "$(wc -l < "$log")" "$lines"
    c_stop "$P" >/dev/null
    # U7: a normal Stop of the staging turn delivers
    m=$(mailput "$P" d1000001 "$(mail_text d1000001 'normal stop mail')" 1)
    c_prompt "$P" "$(pointer "$m")" >/dev/null
    same "U7 attached mail is staged first" "$(mstate "$m")" "staged/1/0"
    ans=$(c_stop "$P")
    emptyans "$ans" && ok_ || bad "U7 a normal Stop with nothing else pending passes" "  got: $ans"
    same "U7 a normal Stop of the staging turn delivers" "$(mstate "$m")" "delivered/1/1"
    # U7: reply closes the task gate and Stop acknowledges its full body.
    t set -s @cntctr_from_d1000002 "$S"; t set -s @cntctr_to_d1000002 "$P"; t set -s @cntctr_sender_d1000002 u5_d1_sender
    m=$(mailput "$P" d1000002 "$(mail_text d1000002 'reply me')" 1)
    c_prompt "$P" "$(pointer "$m")" >/dev/null
    same "U7 mail to be answered is staged" "$(mstate "$m")" "staged/1/0"
    call "$P" reply '{"id":"d1000002","text":"my answer"}' >/dev/null
    same "U7 reply leaves the lease staged until Stop" "$(mstate "$m")" "staged/1/0"
    same "U7 reply closes the task gate" "$(sqx "$CNTCTR_DB" "SELECT answered FROM task_gate WHERE task='d1000002'")" 1
    c_stop "$P" >/dev/null
    same "U7 Stop after reply finishes the lease" "$(mstate "$m")" "delivered/1/1"
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
    expire_mail "$m2"
    a_pre "$Q" 0 "$(pointer "$m2")" >/dev/null
    a_stop "$Q" NO_TOOL_CALL >/dev/null
    same "U7 an agy Stop that ends normally delivers" "$(mstate "$m2")" "delivered/1/1"

    # U8: an abandoned attempt stays staged until its lease expires.
    P=$(hk_agent claude u5_d3)
    m=$(mailput "$P" d3000001 "$(mail_text d3000001 'maybe seen mail')" 1)
    c_prompt "$P" "$(pointer "$m")" >/dev/null
    same "U8 mail is staged in the first turn" "$(mstate "$m")" "staged/1/0"
    c_prompt "$P" "an unrelated question" >/dev/null
    same "U8 a new prompt cannot release a live lease" "$(mstate "$m")" "staged/1/0"
    expire_mail "$m"
    c_prompt "$P" "an unrelated question after expiry" >/dev/null
    same "U8 an expired lease makes staged mail pending again" "$(mstate "$m")" "pending/1/0"
    sqx "$CNTCTR_DB" "UPDATE mail SET presentations=2 WHERE post=$m" # a second line was typed for it
    ans=$(c_prompt "$P" "$(pointer "$m")")
    same "U8 small repeat has the full envelope" "$(ctx_c "$ans")" "$(mail_text d3000001 'maybe seen mail')"
    same "U8 the repeat is staged, still counted twice" "$(mstate "$m")" "staged/2/0"
    c_stop "$P" >/dev/null
    same "U8 the repeat is delivered by the Stop" "$(mstate "$m")" "delivered/2/1"
    # U8: the same for agy
    Q=$(hk_agent agy u5_d4)
    m=$(mailput "$Q" d4000001 "$(mail_text d4000001 'agy maybe seen')" 1)
    a_pre "$Q" 0 "$(pointer "$m")" >/dev/null
    a_pre "$Q" 0 "an unrelated question" >/dev/null
    same "U8 agy: a new turn leaves the live lease staged" "$(mstate "$m")" "staged/1/0"
    expire_mail "$m"
    a_pre "$Q" 0 "question after expiry" >/dev/null
    same "U8 agy: a prompt can recover an expired lease" "$(mstate "$m")" "pending/1/0"

    # A pointer may have been typed for a different prompt: its count alone is not a full presentation.
    P=$(hk_agent claude repeat_pointer)
    local wake_body
    wake_body=$(mail_text e1000001 "$(head -c 1800 /dev/zero | tr '\0' x)")
    m=$(mailput "$P" e1000001 "$wake_body" 1)
    same "pointer-only wake has not shown mail" "$(sq "$CNTCTR_DB" "SELECT shown FROM mail WHERE post=$m")" 0
    ans=$(c_stop "$P")
    same "pointer-only wake first presents the entire large envelope" "$(printf '%s' "$ans" | jq -r '.reason')" "$wake_body"
    same "first hook body increments shown" "$(sq "$CNTCTR_DB" "SELECT shown FROM mail WHERE post=$m")" 1

    out=$(txt "$(call "$P" board "{\"id\":$m}")")
    same "board id returns the exact staged body" "$out" "$wake_body"
    same "complete exact lookup acknowledges staged mail" "$(mstate "$m")" "delivered/2/1"
    out=$(txt "$(call "$P" board "{\"id\":$m}")")
    same "board id still returns the exact delivered body" "$out" "$wake_body"
    same "looking up delivered mail preserves its status" "$(mstate "$m")" "delivered/2/1"

    # A blocked Stop and its continuation retain the turn token. An error leaves the lease unresolved.
    Q=$(hk_agent agy repeat_block)
    m=$(mailput "$Q" e1000002 "$(mail_text e1000002 'blocked-stop body')" 0)
    ans=$(a_stop "$Q" NO_TOOL_CALL)
    check "blocked Stop first shows the body" "$(printf '%s' "$ans" | jq -r '.reason')" "blocked-stop body"
    a_stop "$Q" ERROR >/dev/null
    expire_mail "$m"
    ans=$(a_pre "$Q" 0 "$(pointer "$m")")
    same "second hook presentation repeats the full small envelope" "$(ctx_a "$ans")" "$(mail_text e1000002 'blocked-stop body')"
    same "second hook body increments shown" "$(sq "$CNTCTR_DB" "SELECT shown FROM mail WHERE post=$m")" 2

    # Repeat size is measured inside the markers before JSON escaping.
    local prefix tail body expected
    P=$(hk_agent claude repeat_large)
    prefix=$(head -c 399 /dev/zero | tr '\0' '"')
    tail=$(head -c 700 /dev/zero | tr '\0' x)
    body=$(printf '[cntctr from=sender id=e1000003]\n%sé%s\n[cntctr end id=e1000003]' "$prefix" "$tail")
    m=$(mailput "$P" e1000003 "$body" 1)
    ans=$(c_prompt "$P" "$(pointer "$m")")
    same "first large presentation includes the entire envelope" "$(ctx_c "$ans")" "$body"
    expire_mail "$m"
    ans=$(c_prompt "$P" "$(pointer "$m")")
    expected=$(printf '[cntctr from=sender id=e1000003]\n%s\n[cntctr end id=e1000003]\n[702 more bytes omitted: call board id=%s]' "$prefix" "$m")
    same "large repeat ends on a UTF-8 boundary with exact omitted bytes" "$(ctx_c "$ans")" "$expected"
    check "serialized quoted excerpt fits Claude's 8192-byte limit" "$((${#ans} <= 8192))" 1
    ans=$(c_stop "$P")
    emptyans "$ans" && ok_ || bad "clean Stop does not immediately repeat the excerpt" "  got: $ans"
    same "clean Stop leaves the excerpt unread" "$(mstate "$m")" "staged/1/0"
    expire_mail "$m"
    ans=$(c_prompt "$P" "$(pointer "$m")")
    same "third large presentation has the same exact excerpt" "$(ctx_c "$ans")" "$expected"
    c_stop "$P" >/dev/null
    same "clean Stop cannot acknowledge the third excerpt" "$(mstate "$m")" "staged/1/0"
    expire_mail "$m"
    c_prompt "$P" "recover the expired excerpt" >/dev/null
    same "third expired body stalls without delivery" "$(mstate "$m")" "stalled/1/0"
    same "excerpt stall tells the sender once" "$(notices "$m")" 1
    out=$(txt "$(call "$P" board "{\"id\":$m}")")
    same "board lookup returns the entire stalled body" "$out" "$body"
    same "complete board lookup acknowledges the stalled body" "$(mstate "$m")" "delivered/1/1"

    P=$(hk_agent claude repeat_limit)
    body=$(head -c 1024 /dev/zero | tr '\0' x)
    m=$(mailput "$P" e1000004 "$body" 1)
    c_prompt "$P" "$(pointer "$m")" >/dev/null
    expire_mail "$m"
    ans=$(c_prompt "$P" "$(pointer "$m")")
    same "1024-byte repeat stays full" "$(ctx_c "$ans")" "$body"
    c_stop "$P" >/dev/null

    P=$(hk_agent claude spill_from_stop)
    tail=$(head -c 10000 /dev/zero | tr '\0' x)
    body=$(mail_text e1000006 "$tail")
    m=$(mailput "$P" e1000006 "$body" 0)
    ans=$(c_stop "$P")
    out=$(printf '%s' "$ans" | jq -r '.reason')
    check "first Stop spill names a cache file" "$out" "$HOME/.cache/cntctr/mail/"
    check "first Stop spill also names its durable lookup" "$out" "call board id=$m"
    check "first Stop spill advertises the mail index" "$out" "board mode=mail"
    check "first Stop spill fits the serialized hook budget" "$((${#ans} <= 8192))" 1
    sqx "$CNTCTR_DB" "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<205)
        INSERT INTO posts(scope,sender,text,at)
        SELECT '$U5_SCOPE','sender','newer than spill',strftime('%s','now') FROM n;"
    same "Stop preview ID retrieves the full mail after 205 newer posts" "$(txt "$(call "$P" board "{\"id\":$m}")")" "$body"

    P=$(hk_agent claude spill_unavailable)
    tail=$(head -c 10000 /dev/zero | tr '\0' x)
    body=$(printf '[cntctr from=sender id=e1000005]\n%s\n[cntctr end id=e1000005]' "$tail")
    m=$(mailput "$P" e1000005 "$body" 1)
    local mail_cache="$HOME/.cache/cntctr/mail"
    mkdir -p "$mail_cache"
    mv "$mail_cache" "$mail_cache.saved"
    touch "$mail_cache"
    ans=$(c_prompt "$P" "$(pointer "$m")")
    rm "$mail_cache"
    mv "$mail_cache.saved" "$mail_cache"
    expected=$(printf '[cntctr from=sender id=e1000005]\n%s\n[cntctr end id=e1000005]\n[9600 more bytes omitted: call board id=%s (index: board mode=mail)]' "${tail:0:400}" "$m")
    same "spill failure still gives both markers and a working lookup" "$(ctx_c "$ans")" "$expected"

    c_stop "$P" >/dev/null
    same "clean Stop after a spill fallback leaves mail unread" "$(mstate "$m")" "staged/1/0"

    # A wake for the newest of 205 mixed rows still presents the oldest fitting prefix.
    local socket first last row piece assembled='' sep='' i
    P=$(hk_agent claude mixed_budget)
    socket=$(t display -p '#{socket_path}')
    sqx "$CNTCTR_DB" "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<205)
        INSERT INTO posts(scope,sender,text,at)
        SELECT '$U5_SCOPE','mixed_fixture',printf('batch-%03d:',i) ||
          CASE i%3 WHEN 1 THEN 'small' WHEN 2 THEN printf('%03000d',0) ELSE printf('%06000d',0) END,
          strftime('%s','now') FROM n;
        INSERT INTO mail(post,name,pane,socket,hooked,shown)
        SELECT rowid,'mixed_budget','$P','$socket',1,CASE WHEN length(text)>6000 THEN 1 ELSE 0 END
        FROM posts WHERE scope='$U5_SCOPE' AND sender='mixed_fixture';"
    first=$(sq "$CNTCTR_DB" "SELECT min(post) FROM mail WHERE pane='$P'")
    last=$(sq "$CNTCTR_DB" "SELECT max(post) FROM mail WHERE pane='$P'")
    for i in 1 2 3 4 5 6 7; do
        row=$((first + i - 1))
        piece=$(sq "$CNTCTR_DB" "SELECT text FROM posts WHERE rowid=$row")
        if [ "$((i % 3))" -eq 0 ]; then
            piece=$(printf '%s\n[5610 more bytes omitted: call board id=%s]' "${piece:0:400}" "$row")
        fi
        assembled="$assembled$sep$piece"
        sep=$'\n\n'
    done
    ans=$(c_prompt "$P" "$(pointer "$last")")
    same "205 mixed mails yield the exact oldest fitting seven rows" "$(ctx_c "$ans")" "$assembled"
    check "205 mixed mails stay within the serialized hook budget" "$((${#ans} <= 8192))" 1
    same "only the seven emitted rows are staged" "$(sq "$CNTCTR_DB" "SELECT count(*) FROM mail WHERE pane='$P' AND state='staged'")" 7
    same "the newest wake leaves the newest mail pending" "$(mstate "$last")" "pending/0/0"
    c_stop "$P" true >/dev/null
    same "one Stop delivers only the five full bodies in a mixed answer" "$(sq "$CNTCTR_DB" "SELECT count(*) FROM mail WHERE pane='$P' AND delivered=1")" 5
    same "the two excerpted bodies in a mixed answer remain unread" "$(sq "$CNTCTR_DB" "SELECT count(*) FROM mail WHERE pane='$P' AND shown=2 AND state='staged' AND delivered=0")" 2
    out=$(txt "$(call "$P" board '{"mode":"mail","offset":200}')")
    same "index beyond the 200th item returns five entries and a footer" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 6
    same "index total is independent of the recent board cap" "$(printf '%s\n' "$out" | tail -n 1)" "205 total mail"


    # An exact mail lookup must work after the mail falls outside the recent board window.
    P=$(hk_agent claude lookup_owner)
    Q=$(hk_agent claude lookup_other)
    m=$(mailput "$P" e1000010 "$(mail_text e1000010 'old lookup body')" 0)
    sqx "$CNTCTR_DB" "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<205)
        INSERT INTO posts(scope,sender,text,at) SELECT '$U5_SCOPE','sender','newer',strftime('%s','now') FROM n"
    out=$(txt "$(call "$P" board "{\"id\":$m}")")
    check "board id retrieves old mail beyond 200 posts" "$out" "old lookup body"
    ans=$(call "$Q" board "{\"id\":$m}")
    same "board id rejects another agent's mail" "$(iserr "$ans")" true
    same "board id does not disclose another agent's mail" "$(txt "$ans")" "mail not found"

    # A name fallback is scoped to the project and server. A live pane survives a cwd change.
    local lookup_dir="$TMPD/other_lookup_project" same_name other_sock
    mkdir "$lookup_dir"
    git -C "$lookup_dir" init -q
    same_name=$(newpane lookup_owner)
    same "board id permits the same name on the same project and socket" "$(txt "$(call "$same_name" board "{\"id\":$m}")")" "$(mail_text e1000010 'old lookup body')"
    t respawn-pane -k -t "$same_name" -c "$lookup_dir" cat
    t set -p -t "$same_name" @cntctr_name lookup_owner
    same "board id denies a same-name caller in a different project" "$(txt "$(call "$same_name" board "{\"id\":$m}")")" "mail not found"
    t2 new-session -d -s lookup -c "$PWD" cat
    other_sock=$(t2 display -p '#{socket_path}')
    same_name=$(t2 display -p '#{pane_id}')
    t2 set -p -t "$same_name" @cntctr_name lookup_owner
    ans=$(TMUX="$other_sock,0,0" call_raw "$same_name" board "{\"id\":$m}")
    same "board id denies a same-name caller on a different socket" "$(txt "$ans")" "mail not found"
    t2 kill-server
    t respawn-pane -k -t "$P" -c "$lookup_dir" cat
    t set -p -t "$P" @cntctr_name lookup_owner
    same "board id permits the bound pane after its cwd changes" "$(txt "$(call "$P" board "{\"id\":$m}")")" "$(mail_text e1000010 'old lookup body')"

    # Discard the first answer. The continuation Stop acknowledges the staged attempt.
    P=$(hk_agent claude mail_index_owner)
    body=$(mail_text e1000015 "$(printf 'index recovery preview\nbody available only by ID')")
    m=$(mailput "$P" e1000015 "$body" 0)
    c_stop "$P" >/dev/null
    same "discarded first Stop still records one attempt" "$(sq "$CNTCTR_DB" "SELECT shown FROM mail WHERE post=$m")" 1
    c_stop "$P" true >/dev/null
    same "continuation Stop acknowledges the full attempt" "$(mstate "$m")" "delivered/1/1"

    local pending staged stalled page_ids
    pending=$(mailput "$P" e1000016 "$(mail_text e1000016 'pending index mail')" 0)
    staged=$(mailput "$P" e1000017 "$(mail_text e1000017 'staged index mail')" 1)
    stalled=$(mailput "$P" e1000018 "$(mail_text e1000018 'stalled index mail')" 3)
    sqx "$CNTCTR_DB" "UPDATE mail SET state='staged',shown=1,lease_until=strftime('%s','now')+300 WHERE post=$staged;
        UPDATE mail SET state='stalled',shown=3 WHERE post=$stalled;
        WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<205)
        INSERT INTO posts(scope,sender,text,at) SELECT '$U5_SCOPE','sender','newer than lost attempt',strftime('%s','now') FROM n;"
    out=$(txt "$(call "$P" board '{"limit":200}')")
    refute "recent board no longer lists the lost body" "$out" "index recovery preview"
    check "recent board points to omitted mail" "$out" "board mode=mail"
    out=$(txt "$(call "$P" board '{"mode":"mail","limit":2}')")
    page_ids=$(printf '%s\n' "$out" | sed -n 's/^id=\([0-9]*\) .*/\1/p')
    same "index page one lists newest mail without gaps" "$page_ids" "$(printf '%s\n%s' "$stalled" "$staged")"
    check "index page one reports total and next cursor" "$out" "4 total mail [more: call board mode=mail before=$staged limit=2]"
    check "index includes the stalled state and both counters" "$out" "id=$stalled sender=sender state=stalled attempts=3 presentations=3 bytes="
    same "listing staged mail does not acknowledge it" "$(mstate "$staged")" "staged/1/0"
    out=$(txt "$(call "$P" board '{"mode":"mail","limit":2,"offset":2}')")
    page_ids=$(printf '%s\n' "$out" | sed -n 's/^id=\([0-9]*\) .*/\1/p')
    same "index page two continues with no overlap" "$page_ids" "$(printf '%s\n%s' "$pending" "$m")"
    same "final index footer gives the same total" "$(printf '%s\n' "$out" | tail -n 1)" "4 total mail"
    check "index entry exposes delivered ID and byte count with one-line excerpt" "$out" "id=$m sender=sender state=delivered attempts=1 presentations=1 bytes=${#body} | index recovery preview..."
    refute "index omits the remaining body" "$out" "body available only by ID"
    same "index output has one line per entry and one footer" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 3
    mailput "$P" e1000019 "$(mail_text e1000019 'arrived between index pages')" 0 >/dev/null
    ans=$(call "$P" board "$(printf '{"mode":"mail","limit":2,"before":%s}' "$staged")")
    out=$(txt "$ans")
    page_ids=$(printf '%s\n' "$out" | sed -n 's/^id=\([0-9]*\) .*/\1/p')
    same "cursor page neither repeats nor skips after insertion" "$page_ids" "$(printf '%s\n%s' "$pending" "$m")"
    same "cursor footer counts new mail without advertising an empty page" "$(printf '%s\n' "$out" | tail -n 1)" "5 total mail"
    same "exact lookup recovers the entire lost body by listed ID" "$(txt "$(call "$P" board "{\"id\":$m}")")" "$body"
    same "index leaves pending mail pending" "$(mstate "$pending")" "pending/0/0"

    t2 new-session -d -s mail_index -c "$PWD" cat
    other_sock=$(t2 display -p '#{socket_path}')
    same_name=$(t2 display -p '#{pane_id}')
    t2 set -p -t "$same_name" @cntctr_name mail_index_owner
    ans=$(TMUX="$other_sock,0,0" call_raw "$same_name" board '{"mode":"mail"}')
    same "same-name caller on another socket cannot list the mail index" "$(txt "$ans")" "0 total mail"
    t2 kill-server

    # The first page must stop before the two-byte character at its boundary.
    P=$(hk_agent claude lookup_large)
    local page1 page2 page3 original replies
    body=$(printf '%sé%s' "$(head -c 32767 /dev/zero | tr '\0' x)" "$(head -c 37000 /dev/zero | tr '\0' y)")
    m=$(mailput "$P" e1000012 "$body" 0)
    replies=$(SKIP=1 session "$P" 5 "$INIT" \
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"board\",\"arguments\":{\"id\":$m}}}" \
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"board\",\"arguments\":{\"id\":$m,\"offset\":32768}}}" \
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"board\",\"arguments\":{\"id\":$m,\"offset\":32767}}}" \
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"board\",\"arguments\":{\"id\":$m,\"offset\":65535}}}")
    out=$(printf '%s\n' "$replies" | jq -r 'select(.id == 2) | .result.content[0].text')
    same "first page reports the exact UTF-8 continuation offset" "${out##*$'\n'}" "[37002 bytes remain; call board id=$m offset=32767]"
    page1=${out%$'\n'*}
    out=$(printf '%s\n' "$replies" | jq -r 'select(.id == 3) | .result.content[0].text')
    same "board rejects an offset inside the multibyte character" "$out" "board offset is outside the mail or splits UTF-8"
    out=$(printf '%s\n' "$replies" | jq -r 'select(.id == 4) | .result.content[0].text')
    same "second page reports the next exact byte offset" "${out##*$'\n'}" "[4234 bytes remain; call board id=$m offset=65535]"
    page2=${out%$'\n'*}
    page3=$(printf '%s\n' "$replies" | jq -r 'select(.id == 5) | .result.content[0].text')
    original="$page1$page2$page3"
    [ "$original" = "$body" ] && ok_ || bad "all UTF-8 board pages reconstruct the exact original bytes"
    same "paginated lookups leave the mail unread" "$(mstate "$m")" "pending/0/0"

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
    ans=$(c_stop "$P")
    emptyans "$ans" && ok_ || bad "U10 another non-continuation Stop cannot hold or ack" "  got: $ans"
    same "U10 the held mail still awaits continuation" "$(mstate "$m2")" "staged/1/0"
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
    expect_screen "U6 the pane gets the pointer line" "$P" "$(pointer "$id")"
    same "U6 the pane holds that one line and nothing else" "$(screen_lines "$P")" "$(pointer "$id")"
    same "U6 the stored mail is pending with one presentation" "$(mstate "$id")" "pending/1/0"
    same "U6 the pointer spends one wake charge" "$(sqx "$CNTCTR_DB" "SELECT wake_attempts FROM mail WHERE post=$id")" 1
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
    # A busy hooked recipient cannot be woken, but its queued reply still notifies once.
    cat > "$TMPD/bin/notify-test" <<'EOF'
#!/bin/sh
printf '%s %s %s\n' "$1" "$2" "$3" >> "$CNTCTR_TEST_NOTIFY_LOG"
EOF
    chmod +x "$TMPD/bin/notify-test"
    export CNTCTR_TEST_NOTIFY_LOG="$TMPD/reply-notify.log"
    P=$(hk_agent claude u5_notify); W=$(newpane u5_notify_worker)
    out=$(txt "$(call "$P" send '{"to":"u5_notify_worker","text":"work"}')")
    task=${out#sent id=}
    c_prompt "$P" "busy" >/dev/null
    CNTCTR_NOTIFY=1 CNTCTR_NOTIFY_COMMAND="$TMPD/bin/notify-test" call "$W" reply "{\"id\":\"$task\",\"text\":\"done\"}" >/dev/null
    for _ in $(seq 100); do [ -s "$CNTCTR_TEST_NOTIFY_LOG" ] && break; sleep 0.02; done
    same "busy hooked recipient gets one reply notification from worker" "$(cat "$CNTCTR_TEST_NOTIFY_LOG" 2>/dev/null)" "reply u5_notify_worker $P"
    unset CNTCTR_TEST_NOTIFY_LOG
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
    expect_screen "U16 the pane has the line" "$P" "$(pointer "$id")"
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
    same "U17 terminal submission finishes one charged attempt" "$(sqx "$CNTCTR_DB" "SELECT state || '/' || shown || '/' || delivered FROM mail WHERE pane='$N' AND task='$task'")" "delivered/1/1"

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

    # A prompt can claim mail before the new hook generation sees its first Stop.
    P=$(hk_agent claude u5_first_stop)
    c_start "$P" >/dev/null
    id=$(mailput "$P" j3000001 "$(mail_text j3000001 'first Stop owns this body')" 1)
    ans=$(c_prompt "$P" "$(pointer "$id")")
    check "fresh generation attaches body before first Stop" "$(ctx_c "$ans")" "first Stop owns this body"
    before=$(screen "$P")
    daemon_start "$P"
    daemon_hello
    sleep 2
    same "watcher leaves body owned by fresh hook generation" "$(mstate "$id")" "staged/1/0"
    same "watcher does not paste an already attached body" "$(screen "$P")" "$before"
    c_stop "$P" >/dev/null
    same "first Stop acknowledges its own attachment" "$(mstate "$id")" "delivered/1/1"
    daemon_stop

    # A socket-scoped name can recover old mail, but cannot attach mail bound to a closed pane.
    P=$(hk_agent claude u5_reused_name)
    id=$(mailput "$P" j4000001 "$(mail_text j4000001 'board recovery on reused name')" 0)
    t kill-pane -t "$P"
    P=$(hk_agent claude u5_reused_name)
    id2=$(mailput "$P" j4000002 "$(mail_text j4000002 'mail for the replacement pane')" 0)
    daemon_start "$P"
    daemon_hello
    expect_screen "replacement pane wakes for mail it can attach" "$P" "$(pointer "$id2")"
    refute "replacement pane gets no pointer for the closed pane" "$(screen "$P")" "$(pointer "$id")"
    same "closed-pane row spent no wake presentations" "$(mstate "$id")" "pending/0/0"
    daemon_stop
    check "reused name can still recover old mail by ID" "$(txt "$(call "$P" board "{\"id\":$id}")")" "board recovery on reused name"

    # Restart the watcher and clear the idle reservation between unconsumed wakes.
    # No hook consumes the line, so these only exercise the durable wake budget.
    P=$(hk_agent claude u5_wake_budget)
    id=$(mailput "$P" j5000001 "$(mail_text j5000001 'unconsumed wake budget')" 0)
    local wake
    for wake in 1 2 3; do
        daemon_start "$P"
        daemon_hello
        wait_mstate "wake-only attempt $wake survives watcher restart" "$id" "pending/$wake/0"
        daemon_stop
        sqx "$CNTCTR_DB" "UPDATE hook_sessions SET wake_reserved=0,wake_at=NULL WHERE pane='$P';"
    done
    id2=$(mailput "$P" j5000002 "$(mail_text j5000002 'mail behind exhausted wakes')" 0)
    daemon_start "$P"
    daemon_hello
    expect_screen "exhausted wake budget does not block later mail" "$P" "$(pointer "$id2")"
    same "fourth unconsumed wake did not increment presentations" "$(mstate "$id")" "pending/3/0"
    daemon_stop
    ans=$(c_prompt "$P" "$(pointer "$id")")
    check "exhausted wake can still attach its first body" "$(ctx_c "$ans")" "unconsumed wake budget"
}

# list_call: the long-lived server (daemon_start) learns its agent's identity, which starts its mail retry thread
daemon_hello() { daemon_send '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list","arguments":{}}}'; }
notices() { sqx "$CNTCTR_DB" "SELECT count(*) FROM posts WHERE text LIKE '%undelivered after 3 attempts: $1 to %'"; }

u5p4_run() {
    local S Q P id task out i before ans lines payload envelope
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
        same "U11 presentation $i has the full small envelope" "$(ctx_a "$ans")" "$(sq "$CNTCTR_DB" "SELECT text FROM posts WHERE rowid=$id")"
        same "U11 presentation $i is staged" "$(mstate "$id")" "staged/$i/0"
        a_stop "$Q" ERROR >/dev/null
        expire_mail "$id"
        a_stop "$Q" ERROR >/dev/null # Reconcile the expired lease during an event.
        if [ "$i" -lt 3 ]; then wait_mstate "U11 after an error Stop the retry thread types the line again" "$id" "pending/$((i + 1))/0"; fi
    done
    wait_mstate "U11 the third presentation went unanswered: stalled" "$id" "stalled/3/0"
    before=$(screen "$Q")
    ans=$(a_pre "$Q" 0 "$(pointer "$id")")
    emptyans "$ans" && ok_ || bad "U11 the fourth event attaches nothing" "  got: $ans"
    sleep 3
    same "U11 the retry thread types nothing for a stalled mail" "$(screen "$Q")" "$before"
    same "U11 the sender has one undelivered mail" "$(notices "$id")" 1
    check "U11 it names the mail and the addressee" "$(txt "$(call "$S" board '{}')")" "undelivered after 3 attempts: $id to u5_k1; recipient can call board id=$id"
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

    # Replaying an old line without a Stop still spends the body budget.
    P=$(hk_agent claude stale_replay)
    envelope=$(mail_text e4000001 'stale pointer replay body')
    id=$(mailput "$P" e4000001 "$envelope" 9)
    for i in 1 2 3; do
        ans=$(c_prompt "$P" "$(pointer "$id")")
        same "stale replay body $i" "$(ctx_c "$ans")" "$envelope"
        same "stale replay charges body $i" "$(sq "$CNTCTR_DB" "SELECT shown FROM mail WHERE post=$id")" "$i"
        expire_mail "$id"
    done
    sqx "$CNTCTR_DB" "CREATE TRIGGER fail_stall_notice BEFORE INSERT ON posts
        WHEN NEW.sender='cntctr' AND NEW.text LIKE '%undelivered after 3 attempts: $id to %'
        BEGIN SELECT RAISE(ABORT, 'injected notice error'); END;"
    ans=$(c_prompt "$P" "$(pointer "$id")")
    emptyans "$ans" && ok_ || bad "fourth stale replay attaches nothing" "  got: $ans"
    same "failed stall notice rolls back lease expiry" "$(mstate "$id")" "staged/9/0"
    same "failed notice leaves no partial board post" "$(notices "$id")" 0
    local other other_id
    other=$(hk_agent claude independent_stall_notice)
    other_id=$(mailput "$other" e4000010 "$(mail_text e4000010 'unrelated fresh body')" 1)
    ans=$(c_prompt "$other" "$(pointer "$other_id")")
    check "failed stall notice leaves unrelated hook delivery working" "$(ctx_c "$ans")" "unrelated fresh body"
    same "unrelated mail records its own claim" "$(mstate "$other_id")" staged/1/0
    sqx "$CNTCTR_DB" "DROP TRIGGER fail_stall_notice"
    ans=$(c_prompt "$P" "$(pointer "$id")")
    emptyans "$ans" && ok_ || bad "fifth stale replay attaches nothing" "  got: $ans"
    same "stale replay stalls with the wake count unchanged" "$(mstate "$id")" "stalled/9/0"
    same "stale replay tells the sender once" "$(notices "$id")" 1

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

    # A quiet hook gets the same excerpt and body cap as a responding hook.
    P=$(hk_agent claude quiet_repeat)
    payload=$(head -c 1100 /dev/zero | tr '\0' x)
    envelope=$(printf '[cntctr from=sender id=e4000002]\n%s\n[cntctr end id=e4000002]' "$payload")
    id=$(mailput "$P" e4000002 "$envelope" 0)
    sqx "$CNTCTR_DB" "UPDATE mail SET shown=1, hooked=1 WHERE post=$id; UPDATE hook_sessions SET broken=1 WHERE pane='$P'"
    daemon_start "$P"
    daemon_hello
    expect_screen "quiet repeat keeps the original closing marker" "$P" "[cntctr end id=e4000002]"
    expect_screen "quiet repeat names the exact omitted byte count and lookup" "$P" "[700 more bytes omitted: call board id=$id]"
    refute "quiet repeat does not paste the full payload" "$(screen "$P")" "$payload"
    for i in 2 3; do
        wait_shown "$id" "$i"
        expire_mail "$id"
    done
    wait_mstate "quiet repeat stops after the third body" "$id" "stalled/0/0"
    same "quiet repeat charges the two fallbacks and the first hook body" "$(sq "$CNTCTR_DB" "SELECT shown FROM mail WHERE post=$id")" 3
    same "quiet repeat tells the sender once" "$(notices "$id")" 1
    daemon_stop

    # A DB failure after a full paste must preserve the charged attempt.
    P=$(hk_agent claude quiet_charge)
    payload=$(head -c 800 /dev/zero | tr '\0' x)
    envelope=$(printf '[cntctr from=sender id=e4000003]\n%600s\nFULL-ONLY-CHARGE-MARKER\n%s\n[cntctr end id=e4000003]' x "$payload")
    id=$(mailput "$P" e4000003 "$envelope" 0)
    sqx "$CNTCTR_DB" "UPDATE hook_sessions SET broken=1 WHERE pane='$P';
        CREATE TRIGGER fail_paste_delivery BEFORE UPDATE OF delivered ON mail
        WHEN OLD.post=$id AND NEW.delivered=1
        BEGIN SELECT RAISE(ABORT, 'injected post-paste commit error'); END;"
    daemon_start "$P"
    daemon_hello
    expect_screen "quiet paste reaches the pane before the delivery update fails" "$P" "FULL-ONLY-CHARGE-MARKER"
    for i in 1 2 3; do
        wait_shown "$id" "$i"
        expire_mail "$id"
    done
    wait_mstate "quiet paste spends three body attempts despite the update failure" "$id" "stalled/0/0"
    same "quiet paste never retries the full oversized body" "$(screen "$P" | grep -c 'FULL-ONLY-CHARGE-MARKER')" 2
    same "failed delivery update still leaves three recorded attempts" "$(sq "$CNTCTR_DB" "SELECT shown FROM mail WHERE post=$id")" 3
    sqx "$CNTCTR_DB" "DROP TRIGGER fail_paste_delivery"
    daemon_stop

    # Hold Enter after the paste so a recovering hook overlaps terminal delivery.
    P=$(hk_agent claude recovering_paste)
    envelope=$(mail_text e4000004 'body already pasted before Enter')
    id=$(mailput "$P" e4000004 "$envelope" 0)
    sqx "$CNTCTR_DB" "UPDATE hook_sessions SET broken=1 WHERE pane='$P'"
    CNTCTR_ENTER_DELAY_MS=3500 daemon_start "$P"
    daemon_hello
    expect_screen "quiet fallback has already pasted the body" "$P" "body already pasted before Enter"
    ans=$(c_prompt "$P" "$(pointer "$id")")
    emptyans "$ans" && ok_ || bad "recovering hook cannot stage an in-flight paste" "  got: $ans"
    wait_mstate "the in-flight terminal attempt finalizes" "$id" "delivered/0/1"
    same "terminal attempt and racing hook spend one presentation" "$(sq "$CNTCTR_DB" "SELECT shown FROM mail WHERE post=$id")" 1
    daemon_stop

    # Failed body pastes can yield three pointers without spending any body budget.
    P=$(hk_agent claude u5_l2 sh -c 'exec /bin/cat')   # no bracketed paste: a multi-line paste is refused, one line is not
    daemon_start "$P"
    daemon_hello
    out=$(txt "$(call "$S" send '{"to":"u5_l2","text":"mail that cannot be pasted"}')")
    task=${out#sent id=}; id=$(mailid "$task")
    wait_mstate "U11b three pointers leave mail pending" "$id" "pending/3/0"
    lines=$(screen "$P" | grep -c '\[cntctr mail id=')   # cat shows each typed line twice
    same "U11b the pointer was typed three times" "$lines" 6
    refute "U11b the text itself was never typed" "$(screen "$P")" "mail that cannot be pasted"
    same "U11b pointers leave the body budget untouched" "$(sq "$CNTCTR_DB" "SELECT shown FROM mail WHERE post=$id")" 0
    same "U11b pointer-only fallback sends no stall notice" "$(notices "$id")" 0
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

    # A second server on the same project cannot use a recycled name to get mail.
    local shared_dir="$TMPD/f6_shared_project" saved_scope="$U5_SCOPE"
    mkdir "$shared_dir"
    git -C "$shared_dir" init -q
    W=$(hk_agent claude f6_shared_name)
    t respawn-pane -k -t "$W" -c "$shared_dir" cat
    t set -p -t "$W" @cntctr_name f6_shared_name
    U5_SCOPE=$(txt "$(call "$W" project '{}')" | sed -n 's/^project \(.*\) (root .*/\1/p')
    m=$(mailput "$W" f6a00002 "$(mail_text f6a00002 'first socket private body')" 0)
    t2 new-session -d -s shared -c "$shared_dir" cat
    sock2=$(t2 display -p '#{socket_path}')
    U=$(t2 display -p '#{pane_id}')
    t2 set -p -t "$U" @cntctr_name f6_shared_name
    t2 set -p -t "$U" @cntctr_srv $$
    ans=$(TMUX="$sock2,0,0" call_raw "$U" list '{}')
    refute "foreign socket mail does not count as an unread board post" "$(notice "$ans")" "unread board post"
    ans=$(TMUX="$sock2,0,0" call_raw "$U" board '{}')
    refute "recent board hides same-name mail from a different socket" "$(txt "$ans")" "first socket private body"
    same "recent board cannot acknowledge foreign-socket mail" "$(mstate "$m")" "pending/0/0"
    sqx "$CNTCTR_DB" "UPDATE mail SET state='pending', delivered=0, shown=0, presentations=0 WHERE post=$m"

    # Run its retry watcher and wait for an eligible control to prove the scan ran.
    local first_socket retry_control wake_control
    first_socket=$(t display -p '#{socket_path}')
    retry_control=$(mailput "$W" f6a00003 "$(mail_text f6a00003 'second socket retry control')" 0)
    sqx "$CNTCTR_DB" "UPDATE mail SET socket='$sock2',pane='$U' WHERE post=$retry_control"
    TMUX="$sock2,0,0" daemon_start "$U"
    daemon_hello
    wait_mstate "second socket retry delivers its positive control" "$retry_control" "delivered/0/1"
    refute "terminal retry skips same-name mail from a different socket" "$(t2 capture-pane -p -J -t "$U")" "first socket private body"
    same "terminal retry cannot acknowledge foreign-socket mail" "$(mstate "$m")" "pending/0/0"
    daemon_stop
    sqx "$CNTCTR_DB" "UPDATE mail SET state='pending', delivered=0, shown=0, presentations=0 WHERE post=$m"

    rm -f "$TMPD/hk_claude2_in" "$TMPD/hk_claude2_out"
    mkfifo "$TMPD/hk_claude2_in" "$TMPD/hk_claude2_out"
    TMUX="$sock2,0,0" "$TMPD/hook_harness/claude" "$BIN" claude < "$TMPD/hk_claude2_in" > "$TMPD/hk_claude2_out" &
    HK_PID_c2=$!
    exec 24> "$TMPD/hk_claude2_in" 25< "$TMPD/hk_claude2_out"
    read -r n <&25
    t2 set -p -t "$U" @cntctr_srv $$
    hk claude2 UserPromptSubmit "$U" '{"session_id":"foreign","hook_event_name":"UserPromptSubmit","prompt":"hello"}' >/dev/null
    hk claude2 Stop "$U" '{"session_id":"foreign","hook_event_name":"Stop","stop_hook_active":false}' >/dev/null
    wake_control=$(mailput "$W" f6a00004 "$(mail_text f6a00004 'second socket wake control')" 0)
    sqx "$CNTCTR_DB" "UPDATE mail SET socket='$sock2',pane='$U' WHERE post=$wake_control"
    t2 set -p -t "$U" @cntctr_srv $$
    TMUX="$sock2,0,0" daemon_start "$U"
    daemon_hello
    wait_mstate "second socket hook wakes for its positive control" "$wake_control" "pending/1/0"
    refute "hook wake skips same-name mail from a different socket" "$(t2 capture-pane -p -J -t "$U")" "$(pointer "$m")"
    same "hook wake leaves foreign-socket mail unchanged" "$(mstate "$m")" "pending/0/0"
    same "original mail remains on the first socket" "$(sqx "$CNTCTR_DB" "SELECT socket FROM mail WHERE post=$m")" "$first_socket"
    daemon_stop
    exec 24>&- 25<&-
    kill "$HK_PID_c2" 2>/dev/null
    wait "$HK_PID_c2" 2>/dev/null
    t2 kill-server 2>/dev/null

    U5_SCOPE="$saved_scope"

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
    # Simulate the lease expiring without a Stop, after the last event becomes stale.
    expire_mail "$id"
    sqx "$CNTCTR_DB" "UPDATE hook_sessions SET at=1 WHERE pane='$P'"
    wait_mstate "F5 with no Stop and an idle screen the mail is pending again and the line is typed a second time" "$id" "pending/2/0"
    lines=$(screen "$P" | grep -c '\[cntctr mail id=')   # cat shows each typed line twice
    same "F5 the pointer is on the screen twice, typed twice" "$lines" 4
    ans=$(c_prompt "$P" "$(pointer "$id")")
    same "F5 retry has the full small envelope" "$(ctx_c "$ans")" "$(sq "$CNTCTR_DB" "SELECT text FROM posts WHERE rowid=$id")"
    expire_mail "$id"
    sqx "$CNTCTR_DB" "UPDATE hook_sessions SET at=1 WHERE pane='$P'"
    wait_mstate "F5 again no Stop: pending, typed a third time" "$id" "pending/3/0"
    ans=$(c_prompt "$P" "$(pointer "$id")")
    same "F5 third presentation has the full small envelope" "$(ctx_c "$ans")" "$(sq "$CNTCTR_DB" "SELECT text FROM posts WHERE rowid=$id")"
    expire_mail "$id"
    sqx "$CNTCTR_DB" "UPDATE hook_sessions SET at=1 WHERE pane='$P'"
    wait_mstate "F5 the third presentation ended without delivery: stalled" "$id" "stalled/3/0"
    same "F5 the sender is told once" "$(notices "$id")" 1
    sleep 3
    same "F5 and nothing is told again" "$(notices "$id")" 1
    daemon_stop
    unset CNTCTR_WAKE_SEC
}

# f6_8: an unrecognized agy terminationReason leaves its claim unresolved and sends no reminder.
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
    same "F8 an unrecognized Stop leaves its lease unacknowledged" "$(mstate "$id")" "staged/1/0"
    same "F8 the parent is not told 'no reply after one reminder'" "$(stopped "$T")" 0
}

# f6_9: a database at the current schema version is opened without the schema script (user_version), an older one is migrated
f6_9() {
    local d="$TMPD/f6_9.db" sockpath
    sockpath=$(t display -p '#{socket_path}')
    rm -f "$d" "$d-wal" "$d-shm"
    CNTCTR_DB=$d TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    same "F9 a new database carries a schema version" "$(sqx "$d" 'PRAGMA user_version')" 9
    same "F9 and the machine row" "$(sqx "$d" "SELECT count(*) FROM meta WHERE k='machine'")" 1
    sqx "$d" "DELETE FROM meta WHERE k='machine'"
    CNTCTR_DB=$d TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    same "F9 opening a current database runs no schema script and writes no meta row" "$(sqx "$d" "SELECT count(*) FROM meta WHERE k='machine'")" 0
    sqx "$d" "ALTER TABLE mail DROP COLUMN socket; ALTER TABLE task_gate DROP COLUMN answered; PRAGMA user_version=0"
    CNTCTR_DB=$d TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    same "F9 an older database gets its columns back" "$(sqx "$d" "SELECT count(*) FROM pragma_table_info('mail') WHERE name='socket'")$(sqx "$d" "SELECT count(*) FROM pragma_table_info('task_gate') WHERE name='answered'")" 11
    same "F9 and the current version" "$(sqx "$d" 'PRAGMA user_version')" 9
    sqx "$d" "ALTER TABLE mail DROP COLUMN wake_attempts; PRAGMA user_version=6"
    CNTCTR_DB=$d TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    same "F9 version six migrates the durable wake counter" "$(sqx "$d" "SELECT count(*) FROM pragma_table_info('mail') WHERE name='wake_attempts'")$(sqx "$d" 'PRAGMA user_version')" 19
    sqx "$d" "ALTER TABLE mail DROP COLUMN lease_until;
      INSERT INTO posts(rowid,scope,sender,text,at) VALUES(41,'scope','sender','first',1),(42,'scope','sender','last',2);
      INSERT INTO mail(post,name,pane,socket,state,shown,wake_attempts,staged_turn)
        VALUES(41,'worker','%1','oldsocket','staged',2,1,'old:1'),(42,'worker','%1','oldsocket','staged',3,2,'old:1');
      INSERT INTO hook_sessions(socket,pane,harness,session_id,harness_pid,last_event,at)
        VALUES('oldsocket','%1','claude','legacy',1,'UserPromptSubmit',1);
      PRAGMA user_version=7;"
    CNTCTR_DB=$d TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    CNTCTR_DB=$d TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    same "F9 leases preserve legacy ids, bindings and charges" "$(sqx "$d" "SELECT group_concat(post||':'||pane||':'||socket||':'||state||':'||shown||':'||wake_attempts||':'||lease_until) FROM mail WHERE post IN(41,42)")" '41:%1:oldsocket:pending:2:1:0,42:%1:oldsocket:stalled:3:2:0'
    same "F9 migration creates one durable sender notice" "$(sqx "$d" "SELECT count(*) FROM posts JOIN mail ON post=posts.rowid WHERE name='sender' AND text LIKE '%board id=42'")" 1
    same "F9 migration seeds the active hook generation" "$(sqx "$d" "SELECT length(generation) FROM hook_sessions WHERE session_id='legacy'")" 32
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

# f7_2: a newer database is left untouched and writer paths refuse it.
f7_2() {
    local d="$TMPD/f7_2.db" sockpath
    sockpath=$(t display -p '#{socket_path}')
    rm -f "$d" "$d-wal" "$d-shm"
    CNTCTR_DB=$d TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    sqx "$d" "ALTER TABLE mail DROP COLUMN socket; PRAGMA user_version=999"
    same "F7.2 hook refuses newer schema" "$(CNTCTR_DB=$d TMUX="$sockpath,0,0" "$BIN" hook status %0)" no
    local response
    response=$(CNTCTR_DB=$d rpc "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"recall","arguments":{}}}' | tail -n 1)
    check "F7.2 MCP reports newer schema" "$(txt "$response")" 'newer schema'
    same "F7.2 a newer database keeps its higher stamp" "$(sqx "$d" 'PRAGMA user_version')" 999
    same "F7.2 and is not migrated by this build" "$(sqx "$d" "SELECT count(*) FROM pragma_table_info('mail') WHERE name='socket'")" 0
    sqx "$d" "PRAGMA user_version=0"
    CNTCTR_DB=$d TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    same "F7.2 an older database is migrated and stamped" "$(sqx "$d" "SELECT count(*) FROM pragma_table_info('mail') WHERE name='socket'")$(sqx "$d" 'PRAGMA user_version')" 19
}

# f7_3: an abandoned user's claim is protected until its lease expires.
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
    same "F7.3 the user's next prompt leaves the live lease staged" "$(mstate "$id")" "staged/1/0"
    expire_mail "$id"
    c_prompt "$P" "my question after expiry" >/dev/null
    same "F7.3 the expired lease becomes pending again" "$(mstate "$id")" "pending/1/0"
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
    sqx "$stamped" "INSERT INTO mail(post,name,pane,staged_turn,presentations)
        VALUES(1,'legacy','%1','old-turn',0),(2,'wake_only','%2',NULL,9);"
    CNTCTR_DB=$stamped TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    same "F8.4 legacy staging token preserves one body attempt" "$(sqx "$stamped" "SELECT shown FROM mail WHERE post=1")" 1
    same "F8.4 legacy token does not prove a full body" "$(sqx "$stamped" "SELECT staged_full FROM mail WHERE post=1")" 0
    same "F8.4 pointer-only history keeps zero body attempts" "$(sqx "$stamped" "SELECT shown FROM mail WHERE post=2")" 0
    sqx "$stamped" "UPDATE mail SET shown=2, staged_full=1 WHERE post=1;
        INSERT INTO mail(post,name,pane,staged_turn) VALUES(3,'legacy_v3','%3','old-turn');
        PRAGMA user_version=3;"
    CNTCTR_DB=$stamped TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    same "F8.4 migration preserves existing count and full-body flag" "$(sqx "$stamped" "SELECT shown||'/'||staged_full FROM mail WHERE post=1")" "2/1"
    same "F8.4 v3 token with zero attempts is backfilled" "$(sqx "$stamped" "SELECT shown||'/'||staged_full FROM mail WHERE post=3")" "1/0"
    CNTCTR_DB=$fresh TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    same "F8.4 the stamped database has the tables and columns of a new one" "$(sqx "$stamped" "$cols")" "$(sqx "$fresh" "$cols")"
    same "F8.4 the migrated database has the tables and columns of a new one" "$(sqx "$old" "$cols")" "$(sqx "$fresh" "$cols")"
    check "F8.4 (and the list is not empty)" "$(sqx "$fresh" "$cols")" "mail.socket"
}

# W1-3: hold a recorded Stop while the same harness records the next turn.
f8_5() {
    local P old id ans ready old_claim new_claim
    P=$(hk_agent claude late_stop)
    old=$(mailput "$P" f8000004 "$(mail_text f8000004 'mail for turn N')" 1)
    c_prompt "$P" "$(pointer "$old")" >/dev/null
    old_claim=$(sqx "$CNTCTR_DB" "SELECT shown||'/'||staged_turn FROM mail WHERE post=$old")
    id=$(mailput "$P" f8000005 "$(mail_text f8000005 'mail for turn N plus one')" 1)
    printf '%s' '{"session_id":"S1","hook_event_name":"Stop","stop_hook_active":false}' > "$TMPD/late_stop_event"
    touch "$TMPD/hold_stop"
    printf 'Stop %s %s %s async\n' "$TMPD/late_stop_event" "$P" "$TMPD/late_stop_answer" >&20
    read -r ready <&21
    waitfor_hook_pause "$TMPD/hold_stop.ready"
    same "paused Stop has captured its old claim before acknowledging" "$(mstate "$old")" staged/1/0
    ans=$(c_prompt "$P" "$(pointer "$id")")
    same "newer prompt stages the exact mail body" "$(ctx_c "$ans")" "$(mail_text f8000005 'mail for turn N plus one')"
    new_claim=$(sqx "$CNTCTR_DB" "SELECT shown||'/'||staged_turn FROM mail WHERE post=$id")
    rm -f "$TMPD/hold_stop"
    waitfor_hook_pause "$TMPD/late_stop_answer"
    ans=$(cat "$TMPD/late_stop_answer")
    emptyans "$ans" && ok_ || bad "displaced Stop returns a neutral answer" "  got: $ans"
    same "old Stop acknowledges exactly mail staged in its turn" "$(mstate "$old")" "delivered/1/1"
    same "old Stop cannot acknowledge mail staged in the newer turn" "$(mstate "$id")" "staged/1/0"
    same "old Stop finishes its exact attempt and token" \
        "$(sqx "$CNTCTR_DB" "SELECT shown||'/'||staged_turn FROM mail WHERE post=$old")" "$old_claim"
    same "superseded Stop preserves the newer attempt and token" \
        "$(sqx "$CNTCTR_DB" "SELECT shown||'/'||staged_turn FROM mail WHERE post=$id")" "$new_claim"
    c_stop "$P" >/dev/null
    same "Stop of the newer turn acknowledges its own mail" "$(mstate "$id")" "delivered/1/1"

    # A new SessionStart can reuse the same session ID and turn number.
    local old_token new_token
    c_start "$P" >/dev/null
    id=$(mailput "$P" f8000006 "$(mail_text f8000006 'mail across session restart')" 1)
    c_prompt "$P" "$(pointer "$id")" >/dev/null
    old_token=$(sqx "$CNTCTR_DB" "SELECT staged_turn FROM mail WHERE post=$id")
    c_start "$P" >/dev/null
    same "session restart preserves the active lease" "$(mstate "$id")" "staged/1/0"
    expire_mail "$id"
    ans=$(c_prompt "$P" "$(pointer "$id")")
    same "new generation can restage mail left by the old generation" "$(ctx_c "$ans")" "$(mail_text f8000006 'mail across session restart')"
    new_token=$(sqx "$CNTCTR_DB" "SELECT staged_turn FROM mail WHERE post=$id")
    [ -n "$old_token" ] && [ -n "$new_token" ] && [ "$old_token" != "$new_token" ] && ok_ || bad "new generation has a distinct turn token"

}

waitfor_hook_pause() {
    local i
    for i in $(seq 100); do
        [ -s "$1" ] && return
        sleep 0.01
    done
    bad "hook synchronization timed out for $1"
}

wait_for_mail_enter() {
    local i
    for i in $(seq 160); do
        [ -s "$1" ] && return
        sleep 0.05
    done
    bad "tmux Enter did not reach the lease barrier $1"
}

# Attach a pointer while its injector is still returning from tmux, in both modes.
lease_early_prompt() {
    local S P first id kind bar job out ctx
    S=$(newpane lease_waker)
    for kind in healthy quiet; do
        if [ "$kind" = quiet ]; then
            P=$(hk_agent claude lease_quiet /bin/cat)
            sqx "$CNTCTR_DB" "UPDATE hook_sessions SET broken=1 WHERE pane='$P'"
        else
            P=$(hk_agent claude lease_healthy)
        fi
        first=$(mailput "$P" l0000001 "$(mail_text l0000001 "$kind first row")" 0)
        bar="$TMPD/$kind-enter"
        : > "$bar"
        CNTCTR_TEST_MAIL_ENTER="$bar" CNTCTR_TEST_MAIL_WHEN=after \
            call "$S" send "{\"to\":\"lease_$kind\",\"text\":\"$kind pointer body\"}" > "$bar.out" &
        job=$!
        wait_for_mail_enter "$bar.ready"
        id=$(sqx "$CNTCTR_DB" "SELECT max(post) FROM mail WHERE pane='$P'")
        same "$kind wake charges before returning from tmux" \
            "$(sqx "$CNTCTR_DB" "SELECT wake_attempts||'/'||shown FROM mail WHERE post=$id")" 1/0
        same "$kind wake reserves the pane once" "$(sqx "$CNTCTR_DB" "SELECT wake_reserved FROM hook_sessions WHERE pane='$P'")" 1
        out=$(c_prompt "$P" "$(pointer "$id")")
        ctx=$(ctx_c "$out")
        check "$kind prompt claims the wake row" "$ctx" "$kind pointer body"
        check "$kind prompt also claims the older row" "$ctx" "$kind first row"
        same "$kind prompt consumes reservation at claim" "$(sqx "$CNTCTR_DB" "SELECT wake_reserved FROM hook_sessions WHERE pane='$P'")" 0
        same "$kind older row spends no wake charge" "$(sqx "$CNTCTR_DB" "SELECT wake_attempts FROM mail WHERE post=$first")" 0
        rm -f "$bar"
        wait "$job" || bad "$kind wake sender failed"
        c_stop "$P" >/dev/null
        same "$kind Stop acknowledges both charged rows" \
            "$(sqx "$CNTCTR_DB" "SELECT count(*) FROM mail WHERE post IN ($first,$id) AND shown=1 AND state='delivered'")" 2
    done
}

lease_ordinary_prompt() {
    local S P id now out before
    S=$(newpane lease_prompt_sender); P=$(hk_agent claude lease_prompt_live)
    out=$(txt "$(call "$S" send '{"to":"lease_prompt_live","text":"keep queued after ordinary prompt"}')")
    id=$(mailid "${out#sent id=}")
    same "wake is reserved before an ordinary prompt" "$(sqx "$CNTCTR_DB" "SELECT wake_reserved FROM hook_sessions WHERE pane='$P'")" 1
    # Put the original deadline one second away under the watcher interval.
    now=$(date +%s)
    sqx "$CNTCTR_DB" "UPDATE hook_sessions SET wake_at=$((now-2)) WHERE pane='$P'"
    before=$(screen "$P")
    out=$(c_prompt "$P" 'ordinary user prompt')
    emptyans "$out" && ok_ || bad "ordinary prompt does not attach mail" "  got: $out"
    same "ordinary prompt clears wake reservation and timestamp" \
        "$(sqx "$CNTCTR_DB" "SELECT wake_reserved||'/'||(wake_at IS NULL) FROM hook_sessions WHERE pane='$P'")" 0/1
    sleep 2
    CNTCTR_WAKE_SEC=3 daemon_start "$P"
    daemon_hello
    same "responsive generation stays healthy across the old wake deadline" \
        "$(sqx "$CNTCTR_DB" "SELECT broken FROM hook_sessions WHERE pane='$P'")" 0
    same "old deadline submits no terminal body" "$(screen "$P")" "$before"
    same "mail remains queued without a body claim" "$(mstate "$id")" pending/1/0
    daemon_stop
}

lease_failed_pointer_claim() {
    local S P id out now
    S=$(newpane lease_claim_sender); P=$(hk_agent claude lease_claim_live)
    out=$(txt "$(call "$S" send '{"to":"lease_claim_live","text":"wake with rejected claim"}')")
    id=$(mailid "${out#sent id=}")
    now=$(date +%s)
    sqx "$CNTCTR_DB" "UPDATE hook_sessions SET wake_at=$((now-2)) WHERE pane='$P';
        CREATE TRIGGER reject_pointer_claim BEFORE UPDATE OF state ON mail
        WHEN NEW.post=$id AND NEW.state='staged' BEGIN SELECT RAISE(ABORT,'rejected pointer claim'); END"
    same "wake is reserved before a failed pointer claim" "$(sqx "$CNTCTR_DB" "SELECT wake_reserved FROM hook_sessions WHERE pane='$P'")" 1
    out=$(c_prompt "$P" "$(pointer "$id")")
    emptyans "$out" && ok_ || bad "failed pointer claim returns no mail"
    sleep 2
    CNTCTR_WAKE_SEC=3 daemon_start "$P"
    daemon_hello
    same "failed pointer claim leaves the responsive hook healthy" \
        "$(sqx "$CNTCTR_DB" "SELECT wake_reserved||'/'||broken||(case when wake_at is null then '/empty' else '/set' end) FROM hook_sessions WHERE pane='$P'")" 0/0/empty
    same "rejected body claim remains pending" "$(mstate "$id")" pending/1/0
    refute "failed pointer does not submit a terminal body" "$(screen "$P")" "wake with rejected claim"
    daemon_stop
    sqx "$CNTCTR_DB" "DROP TRIGGER reject_pointer_claim"
}

lease_start_second() {
    local P S old id epoch out
    P=$(newpane lease_start_second); S=$(newpane lease_start_second_sender)
    epoch=$(t display -p '#{start_time}')
    old=$(mailput "$P" l0000081 "$(mail_text l0000081 'old ambiguous same-second row')" 0 "$epoch")
    sqx "$CNTCTR_DB" "CREATE TRIGGER send_at_server_start AFTER INSERT ON posts
        WHEN NEW.text LIKE '%fresh same-second body%' BEGIN UPDATE posts SET at=$epoch WHERE rowid=NEW.rowid; END"
    out=$(txt "$(call "$S" send '{"to":"lease_start_second","text":"fresh same-second body"}')")
    id=$(mailid "${out#sent id=}")
    same "new send is stamped in the server start second" "$(sqx "$CNTCTR_DB" "SELECT at FROM posts WHERE rowid=$id")" "$epoch"
    same "direct send finishes the new row in the start second" "$(mstate "$id")" delivered/0/1
    check "recipient receives fresh same-second body" "$(screen "$P")" "fresh same-second body"
    daemon_start "$P"
    daemon_hello
    daemon_stop
    same "watcher leaves an ambiguous old same-second row pending" "$(mstate "$old")" pending/0/0
    refute "old same-second body stays off terminal" "$(screen "$P")" "old ambiguous same-second row"
    P=$(hk_agent claude lease_hook_start_second)
    out=$(txt "$(call "$S" send '{"to":"lease_hook_start_second","text":"fresh same-second body for hook"}')")
    sqx "$CNTCTR_DB" "DROP TRIGGER send_at_server_start"
    check "same-second send to a hook reports board fallback" "$out" " on board"
    out=${out% on board}
    id=$(mailid "${out#sent id=}")
    same "board-only same-second row spends no automatic attempts" \
        "$(sqx "$CNTCTR_DB" "SELECT shown||'/'||wake_attempts FROM mail WHERE post=$id")" 0/0
    out=$(c_prompt "$P" "$(pointer "$id")")
    emptyans "$out" && ok_ || bad "ambiguous same-second pointer stays off the hook"
    check "hook recipient can recover the fresh body by ID" "$(txt "$(call "$P" board "{\"id\":$id}")")" "fresh same-second body for hook"
}

lease_failed_spill() {
    local P id out payload before after
    P=$(hk_agent claude lease_failed_spill)
    payload=$(head -c 18000 /dev/zero | tr '\0' x)
    id=$(mailput "$P" l0000082 "$(mail_text l0000082 "$payload")" 1)
    before=$(find "$HOME/.cache" -name 'mail-*' -type f 2>/dev/null | wc -l | tr -d ' ')
    sqx "$CNTCTR_DB" "CREATE TRIGGER fail_spill_claim BEFORE UPDATE OF state ON mail
        WHEN NEW.post=$id AND NEW.state='staged' BEGIN SELECT RAISE(ABORT,'failed spill claim'); END"
    out=$(c_prompt "$P" "$(pointer "$id")")
    emptyans "$out" && ok_ || bad "failed oversized claim returns neutral output"
    same "failed oversized claim leaves mail pending" "$(mstate "$id")" pending/1/0
    after=$(find "$HOME/.cache" -name 'mail-*' -type f 2>/dev/null | wc -l | tr -d ' ')
    same "failed oversized claim leaves no orphan spill" "$after" "$before"
    sqx "$CNTCTR_DB" "DROP TRIGGER fail_spill_claim"
}

lease_late_terminal() {
    local S P bar job id out reconciling=${1:-0}
    S=$(newpane lease_terminal_sender); P=$(newpane "lease_late_$reconciling")
    bar="$TMPD/terminal-enter-$reconciling"
    : > "$bar"
    CNTCTR_TEST_MAIL_ENTER="$bar" CNTCTR_TEST_MAIL_WHEN=before \
        call "$S" send "{\"to\":\"lease_late_$reconciling\",\"text\":\"late submission lease body\"}" > "$bar.out" &
    job=$!
    wait_for_mail_enter "$bar.ready"
    id=$(sqx "$CNTCTR_DB" "SELECT max(post) FROM mail WHERE pane='$P'")
    same "terminal attempt is durable before Enter" \
        "$(sqx "$CNTCTR_DB" "SELECT state||'/'||shown||'/'||(lease_until>strftime('%s','now')) FROM mail WHERE post=$id")" staged/1/1
    if [ "$reconciling" -eq 0 ]; then
        sqx "$CNTCTR_DB" "CREATE TRIGGER defer_terminal_reconcile BEFORE UPDATE OF state ON mail
            WHEN OLD.post=$id AND NEW.state='pending' BEGIN SELECT RAISE(IGNORE); END"
    fi
    expire_mail "$id"
    if [ "$reconciling" -eq 1 ]; then
        c_start "$P" >/dev/null
        out=$(c_prompt "$P" "$(pointer "$id")")
        emptyans "$out" && ok_ || bad "terminal row lock protects the paused emitter" "  got: $out"
    fi
    rm -f "$bar"
    wait "$job" || bad "paused terminal sender failed"
    check "late Enter finishes submitting the body" "$(screen "$P")" "late submission lease body"
    check "sender sees the expired submission left on board" "$(txt "$(cat "$bar.out")")" "on board"
    if [ "$reconciling" -eq 1 ]; then
        same "late terminal submission cannot finish a reclaimed row" "$(mstate "$id")" pending/0/0
    else
        same "late terminal submission cannot finish before reconcile" \
            "$(sqx "$CNTCTR_DB" "SELECT state||'/'||shown||'/'||delivered FROM mail WHERE post=$id")" staged/1/0
        sqx "$CNTCTR_DB" "DROP TRIGGER defer_terminal_reconcile"
        c_start "$P" >/dev/null
        same "hook entry makes the expired claim reclaimable" "$(mstate "$id")" pending/0/0
    fi
    out=$(c_prompt "$P" "$(pointer "$id")")
    check "next hook can claim the re-pended terminal body" "$(ctx_c "$out")" "late submission lease body"
    c_stop "$P" >/dev/null
    same "the new attempt alone finishes the row" \
        "$(sqx "$CNTCTR_DB" "SELECT state||'/'||shown FROM mail WHERE post=$id")" delivered/2
}

lease_failed_stop() {
    local P first id event row out q
    P=$(hk_agent claude lease_failed_stop)
    first=$(mailput "$P" l0000012 "$(mail_text l0000012 'first Stop claim')" 0)
    id=$(mailput "$P" l0000002 "$(mail_text l0000002 'rollback owned Stop claim')" 1)
    c_prompt "$P" "$(pointer "$id")" >/dev/null
    q="SELECT generation||'/'||turn||'/'||event_seq||'/'||last_event||'/'||at FROM hook_sessions WHERE pane='$P'"
    event=$(sqx "$CNTCTR_DB" "$q")
    row=$(sqx "$CNTCTR_DB" "SELECT state||'/'||shown||'/'||staged_turn||'/'||lease_until FROM mail WHERE post=$id")
    sqx "$CNTCTR_DB" "CREATE TRIGGER fail_stop_ack BEFORE UPDATE OF delivered ON mail
        WHEN NEW.post=$id AND NEW.delivered=1 BEGIN SELECT RAISE(ABORT,'failed Stop acknowledgement'); END"
    out=$(c_stop "$P")
    emptyans "$out" && ok_ || bad "failed Stop sends no decision" "  got: $out"
    same "failed Stop rolls back its event and turn" "$(sqx "$CNTCTR_DB" "$q")" "$event"
    same "failed Stop also rolls back the earlier acknowledgement" "$(mstate "$first")" staged/1/0
    same "failed Stop rolls back its claim decision" \
        "$(sqx "$CNTCTR_DB" "SELECT state||'/'||shown||'/'||staged_turn||'/'||lease_until FROM mail WHERE post=$id")" "$row"
    sqx "$CNTCTR_DB" "DROP TRIGGER fail_stop_ack"
    c_stop "$P" >/dev/null
    same "retry acknowledges both original claims" "$(mstate "$first")/$(mstate "$id")" delivered/1/1/delivered/1/1
}

lease_legacy_stage() {
    local P id db
    P=$(hk_agent claude lease_legacy)
    id=$(mailput "$P" l0000003 "$(mail_text l0000003 'active legacy claim')" 1)
    c_prompt "$P" "$(pointer "$id")" >/dev/null
    db="$TMPD/legacy-active.db"
    sqx "$CNTCTR_DB" ".backup '$db'"
    sqx "$db" "ALTER TABLE mail DROP COLUMN lease_until;
        UPDATE hook_sessions SET generation='' WHERE pane='$P'; PRAGMA user_version=7"
    same "migration keeps the active session responsive" "$(CNTCTR_DB="$db" "$BIN" hook status "$P")" yes
    same "migration seeds the active session generation" \
        "$(sqx "$db" "SELECT length(generation) FROM hook_sessions WHERE pane='$P'")" 32
    same "legacy staged claim is reclaimable with its attempt intact" \
        "$(sqx "$db" "SELECT state||'/'||shown||'/'||lease_until FROM mail WHERE post=$id")" pending/1/0
}

lease_idle_watcher() {
    local P log before
    P=$(newpane lease_idle_watcher)
    log="$TMPD/idle-tmux.log"
    CNTCTR_WAKE_SEC=1 CNTCTR_TEST_IDLE_LOG="$log" daemon_start "$P"
    daemon_hello
    # count from after the hello reply: answering it makes the last startup tmux call
    # (the unread count's @cntctr_seen_ lookup), which a fixed sleep misses on a busy machine
    for _ in $(seq 300); do jq -e 'select(.id == 2)' "$DOUT" >/dev/null 2>&1 && break; sleep 0.1; done
    before=$(wc -l < "$log")
    sleep 6   # the idle poll is capped at 4 intervals (4 s here); wait past one capped wake
    same "idle watcher makes no tmux calls across a capped idle wake" "$(wc -l < "$log")" "$before"
    daemon_stop
}

lease_stall_notice_wakes() {
    local S P id
    S=$(newpane lease_stall_sender); P=$(hk_agent claude lease_stall_worker)
    CNTCTR_WAKE_SEC=1 daemon_start "$S"
    daemon_hello
    # Ensure the sender has scanned its empty queue before giving the hook any work.
    sleep 1
    id=$(mailput "$P" l0000083 "$(mail_text l0000083 'stall for idle sender')" 1)
    sqx "$CNTCTR_DB" "UPDATE posts SET sender='lease_stall_sender' WHERE rowid=$id;
        UPDATE mail SET state='staged',shown=3,lease_until=1,from_pane='$S' WHERE post=$id"
    c_prompt "$P" 'ordinary prompt after lease expiry' >/dev/null
    same "hook stalls exhausted mail" "$(mstate "$id")" stalled/1/0
    expect_screen "hook stall wakes an idle sender without another event" "$S" "undelivered after 3 attempts: $id"
    same "hook created one notice for the sleeping sender" "$(notices "$id")" 1
    same "stall notice carries no return route" "$(sqx "$CNTCTR_DB" "SELECT '['||from_pane||'/'||from_scope||']' FROM mail JOIN posts ON posts.rowid=mail.post WHERE text LIKE '%undelivered after 3 attempts: $id to %'")" "[/]"
    daemon_stop
}

lease_attach_idle_watcher() {
    local S P id i
    S=$(newpane lease_attach_sender); P=$(hk_agent claude lease_attach_worker)
    CNTCTR_WAKE_SEC=1 daemon_start "$S"
    daemon_hello
    sleep 1   # the sender's watcher has scanned an empty queue and sleeps
    id=$(mailput "$P" l0000084 "$(mail_text l0000084 'third body for idle sender')" 1)
    sqx "$CNTCTR_DB" "UPDATE posts SET sender='lease_attach_sender' WHERE rowid=$id;
        UPDATE mail SET shown=2,from_pane='$S' WHERE post=$id"
    c_prompt "$P" "$(pointer "$id")" >/dev/null
    same "pointer attach stages the third body" "$(sqx "$CNTCTR_DB" "SELECT state||'/'||shown FROM mail WHERE post=$id")" staged/3
    expire_mail "$id"   # no hook event or FIFO byte follows
    for i in $(seq 100); do [ "$(mstate "$id")" = stalled/1/0 ] && break; sleep 0.1; done
    same "idle watcher stalls the attached lease on its own" "$(mstate "$id")" stalled/1/0
    for i in $(seq 50); do [ "$(notices "$id")" = 1 ] && break; sleep 0.1; done
    same "idle watcher creates the notice on its own" "$(notices "$id")" 1
    daemon_stop
}

lease_deadlines() {
    local S P id fifo start i out
    S=$(newpane lease_deadline_watcher); P=$(hk_agent claude lease_deadline_target)
    id=$(mailput "$P" l0000004 "$(mail_text l0000004 'dropped hook response near the cap')" 1)
    sqx "$CNTCTR_DB" "UPDATE mail SET shown=2,wake_attempts=3 WHERE post=$id"
    c_prompt "$P" "$(pointer "$id")" >/dev/null
    same "dropping host response keeps the third attempt charged" \
        "$(sqx "$CNTCTR_DB" "SELECT state||'/'||shown||'/'||wake_attempts FROM mail WHERE post=$id")" staged/3/3
    start=$(date +%s)
    sqx "$CNTCTR_DB" "UPDATE hook_sessions SET wake_reserved=1,wake_at=$((start-5)) WHERE pane='$P';
        UPDATE mail SET pane='%99999',lease_until=$((start+3)) WHERE post=$id"
    CNTCTR_WAKE_SEC=8 daemon_start "$S"
    daemon_hello
    fifo="$(realpath "${TMPDIR:-/tmp}")/cntctr-$(id -u)/tools/$DPID.fifo"
    for i in $(seq 50); do [ -p "$fifo" ] && break; sleep 0.02; done
    if [ -p "$fifo" ]; then
        printf m > "$fifo"
    else
        bad "deadline watcher registered its FIFO"
    fi
    for i in $(seq 120); do
        [ "$(sqx "$CNTCTR_DB" "SELECT state FROM mail WHERE post=$id")" = stalled ] && break
        [ "$(date +%s)" -lt "$((start+7))" ] || break
        sleep 0.05
    done
    same "early FIFO scan preserves the original wake deadline" \
        "$(sqx "$CNTCTR_DB" "SELECT wake_reserved||'/'||broken FROM hook_sessions WHERE pane='$P'")" 0/1
    same "watcher stalls an expired cap even with no eligible recipient" "$(mstate "$id")" stalled/1/0
    same "lease expiry and one sender notice commit together" "$(notices "$id")" 1
    daemon_stop
    daemon_start "$S"
    daemon_hello
    same "restart cannot give the capped row another body charge" \
        "$(sqx "$CNTCTR_DB" "SELECT state||'/'||shown FROM mail WHERE post=$id")" stalled/3
    same "restart cannot duplicate sender notice" "$(notices "$id")" 1
    daemon_stop
}

f8_6() {
    lease_idle_watcher
    lease_stall_notice_wakes
    lease_attach_idle_watcher
    lease_early_prompt
    lease_ordinary_prompt
    lease_failed_pointer_claim
    lease_start_second
    lease_failed_spill
    lease_late_terminal
    lease_late_terminal 1
    lease_failed_stop
    lease_legacy_stage
    lease_deadlines
}

b_race_schema() {
    local fresh="$TMPD/b_race_schema.db" sockpath version generation session
    sockpath=$(t display -p '#{socket_path}')
    CNTCTR_DB=$fresh TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    version=$(sq "$fresh" 'PRAGMA user_version')
    sq "$fresh" "ALTER TABLE hook_sessions DROP COLUMN generation; PRAGMA user_version=0;
        INSERT INTO hook_sessions(socket,pane,harness,session_id,harness_pid,last_event,at,turn)
        VALUES('legacy','%0','claude','S1',1,'UserPromptSubmit',0,3)"
    CNTCTR_DB=$fresh TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    same "B F9 older database gets generation column" \
        "$(sq "$fresh" "SELECT count(*) FROM pragma_table_info('hook_sessions') WHERE name='generation'")" 1
    same "B F9 re-opened database gets current schema stamp" "$(sq "$fresh" 'PRAGMA user_version')" "$version"
    session="SELECT session_id||'/'||turn||'/'||generation FROM hook_sessions WHERE socket='legacy' AND pane='%0'"
    generation=$(sq "$fresh" "$session")
    case "$generation" in
        S1/3/?*) ok_ ;;
        *) bad "B F9 schema preserves the older session and backfills its generation" " got: $generation" ;;
    esac
    CNTCTR_DB=$fresh TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    same "B F9 another open keeps the migrated session generation" "$(sq "$fresh" "$session")" "$generation"
}

b_race_migration() {
    local stamped="$TMPD/b_race_stamped.db" sockpath bindings before claims
    sockpath=$(t display -p '#{socket_path}')
    sqlite3 "$stamped" < tests/schema_stamp1.sql
    sq "$stamped" "INSERT INTO hook_sessions(socket,pane,harness,session_id,harness_pid,last_event,at,turn)
        VALUES('socket-a','%0','claude','S1',1,'UserPromptSubmit',0,3);
        INSERT INTO posts(rowid,scope,sender,text,at)
        VALUES(1,'project','sender','active turn body',1),
              (2,'project','sender','another socket body',1),
              (3,'project','sender','another pane body',1);
        INSERT INTO mail(post,name,pane,socket,state,staged_turn,presentations)
        VALUES(1,'worker','%0','socket-a','staged','S1:3',1),
              (2,'worker','%0','socket-b','staged','S1:3',2),
              (3,'worker','%1','socket-a','staged','S1:3',3)"
    bindings="SELECT post,name,pane,socket,staged_turn,presentations,scope,sender,text,at
        FROM mail JOIN posts ON posts.rowid=mail.post ORDER BY post"
    before=$(sq "$stamped" "$bindings")

    CNTCTR_DB=$stamped TMUX="$sockpath,0,0" "$BIN" hook status %0 >/dev/null
    # Legacy tokens account for one attempt but provide no live lease or proof of a full body.
    claims="SELECT state||'/'||shown||'/'||wake_attempts||'/'||delivered||'/'||staged_full||'/'||lease_until FROM mail"
    same "B F8.4 migration requeues active turn mail with its legacy attempt" \
        "$(sq "$stamped" "$claims WHERE post=1")" pending/1/0/0/0/0
    same "B F8.4 migration requeues another socket's legacy claim" \
        "$(sq "$stamped" "$claims WHERE post=2")" pending/1/0/0/0/0
    same "B F8.4 migration requeues another pane's legacy claim" \
        "$(sq "$stamped" "$claims WHERE post=3")" pending/1/0/0/0/0
    same "B F8.4 migration preserves post bodies, bindings and legacy token history" \
        "$(sq "$stamped" "$bindings")" "$before"
    same "B F8.4 migration seeds generation and preserves active session identity" \
        "$(sq "$stamped" "SELECT session_id||'/'||harness_pid||'/'||turn||'/'||(generation!='')
          FROM hook_sessions WHERE socket='socket-a' AND pane='%0'")" S1/1/3/1
}

b_race_mail() {
    sqx "$CNTCTR_DB" "SELECT state||'/'||shown||'/'||wake_attempts||'/'||delivered FROM mail WHERE post=$1"
}

b_race_resume() {
    local p m change body generation prior claim out
    for change in SessionStart PID; do
        p=$(hk_agent claude "race_resume_$change")
        body=$(mail_text race0001 "old turn mail before $change")
        m=$(mailput "$p" race0001 "$body" 1)
        c_prompt "$p" "$(pointer "$m")" >/dev/null
        same "race $change initially stages one body attempt" "$(b_race_mail "$m")" staged/1/0/0
        generation=$(sqx "$CNTCTR_DB" "SELECT generation FROM hook_sessions WHERE pane='$p'")
        claim="SELECT staged_turn||'/'||staged_full||'/'||lease_until FROM mail WHERE post=$m"
        prior=$(sqx "$CNTCTR_DB" "$claim")
        check "race $change old claim belongs to old generation" "$prior" "$generation:"
        if [ "$change" = SessionStart ]; then
            c_start "$p" >/dev/null
        else
            sq "$CNTCTR_DB" "UPDATE hook_sessions SET harness_pid=harness_pid+1 WHERE pane='$p'"
        fi
        c_prompt "$p" "unrelated new turn" >/dev/null
        same "race $change changes generation" \
            "$(sqx "$CNTCTR_DB" "SELECT length(generation)>0 AND generation!='$generation' FROM hook_sessions WHERE pane='$p'")" 1
        c_stop "$p" true >/dev/null
        same "race $change cannot acknowledge an unexpired old claim" "$(b_race_mail "$m")" staged/1/0/0
        same "race $change preserves old claim and deadline" "$(sqx "$CNTCTR_DB" "$claim")" "$prior"

        expire_mail "$m"
        c_prompt "$p" "after the old claim expires" >/dev/null
        same "race $change expiry makes the old row eligible again" "$(b_race_mail "$m")" pending/1/0/0
        out=$(c_prompt "$p" "$(pointer "$m")")
        check "race $change reattaches the original envelope" "$(ctx_c "$out")" "$body"
        same "race $change reattachment charges a second body attempt" "$(b_race_mail "$m")" staged/2/0/0
        same "race $change reattachment uses the new generation and a live lease" \
            "$(sqx "$CNTCTR_DB" "SELECT count(*) FROM mail m JOIN hook_sessions h USING(socket,pane)
              WHERE m.post=$m AND m.staged_turn=h.generation||':'||h.turn||':'||h.event_seq
              AND m.staged_full=1 AND m.lease_until>strftime('%s','now')")" 1
        c_stop "$p" >/dev/null
        same "race $change current Stop acknowledges the reattached claim" "$(b_race_mail "$m")" delivered/2/0/1
    done
}

b_race_wait_mail() {
    local label=$1 post=$2 expected=$3 i actual
    for i in $(seq 80); do
        actual=$(b_race_mail "$post")
        [ "$actual" = "$expected" ] && break
        sleep 0.1
    done
    same "$label" "$actual" "$expected"
}

b_race_retry() {
    local sender p q m foreign own other_claims other_rows wake
    sender=$(newpane race_sender)
    p=$(hk_agent claude race_owner)
    q=$(hk_agent claude race_other)
    t set -p -t "$p" @cntctr_parent "$sender"
    m=$(mailput "$q" race0002 "$(mail_text race0002 'other pane mail')" 1)
    foreign=$(mailput "$q" race0003 "$(mail_text race0003 'other socket mail')" 0)
    c_prompt "$q" "$(pointer "$m")" >/dev/null
    sq "$CNTCTR_DB" "UPDATE mail SET name='race_owner' WHERE post IN ($m,$foreign);
        UPDATE mail SET socket=socket||'-other',pane='$p' WHERE post=$foreign"
    same "race other pane initially has an active body claim" "$(b_race_mail "$m")" staged/1/0/0
    same "race other socket initially has an active body claim" "$(b_race_mail "$foreign")" staged/1/0/0
    other_rows="SELECT post,state,shown,wake_attempts,delivered,staged_turn,staged_full,lease_until
        FROM mail WHERE post IN ($m,$foreign) ORDER BY post"
    other_claims=$(sqx "$CNTCTR_DB" "$other_rows")

    own=$(mailput "$p" race0004 "$(mail_text race0004 'own pane mail')" 1)
    c_prompt "$p" "$(pointer "$own")" >/dev/null
    sq "$CNTCTR_DB" "UPDATE mail SET wake_attempts=1 WHERE post=$own;
        UPDATE hook_sessions SET at=strftime('%s','now')-130 WHERE pane='$p'"
    same "race owner starts with one body attempt and one prior wake" "$(b_race_mail "$own")" staged/1/1/0
    expire_mail "$own"

    wake="SELECT broken||'/'||wake_reserved||'/'||(wake_at IS NOT NULL) FROM hook_sessions WHERE pane='$p'"
    export CNTCTR_WAKE_SEC=20
    daemon_start "$p"
    daemon_hello
    b_race_wait_mail "race expired claim releases owner mail and charges a wake only" "$own" pending/1/2/0
    same "race retry records a new wake reservation" "$(sqx "$CNTCTR_DB" "$wake")" 0/1/1
    same "race retry preserves both foreign claims" "$(sqx "$CNTCTR_DB" "$other_rows")" "$other_claims"
    daemon_stop
    check "race retry types the owner's pointer" "$(screen "$p")" "$(pointer "$own")"
    refute "race retry has not sent the body" "$(screen "$p")" "own pane mail"

    sq "$CNTCTR_DB" "UPDATE hook_sessions SET wake_at=1 WHERE pane='$p' AND wake_reserved=1"
    daemon_start "$p"
    daemon_hello
    b_race_wait_mail "race expired wake triggers a terminal body attempt" "$own" delivered/2/2/1
    same "race terminal fallback clears the expired reservation and marks the hook broken" "$(sqx "$CNTCTR_DB" "$wake")" 1/0/0
    same "race terminal fallback preserves both foreign claims" "$(sqx "$CNTCTR_DB" "$other_rows")" "$other_claims"
    check "race terminal fallback types the owner's full envelope" "$(screen "$p")" "[cntctr end id=race0004]"
    daemon_stop
    unset CNTCTR_WAKE_SEC
}

b_race_driver() {
    cat > "$TMPD/race_driver.c" <<'EOF'
#define main cntctr_original_main
#include "cntctr.c"
#undef main

/* Hold Stop after capturing its entry turn and before recording/acking it. */
static int pause_before_record(const char *ready_path, const char *go_path) {
    FILE *ready = fopen(ready_path, "w");
    if (!ready || fclose(ready)) return 0;
    for (int i = 0; i < 500 && access(go_path, F_OK); i++) usleep(10000);
    return access(go_path, F_OK) == 0;
}

int main(int argc, char **argv) {
    if (argc != 4 && argc != 6) return 2;
    const char *socket = argv[1], *pane = argv[2], *harness = "claude";
    long pid = atol(argv[3]);
    char *err = NULL;
    sqlite3 *db = kb_timed(&err, 1000);
    free(err);
    if (!db) return 1;

    struct hook_event event = {.session="S1", .kind="Stop", .prompt="", .reason=""};
    struct recorded_hook entry, record;
    if (capture_stop(db, socket, pane, harness, pid, event.session, &entry) != SQLITE_ROW ||
        (argc == 6 && !pause_before_record(argv[4], argv[5]))) {
        sqlite3_close(db);
        return 2;
    }

    json_object *answer = NULL;
    if (record_hook(db, socket, pane, harness, pid, &event, 0, &entry, &record))
        answer = hook_stop(db, socket, pane, harness, &event, &record);
    puts(answer ? json_object_to_json_string_ext(answer, JSON_C_TO_STRING_PLAIN) : "{}");
    if (answer) json_object_put(answer);
    sqlite3_close(db);
    return 0;
}
EOF
    local jsonc qjs_objs="" qf
    jsonc=$(brew --prefix json-c 2>/dev/null || echo /usr/local)
    for qf in dtoa libregexp libunicode quickjs; do
        if [ -f "build/qjs/$qf.o" ]; then
            qjs_objs="$qjs_objs build/qjs/$qf.o"
        else
            "${CC:-cc}" -std=c11 -O1 -D_GNU_SOURCE -w -c "vendor/quickjs/$qf.c" -o "$TMPD/qjs_$qf.o" || { bad "race could not build the Stop driver"; return 1; }
            qjs_objs="$qjs_objs $TMPD/qjs_$qf.o"
        fi
    done
    if ! "${CC:-cc}" -std=c11 -O1 -pthread -I. -Ivendor/quickjs -I"$jsonc/include" -o "$TMPD/race_driver" \
        "$TMPD/race_driver.c" kb.c fleet.c hooks.c usage.c code_schema.c code_js.c code_mcp.c code_daemon.c $qjs_objs -L"$jsonc/lib" -ljson-c -lsqlite3 -lm; then
        bad "race could not build the Stop driver"
        return 1
    fi
}

b_race_interleave() {
    local p old renewed next sock pid driver i out old_claim new_claim claims event hook_row
    b_race_driver || return
    p=$(hk_agent claude race_interleave)
    sock=$(t display -p '#{socket_path}')
    pid=$(sqx "$CNTCTR_DB" "SELECT harness_pid FROM hook_sessions WHERE pane='$p'")
    old=$(mailput "$p" race0005 "$(mail_text race0005 'live old turn mail')" 1)
    renewed=$(mailput "$p" race0006 "$(mail_text race0006 'old turn mail to reclaim')" 0)
    c_prompt "$p" "$(pointer "$old")" >/dev/null
    same "race live old mail starts as a first attempt" "$(b_race_mail "$old")" staged/1/0/0
    same "race reclaimable old mail starts as a first attempt" "$(b_race_mail "$renewed")" staged/1/0/0
    old_claim=$(sqx "$CNTCTR_DB" "SELECT staged_turn FROM mail WHERE post=$old")
    next=$(mailput "$p" race0007 "$(mail_text race0007 'new turn mail')" 1)

    "$TMPD/race_driver" "$sock" "$p" "$pid" "$TMPD/race_ready" "$TMPD/race_go" > "$TMPD/race_answer" &
    driver=$!
    for i in $(seq 1 100); do
        [ -e "$TMPD/race_ready" ] && break
        sleep 0.02
    done
    if [ ! -e "$TMPD/race_ready" ] || ! sqlite3 "$CNTCTR_DB" "BEGIN IMMEDIATE; ROLLBACK" 2>/dev/null; then
        : > "$TMPD/race_go"
        wait "$driver"
        bad "race captured Stop did not yield the writer to the newer prompt"
        return
    fi

    expire_mail "$renewed"
    out=$(c_prompt "$p" "$(pointer "$next")")
    check "race newer prompt attaches its own envelope" "$(ctx_c "$out")" "new turn mail"
    check "race newer prompt reclaims the expired old envelope" "$(ctx_c "$out")" "old turn mail to reclaim"
    same "race newer prompt has a first body attempt" "$(b_race_mail "$next")" staged/1/0/0
    same "race newer prompt charges another attempt on the same row" "$(b_race_mail "$renewed")" staged/2/0/0
    claims="SELECT post,shown,staged_turn,staged_full,lease_until FROM mail WHERE post IN ($next,$renewed) ORDER BY post"
    new_claim=$(sqx "$CNTCTR_DB" "$claims")
    hook_row="SELECT generation,event_seq,turn,last_event FROM hook_sessions WHERE pane='$p'"
    event=$(sqx "$CNTCTR_DB" "$hook_row")

    : > "$TMPD/race_go"
    wait "$driver" || bad "race Stop driver failed"
    same "race displaced Stop answers without a new decision" "$(cat "$TMPD/race_answer")" '{}'
    same "race displaced Stop preserves the newer prompt record" "$(sqx "$CNTCTR_DB" "$hook_row")" "$event"
    same "race displaced Stop acknowledges its own live lease" "$(b_race_mail "$old")" delivered/1/0/1
    same "race displaced Stop acknowledges the captured token" \
        "$(sqx "$CNTCTR_DB" "SELECT staged_turn FROM mail WHERE post=$old")" "$old_claim"
    same "race displaced Stop leaves the newer mail staged" "$(b_race_mail "$next")" staged/1/0/0
    same "race displaced Stop leaves the reattached old mail staged" "$(b_race_mail "$renewed")" staged/2/0/0
    same "race displaced Stop leaves both newer claims unchanged" "$(sqx "$CNTCTR_DB" "$claims")" "$new_claim"
}

b_race_snapshot() {
    local p old renewed next pending sock pid driver i barrier out claims attached hook_row event
    b_race_driver || return
    p=$(hk_agent claude race_snapshot)
    sock=$(t display -p '#{socket_path}')
    pid=$(sqx "$CNTCTR_DB" "SELECT harness_pid FROM hook_sessions WHERE pane='$p'")
    old=$(mailput "$p" race0006 "$(mail_text race0006 'live mail before snapshot')" 1)
    renewed=$(mailput "$p" race0007 "$(mail_text race0007 'expired mail before snapshot')" 0)
    c_prompt "$p" "$(pointer "$old")" >/dev/null
    same "race snapshot starts with two staged body attempts" \
        "$(b_race_mail "$old")/$(b_race_mail "$renewed")" staged/1/0/0/staged/1/0/0
    expire_mail "$renewed"

    barrier="$TMPD/race_gate"
    HOOK_GATE_BARRIER="$barrier" "$TMPD/race_driver" "$sock" "$p" "$pid" > "$TMPD/race_answer" &
    driver=$!
    for i in $(seq 1 100); do
        [ -e "$barrier.ready" ] && break
        sleep 0.02
    done
    if [ ! -e "$barrier.ready" ] || ! sqlite3 "$CNTCTR_DB" "BEGIN IMMEDIATE; ROLLBACK" 2>/dev/null; then
        : > "$barrier.go"
        wait "$driver"
        bad "race Stop did not yield the writer while waiting for tmux"
        return
    fi

    hook_row="SELECT generation,event_seq,turn,last_event FROM hook_sessions WHERE pane='$p'"
    same "race Stop has recorded before waiting for tmux" \
        "$(sqx "$CNTCTR_DB" "SELECT last_event FROM hook_sessions WHERE pane='$p'")" Stop
    same "race Stop acknowledges live mail before waiting for tmux" "$(b_race_mail "$old")" delivered/1/0/1
    same "race Stop releases expired mail without acknowledging it" "$(b_race_mail "$renewed")" pending/1/0/0
    next=$(mailput "$p" race0008 "$(mail_text race0008 'new mail during snapshot')" 1)
    out=$(c_prompt "$p" "$(pointer "$next")")
    check "race prompt attaches new mail while Stop waits for tmux" "$(ctx_c "$out")" "new mail during snapshot"
    check "race prompt reattaches expired mail while Stop waits for tmux" "$(ctx_c "$out")" "expired mail before snapshot"
    same "race both prompt claims commit while Stop waits for tmux" \
        "$(b_race_mail "$next")/$(b_race_mail "$renewed")" staged/1/0/0/staged/2/0/0
    # Give the old Stop eligible mail so its gate would have work if it retained ownership.
    pending=$(mailput "$p" race0009 "$(mail_text race0009 'mail after the newer prompt')")
    claims="SELECT post,shown,staged_turn,staged_full,lease_until FROM mail WHERE post IN ($next,$renewed) ORDER BY post"
    attached=$(sqx "$CNTCTR_DB" "$claims")
    event=$(sqx "$CNTCTR_DB" "$hook_row")

    : > "$barrier.go"
    wait "$driver" || bad "race Stop snapshot driver failed"
    same "race Stop after tmux cannot emit a displaced decision" "$(cat "$TMPD/race_answer")" '{}'
    same "race Stop after tmux preserves the newer prompt record" "$(sqx "$CNTCTR_DB" "$hook_row")" "$event"
    same "race Stop after tmux leaves both newer claims staged" \
        "$(b_race_mail "$next")/$(b_race_mail "$renewed")" staged/1/0/0/staged/2/0/0
    same "race Stop after tmux leaves both newer claims unchanged" "$(sqx "$CNTCTR_DB" "$claims")" "$attached"
    same "race Stop after tmux cannot claim mail arriving after the prompt" "$(b_race_mail "$pending")" pending/0/0/0
    c_stop "$p" true >/dev/null
    same "race current Stop acknowledges both newer claims" \
        "$(b_race_mail "$next")/$(b_race_mail "$renewed")" delivered/1/0/1/delivered/2/0/1
}

b_race_rollback() {
    local p old due reject sock hook_query event next_event mail_query rows out
    p=$(hk_agent claude race_rollback)
    sock=$(t display -p '#{socket_path}')
    old=$(mailput "$p" race0010 "$(mail_text race0010 'live mail before failed reconcile')" 1)
    due=$(mailput "$p" race0011 "$(mail_text race0011 'expired mail before failed reconcile')")
    c_prompt "$p" "$(pointer "$old")" >/dev/null
    same "race rollback starts with two staged claims" \
        "$(b_race_mail "$old")/$(b_race_mail "$due")" staged/1/0/0/staged/1/0/0
    expire_mail "$due"
    hook_query="SELECT generation,turn,event_seq,last_event,harness_pid,at,wake_reserved,wake_at,broken
        FROM hook_sessions WHERE socket='$sock' AND pane='$p'"
    event=$(sqx "$CNTCTR_DB" "$hook_query")
    mail_query="SELECT post,state,shown,wake_attempts,delivered,staged_turn,staged_full,lease_until
        FROM mail WHERE pane='$p' AND socket='$sock' ORDER BY post"
    rows=$(sqx "$CNTCTR_DB" "$mail_query")
    sq "$CNTCTR_DB" "CREATE TRIGGER race_reject_reconcile BEFORE UPDATE OF state ON mail
        WHEN NEW.post=$due AND NEW.state='pending'
        BEGIN SELECT RAISE(ABORT,'test reconcile rollback'); END"

    out=$(c_prompt "$p" "prompt with a rejected expiry transition")
    same "race rejected reconcile returns a neutral hook result" "$out" '{}'
    same "race rejected reconcile rolls back the event record" "$(sqx "$CNTCTR_DB" "$hook_query")" "$event"
    same "race rejected reconcile preserves live and expired claims" "$(sqx "$CNTCTR_DB" "$mail_query")" "$rows"
    sq "$CNTCTR_DB" "DROP TRIGGER race_reject_reconcile"
    c_prompt "$p" "retry the expiry transition" >/dev/null
    same "race successful reconcile releases only the expired row" \
        "$(b_race_mail "$old")/$(b_race_mail "$due")" staged/1/0/0/pending/1/0/0

    # Once the prompt is accepted, its liveness update survives a later body claim failure (L2-2).
    reject=$(mailput "$p" race0012 "$(mail_text race0012 'body claim rejected after accepted prompt')")
    sq "$CNTCTR_DB" "UPDATE hook_sessions SET wake_reserved=1,wake_at=strftime('%s','now') WHERE pane='$p';
        CREATE TRIGGER race_reject_claim BEFORE UPDATE OF state ON mail
        WHEN NEW.post=$reject AND NEW.state='staged'
        BEGIN SELECT RAISE(ABORT,'test body claim rollback'); END"
    next_event=$(sqx "$CNTCTR_DB" "SELECT generation||'/'||(turn+1)||'/'||(event_seq+1)
        FROM hook_sessions WHERE pane='$p'")
    rows=$(sqx "$CNTCTR_DB" "$mail_query")

    out=$(c_prompt "$p" "$(pointer "$due")")
    same "race rejected claim emits no mail decision" "$out" '{}'
    same "race rejected claim leaves the accepted prompt recorded" \
        "$(sqx "$CNTCTR_DB" "SELECT generation||'/'||turn||'/'||event_seq FROM hook_sessions WHERE pane='$p'")" "$next_event"
    same "race accepted prompt clears the wake reservation despite rejected claim" \
        "$(sqx "$CNTCTR_DB" "SELECT wake_reserved||'/'||(wake_at IS NULL)||'/'||broken FROM hook_sessions WHERE pane='$p'")" 0/1/0
    same "race rejected claim rolls back all body charges and tokens" "$(sqx "$CNTCTR_DB" "$mail_query")" "$rows"

    sq "$CNTCTR_DB" "DROP TRIGGER race_reject_claim"
    out=$(c_prompt "$p" "$(pointer "$due")")
    check "race retry emits the previously rejected envelope" "$(ctx_c "$out")" "body claim rejected after accepted prompt"
    same "race retry commits both body claims once" \
        "$(b_race_mail "$due")/$(b_race_mail "$reject")" staged/2/0/0/staged/1/0/0
}

u5p6_run() {
    export CNTCTR_PASTE_WAIT_MS=100
    local f
    for f in ${F6:-1 2 3 4 5 6 7 8 9}; do declare -F "f6_$f" >/dev/null && "f6_$f"; done
    for f in ${F7:-1 2 3 4 5 6}; do declare -F "f7_$f" >/dev/null && "f7_$f"; done
    for f in ${F8:-1 2 3 4 5 6}; do declare -F "f8_$f" >/dev/null && "f8_$f"; done
    unset CNTCTR_PASTE_WAIT_MS
}

u5p7_run() {   # stream B hook-race regressions on the lease code
    export CNTCTR_PASTE_WAIT_MS=100
    local c
    for c in ${B_CASE:-schema migration resume retry interleave snapshot rollback}; do "b_race_$c"; done
    unset CNTCTR_PASTE_WAIT_MS
}

u5_run() {   # U5PARTS="p3 p4" runs just those parts, in that order
    hk_boot
    local part
    for part in ${U5PARTS:-p1 p2 p3 p4 p5 p6 p7}; do "u5${part}_run"; done
    hk_stop
}
if [ "${ONLY:-}" = mail-lease ]; then
    hk_boot
    F6=none F7=none F8='5 6' u5p6_run
    hk_stop
    echo "$pass passed, $fail failed"
    [ "$fail" -eq 0 ]; exit $?
fi

if [ "${ONLY:-}" = u5 ] || [ "${ONLY:-}" = u5p1 ] || [ "${ONLY:-}" = u5p2 ] || [ "${ONLY:-}" = u5p3 ] || [ "${ONLY:-}" = u5p4 ] || [ "${ONLY:-}" = u5p5 ] || [ "${ONLY:-}" = u5p6 ] || [ "${ONLY:-}" = u5p7 ]; then
    case $ONLY in
        u5) u5_run ;;
        u5p1) hk_boot; u5p1_run; hk_stop ;;
        u5p2) hk_boot; u5p2_run; hk_stop ;;
        u5p3) hk_boot; u5p3_run; hk_stop ;;
        u5p4) hk_boot; u5p4_run; hk_stop ;;
        u5p5) hk_boot; u5p5_run; hk_stop ;;
        u5p6) hk_boot; u5p6_run; hk_stop ;;
        u5p7) hk_boot; u5p7_run; hk_stop ;;
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

stale_name_run() {
    local pane init
    init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"claude-code"}}}'
    pane=$(t new-window -d -P -F '#{pane_id}' cat)
    t set -p -t "$pane" @cntctr_name "codex-mcp-client-${pane#%}"
    t set -p -t "$pane" @cntctr_harness codex-mcp-client
    printf '%s\n' "$init" | TMUX_PANE=$pane "$BIN" >/dev/null
    same "stale automatic name follows new harness" "$(t show -pqv -t "$pane" @cntctr_name)" "claude-code-${pane#%}"
    same "renamed pane records new harness" "$(t show -pqv -t "$pane" @cntctr_harness)" claude-code
    t set -p -t "$pane" @cntctr_name librarian-1
    t set -p -t "$pane" @cntctr_harness codex-mcp-client
    printf '%s\n' "$init" | TMUX_PANE=$pane "$BIN" >/dev/null
    same "spawn name is preserved" "$(t show -pqv -t "$pane" @cntctr_name)" librarian-1
    t set -p -t "$pane" @cntctr_name "codex-mcp-client-${pane#%}"
    t set -p -t "$pane" @cntctr_srv $$
    printf '%s\n' "$init" | TMUX_PANE=$pane "$BIN" >/dev/null
    same "live owner keeps automatic name" "$(t show -pqv -t "$pane" @cntctr_name)" "codex-mcp-client-${pane#%}"
}
if [ "${ONLY:-}" = stale-name ]; then
    stale_name_run
    printf '%d passed, %d failed\n' "$pass" "$fail"
    [ "$fail" -eq 0 ]; exit $?
fi

# ---- Code Mode Phase 2: storage, grant resolver, cli_admin_guard, server CLI ----
code_kb_run() {
    local d="$TMPD/code_kb" db mig projA projB wtA out rc reg_user reg_proj reg_gh reg_drop exp_json
    mkdir -p "$d/projA" "$d/projB" "$d/bin"
    db="$d/code.db"
    mig="$d/mig.db"

    # 1. Existing v0.1.0 DB migration creates all 4 code_* tables and stamps user_version = 9
    sqlite3 "$mig" < tests/schema_v0.1.0.sql
    CNTCTR_DB="$mig" "$BIN" _test-code-kb server-list "" >/dev/null 2>&1
    same "code-kb migration stamps user_version 9" "$(sq "$mig" 'PRAGMA user_version')" 9
    same "code-kb migration creates all 4 code_* tables" \
        "$(sq "$mig" "SELECT group_concat(name, ',') FROM (SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'code_%' ORDER BY name)")" \
        "code_catalogs,code_grants,code_runs,code_servers"

    # 1b. A test build never opens a DB without CNTCTR_DB (a hand-run ./cntctr-test once migrated the user's real kb.db):
    # it aborts before touching anything, and creates no kb.db under the HOME it was given. Test builds only: the guard is compiled out otherwise.
    if [ "$(basename "$BIN")" = cntctr-test ]; then
        mkdir -p "$d/leakhome"
        out=$(printf '%s\n' "$INIT" | env -u CNTCTR_DB HOME="$d/leakhome" "$BIN" 2>&1 >/dev/null)
        check "code-kb test build refuses to open a DB with CNTCTR_DB unset" "$out" "refusing to open a knowledge DB"
        same "code-kb test build left no kb.db under the unisolated HOME" "$(ls "$d/leakhome/.local/share/cntctr/kb.db" 2>/dev/null)" ""
        out=$(env -u CNTCTR_DB HOME="$d/leakhome" "$BIN" stats 2>&1 >/dev/null)
        check "code-kb test build refuses stats with CNTCTR_DB unset" "$out" "refusing to open a knowledge DB"
    fi

    # Canonical project roots (git repo + worktree + symlink)
    git -C "$d/projA" init -q
    git -C "$d/projA" -c user.name=T -c user.email=t@example.invalid commit --allow-empty -qm init
    git -C "$d/projA" worktree add -qb wt "$d/wtA" >/dev/null 2>&1
    ln -s "$d/projA" "$d/linkA"
    projA=$(CNTCTR_DB="$db" "$BIN" _test-code-kb resolve-cwd "$d/projA")
    wtA=$(CNTCTR_DB="$db" "$BIN" _test-code-kb resolve-cwd "$d/wtA")
    same "code-kb resolve_code_cwd unifies git worktree to common root" "$wtA" "$projA"
    same "code-kb resolve_code_cwd resolves symlinks via realpath" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb resolve-cwd "$d/linkA")" "$projA"
    projB=$(CNTCTR_DB="$db" "$BIN" _test-code-kb resolve-cwd "$d/projB")
    same "code-kb shell_quote escapes apostrophes" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb shell-quote "proj's dir")" "'proj'\''s dir'"

    # 2. CLI cntctr code server add|list|remove (plain non-tmux shell)
    out=$(CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ env -u TMUX_PANE -u CNTCTR_PANE -u CNTCTR_ROOT \
        "$BIN" code server add cntctr --cmd /bin/echo 2>&1); rc=$?
    same "code-kb CLI rejects reserved name cntctr" "$((rc != 0))" 1
    out=$(CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ env -u TMUX_PANE -u CNTCTR_PANE -u CNTCTR_ROOT \
        "$BIN" code server add bad.name --cmd /bin/echo 2>&1); rc=$?
    same "code-kb CLI rejects dotted name bad.name" "$((rc != 0))" 1
    out=$(CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ env -u TMUX_PANE -u CNTCTR_PANE -u CNTCTR_ROOT \
        "$BIN" code server add myecho --cmd "npx foo" 2>&1); rc=$?
    same "code-kb CLI rejects whitespace in --cmd" "$((rc != 0))" 1

    out=$(CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ env -u TMUX_PANE -u CNTCTR_PANE -u CNTCTR_ROOT \
        "$BIN" code server add myecho --cmd /bin/echo --arg hi --env SECRET=topsecret 2>&1); rc=$?
    same "code-kb CLI adds valid server" "$rc" 0
    out=$(CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ env -u TMUX_PANE -u CNTCTR_PANE -u CNTCTR_ROOT \
        "$BIN" code server list 2>&1); rc=$?
    same "code-kb CLI lists servers" "$rc" 0
    check "code-kb CLI list shows env key SECRET" "$out" "SECRET"
    refute "code-kb CLI list hides env value topsecret" "$out" "topsecret"

    # Seed non-human grants across 2 projects and a catalog, then replace & remove via CLI -> dropped N grants in M projects
    reg_drop=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-get "" myecho | jq -r '.reg_id')
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_drop" myecho "*" access read "" orch "seed" 0 >/dev/null
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_drop" myecho "ping" access allow "read" orch "seed" 0 >/dev/null
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projB" "$reg_drop" myecho "*" access read "" orch "seed" 0 >/dev/null
    CNTCTR_DB="$db" "$BIN" _test-code-kb catalog-set "$reg_drop" "" '[{"name":"ping"}]' >/dev/null
    out=$(CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ env -u TMUX_PANE -u CNTCTR_PANE -u CNTCTR_ROOT \
        "$BIN" code server add myecho --cmd /bin/echo --arg v2 2>&1); rc=$?
    same "code-kb CLI replace succeeds" "$rc" 0
    check "code-kb CLI replace reports dropped grants and projects" "$out" "dropped 3 grants in 2 projects"
    same "code-kb CLI replace deletes old reg_id grants" "$(sq "$db" "SELECT count(*) FROM code_grants WHERE reg_id='$reg_drop'")" 0
    same "code-kb CLI replace deletes old reg_id catalogs" "$(sq "$db" "SELECT count(*) FROM code_catalogs WHERE reg_id='$reg_drop'")" 0

    reg_drop=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-get "" myecho | jq -r '.reg_id')
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_drop" myecho "*" access read "" orch "seed" 0 >/dev/null
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projB" "$reg_drop" myecho "*" access read "" orch "seed" 0 >/dev/null
    out=$(CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ env -u TMUX_PANE -u CNTCTR_PANE -u CNTCTR_ROOT \
        "$BIN" code server remove myecho 2>&1); rc=$?
    same "code-kb CLI remove succeeds" "$rc" 0
    check "code-kb CLI remove reports dropped grants and projects" "$out" "dropped 2 grants in 2 projects"
    same "code-kb CLI remove deletes old reg_id grants" "$(sq "$db" "SELECT count(*) FROM code_grants WHERE reg_id='$reg_drop'")" 0

    # 3. cli_admin_guard checks
    out=$(CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ CNTCTR_ROOT="$d" env -u TMUX_PANE -u CNTCTR_PANE \
        "$BIN" code server add blocked1 --cmd /bin/echo 2>&1); rc=$?
    same "code-kb cli_admin_guard refuses CNTCTR_ROOT" "$((rc != 0))" 1
    check "code-kb cli_admin_guard names CNTCTR_ROOT" "$out" "CNTCTR_ROOT"

    local p_worker p_stale
    p_worker=$(newpane kb_worker)
    t set -p -t "$p_worker" @cntctr_parent "%0"
    out=$(CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ TMUX_PANE="$p_worker" env -u CNTCTR_PANE -u CNTCTR_ROOT \
        "$BIN" code server add blocked2 --cmd /bin/echo 2>&1); rc=$?
    same "code-kb cli_admin_guard refuses @cntctr_parent pane" "$((rc != 0))" 1
    check "code-kb cli_admin_guard names @cntctr_parent" "$out" "@cntctr_parent"

    out=$(CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ TMUX_PANE="$p_worker" TMUX="/nonexistent/sock,0,0" env -u CNTCTR_PANE -u CNTCTR_ROOT \
        "$BIN" code server add blocked_tmuxerr --cmd /bin/echo 2>&1); rc=$?
    same "code-kb cli_admin_guard fails closed on tmux error" "$((rc != 0))" 1
    check "code-kb cli_admin_guard names tmux check" "$out" "tmux"

    p_stale=$(newpane kb_stale)
    t set -pu -t "$p_stale" @cntctr_parent 2>/dev/null || true
    out=$(CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ TMUX_PANE="$p_stale" env -u CNTCTR_PANE -u CNTCTR_ROOT \
        "$BIN" code server add allowed_stale --cmd /bin/echo 2>&1); rc=$?
    same "code-kb cli_admin_guard allows pane with stale @cntctr_name and empty @cntctr_parent" "$rc" 0
    CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ TMUX_PANE="$p_stale" env -u CNTCTR_PANE -u CNTCTR_ROOT \
        "$BIN" code server remove allowed_stale >/dev/null 2>&1
    t kill-pane -t "$p_worker"; t kill-pane -t "$p_stale"

    # Fake claude & codex child wrappers (including with a real PTY)
    cat > "$d/wrap.c" << 'EOF'
#include <stdlib.h>
#include <sys/wait.h>
int main(int argc, char **argv) {
    if (argc <= 1) return 1;
    int s = system(argv[1]);
    return WIFEXITED(s) ? WEXITSTATUS(s) : 1;
}
EOF
    cc -o "$d/bin/claude" "$d/wrap.c"
    cc -o "$d/bin/codex" "$d/wrap.c"
    out=$(CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ env -u TMUX_PANE -u CNTCTR_PANE -u CNTCTR_ROOT \
        "$d/bin/claude" "'$BIN' code server add blocked3 --cmd /bin/echo" 2>&1); rc=$?
    same "code-kb cli_admin_guard refuses claude ancestor" "$((rc != 0))" 1
    check "code-kb cli_admin_guard names claude ancestor" "$out" "claude"

    out=$(python3 - "$d/bin/codex" "$BIN" "$db" "$$" <<'PY'
import os, pty, select, subprocess, sys
codex, binp, db, stop_pid = sys.argv[1:]
m, s = pty.openpty()
env = dict(os.environ)
env["CNTCTR_DB"] = db
env["CNTCTR_TEST_ANCESTOR_STOP_PID"] = stop_pid
for k in ("TMUX_PANE", "CNTCTR_PANE", "CNTCTR_ROOT"):
    env.pop(k, None)
p = subprocess.Popen([codex, f"'{binp}' code server add blocked4 --cmd /bin/echo"], stdin=s, stdout=s, stderr=s, env=env)
os.close(s)
buf = bytearray()
while True:
    r, _, _ = select.select([m], [], [], 5.0)
    if not r:
        break
    try:
        chunk = os.read(m, 4096)
        if not chunk:
            break
        buf.extend(chunk)
    except OSError:
        break
os.close(m)
rc = p.wait()
print(f"RC={rc} OUT={buf.decode('utf-8', 'replace')}")
PY
    )
    refute "code-kb cli_admin_guard refuses codex ancestor even with PTY" "$out" "RC=0 "
    check "code-kb cli_admin_guard names codex ancestor" "$out" "codex"

    # Destructive prompt for human-rule server replace/remove (non-TTY refused, PTY y succeeds)
    CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ env -u TMUX_PANE -u CNTCTR_PANE -u CNTCTR_ROOT \
        "$BIN" code server add hsrv --cmd /bin/echo >/dev/null 2>&1
    local reg_hsrv
    reg_hsrv=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-get "" hsrv | jq -r '.reg_id')
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_hsrv" hsrv "*" access read "" human "by human" 0 >/dev/null
    out=$(CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ env -u TMUX_PANE -u CNTCTR_PANE -u CNTCTR_ROOT \
        "$BIN" code server remove hsrv </dev/null 2>&1); rc=$?
    same "code-kb CLI remove with human grants refuses without TTY" "$((rc != 0))" 1
    check "code-kb CLI remove without TTY names TTY check" "$out" "TTY"
    out=$(python3 - "$BIN" "$db" "$$" <<'PY'
import os, pty, select, subprocess, sys, time
binp, db, stop_pid = sys.argv[1:]
m, s = pty.openpty()
env = dict(os.environ)
env["CNTCTR_DB"] = db
env["CNTCTR_TEST_ANCESTOR_STOP_PID"] = stop_pid
for k in ("TMUX_PANE", "CNTCTR_PANE", "CNTCTR_ROOT"):
    env.pop(k, None)
p = subprocess.Popen([binp, "code", "server", "remove", "hsrv"], stdin=s, stdout=s, stderr=s, env=env)
os.close(s)
buf = bytearray()
sent = False
deadline = time.time() + 5.0
while time.time() < deadline:
    r, _, _ = select.select([m], [], [], 0.2)
    if r:
        try:
            chunk = os.read(m, 4096)
            if not chunk:
                break
            buf.extend(chunk)
            if not sent and b"[y/N]" in buf:
                os.write(m, b"y\n")
                sent = True
        except OSError:
            break
    elif p.poll() is not None:
        break
os.close(m)
rc = p.wait()
print(f"RC={rc} OUT={buf.decode('utf-8', 'replace')}")
PY
    )
    check "code-kb CLI remove with human grants succeeds with PTY y" "$out" "RC=0 "
    check "code-kb CLI remove with human grants reports dropped grants" "$out" "dropped 1 grants in 1 projects"

    # 4. Registration & catalog isolation + shadowing + effective grant listing + Sol R4-01 checked recheck
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-put "" fake /bin/echo '[]' '{}' 1 annotations human 0)
    check "code-kb user server-put succeeds" "$out" "rc=0 "
    reg_user=$(printf '%s' "$out" | sed -n 's/.*reg_id=\([^ ]*\).*/\1/p')

    # MCP cannot shadow user-scoped server
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-put "$projA" fake /bin/echo '[]' '{}' 0 none orch 1)
    check "code-kb MCP cannot shadow user server" "$out" "rc=-2 "

    # CLI (from_mcp=0) project-local shadows user server with distinct reg_id
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-put "$projA" fake /bin/echo '["p"]' '{}' 0 annotations human 0)
    check "code-kb CLI project-local server-put shadows user" "$out" "rc=0 "
    reg_proj=$(printf '%s' "$out" | sed -n 's/.*reg_id=\([^ ]*\).*/\1/p')
    same "code-kb shadowed server has distinct reg_id" "$([ "$reg_proj" != "$reg_user" ] && echo 1 || echo 0)" 1
    same "code-kb server-get in projA returns project-local reg_id" \
        "$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-get "$projA" fake | jq -r '.reg_id')" "$reg_proj"
    same "code-kb server-get in projB returns user reg_id" \
        "$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-get "$projB" fake | jq -r '.reg_id')" "$reg_user"

    # Per-instance code_catalogs: separate (tools_json, meta_gen) for (reg_user, projA) vs (reg_user, projB)
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb catalog-set "$reg_user" "$projA" '[{"name":"a1"}]')
    check "code-kb catalog-set projA meta_gen=1" "$out" "rc=0 meta_gen=1"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb catalog-set "$reg_user" "$projA" '[{"name":"a2"}]')
    check "code-kb catalog-set projA increments meta_gen=2" "$out" "rc=0 meta_gen=2"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb catalog-set "$reg_user" "$projB" '[{"name":"b1"}]')
    check "code-kb catalog-set projB independent meta_gen=1" "$out" "rc=0 meta_gen=1"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb catalog-get "$reg_user" "$projA")
    check "code-kb catalog-get projA returns a2 gen=2" "$out" 'rc=0 meta_gen=2 tools=[{"name":"a2"}]'
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb catalog-get "$reg_user" "$projB")
    check "code-kb catalog-get projB returns b1 gen=1" "$out" 'rc=0 meta_gen=1 tools=[{"name":"b1"}]'

    # kb_code_grant_list_json filters to effective reg_ids + virtual "cntctr"
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_user" fake "*" access read "" human "shadowed" 0 >/dev/null
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_proj" fake "*" access read "" human "active" 0 >/dev/null
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "cntctr" cntctr "*" access read "" human "virtual" 0 >/dev/null
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-list "$projA")
    same "code-kb grant-list excludes shadowed user reg_id and keeps effective + cntctr" \
        "$(printf '%s' "$out" | jq -r 'map(.reg_id) | sort | join(",")')" \
        "$(printf '%s\n%s\n' "$reg_proj" "cntctr" | sort | paste -sd, -)"

    # Sol R4-01: checked put/del aborts (-3) if expected_reg_id is stale or human grants not approved
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-put-checked "$projA" fake /bin/echo "stale-reg" 1)
    check "code-kb server-put-checked aborts on stale reg_id" "$out" "rc=-3 "
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-put-checked "$projA" fake /bin/echo "$reg_proj" 0)
    check "code-kb server-put-checked aborts when human grants unapproved" "$out" "rc=-3 "
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-del-checked "$projA" fake "$reg_proj" 0)
    check "code-kb server-del-checked aborts when human grants unapproved" "$out" "rc=-3 "

    # MCP server-put/del refused (-2) when human grants exist on old reg_id
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-del "$projA" fake 1)
    check "code-kb MCP server-del refused when human grants exist" "$out" "rc=-2 "

    # 5. Grants two-pass, replacement & human protection
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-put "$projA" gh /bin/echo '[]' '{}' 0 annotations human 0)
    reg_gh=$(printf '%s' "$out" | sed -n 's/.*reg_id=\([^ ]*\).*/\1/p')

    # Default-deny when no rule matches
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "$projA" "$reg_gh" list_issues read)
    check "code-kb default-deny denies read with no rules" "$out" "rc=1 effective=read "
    same "code-kb has-non-deny false before grants" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb has-non-deny "$projA" "$reg_gh")" 0

    # gh.* read allows read, denies write
    same "code-kb grant-put gh.* read" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_gh" gh "*" access read "" orch "allow reads" 0)" "rc=0"
    same "code-kb has-non-deny true after read grant" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb has-non-deny "$projA" "$reg_gh")" 1
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "$projA" "$reg_gh" list_issues read)
    check "code-kb gh.* read allows read" "$out" "rc=0 effective=read"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "$projA" "$reg_gh" create_issue write)
    check "code-kb gh.* read denies write" "$out" "rc=1 effective=write "

    # class:write override raises effective_out=CODE_WRITE without shadowing gh.* read
    same "code-kb grant-put class:write" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_gh" gh "sneaky_read" class "class:write" "" human "override" 0)" "rc=0"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "$projA" "$reg_gh" sneaky_read read)
    check "code-kb class:write raises effective class and denies under read" "$out" "rc=1 effective=write "
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "$projA" "$reg_gh" list_issues read)
    check "code-kb class:write does not shadow gh.* read for other tools" "$out" "rc=0 effective=read"

    # Wildcard allow rejected
    same "code-kb wildcard allow rejected" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_gh" gh "create_*" access allow "write" human "bad" 0)" "rc=-1"
    same "code-kb ? wildcard allow rejected" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_gh" gh "create_?" access allow "write" human "bad" 0)" "rc=-1"

    # Exact allow (class_at_grant=write) allows create_issue
    same "code-kb exact allow grant-put" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_gh" gh "create_issue" access allow "write" orch "needed" 0)" "rc=0"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "$projA" "$reg_gh" create_issue write)
    check "code-kb exact allow allows create_issue" "$out" "rc=0 effective=write"

    # Human protection: from_mcp=1 returns -2 when replacing or deleting human row; from_mcp=0 replaces deny with allow atomically
    same "code-kb human deny put" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_gh" gh "deploy" access deny "" human "no deploy" 0)" "rc=0"
    same "code-kb from_mcp=1 refused replacing human row" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_gh" gh "deploy" access allow "write" orch "try" 1)" "rc=-2"
    same "code-kb from_mcp=1 refused deleting human row" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-del "$projA" "$reg_gh" "deploy" access 1)" "rc=-2"
    same "code-kb from_mcp=0 atomically replaces deny with allow" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_gh" gh "deploy" access allow "write" human "approved" 0)" "rc=0"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "$projA" "$reg_gh" deploy write)
    check "code-kb replaced deny->allow now allows deploy" "$out" "rc=0 effective=write"

    # class_at_grant=read denies if class rises to destructive
    same "code-kb grant-put class_at_grant=read" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_gh" gh "upgrade_tool" access allow "read" orch "was read" 0)" "rc=0"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "$projA" "$reg_gh" upgrade_tool destructive)
    check "code-kb class_at_grant=read denies when class rises to destructive" "$out" "rc=1 effective=destructive "

    # deny on gh.* beats exact allow
    same "code-kb grant-put deny gh.*" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_gh" gh "*" access deny "" human "lockdown" 0)" "rc=0"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "$projA" "$reg_gh" create_issue write)
    check "code-kb deny on gh.* beats exact allow" "$out" "rc=1 effective=write "

    # 5b. The all-projects policy (project "*"): human, access read/deny, user-scoped servers; precedence against project rules
    local reg_ap reg_ap_loc kbs="$BIN" ap='*'
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-put "" apsrv /bin/echo '[]' '{}' 0 annotations human 0)
    reg_ap=$(printf '%s' "$out" | sed -n 's/.*reg_id=\([^ ]*\).*/\1/p')
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "$projB" "$reg_ap" list_x read)
    check "code-kb all-projects: default-deny before any rule" "$out" "rc=1 effective=read "
    same "code-kb all-projects: read put is rc=0" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$ap" "$reg_ap" apsrv "*" access read "" human "everywhere" 0)" "rc=0"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "$projB" "$reg_ap" list_x read)
    check "code-kb all-projects: read rule allows a project with no rule of its own" "$out" "rc=0 effective=read"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "$projB" "$reg_ap" write_x write)
    check "code-kb all-projects: a read rule still denies a write tool" "$out" "rc=1 effective=write "
    same "code-kb all-projects: has-non-deny counts the user-wide rule" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb has-non-deny "$projB" "$reg_ap")" 1
    same "code-kb all-projects: allow is refused" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$ap" "$reg_ap" apsrv "x" access allow "write" human "no" 0)" "rc=-1"
    same "code-kb all-projects: class rule is refused" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$ap" "$reg_ap" apsrv "x" class "class:write" "" human "no" 0)" "rc=-1"
    same "code-kb all-projects: a non-human granter is refused" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$ap" "$reg_ap" apsrv "x" access read "" orch "no" 0)" "rc=-1"
    same "code-kb all-projects: MCP put is refused" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$ap" "$reg_ap" apsrv "x" access read "" human "no" 1)" "rc=-2"
    same "code-kb all-projects: the virtual cntctr server is refused" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$ap" cntctr cntctr "x" access read "" human "no" 0)" "rc=-1"
    same "code-kb all-projects: MCP delete is refused" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-del "$ap" "$reg_ap" "*" access 1)" "rc=-2"
    same "code-kb all-projects: the rule survived the MCP attempts" "$(sq "$db" "SELECT count(*) FROM code_grants WHERE project='*' AND reg_id='$reg_ap'")" 1
    # a project-local deny beats the user-wide read, only there
    same "code-kb all-projects: project-local deny put" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_ap" apsrv "secret_*" access deny "" human "not here" 0)" "rc=0"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "$projA" "$reg_ap" secret_a read)
    check "code-kb all-projects: a project-local deny beats the user-wide read" "$out" "rc=1 effective=read why=denied by rule secret_* (not here)"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "$projB" "$reg_ap" secret_a read)
    check "code-kb all-projects: ...and only in that project" "$out" "rc=0 effective=read"
    # a user-wide deny beats a project-local read or allow
    same "code-kb all-projects: user-wide deny put" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$ap" "$reg_ap" apsrv "banned" access deny "" human "never" 0)" "rc=0"
    same "code-kb all-projects: project-local read of the banned tool put" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_ap" apsrv "banned" access read "" human "try" 0)" "rc=0"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "$projA" "$reg_ap" banned read)
    check "code-kb all-projects: a user-wide deny beats a project-local read" "$out" "rc=1 effective=read why=denied by rule banned [all-projects] (never)"
    # a project-local allow decides for its tool; the user-wide read decides elsewhere
    same "code-kb all-projects: project-local allow put" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_ap" apsrv "write_x" access allow "write" human "ok here" 0)" "rc=0"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "$projA" "$reg_ap" write_x write)
    check "code-kb all-projects: a project-local allow beats the user-wide read" "$out" "rc=0 effective=write"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "$projB" "$reg_ap" write_x write)
    check "code-kb all-projects: ...the user-wide read still holds elsewhere" "$out" "rc=1 effective=write "
    # listing: marked, effective servers only
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-list "$projB")
    same "code-kb all-projects: grant-list marks the user-wide row" "$(printf '%s' "$out" | jq -r '[.[] | select(.scope == "all-projects") | .tool_pattern] | join(",")')" "*,banned"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-put "$projB" apsrv /bin/echo '[]' '{}' 0 annotations human 0)
    reg_ap_loc=$(printf '%s' "$out" | sed -n 's/.*reg_id=\([^ ]*\).*/\1/p')
    same "code-kb all-projects: a project-local server of that name is not covered" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "$projB" "$reg_ap_loc" list_x read | cut -c1-4)" "rc=1"
    same "code-kb all-projects: ...and the shadowed user-wide rows are not listed there" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-list "$projB" | jq -r '[.[] | select(.scope == "all-projects")] | length')" 0
    # replacing the server drops the user-wide rule with it; MCP cannot replace a server that has one
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-put "" apsrv /bin/true '[]' '{}' 0 annotations orch 1)
    check "code-kb all-projects: MCP cannot replace a server with a human user-wide rule" "$out" "rc=-2 "
    CNTCTR_DB="$db" "$BIN" _test-code-kb server-put "" apsrv /bin/true '[]' '{}' 0 annotations human 0 >/dev/null
    same "code-kb all-projects: replacing the server dropped its user-wide rows" "$(sq "$db" "SELECT count(*) FROM code_grants WHERE project='*' AND reg_id='$reg_ap'")" 0

    # 6. code_runs: UTF-8 boundary alignment, 64 KiB clamp, wrong project not-found, sweep -> expired, invisible to recall
    local utf8_text="aé€😀z"
    same "code-kb run-save utf8" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb run-save run1 "$projA" tester hash1 "$utf8_text" "log1" "call1" "den1" 1 3600)" "rc=0"
    exp_json=$(CNTCTR_DB="$db" "$BIN" _test-code-kb run-expand "$projA" run1 result 0 2)
    same "code-kb run-expand UTF-8 avoids splitting 2-byte char" "$(printf '%s' "$exp_json" | jq -r '.slice')" "a"
    same "code-kb run-expand reports total_len and retained_capped" "$(printf '%s' "$exp_json" | jq -r '[.rc,.total_len,.retained_capped]|join(",")')" "0,11,1"
    exp_json=$(CNTCTR_DB="$db" "$BIN" _test-code-kb run-expand "$projA" run1 result 1 4)
    same "code-kb run-expand UTF-8 avoids splitting 3-byte char" "$(printf '%s' "$exp_json" | jq -r '.slice')" "é"
    exp_json=$(CNTCTR_DB="$db" "$BIN" _test-code-kb run-expand "$projA" run1 result 3 6)
    same "code-kb run-expand UTF-8 avoids splitting 4-byte emoji" "$(printf '%s' "$exp_json" | jq -r '.slice')" "€"
    exp_json=$(CNTCTR_DB="$db" "$BIN" _test-code-kb run-expand "$projA" run1 result 6 5)
    same "code-kb run-expand UTF-8 reads emoji+tail" "$(printf '%s' "$exp_json" | jq -r '.slice')" "😀z"

    # 64 KiB clamp
    python3 -c 'import sys; sys.stdout.write("X" * 70000)' | \
        CNTCTR_DB="$db" "$BIN" _test-code-kb run-save runbig "$projA" tester hash2 "@stdin" "" "" "" 0 3600 >/dev/null
    exp_json=$(CNTCTR_DB="$db" "$BIN" _test-code-kb run-expand "$projA" runbig result 0 100000)
    same "code-kb run-expand clamps limit to 65536" "$(printf '%s' "$exp_json" | jq -r '[.rc,(.slice|length),.total_len]|join(",")')" "0,65536,70000"

    # Wrong project returns not-found
    exp_json=$(CNTCTR_DB="$db" "$BIN" _test-code-kb run-expand "$projB" run1 result 0 100)
    same "code-kb run-expand wrong project returns not_found" "$(printf '%s' "$exp_json" | jq -r '.status')" "not_found"

    # Sweep turns expand into expired
    same "code-kb run-save short ttl" "$(CNTCTR_DB="$db" "$BIN" _test-code-kb run-save runexp "$projA" tester hash3 "SECRET_RUN_MARKER" "" "" "" 0 1)" "rc=0"
    local future=$(( $(date +%s) + 100 ))
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb run-sweep "$future")
    check "code-kb run-sweep sweeps expired run" "$out" "swept=1"
    exp_json=$(CNTCTR_DB="$db" "$BIN" _test-code-kb run-expand "$projA" runexp result 0 100)
    same "code-kb run-expand after sweep returns expired" "$(printf '%s' "$exp_json" | jq -r '.status')" "expired"

    # recall returns nothing from code_* tables
    out=$(cd "$d/projA" && CNTCTR_DB="$db" rpc "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"recall","arguments":{"query":"SECRET_RUN_MARKER"}}}' | tail -n 1)
    refute "code-kb recall does not leak code_runs" "$(txt "$out")" "SECRET_RUN_MARKER"

    # 7. Sol Phase 2 review fixes (CODE-KB-01 through CODE-KB-06)
    # CODE-KB-01: interrupted grant scan must fail closed (deny), never allow from partial rows
    local reg_r1
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-put "$projA" r1srv /bin/echo '[]' '{}' 0 annotations human 0)
    reg_r1=$(printf '%s' "$out" | sed -n 's/.*reg_id=\([^ ]*\).*/\1/p')
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_r1" r1srv "t1" access allow "read" human "seed" 0 >/dev/null
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_r1" r1srv "t2" access allow "read" human "seed" 0 >/dev/null
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check-interrupt "$projA" "$reg_r1" t1 read)
    refute "code-kb CODE-KB-01 progress handler actually interrupted scan" "$out" "fired=0 "
    check "code-kb CODE-KB-01 interrupted scan never allows from partial rows" "$out" "allowed_on_interrupt=0"

    # CODE-KB-02: DB error during auth checks must roll back mutation, never treat error as absence
    local reg_r2
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-put "$projA" r2srv /bin/echo '[]' '{}' 0 annotations human 0)
    reg_r2=$(printf '%s' "$out" | sed -n 's/.*reg_id=\([^ ]*\).*/\1/p')
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_r2" r2srv "hrule" access deny "" human "locked" 0 >/dev/null
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb auth-interrupt grant-put "$projA" "$reg_r2" r2srv "hrule")
    refute "code-kb CODE-KB-02 grant-put interrupt fired" "$out" "fired=0 "
    check "code-kb CODE-KB-02 grant-put never bypasses human rule on DB error" "$out" "bypassed=0"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb auth-interrupt grant-del "$projA" "$reg_r2" "hrule")
    refute "code-kb CODE-KB-02 grant-del interrupt fired" "$out" "fired=0 "
    check "code-kb CODE-KB-02 grant-del never bypasses human rule on DB error" "$out" "bypassed=0"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb auth-interrupt server-put-human "$projA" r2srv)
    refute "code-kb CODE-KB-02 server-put-human interrupt fired" "$out" "fired=0 "
    check "code-kb CODE-KB-02 server-put never bypasses human grant check on DB error" "$out" "bypassed=0"
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb auth-interrupt server-del-human "$projA" r2srv)
    refute "code-kb CODE-KB-02 server-del-human interrupt fired" "$out" "fired=0 "
    check "code-kb CODE-KB-02 server-del never bypasses human grant check on DB error" "$out" "bypassed=0"
    CNTCTR_DB="$db" "$BIN" _test-code-kb server-put "" r2user /bin/echo '[]' '{}' 0 annotations human 0 >/dev/null
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb auth-interrupt server-shadow "$projA" r2user)
    refute "code-kb CODE-KB-02 server-shadow interrupt fired" "$out" "fired=0 "
    check "code-kb CODE-KB-02 server-put never bypasses user-shadowing check on DB error" "$out" "bypassed=0"

    # CODE-KB-03: strongest matching human-set class acts as floor (more-specific non-human class cannot lower it)
    local reg_r3
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-put "$projA" r3srv /bin/echo '[]' '{}' 0 annotations human 0)
    reg_r3=$(printf '%s' "$out" | sed -n 's/.*reg_id=\([^ ]*\).*/\1/p')
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_r3" r3srv "*" class "class:destructive" "" human "floor" 0 >/dev/null
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_r3" r3srv "nuke" class "class:write" "" orch "try lower" 0 >/dev/null
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$projA" "$reg_r3" r3srv "nuke" access allow "write" orch "allow write" 0 >/dev/null
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "$projA" "$reg_r3" nuke read)
    check "code-kb CODE-KB-03 human class:destructive floor beats more-specific orch class:write" "$out" "rc=1 effective=destructive "

    # CODE-KB-04: server list runs cli_admin_guard before git probe (both text and --json modes)
    mkdir -p "$d/fakegit"
    cat > "$d/fakegit/git" <<EOF
#!/bin/sh
: > "$d/git_probed"
exit 1
EOF
    chmod +x "$d/fakegit/git"
    rm -f "$d/git_probed"
    out=$(PATH="$d/fakegit:$PATH" CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ CNTCTR_ROOT="$d" env -u TMUX_PANE -u CNTCTR_PANE \
        "$BIN" code server list 2>&1); rc=$?
    same "code-kb CODE-KB-04 server list refuses under CNTCTR_ROOT" "$((rc != 0))" 1
    check "code-kb CODE-KB-04 server list names guard check" "$out" "CNTCTR_ROOT"
    same "code-kb CODE-KB-04 server list refused before git probe" "$([ -e "$d/git_probed" ] && echo 1 || echo 0)" 0
    out=$(PATH="$d/fakegit:$PATH" CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ CNTCTR_ROOT="$d" env -u TMUX_PANE -u CNTCTR_PANE \
        "$BIN" code server list --json 2>&1); rc=$?
    same "code-kb CODE-KB-04 server list --json refuses under CNTCTR_ROOT" "$((rc != 0))" 1
    check "code-kb CODE-KB-04 server list --json names guard check" "$out" "CNTCTR_ROOT"
    same "code-kb CODE-KB-04 server list --json refused before git probe" "$([ -e "$d/git_probed" ] && echo 1 || echo 0)" 0

    # CODE-KB-05: reject overlong scope_project instead of silently truncating
    local long_scope
    long_scope=$(python3 -c 'print("/" + "a" * 5000)')
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-put "$long_scope" oversrv /bin/echo '[]' '{}' 0 annotations human 0 2>&1); rc=$?
    same "code-kb CODE-KB-05 overlong scope_project rejected" "$((rc != 0))" 1
    same "code-kb CODE-KB-05 no truncated oversrv row stored" "$(sq "$db" "SELECT count(*) FROM code_servers WHERE name='oversrv'")" 0

    # CODE-KB-06: server remove supports '--' so names starting with '-' are removable
    out=$(CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ env -u TMUX_PANE -u CNTCTR_PANE -u CNTCTR_ROOT \
        "$BIN" code server add -dashsrv --cmd /bin/echo 2>&1); rc=$?
    same "code-kb CODE-KB-06 server add accepts leading-dash name" "$rc" 0
    out=$(CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ env -u TMUX_PANE -u CNTCTR_PANE -u CNTCTR_ROOT \
        "$BIN" code server remove -- -dashsrv 2>&1); rc=$?
    same "code-kb CODE-KB-06 server remove -- removes leading-dash name" "$rc" 0
    same "code-kb CODE-KB-06 leading-dash server actually removed" "$(sq "$db" "SELECT count(*) FROM code_servers WHERE name='-dashsrv'")" 0
}
if [ "${ONLY:-}" = code-kb ]; then
    code_kb_run
    printf '%d passed, %d failed\n' "$pass" "$fail"
    [ "$fail" -eq 0 ]; exit $?
fi

# ---- Code Mode Phase 3: QuickJS runner, tri-state schema validator, refcounted bridge ----
code_js_run() {
    local d="$TMPD/code_js" db proj proj_q reg_mock reg_lazy out
    mkdir -p "$d/proj" "$d/proj's dir"
    db="$d/code.db"
    proj=$(CNTCTR_DB="$db" "$BIN" _test-code-kb resolve-cwd "$d/proj")
    proj_q=$(CNTCTR_DB="$db" "$BIN" _test-code-kb resolve-cwd "$d/proj's dir")
    reg_mock="reg-mock"
    reg_lazy="reg-lazy"

    # Seed grants for $proj: mock.* read, lazy.* read
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$proj" "$reg_mock" mock "*" access read "" human "seed" 0 >/dev/null
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$proj" "$reg_lazy" lazy "*" access read "" human "seed" 0 >/dev/null
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put "$proj" "$reg_lazy" lazy "blocked*" access deny "" human "seed deny" 0 >/dev/null

    # Helper to run a JSON spec through _test-code-js run
    _js_run() {
        CNTCTR_DB="$db" "$BIN" _test-code-js run
    }

    # 1. Basic async script: omitted args default to {}, explicit args, unwrapped JSON, console.log, calls
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg,
        script: "console.log(\"hello\", 42); const a = await tools.mock.fast(); const b = await tools.mock.fast({q:\"hi\"}); return {a, b};"
    }' | _js_run)
    same "code-js basic script succeeds" "$(printf '%s' "$out" | jq -r '.is_error')" 0
    same "code-js omitted args defaults to {}" "$(printf '%s' "$out" | jq -r '.result | fromjson | .a.echo | length')" 0
    same "code-js explicit args unwrapped JSON" "$(printf '%s' "$out" | jq -r '.result | fromjson | .b.echo.q')" "hi"
    check "code-js captures console.log" "$(printf '%s' "$out" | jq -r '.logs')" "hello 42"
    check "code-js records calls" "$(printf '%s' "$out" | jq -r '.calls')" "mock.fast read "

    # 2. Sandbox isolation
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg,
        script: "return {req: typeof require, proc: typeof process, f: typeof fetch, s: typeof std, o: typeof os};"
    }' | _js_run)
    same "code-js sandbox ok" "$(printf '%s' "$out" | jq -r '.is_error')" 0
    same "code-js typeof require/process/fetch/std/os undefined" \
        "$(printf '%s' "$out" | jq -r '.result | fromjson | [.req,.proc,.f,.s,.o] | join(",")')" \
        "undefined,undefined,undefined,undefined,undefined"

    # 3. Promise.all concurrency via barrier (no timing threshold)
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, barrier_n: 3, wall_sec: 10,
        script: "const res = await Promise.all([tools.mock.barrier_tool({}), tools.mock.barrier_tool({}), tools.mock.barrier_tool({})]); return res.length;"
    }' | _js_run)
    same "code-js Promise.all barrier resolves" "$(printf '%s' "$out" | jq -r '.is_error')" 0
    same "code-js Promise.all barrier result length 3" "$(printf '%s' "$out" | jq -r '.result')" "3"
    same "code-js Promise.all barrier peak_inflight == 3" "$(printf '%s' "$out" | jq -r '.peak_inflight')" 3

    # 4. In-flight & queue caps
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, max_inflight: 4, wall_sec: 10,
        script: "const ps = []; for (let i = 0; i < 20; i++) ps.push(tools.mock.slow_3000ms({})); await Promise.all(ps);"
    }' | _js_run)
    same "code-js max_inflight fanout fails" "$(printf '%s' "$out" | jq -r '.is_error')" 1
    check "code-js max_inflight names CNTCTR_CODE_MAX_INFLIGHT" "$(printf '%s' "$out" | jq -r '.result')" "CNTCTR_CODE_MAX_INFLIGHT"

    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, max_queue_bytes: 1024, wall_sec: 10,
        script: "await tools.mock.fast({q: \"x\".repeat(4096)});"
    }' | _js_run)
    same "code-js max_queue_bytes rejects large args" "$(printf '%s' "$out" | jq -r '.is_error')" 1
    check "code-js max_queue_bytes names CNTCTR_CODE_MAX_QUEUE_BYTES" "$(printf '%s' "$out" | jq -r '.result')" "CNTCTR_CODE_MAX_QUEUE_BYTES"

    # 5. CPU budget via CLOCK_THREAD_CPUTIME_ID
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, cpu_sec: 1, wall_sec: 10,
        script: "while (true) {}"
    }' | _js_run)
    same "code-js CPU spin fails" "$(printf '%s' "$out" | jq -r '.is_error')" 1
    check "code-js CPU spin names CNTCTR_CODE_CPU_SEC" "$(printf '%s' "$out" | jq -r '.result')" "CNTCTR_CODE_CPU_SEC"

    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, cpu_sec: 1, wall_sec: 5,
        script: "return await tools.mock.slow_1500ms({});"
    }' | _js_run)
    same "code-js slow_1500ms with cpu_sec=1 wall_sec=5 succeeds" "$(printf '%s' "$out" | jq -r '.is_error')" 0

    # 6. Wall limit + microtask job-loop check
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, cpu_sec: 10, wall_sec: 1,
        script: "return await tools.mock.slow_3000ms({});"
    }' | _js_run)
    same "code-js slow_3000ms with wall_sec=1 fails" "$(printf '%s' "$out" | jq -r '.is_error')" 1
    check "code-js wall timeout names CNTCTR_CODE_WALL_SEC" "$(printf '%s' "$out" | jq -r '.result')" "CNTCTR_CODE_WALL_SEC"

    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, cpu_sec: 10, wall_sec: 1,
        script: "function spin(){ Promise.resolve().then(spin); } spin(); await new Promise(() => {});"
    }' | _js_run)
    same "code-js microtask spin hits wall limit" "$(printf '%s' "$out" | jq -r '.is_error')" 1
    check "code-js microtask spin names CNTCTR_CODE_WALL_SEC" "$(printf '%s' "$out" | jq -r '.result')" "CNTCTR_CODE_WALL_SEC"

    # 7. Per-call timeout (catchable)
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, call_sec: 1, wall_sec: 5,
        script: "try { await tools.mock.slow_3000ms({}); return \"no\"; } catch (e) { return {caught: e.message}; }"
    }' | _js_run)
    same "code-js per-call timeout is catchable" "$(printf '%s' "$out" | jq -r '.is_error')" 0
    check "code-js per-call timeout names CNTCTR_CODE_CALL_SEC" "$(printf '%s' "$out" | jq -r '.result | fromjson | .caught')" "CNTCTR_CODE_CALL_SEC"

    # 8. Review Focus #2: native stack, memory limit, hostile JS, late completion & cancel races
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, max_stack_bytes: 1048576,
        script: "function rec(n){ return rec(n+1) + 1; } return rec(0);"
    }' | _js_run)
    same "code-js infinite recursion fails cleanly without SIGSEGV" "$(printf '%s' "$out" | jq -r '.is_error')" 1
    check "code-js infinite recursion mentions stack" "$(printf '%s' "$out" | jq -r '.result')" "stack"

    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, max_mb: 4,
        script: "let a=[]; for(;;) a.push(new Array(10000));"
    }' | _js_run)
    same "code-js memory limit fails" "$(printf '%s' "$out" | jq -r '.is_error')" 1
    check "code-js memory limit names CNTCTR_CODE_MAX_MB" "$(printf '%s' "$out" | jq -r '.result')" "CNTCTR_CODE_MAX_MB"
    check "code-js memory limit reports usage" "$(printf '%s' "$out" | jq -r '.result')" "bytes"

    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg,
        script: "Object.prototype.toString = () => { throw 1; }; console.log({a:1}); throw new Error(\"boom\");"
    }' | _js_run)
    same "code-js hostile Object.prototype.toString fails cleanly" "$(printf '%s' "$out" | jq -r '.is_error')" 1

    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg,
        script: "const a = {}; a.self = a; await tools.mock.fast(a);"
    }' | _js_run)
    same "code-js circular object arg fails cleanly" "$(printf '%s' "$out" | jq -r '.is_error')" 1

    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg,
        script: "await tools.mock.fast({n: BigInt(1)});"
    }' | _js_run)
    same "code-js BigInt arg fails cleanly" "$(printf '%s' "$out" | jq -r '.is_error')" 1

    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg,
        script: "await tools.mock.fast({q: \"a\\u0000b\"});"
    }' | _js_run)
    same "code-js NUL string value arg fails cleanly" "$(printf '%s' "$out" | jq -r '.is_error')" 1
    check "code-js NUL arg mentions NUL" "$(printf '%s' "$out" | jq -r '.result')" "NUL"

    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg,
        script: "await tools.mock.fast({\"a\\u0000b\": \"x\"});"
    }' | _js_run)
    same "code-js NUL object key arg fails cleanly" "$(printf '%s' "$out" | jq -r '.is_error')" 1

    # Late completion after wall_sec=1 (mock sleeps 1500ms, test waits 2000ms for detached completion under ASan)
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, wall_sec: 1, wait_late_ms: 2000,
        script: "return await tools.mock.slow_1500ms({});"
    }' | _js_run)
    same "code-js late completion run times out cleanly" "$(printf '%s' "$out" | jq -r '.is_error')" 1
    check "code-js late completion names CNTCTR_CODE_WALL_SEC" "$(printf '%s' "$out" | jq -r '.result')" "CNTCTR_CODE_WALL_SEC"
    same "code-js late completion callback ran after detach without UAF" \
        "$(printf '%s' "$out" | jq -r 'if .late_completions >= 1 then 1 else 0 end')" 1

    # Unawaited call triggers cancel_call on run exit
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, wall_sec: 5,
        script: "tools.mock.slow_3000ms({}); return \"done\";"
    }' | _js_run)
    same "code-js unawaited call script returns cleanly" "$(printf '%s' "$out" | jq -r '.is_error')" 0
    same "code-js unawaited call triggered cancel_call" \
        "$(printf '%s' "$out" | jq -r 'if .cancel_count >= 1 then 1 else 0 end')" 1

    # External code_run_cancel_signal wakes promptly with zero UAF
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, wall_sec: 10, cancel_after_ms: 200,
        script: "return await tools.mock.slow_3000ms({});"
    }' | _js_run)
    same "code-js external cancel fails run" "$(printf '%s' "$out" | jq -r '.is_error')" 1
    check "code-js external cancel reports reason" "$(printf '%s' "$out" | jq -r '.result')" "test cancel"
    same "code-js external cancel woke promptly (<2000ms)" \
        "$(printf '%s' "$out" | jq -r 'if .elapsed_ms < 2000 then 1 else 0 end')" 1
    same "code-js external cancel invoked cancel_call" \
        "$(printf '%s' "$out" | jq -r 'if .cancel_count >= 1 then 1 else 0 end')" 1

    # 9. Tri-state C schema validator
    out=$("$BIN" _test-code-js schema '{"type":"object","properties":{"q":{"type":"string"}}}' '{"q":123}')
    same "code-js schema wrong type rejects" "$(printf '%s' "$out" | jq -r '.validate')" 1
    check "code-js schema wrong type names field q" "$(printf '%s' "$out" | jq -r '.err')" "q"

    out=$("$BIN" _test-code-js schema '{"type":"object","required":["name"],"properties":{"name":{"type":"string"}}}' '{}')
    same "code-js schema missing required rejects" "$(printf '%s' "$out" | jq -r '.validate')" 1
    check "code-js schema missing required names field name" "$(printf '%s' "$out" | jq -r '.err')" "name"

    out=$("$BIN" _test-code-js schema '{"type":"object","properties":{"mode":{"enum":["a","b"]}}}' '{"mode":"c"}')
    same "code-js schema bad enum rejects" "$(printf '%s' "$out" | jq -r '.validate')" 1
    check "code-js schema bad enum names field mode" "$(printf '%s' "$out" | jq -r '.err')" "mode"

    out=$("$BIN" _test-code-js schema '{"type":"object","properties":{"nested":{"type":"object","required":["id"],"properties":{"id":{"type":"integer"}}}}}' '{"nested":{"id":"nope"}}')
    same "code-js schema nested error rejects" "$(printf '%s' "$out" | jq -r '.validate')" 1
    check "code-js schema nested error names nested.id" "$(printf '%s' "$out" | jq -r '.err')" "nested.id"

    out=$("$BIN" _test-code-js schema '{"type":"object","x-custom":1,"properties":{"x":{"type":"string"}}}' '{"x":"ok"}')
    same "code-js schema top-level unknown keyword evaluates INDETERMINATE" "$(printf '%s' "$out" | jq -r '.eval')" 2
    same "code-js schema top-level unknown keyword passes" "$(printf '%s' "$out" | jq -r '.validate')" 0

    out=$("$BIN" _test-code-js schema '{"oneOf":[{"type":"object"},{"properties":{"a":{"type":"integer"}}},{"x-custom":1}]}' '{"a":1}')
    same "code-js schema oneOf 2 VALID + 1 INDETERMINATE rejects" "$(printf '%s' "$out" | jq -r '.eval')" 1
    same "code-js schema oneOf 2 VALID + 1 INDETERMINATE validate=1" "$(printf '%s' "$out" | jq -r '.validate')" 1

    out=$("$BIN" _test-code-js schema '{"allOf":[{"required":["must_have"]},{"x-custom":1}]}' '{}')
    same "code-js schema allOf 1 INVALID + 1 INDETERMINATE rejects" "$(printf '%s' "$out" | jq -r '.eval')" 1
    same "code-js schema allOf 1 INVALID + 1 INDETERMINATE validate=1" "$(printf '%s' "$out" | jq -r '.validate')" 1

    out=$("$BIN" _test-code-js schema '{"anyOf":[{"required":["must_have"]},{"x-custom":1}]}' '{}')
    same "code-js schema anyOf 1 INVALID + 1 INDETERMINATE indeterminate" "$(printf '%s' "$out" | jq -r '.eval')" 2
    same "code-js schema anyOf 1 INVALID + 1 INDETERMINATE passes" "$(printf '%s' "$out" | jq -r '.validate')" 0

    out=$("$BIN" _test-code-js schema '{"$defs":{"id":{"type":"integer"}},"type":"object","properties":{"x":{"$ref":"#/$defs/id"}}}' '{"x":"bad"}')
    same 'code-js schema local $defs $ref rejects bad type' "$(printf '%s' "$out" | jq -r '.validate')" 1
    check 'code-js schema local $defs $ref names field x' "$(printf '%s' "$out" | jq -r '.err')" "x"

    out=$("$BIN" _test-code-js schema '{"$defs":{"loop":{"$ref":"#/$defs/loop"}},"$ref":"#/$defs/loop"}' '{}')
    same 'code-js schema cyclic $ref depth cap returns INDETERMINATE' "$(printf '%s' "$out" | jq -r '.eval')" 2
    same 'code-js schema cyclic $ref fails open cleanly' "$(printf '%s' "$out" | jq -r '.validate')" 0

    # Schema rejection via JS bridge names field before dispatching
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg,
        script: "await tools.mock.fast({nested: {id: \"not-an-int\"}});"
    }' | _js_run)
    same "code-js bridge schema violation rejects" "$(printf '%s' "$out" | jq -r '.is_error')" 1
    check "code-js bridge schema violation names nested.id" "$(printf '%s' "$out" | jq -r '.result')" "nested.id"

    # 10. Mistyped tool name, denials with shell-quoted commands, CODE_CALL_DENIED, scope, lazy gate
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg,
        script: "await tools.mock.fsat({});"
    }' | _js_run)
    same "code-js mistyped tool fails" "$(printf '%s' "$out" | jq -r '.is_error')" 1
    check "code-js mistyped tool suggests fast" "$(printf '%s' "$out" | jq -r '.result')" "fast"

    # Read denial on ungranted project with apostrophe in path
    out=$(jq -nc --arg db "$db" --arg proj "$proj_q" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg,
        script: "await tools.mock.fast({});"
    }' | _js_run)
    same "code-js read denial fails" "$(printf '%s' "$out" | jq -r '.is_error')" 1
    local q_proj_q
    q_proj_q=$(CNTCTR_DB="$db" "$BIN" _test-code-kb shell-quote "$proj_q")
    check "code-js read denial suggests shell-quoted grant mock.* read" \
        "$(printf '%s' "$out" | jq -r '.denied')" "cd ${q_proj_q} && cntctr code grant 'mock.*' read"

    # Write denial on project with only mock.* read
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg,
        script: "await tools.mock.write_tool({name:\"x\"});"
    }' | _js_run)
    same "code-js write denial fails" "$(printf '%s' "$out" | jq -r '.is_error')" 1
    local q_proj
    q_proj=$(CNTCTR_DB="$db" "$BIN" _test-code-kb shell-quote "$proj")
    check "code-js write denial suggests shell-quoted grant mock.write_tool allow" \
        "$(printf '%s' "$out" | jq -r '.denied')" "cd ${q_proj} && cntctr code grant 'mock.write_tool' allow"
    check "code-js write denial recorded in calls" "$(printf '%s' "$out" | jq -r '.calls')" "mock.write_tool write "

    # CODE_CALL_DENIED from async dispatcher records in denied and calls
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg,
        script: "try { await tools.mock.async_denied({}); return \"no\"; } catch (e) { return {caught: e.message}; }"
    }' | _js_run)
    same "code-js async CODE_CALL_DENIED is catchable" "$(printf '%s' "$out" | jq -r '.is_error')" 0
    check "code-js async CODE_CALL_DENIED recorded in denied" "$(printf '%s' "$out" | jq -r '.denied')" "mock.async_denied"
    check "code-js async CODE_CALL_DENIED recorded in calls" "$(printf '%s' "$out" | jq -r '.calls')" "mock.async_denied"

    # scope only narrows
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, scope: ["mock.fast", "mock.write_tool"],
        script: "const r = {}; r.ok = (await tools.mock.fast({})).ok; try { await tools.mock.barrier_tool({}); } catch(e) { r.narrow = e.message; } try { await tools.mock.write_tool({name:\"a\"}); } catch(e) { r.still_denied = e.message; } return r;"
    }' | _js_run)
    same "code-js scope narrows cleanly" "$(printf '%s' "$out" | jq -r '.is_error')" 0
    same "code-js scope permits in-scope granted tool" "$(printf '%s' "$out" | jq -r '.result | fromjson | .ok')" true
    check "code-js scope blocks out-of-scope granted tool" "$(printf '%s' "$out" | jq -r '.result | fromjson | .narrow')" "scope"
    check "code-js scope cannot widen ungranted write tool" "$(printf '%s' "$out" | jq -r '.result | fromjson | .still_denied')" "grant"

    # Uncatalogued server lazy discovery respects scope & deny before dispatching (Sol R3-03)
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" --arg lreg "$reg_lazy" '{
        db: $db, project: $proj, reg_id: $reg, uncat_reg_id: $lreg, scope: ["mock.*"],
        script: "try { await tools.lazy.ping({}); } catch(e) { return e.message; }"
    }' | _js_run)
    same "code-js uncatalogued scope-excluded does not dispatch" "$(printf '%s' "$out" | jq -r '.lazy_dispatches')" 0
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" --arg lreg "$reg_lazy" '{
        db: $db, project: $proj, reg_id: $reg, uncat_reg_id: $lreg,
        script: "try { await tools.lazy.blocked_op({}); } catch(e) { return e.message; }"
    }' | _js_run)
    same "code-js uncatalogued deny-matched does not dispatch" "$(printf '%s' "$out" | jq -r '.lazy_dispatches')" 0
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" --arg lreg "$reg_lazy" '{
        db: $db, project: $proj, reg_id: $reg, uncat_reg_id: $lreg,
        script: "return await tools.lazy.ping({});"
    }' | _js_run)
    same "code-js uncatalogued granted & permitted dispatches lazily" "$(printf '%s' "$out" | jq -r '.lazy_dispatches')" 1
    same "code-js uncatalogued lazy dispatch succeeds" "$(printf '%s' "$out" | jq -r '.is_error')" 0

    # 11. C-side buffer caps & all 4 previews with offset= expand hints
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, result_cap_bytes: 512, calls_preview_bytes: 512, max_log_bytes: 1048576,
        script: "const line = \"L\".repeat(1000); for (let i = 0; i < 2200; i++) console.log(line); for (let i = 0; i < 30; i++) { await tools.mock.fast({}); try { await tools.mock.write_tool({name:\"a\"}); } catch(e) {} } return \"R\".repeat(2000);"
    }' | _js_run)
    same "code-js buffer cap test succeeds" "$(printf '%s' "$out" | jq -r '.is_error')" 0
    same "code-js 2 MiB log loop sets retained_capped=1" "$(printf '%s' "$out" | jq -r '.retained_capped')" 1
    same "code-js retained logs capped at <= 1 MiB" \
        "$(printf '%s' "$out" | jq -r 'if (.logs | length) <= 1048576 then 1 else 0 end')" 1
    check "code-js retained logs mentions dropped lines" "$(printf '%s' "$out" | jq -r '.logs')" "log lines dropped"
    check "code-js result_preview has offset=" "$(printf '%s' "$out" | jq -r '.result_preview')" "offset="
    check "code-js logs_preview has offset=" "$(printf '%s' "$out" | jq -r '.logs_preview')" "offset="
    check "code-js calls_preview has offset=" "$(printf '%s' "$out" | jq -r '.calls_preview')" "offset="
    check "code-js denied_preview has offset=" "$(printf '%s' "$out" | jq -r '.denied_preview')" "offset="
    same "code-js all 4 previews are bounded" \
        "$(printf '%s' "$out" | jq -r 'if (.result_preview|length) <= 600 and (.logs_preview|length) <= 600 and (.calls_preview|length) <= 600 and (.denied_preview|length) <= 600 then 1 else 0 end')" 1

    # ---- Phase 3 review fixes (CODE-JS-02 through CODE-JS-09) ----
    # CODE-JS-02: reentrant toJSON() inflating queued_bytes past max_queue_bytes must be rejected before dispatch
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, max_queue_bytes: 1024, wall_sec: 10,
        script: "const arg = { toJSON() { tools.mock.slow_3000ms({q: \"a\".repeat(700)}); return {q: \"b\".repeat(700)}; } }; try { await tools.mock.fast(arg); return \"dispatched\"; } catch(e) { return {caught: e.message}; }"
    }' | _js_run)
    same "code-js CODE-JS-02 reentrant toJSON queued_bytes rechecked" "$(printf '%s' "$out" | jq -r '.is_error')" 0
    check "code-js CODE-JS-02 reentrant overflow names CNTCTR_CODE_MAX_QUEUE_BYTES" \
        "$(printf '%s' "$out" | jq -r '.result | fromjson | .caught // ""')" "CNTCTR_CODE_MAX_QUEUE_BYTES"

    # CODE-JS-03: console.log renders incrementally within remaining budget and stops when exhausted
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, max_log_bytes: 256,
        script: "let side = 0; const bomb = { toJSON() { side++; return \"z\"; } }; console.log(\"x\".repeat(1024), bomb); console.log(bomb); return {side};"
    }' | _js_run)
    same "code-js CODE-JS-03 console.log incremental budget succeeds" "$(printf '%s' "$out" | jq -r '.is_error')" 0
    same "code-js CODE-JS-03 console.log stops rendering once budget exhausted" \
        "$(printf '%s' "$out" | jq -r '.result | fromjson | .side')" 0
    same "code-js CODE-JS-03 console.log sets retained_capped=1" "$(printf '%s' "$out" | jq -r '.retained_capped')" 1
    check "code-js CODE-JS-03 console.log counts both dropped lines" "$(printf '%s' "$out" | jq -r '.logs')" "2 log lines dropped"

    # CODE-JS-04: schema validator work budget bounds wide branching DAG (within depth 16) and skips unsafe backtracking regex
    local dag_schema
    dag_schema=$(python3 -c '
import json
defs = {
    "d0": {"allOf": [{"$ref": "#/$defs/d1"}] * 16},
    "d1": {"allOf": [{"$ref": "#/$defs/d2"}] * 16},
    "d2": {"allOf": [{"$ref": "#/$defs/d3"}] * 16},
    "d3": {"allOf": [{"$ref": "#/$defs/d4"}] * 16},
    "d4": {"type": "object"}
}
print(json.dumps({"$defs": defs, "$ref": "#/$defs/d0"}))
')
    out=$("$BIN" _test-code-js schema "$dag_schema" '{}')
    same "code-js CODE-JS-04 wide DAG within depth cap hits work budget -> INDETERMINATE" "$(printf '%s' "$out" | jq -r '.eval')" 2
    same "code-js CODE-JS-04 wide DAG fails open cleanly" "$(printf '%s' "$out" | jq -r '.validate')" 0

    local redos_args
    redos_args=$(python3 -c 'import json; print(json.dumps({"q": "a"*30 + "!"}))')
    out=$("$BIN" _test-code-js schema '{"type":"object","properties":{"q":{"type":"string","pattern":"^(a+)+$"}}}' "$redos_args")
    same "code-js CODE-JS-04 unsafe nested-quantifier regex skipped -> INDETERMINATE" "$(printf '%s' "$out" | jq -r '.eval')" 2
    same "code-js CODE-JS-04 unsafe regex fails open cleanly" "$(printf '%s' "$out" | jq -r '.validate')" 0

    # CODE-JS-04 + CODE-JS-02: expired wall deadline during arg serialization stops before dispatch
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" --argjson fs "$dag_schema" '{
        db: $db, project: $proj, reg_id: $reg, wall_sec: 1, cpu_sec: 5, fast_schema: $fs,
        script: "const arg = { toJSON() { const t0 = Date.now(); while (Date.now() - t0 < 1200) {} return {}; } }; await tools.mock.fast(arg);"
    }' | _js_run)
    same "code-js CODE-JS-04 expired run aborts before dispatch" "$(printf '%s' "$out" | jq -r '.is_error')" 1
    check "code-js CODE-JS-04 expired run names CNTCTR_CODE_WALL_SEC" "$(printf '%s' "$out" | jq -r '.result')" "CNTCTR_CODE_WALL_SEC"
    same "code-js CODE-JS-04 expired run never dispatches tool" "$(printf '%s' "$out" | jq -r '.fast_dispatches')" 0

    # CODE-JS-05: completion delivered after call deadline must time out rather than resolve as success
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, call_sec: 1, cpu_sec: 5, wall_sec: 10,
        script: "const p = tools.mock.slow_1500ms({}); const t0 = Date.now(); while (Date.now() - t0 < 2300) {} try { await p; return \"resolved\"; } catch(e) { return {caught: e.message}; }"
    }' | _js_run)
    same "code-js CODE-JS-05 late completion past call_sec is catchably rejected" "$(printf '%s' "$out" | jq -r '.is_error')" 0
    check "code-js CODE-JS-05 late completion names CNTCTR_CODE_CALL_SEC" \
        "$(printf '%s' "$out" | jq -r '.result | fromjson | .caught // ""')" "CNTCTR_CODE_CALL_SEC"

    # CODE-JS-06: small preview caps strictly bound total rendered preview length
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, result_cap_bytes: 8, calls_preview_bytes: 8,
        script: "await tools.mock.fast({}); return \"0123456789abcdef\";"
    }' | _js_run)
    same "code-js CODE-JS-06 cap=8 result_preview strictly <= 8 bytes" \
        "$(printf '%s' "$out" | jq -r 'if (.result_preview|length) <= 8 then 1 else 0 end')" 1
    same "code-js CODE-JS-06 cap=8 calls_preview strictly <= 8 bytes" \
        "$(printf '%s' "$out" | jq -r 'if (.calls_preview|length) <= 8 then 1 else 0 end')" 1
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, result_cap_bytes: 32,
        script: "return \"0123456789abcdef0123456789abcdef0123456789abcdef\";"
    }' | _js_run)
    same "code-js CODE-JS-06 cap=32 result_preview strictly <= 32 bytes" \
        "$(printf '%s' "$out" | jq -r 'if (.result_preview|length) <= 32 then 1 else 0 end')" 1
    check "code-js CODE-JS-06 cap=32 result_preview keeps compact offset=" "$(printf '%s' "$out" | jq -r '.result_preview')" "offset="

    # CODE-JS-07: exact integer comparisons beyond 2^53
    out=$("$BIN" _test-code-js schema '{"type":"integer","maximum":9007199254740992}' '9007199254740993')
    same "code-js CODE-JS-07 maximum 2^53 rejects 2^53+1" "$(printf '%s' "$out" | jq -r '.validate')" 1
    out=$("$BIN" _test-code-js schema '{"type":"integer","maximum":9007199254740992}' '9007199254740992')
    same "code-js CODE-JS-07 maximum 2^53 accepts 2^53" "$(printf '%s' "$out" | jq -r '.validate')" 0
    out=$("$BIN" _test-code-js schema '{"const":9007199254740992}' '9007199254740993')
    same "code-js CODE-JS-07 const 2^53 rejects 2^53+1" "$(printf '%s' "$out" | jq -r '.validate')" 1
    out=$("$BIN" _test-code-js schema '{"type":"integer","multipleOf":2}' '9007199254740993')
    same "code-js CODE-JS-07 multipleOf 2 rejects 2^53+1" "$(printf '%s' "$out" | jq -r '.validate')" 1

    # CODE-JS-08: RFC 6901 section 6 percent-decoding in local $ref fragments
    out=$("$BIN" _test-code-js schema '{"$defs":{"my type":{"type":"integer"}},"type":"object","properties":{"x":{"$ref":"#/$defs/my%20type"}}}' '{"x":"bad"}')
    same 'code-js CODE-JS-08 percent-encoded $ref rejects bad type' "$(printf '%s' "$out" | jq -r '.eval')" 1
    same 'code-js CODE-JS-08 percent-encoded $ref validate=1' "$(printf '%s' "$out" | jq -r '.validate')" 1
    out=$("$BIN" _test-code-js schema '{"$defs":{"my type":{"type":"integer"}},"type":"object","properties":{"x":{"$ref":"#/$defs/my%20type"}}}' '{"x":42}')
    same 'code-js CODE-JS-08 percent-encoded $ref accepts valid int' "$(printf '%s' "$out" | jq -r '.eval')" 0

    # CODE-JS-09: SQLite busy wait must honor external cancellation promptly (exclusive lock blocks reader)
    rm -f "$d/lock_ready" "$d/lock_stop"
    python3 -c '
import sqlite3, sys, time, os
conn = sqlite3.connect(sys.argv[1], isolation_level=None)
conn.execute("PRAGMA locking_mode = EXCLUSIVE")
conn.execute("BEGIN EXCLUSIVE")
conn.execute("INSERT OR REPLACE INTO meta(k,v) VALUES(\"_test_lock\",\"1\")")
open(sys.argv[2], "w").close()
t0 = time.monotonic()
while not os.path.exists(sys.argv[3]) and time.monotonic() - t0 < 6.0:
    time.sleep(0.05)
conn.execute("ROLLBACK")
conn.execute("PRAGMA locking_mode = NORMAL")
conn.execute("SELECT 1 FROM meta LIMIT 1")
conn.close()
' "$db" "$d/lock_ready" "$d/lock_stop" &
    local lock_pid=$!
    for _ in $(seq 100); do [ -f "$d/lock_ready" ] && break; sleep 0.02; done
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, wall_sec: 10, cancel_after_ms: 200,
        script: "await tools.mock.fast({}); return \"ok\";"
    }' | _js_run)
    : > "$d/lock_stop"
    wait "$lock_pid" 2>/dev/null || true
    same "code-js CODE-JS-09 cancel wakes SQLite busy wait promptly (<1500ms)" \
        "$(printf '%s' "$out" | jq -r 'if .elapsed_ms < 1500 then 1 else 0 end')" 1
    same "code-js CODE-JS-09 cancelled busy wait fails run" "$(printf '%s' "$out" | jq -r '.is_error')" 1
    check "code-js CODE-JS-09 cancelled busy wait reports reason" "$(printf '%s' "$out" | jq -r '.result')" "test cancel"

    # ---- Phase 3 round 2 review fixes (CODE-JS-03/04/05/07/10/11) ----
    # CODE-JS-03: Error args in console.log read name/message incrementally within budget (never read message if name overflows)
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, max_log_bytes: 256,
        script: "let msg_read = 0; const e = new Error(\"init\"); e.name = \"N\".repeat(512); Object.defineProperty(e, \"message\", { get() { msg_read++; return \"M\".repeat(512); } }); console.log(e); return {msg_read};"
    }' | _js_run)
    same "code-js CODE-JS-03r2 Error oversized name stops before reading message" \
        "$(printf '%s' "$out" | jq -r '.result | fromjson | .msg_read')" 0
    same "code-js CODE-JS-03r2 Error oversized name sets retained_capped=1" \
        "$(printf '%s' "$out" | jq -r '.retained_capped')" 1
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg,
        script: "console.log(new TypeError(\"boom\")); console.log(new Error(\"\")); return \"ok\";"
    }' | _js_run)
    check "code-js CODE-JS-03r2 normal Error formatting preserves Name: message" \
        "$(printf '%s' "$out" | jq -r '.logs')" "TypeError: boom"

    # CODE-JS-04: pattern always yields INDETERMINATE (fail-open; no POSIX/ECMAScript mismatch); other keywords still reject
    out=$("$BIN" _test-code-js schema '{"type":"string","pattern":"[\\d]+"}' '"5"')
    same 'code-js CODE-JS-04r3 pattern [\d]+ yields INDETERMINATE' "$(printf '%s' "$out" | jq -r '.eval')" 2
    same 'code-js CODE-JS-04r3 pattern [\d]+ passes fail-open' "$(printf '%s' "$out" | jq -r '.validate')" 0

    out=$("$BIN" _test-code-js schema '{"type":"string","pattern":"^.$"}' '"é"')
    same 'code-js CODE-JS-04r3 pattern ^.$ on UTF-8 é yields INDETERMINATE' "$(printf '%s' "$out" | jq -r '.eval')" 2
    same 'code-js CODE-JS-04r3 pattern ^.$ on UTF-8 é passes fail-open' "$(printf '%s' "$out" | jq -r '.validate')" 0

    out=$("$BIN" _test-code-js schema '{"type":"string","pattern":"^[a-z0-9_-]+$"}' '"bad!"')
    same 'code-js CODE-JS-04r3 pattern never rejects -> INDETERMINATE' "$(printf '%s' "$out" | jq -r '.eval')" 2
    same 'code-js CODE-JS-04r3 pattern passes fail-open' "$(printf '%s' "$out" | jq -r '.validate')" 0

    out=$("$BIN" _test-code-js schema '{"type":"string","pattern":"^[a-z]+$"}' '123')
    same 'code-js CODE-JS-04r3 other keywords alongside pattern still reject' "$(printf '%s' "$out" | jq -r '.eval')" 1
    same 'code-js CODE-JS-04r3 other keywords alongside pattern validate=1' "$(printf '%s' "$out" | jq -r '.validate')" 1

    local byte_utf8_schema byte_utf8_val
    byte_utf8_schema=$(python3 -c 'import json; print(json.dumps({"allOf": [{"minLength": 1}] * 200}))')
    byte_utf8_val=$(python3 -c 'import json; print(json.dumps("a" * 8192))')
    out=$("$BIN" _test-code-js schema "$byte_utf8_schema" "$byte_utf8_val")
    same "code-js CODE-JS-04r2 repeated long UTF-8 scans hit byte budget -> INDETERMINATE" "$(printf '%s' "$out" | jq -r '.eval')" 2

    local byte_eq_schema byte_eq_val
    byte_eq_schema=$(python3 -c 'import json; print(json.dumps({"$defs": {"s": {"const": ("a" * 8191) + "x"}}, "anyOf": [{"$ref": "#/$defs/s"}] * 200}))')
    byte_eq_val=$(python3 -c 'import json; print(json.dumps(("a" * 8191) + "y"))')
    out=$("$BIN" _test-code-js schema "$byte_eq_schema" "$byte_eq_val")
    same "code-js CODE-JS-04r2 repeated long equality scans hit byte budget -> INDETERMINATE" "$(printf '%s' "$out" | jq -r '.eval')" 2

    # CODE-JS-05: on-time completion claimed before deadline still resolves even if JS stays busy past call_sec.
    # inline:true makes the mock complete before dispatch returns, so the claim precedes the 1 s deadline by construction
    # (no worker thread to schedule, so machine load cannot turn this into a timeout).
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg, call_sec: 1, cpu_sec: 5, wall_sec: 10,
        script: "const p = tools.mock.fast({q:\"ontime\", inline:true}); const t0 = Date.now(); while (Date.now() - t0 < 1400) {} return await p;"
    }' | _js_run)
    same "code-js CODE-JS-05r2 on-time completion resolves after busy JS" "$(printf '%s' "$out" | jq -r '.is_error')" 0
    same "code-js CODE-JS-05r2 on-time completion preserves payload" \
        "$(printf '%s' "$out" | jq -r '.result | fromjson | .echo.q // ""')" "ontime"

    # CODE-JS-07: multipleOf routes integral doubles through exact divisibility and returns INDETERMINATE on unreliable fractions
    out=$("$BIN" _test-code-js schema '{"multipleOf":2.0}' '1000000001')
    same "code-js CODE-JS-07r2 multipleOf 2.0 rejects 1000000001" "$(printf '%s' "$out" | jq -r '.eval')" 1
    same "code-js CODE-JS-07r2 multipleOf 2.0 validate=1 for 1000000001" "$(printf '%s' "$out" | jq -r '.validate')" 1
    out=$("$BIN" _test-code-js schema '{"multipleOf":2.0}' '9007199254740993')
    same "code-js CODE-JS-07r2 multipleOf 2.0 rejects 2^53+1" "$(printf '%s' "$out" | jq -r '.eval')" 1
    out=$("$BIN" _test-code-js schema '{"multipleOf":2.0}' '1000000000.0')
    same "code-js CODE-JS-07r2 multipleOf 2.0 accepts 1000000000.0" "$(printf '%s' "$out" | jq -r '.eval')" 0
    out=$("$BIN" _test-code-js schema '{"multipleOf":0.1}' '0.3')
    same "code-js CODE-JS-07r2 fractional multipleOf 0.1 on 0.3 returns INDETERMINATE" "$(printf '%s' "$out" | jq -r '.eval')" 2
    same "code-js CODE-JS-07r2 fractional multipleOf 0.1 on 0.3 passes fail-open" "$(printf '%s' "$out" | jq -r '.validate')" 0
    out=$("$BIN" _test-code-js schema '{"multipleOf":0.1}' '0.35')
    same "code-js CODE-JS-07r2 fractional multipleOf 0.1 rejects 0.35" "$(printf '%s' "$out" | jq -r '.eval')" 1
    out=$("$BIN" _test-code-js schema '{"multipleOf":8e-324}' '2.4e-323')
    same "code-js CODE-JS-07r3 subnormal multipleOf 8e-324 on 2.4e-323 returns INDETERMINATE" "$(printf '%s' "$out" | jq -r '.eval')" 2
    same "code-js CODE-JS-07r3 subnormal multipleOf passes fail-open" "$(printf '%s' "$out" | jq -r '.validate')" 0
    out=$("$BIN" _test-code-js schema '{"multipleOf":1e-305}' '3e-305')
    same "code-js CODE-JS-07r3 underflow-adjacent multipleOf returns INDETERMINATE" "$(printf '%s' "$out" | jq -r '.eval')" 2

    # CODE-JS-10: concurrent validation of one shared schema under numeric diagnostics must not race
    out=$("$BIN" _test-code-js schema-race 2>&1)
    rc=$?
    same "code-js CODE-JS-10 shared schema concurrent numeric diagnostics exit 0" "$rc" 0
    same "code-js CODE-JS-10 shared schema concurrent numeric diagnostics zero failures" \
        "$(printf '%s' "$out" | jq -r '.failures // -1')" 0

    # CODE-JS-11: embedded NUL in console.log is escaped and does not truncate later lines
    out=$(jq -nc --arg db "$db" --arg proj "$proj" --arg reg "$reg_mock" '{
        db: $db, project: $proj, reg_id: $reg,
        script: "console.log(\"first\\u0000tail\"); console.log(\"second_line\"); return \"ok\";"
    }' | _js_run)
    same "code-js CODE-JS-11 embedded NUL log succeeds" "$(printf '%s' "$out" | jq -r '.is_error')" 0
    check "code-js CODE-JS-11 embedded NUL escapes NUL and keeps tail" "$(printf '%s' "$out" | jq -r '.logs')" "first\\u0000tail"
    check "code-js CODE-JS-11 embedded NUL preserves subsequent log line" "$(printf '%s' "$out" | jq -r '.logs')" "second_line"
}
if [ "${ONLY:-}" = code-js ]; then
    code_js_run
    printf '%d passed, %d failed\n' "$pass" "$fail"
    [ "$fail" -eq 0 ]; exit $?
fi

# ---- Code Mode Phase 4: daemon skeleton, Unix socket, lockfile, semver drain, status ----
code_daemon_run() {
    local d="$TMPD/cd" out rc dpid dpid2 old_pid new_pid new_pid2 smode dmode
    mkdir -p "$d"

    _cd_stat_mode() {
        stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null
    }
    _cd_wait_file() {
        local f=$1 i=0
        while [ ! -f "$f" ] && [ "$i" -lt 200 ]; do
            sleep 0.02
            i=$((i + 1))
        done
        [ -f "$f" ]
    }
    _cd_wait_dead() {
        local p=$1 i=0
        while kill -0 "$p" 2>/dev/null && [ "$i" -lt 200 ]; do
            sleep 0.02
            i=$((i + 1))
        done
        ! kill -0 "$p" 2>/dev/null
    }
    _cd_wait_off() {
        local db=$1 i=0 st=""
        while [ "$i" -lt 200 ]; do
            st=$(CNTCTR_DB="$db" env -u CNTCTR_CODE_SOCK "$BIN" code status 2>&1)
            [ "$st" = "code: off" ] && return 0
            sleep 0.05
            i=$((i + 1))
        done
        return 1
    }

    # 1. When off: status prints 'code: off', --short prints 'code ○', stop exits 0, none start daemon
    mkdir -p "$d/off"
    out=$(CNTCTR_DB="$d/off/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" code status 2>&1); rc=$?
    same "code-daemon off status exit 0" "$rc" 0
    same "code-daemon off status text" "$out" "code: off"
    same "code-daemon off status does not create socket" "$([ -e "$d/off/code.sock" ] && echo yes || echo no)" "no"

    out=$(CNTCTR_DB="$d/off/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" code status --short 2>&1); rc=$?
    same "code-daemon off status --short exit 0" "$rc" 0
    same "code-daemon off status --short text" "$out" "code ○"

    out=$(CNTCTR_DB="$d/off/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop 2>&1); rc=$?
    same "code-daemon off stop exit 0" "$rc" 0
    same "code-daemon off stop does not create socket" "$([ -e "$d/off/code.sock" ] && echo yes || echo no)" "no"

    # 2. Cold start via _test-code-rpc ping, status formats, 0600 sock in 0700 dir, detached (ppid=1)
    out=$(CNTCTR_DB="$d/s1/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon cold start ping exit 0" "$rc" 0
    same "code-daemon cold start ping ok" "$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)" "true"
    same "code-daemon cold start ping pong" "$(printf '%s' "$out" | jq -r '.pong // false' 2>/dev/null)" "true"
    dpid=$(printf '%s' "$out" | jq -r '.pid // 0' 2>/dev/null)
    same "code-daemon cold start pid alive" "$([ "$dpid" -gt 1 ] 2>/dev/null && kill -0 "$dpid" 2>/dev/null && echo yes || echo no)" "yes"
    same "code-daemon double-fork detached (ppid 1)" "$(ps -o ppid= -p "$dpid" 2>/dev/null | tr -d ' ')" "1"

    out=$(CNTCTR_DB="$d/s1/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" code status 2>&1); rc=$?
    same "code-daemon on status exit 0" "$rc" 0
    if printf '%s\n' "$out" | grep -Eq '^code: on · pid [0-9]+ · 0 servers · [0-9]+ MB · 0 projects · up [0-9]+[smhd]$'; then
        ok_
    else
        bad "code-daemon on status format" "  got: $out"
    fi
    out=$(CNTCTR_DB="$d/s1/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" code status --short 2>&1); rc=$?
    same "code-daemon on status --short exit 0" "$rc" 0
    same "code-daemon on status --short text" "$out" "code ●0"

    out=$(CNTCTR_DB="$d/s1/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" code status --verbose 2>&1); rc=$?
    same "code-daemon on status --verbose exit 0" "$rc" 0
    check "code-daemon on status --verbose includes socket path" "$out" "code.sock"

    smode=$(_cd_stat_mode "$d/s1/code.sock")
    dmode=$(_cd_stat_mode "$d/s1")
    same "code-daemon socket mode 0600" "$smode" "600"
    same "code-daemon socket dir mode 0700" "$dmode" "700"

    out=$(CNTCTR_DB="$d/s1/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop 2>&1); rc=$?
    same "code-daemon stop running exit 0" "$rc" 0
    same "code-daemon stop waits for exit" "$(_cd_wait_dead "$dpid" && echo yes || echo no)" "yes"
    same "code-daemon status after stop is off" "$(CNTCTR_DB="$d/s1/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" code status 2>&1)" "code: off"

    # 3. Scrubbed env check: SECRET_TEST_TOKEN absent; CNTCTR_TEST_DAEMON_VERSION & ASAN_OPTIONS pass through under CNTCTR_TEST_HOOKS
    out=$(CNTCTR_DB="$d/env/kb.db" env -u CNTCTR_CODE_SOCK \
        SECRET_TEST_TOKEN=leak CNTCTR_TEST_DAEMON_VERSION=0.5.5 CNTCTR_TEST_CLIENT_VERSION=0.5.5 \
        ASAN_OPTIONS="${ASAN_OPTIONS:+${ASAN_OPTIONS}:}halt_on_error=1" \
        "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon scrubbed env launch exit 0" "$rc" 0
    out=$(CNTCTR_DB="$d/env/kb.db" env -u CNTCTR_CODE_SOCK CNTCTR_TEST_CLIENT_VERSION=0.5.5 \
        "$BIN" _test-code-rpc '{"method":"test_env","key":"SECRET_TEST_TOKEN"}' 2>&1); rc=$?
    same "code-daemon scrubbed env hides SECRET_TEST_TOKEN" "$(printf '%s' "$out" | jq -r '.present' 2>/dev/null)" "false"
    out=$(CNTCTR_DB="$d/env/kb.db" env -u CNTCTR_CODE_SOCK CNTCTR_TEST_CLIENT_VERSION=0.5.5 \
        "$BIN" _test-code-rpc '{"method":"test_env","key":"CNTCTR_TEST_DAEMON_VERSION"}' 2>&1); rc=$?
    same "code-daemon test hook passes CNTCTR_TEST_DAEMON_VERSION" "$(printf '%s' "$out" | jq -r '.value // ""' 2>/dev/null)" "0.5.5"
    out=$(CNTCTR_DB="$d/env/kb.db" env -u CNTCTR_CODE_SOCK CNTCTR_TEST_CLIENT_VERSION=0.5.5 \
        "$BIN" _test-code-rpc '{"method":"test_env","key":"ASAN_OPTIONS"}' 2>&1); rc=$?
    check "code-daemon test hook passes ASAN_OPTIONS" "$(printf '%s' "$out" | jq -r '.value // ""' 2>/dev/null)" "halt_on_error=1"
    CNTCTR_DB="$d/env/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop >/dev/null 2>&1

    # 4. Oversized sun_path (115 chars) fails cleanly naming CNTCTR_CODE_SOCK
    local long_sock="/tmp/$(printf 'a%.0s' $(seq 1 105)).sock"
    out=$(CNTCTR_DB="$d/off/kb.db" CNTCTR_CODE_SOCK="$long_sock" "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon 115-char sock rpc fails" "$((rc != 0))" 1
    check "code-daemon 115-char sock rpc names CNTCTR_CODE_SOCK" "$out" "CNTCTR_CODE_SOCK"
    out=$(CNTCTR_DB="$d/off/kb.db" CNTCTR_CODE_SOCK="$long_sock" "$BIN" code status 2>&1); rc=$?
    same "code-daemon 115-char sock status fails" "$((rc != 0))" 1
    check "code-daemon 115-char sock status names CNTCTR_CODE_SOCK" "$out" "CNTCTR_CODE_SOCK"

    # 5. db_mismatch: daemon on db1, client with CNTCTR_CODE_SOCK=db1's sock and CNTCTR_DB=db2
    mkdir -p "$d/m1" "$d/m2"
    out=$(CNTCTR_DB="$d/m1/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon db_mismatch setup ping exit 0" "$rc" 0
    dpid=$(printf '%s' "$out" | jq -r '.pid // 0' 2>/dev/null)
    out=$(CNTCTR_DB="$d/m2/kb.db" CNTCTR_CODE_SOCK="$d/m1/code.sock" "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon db_mismatch fails" "$((rc != 0))" 1
    check "code-daemon db_mismatch error tag" "$out" "db_mismatch"
    check "code-daemon db_mismatch names db1" "$out" "m1/kb.db"
    check "code-daemon db_mismatch names db2" "$out" "m2/kb.db"
    check "code-daemon db_mismatch names CNTCTR_CODE_SOCK" "$out" "CNTCTR_CODE_SOCK"
    same "code-daemon db_mismatch leaves daemon alive" "$(kill -0 "$dpid" 2>/dev/null && echo yes || echo no)" "yes"
    CNTCTR_DB="$d/m1/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop >/dev/null 2>&1

    # 6. 4 parallel cold-start pings -> all 4 succeed, 1 daemon PID
    mkdir -p "$d/p4"
    local p4_pids="" i
    for i in 1 2 3 4; do
        CNTCTR_DB="$d/p4/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' \
            > "$d/p4/r$i.out" 2>&1 &
        p4_pids="$p4_pids $!"
    done
    local p4_ok=1 p4_first=""
    for i in $p4_pids; do wait "$i" || p4_ok=0; done
    same "code-daemon 4 parallel cold starts all exit 0" "$p4_ok" 1
    local p4_same=1
    for i in 1 2 3 4; do
        local rpid
        rpid=$(jq -r '.pid // 0' "$d/p4/r$i.out" 2>/dev/null)
        [ -z "$p4_first" ] && p4_first="$rpid"
        [ "$rpid" = "$p4_first" ] && [ "$rpid" -gt 1 ] 2>/dev/null || p4_same=0
    done
    same "code-daemon 4 parallel cold starts share 1 daemon PID" "$p4_same" 1
    CNTCTR_DB="$d/p4/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop >/dev/null 2>&1

    # 7. Two concurrent newer upgraders + one live run completing within grace + draining rejects work RPC
    mkdir -p "$d/u1"
    out=$(CNTCTR_DB="$d/u1/kb.db" env -u CNTCTR_CODE_SOCK \
        CNTCTR_TEST_DAEMON_VERSION=0.0.1 CNTCTR_TEST_CLIENT_VERSION=0.0.1 \
        "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon upgrade1 start old daemon exit 0" "$rc" 0
    old_pid=$(printf '%s' "$out" | jq -r '.pid // 0' 2>/dev/null)

    CNTCTR_DB="$d/u1/kb.db" env -u CNTCTR_CODE_SOCK CNTCTR_TEST_CLIENT_VERSION=0.0.1 \
        "$BIN" _test-code-rpc "$(jq -nc --arg rf "$d/u1/hold.ready" '{method:"test_hold",ms:1000,ready_file:$rf}')" \
        > "$d/u1/hold.out" 2>&1 &
    local hold_job=$!
    same "code-daemon upgrade1 hold active" "$(_cd_wait_file "$d/u1/hold.ready" && echo yes || echo no)" "yes"

    # Launch 2 concurrent normal-version upgraders
    CNTCTR_DB="$d/u1/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' > "$d/u1/up1.out" 2>&1 &
    local up1_job=$!
    CNTCTR_DB="$d/u1/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' > "$d/u1/up2.out" 2>&1 &
    local up2_job=$!

    # Poll until daemon reports draining=true via --no-autostart status, then test work RPC rejection while draining
    local dr_seen=0 dr_work_out="" dr_work_rc=0
    for i in $(seq 1 100); do
        out=$(CNTCTR_DB="$d/u1/kb.db" env -u CNTCTR_CODE_SOCK CNTCTR_TEST_CLIENT_VERSION=0.0.1 \
            "$BIN" _test-code-rpc --no-autostart '{"method":"status"}' 2>&1)
        if [ "$(printf '%s' "$out" | jq -r '.draining // false' 2>/dev/null)" = "true" ]; then
            dr_seen=1
            dr_work_out=$(CNTCTR_DB="$d/u1/kb.db" env -u CNTCTR_CODE_SOCK CNTCTR_TEST_CLIENT_VERSION=0.0.1 \
                "$BIN" _test-code-rpc --no-autostart '{"method":"ping"}' 2>&1); dr_work_rc=$?
            break
        fi
        sleep 0.02
    done
    same "code-daemon upgrade1 observed draining status while hold active" "$dr_seen" 1
    same "code-daemon upgrade1 draining work RPC rejected" "$((dr_work_rc != 0))" 1
    check "code-daemon upgrade1 draining work RPC retryable message" "$dr_work_out" "cntctr is upgrading; retry in a few seconds"

    local hold_rc=0 up1_rc=0 up2_rc=0
    wait "$hold_job" || hold_rc=$?
    wait "$up1_job" || up1_rc=$?
    wait "$up2_job" || up2_rc=$?
    same "code-daemon upgrade1 live run completes cleanly" "$hold_rc" 0
    same "code-daemon upgrade1 live run ok" "$(jq -r '.ok // false' "$d/u1/hold.out" 2>/dev/null)" "true"
    same "code-daemon upgrade1 upgrader 1 succeeds" "$up1_rc" 0
    same "code-daemon upgrade1 upgrader 2 succeeds" "$up2_rc" 0
    new_pid=$(jq -r '.pid // 0' "$d/u1/up1.out" 2>/dev/null)
    new_pid2=$(jq -r '.pid // 0' "$d/u1/up2.out" 2>/dev/null)
    same "code-daemon upgrade1 both upgraders hit 1 new daemon" "$new_pid" "$new_pid2"
    same "code-daemon upgrade1 new daemon PID differs from old" "$((new_pid != old_pid && new_pid > 1))" 1
    same "code-daemon upgrade1 old daemon exited" "$(_cd_wait_dead "$old_pid" && echo yes || echo no)" "yes"
    CNTCTR_DB="$d/u1/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop >/dev/null 2>&1

    # 8. Drain grace timeout: test_hold > CNTCTR_CODE_DRAIN_GRACE_SEC=1 cancelled with "daemon upgrading; rerun"
    mkdir -p "$d/u2"
    out=$(CNTCTR_DB="$d/u2/kb.db" env -u CNTCTR_CODE_SOCK \
        CNTCTR_TEST_DAEMON_VERSION=0.0.1 CNTCTR_TEST_CLIENT_VERSION=0.0.1 CNTCTR_CODE_DRAIN_GRACE_SEC=1 \
        "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon upgrade2 start old daemon exit 0" "$rc" 0
    old_pid=$(printf '%s' "$out" | jq -r '.pid // 0' 2>/dev/null)

    CNTCTR_DB="$d/u2/kb.db" env -u CNTCTR_CODE_SOCK CNTCTR_TEST_CLIENT_VERSION=0.0.1 \
        "$BIN" _test-code-rpc "$(jq -nc --arg rf "$d/u2/hold.ready" '{method:"test_hold",ms:15000,ready_file:$rf}')" \
        > "$d/u2/hold.out" 2>&1 &
    hold_job=$!
    same "code-daemon upgrade2 hold active" "$(_cd_wait_file "$d/u2/hold.ready" && echo yes || echo no)" "yes"

    CNTCTR_DB="$d/u2/kb.db" env -u CNTCTR_CODE_SOCK CNTCTR_CODE_DRAIN_GRACE_SEC=1 \
        "$BIN" _test-code-rpc '{"method":"ping"}' > "$d/u2/up1.out" 2>&1 &
    up1_job=$!
    CNTCTR_DB="$d/u2/kb.db" env -u CNTCTR_CODE_SOCK CNTCTR_CODE_DRAIN_GRACE_SEC=1 \
        "$BIN" _test-code-rpc '{"method":"ping"}' > "$d/u2/up2.out" 2>&1 &
    up2_job=$!

    hold_rc=0; up1_rc=0; up2_rc=0
    wait "$hold_job" || hold_rc=$?
    wait "$up1_job" || up1_rc=$?
    wait "$up2_job" || up2_rc=$?
    same "code-daemon upgrade2 grace-exceeded run fails" "$((hold_rc != 0))" 1
    check "code-daemon upgrade2 grace-exceeded error text" "$(cat "$d/u2/hold.out")" "daemon upgrading; rerun"
    same "code-daemon upgrade2 upgrader 1 succeeds" "$up1_rc" 0
    same "code-daemon upgrade2 upgrader 2 succeeds" "$up2_rc" 0
    new_pid=$(jq -r '.pid // 0' "$d/u2/up1.out" 2>/dev/null)
    new_pid2=$(jq -r '.pid // 0' "$d/u2/up2.out" 2>/dev/null)
    same "code-daemon upgrade2 both upgraders hit 1 new daemon" "$new_pid" "$new_pid2"
    same "code-daemon upgrade2 new daemon PID differs from old" "$((new_pid != old_pid && new_pid > 1))" 1
    same "code-daemon upgrade2 old daemon exited" "$(_cd_wait_dead "$old_pid" && echo yes || echo no)" "yes"
    CNTCTR_DB="$d/u2/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop >/dev/null 2>&1

    # 9. Older client vs newer daemon -> daemon NOT drained (same PID), client gets version_mismatch
    mkdir -p "$d/ov"
    out=$(CNTCTR_DB="$d/ov/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon older-client setup exit 0" "$rc" 0
    dpid=$(printf '%s' "$out" | jq -r '.pid // 0' 2>/dev/null)
    out=$(CNTCTR_DB="$d/ov/kb.db" env -u CNTCTR_CODE_SOCK CNTCTR_TEST_CLIENT_VERSION=0.0.1 \
        "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon older client rejected" "$((rc != 0))" 1
    check "code-daemon older client version_mismatch" "$out" "version_mismatch"
    check "code-daemon older client mentions newer" "$out" "is newer"
    check "code-daemon older client advises restart" "$out" "restart your harness"
    out=$(CNTCTR_DB="$d/ov/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    dpid2=$(printf '%s' "$out" | jq -r '.pid // 0' 2>/dev/null)
    same "code-daemon older client did not drain daemon" "$dpid2" "$dpid"
    CNTCTR_DB="$d/ov/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop >/dev/null 2>&1

    # 10. Idle exit boundary: CNTCTR_CODE_DAEMON_IDLE_SEC=1
    mkdir -p "$d/id"
    out=$(CNTCTR_DB="$d/id/kb.db" env -u CNTCTR_CODE_SOCK CNTCTR_CODE_DAEMON_IDLE_SEC=1 \
        "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon idle setup exit 0" "$rc" 0
    dpid=$(printf '%s' "$out" | jq -r '.pid // 0' 2>/dev/null)
    # Poll status (which does not reset idle timer) until uptime_sec >= 1 or daemon begins exiting,
    # then fire concurrent pings right at the 1s boundary so retries under code.lock succeed.
    for i in $(seq 1 100); do
        out=$(CNTCTR_DB="$d/id/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc --no-autostart '{"method":"status"}' 2>&1) || break
        [ "$(printf '%s' "$out" | jq -r '.uptime_sec // 0' 2>/dev/null)" -ge 1 ] 2>/dev/null && break
        sleep 0.02
    done
    local b_pids="" boundary_ok=1
    for i in 1 2 3 4; do
        CNTCTR_DB="$d/id/kb.db" env -u CNTCTR_CODE_SOCK CNTCTR_CODE_DAEMON_IDLE_SEC=1 \
            "$BIN" _test-code-rpc '{"method":"ping"}' >/dev/null 2>&1 &
        b_pids="$b_pids $!"
    done
    for i in $b_pids; do wait "$i" || boundary_ok=0; done
    same "code-daemon idle boundary pings succeed" "$boundary_ok" 1
    out=$(CNTCTR_DB="$d/id/kb.db" env -u CNTCTR_CODE_SOCK CNTCTR_CODE_DAEMON_IDLE_SEC=1 \
        "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1)
    dpid=$(printf '%s' "$out" | jq -r '.pid // 0' 2>/dev/null)
    # Now stay quiet (polling status does NOT reset idle timer) until daemon exits cleanly on idle timeout
    same "code-daemon idle exits cleanly to off" "$(_cd_wait_off "$d/id/kb.db" && echo yes || echo no)" "yes"
    same "code-daemon idle unlinks socket" "$([ -e "$d/id/code.sock" ] && echo yes || echo no)" "no"
    same "code-daemon idle process exited" "$(_cd_wait_dead "$dpid" && echo yes || echo no)" "yes"

    # 11. Client cancellation polling (<=200 ms slice) + daemon releases active_runs on client disconnect
    mkdir -p "$d/cn"
    out=$(CNTCTR_DB="$d/cn/kb.db" env -u CNTCTR_CODE_SOCK \
        "$BIN" _test-code-rpc --cancel-after 150 '{"method":"test_hold","ms":15000}' 2>&1); rc=$?
    same "code-daemon cancel-after exits non-zero" "$((rc != 0))" 1
    check "code-daemon cancel-after reports cancelled" "$out" "cancelled"
    local runs_zero=0
    for i in $(seq 1 50); do
        out=$(CNTCTR_DB="$d/cn/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc --no-autostart '{"method":"status"}' 2>&1)
        if [ "$(printf '%s' "$out" | jq -r '.active_runs // -1' 2>/dev/null)" = "0" ]; then
            runs_zero=1
            break
        fi
        sleep 0.02
    done
    same "code-daemon cancel disconnects and drops active_runs to 0" "$runs_zero" 1
    CNTCTR_DB="$d/cn/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop >/dev/null 2>&1

    # 12. Crash recovery: kill -9 -> status prints 'code: off' (no stale on), next autostart restarts cleanly
    mkdir -p "$d/cr"
    out=$(CNTCTR_DB="$d/cr/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon crash setup exit 0" "$rc" 0
    dpid=$(printf '%s' "$out" | jq -r '.pid // 0' 2>/dev/null)
    kill -9 "$dpid" 2>/dev/null
    same "code-daemon crash target killed" "$(_cd_wait_dead "$dpid" && echo yes || echo no)" "yes"
    same "code-daemon crash stale socket exists before probe" "$([ -e "$d/cr/code.sock" ] && echo yes || echo no)" "yes"
    out=$(CNTCTR_DB="$d/cr/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" code status 2>&1); rc=$?
    same "code-daemon crash status exit 0" "$rc" 0
    same "code-daemon crash status prints off (not stale on)" "$out" "code: off"
    same "code-daemon crash status --short prints off" \
        "$(CNTCTR_DB="$d/cr/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" code status --short 2>&1)" "code ○"
    out=$(CNTCTR_DB="$d/cr/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon crash autostart restarts exit 0" "$rc" 0
    dpid2=$(printf '%s' "$out" | jq -r '.pid // 0' 2>/dev/null)
    same "code-daemon crash restarted with new PID" "$((dpid2 != dpid && dpid2 > 1))" 1
    CNTCTR_DB="$d/cr/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop >/dev/null 2>&1

    # 13. CODE-DAEMON-02: trusted parent dir, O_NOFOLLOW symlink lockfile, regular file not unlinked as stale socket
    mkdir -p "$d/bp"
    chmod 0777 "$d/bp"
    out=$(CNTCTR_DB="$d/bp/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    chmod 0700 "$d/bp"
    same "code-daemon CODE-DAEMON-02 rejects world-writable socket dir" "$((rc != 0))" 1
    check "code-daemon CODE-DAEMON-02 world-writable error explains perms" "$out" "writable"

    mkdir -p "$d/sl"
    printf 'keep\n' > "$d/sl/target"
    ln -s "$d/sl/target" "$d/sl/code.lock"
    out=$(CNTCTR_DB="$d/sl/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon CODE-DAEMON-02 rejects symlink lockfile" "$((rc != 0))" 1
    same "code-daemon CODE-DAEMON-02 symlink target untouched" "$(/bin/cat "$d/sl/target")" "keep"

    mkdir -p "$d/rf"
    printf 'not-a-socket\n' > "$d/rf/code.sock"
    out=$(CNTCTR_DB="$d/rf/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon CODE-DAEMON-02 rejects regular file at sock_path" "$((rc != 0))" 1
    same "code-daemon CODE-DAEMON-02 does not unlink regular file at sock_path" "$(/bin/cat "$d/rf/code.sock" 2>/dev/null)" "not-a-socket"

    # 14. CODE-DAEMON-04: lock timeout, lock cancel, and outbound frame cap
    mkdir -p "$d/lk"
    python3 -c '
import fcntl, os, sys, time
lpath, rpath, spath = sys.argv[1], sys.argv[2], sys.argv[3]
fd = os.open(lpath, os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
with open(rpath, "w") as f: f.write("locked\n")
while not os.path.exists(spath):
    time.sleep(0.02)
os.close(fd)
' "$d/lk/code.lock" "$d/lk/lock.ready" "$d/lk/lock.stop" &
    local lk_job=$!
    same "code-daemon CODE-DAEMON-04 lock holder ready" "$(_cd_wait_file "$d/lk/lock.ready" && echo yes || echo no)" "yes"
    out=$(CNTCTR_DB="$d/lk/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc --timeout 250 '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon CODE-DAEMON-04 lock acquisition honors timeout" "$((rc != 0))" 1
    check "code-daemon CODE-DAEMON-04 lock timeout message" "$out" "timed out"
    out=$(CNTCTR_DB="$d/lk/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc --cancel-after 150 '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon CODE-DAEMON-04 lock acquisition honors cancel" "$((rc != 0))" 1
    check "code-daemon CODE-DAEMON-04 lock cancel message" "$out" "cancelled"
    : > "$d/lk/lock.stop"
    wait "$lk_job"

    mkdir -p "$d/cap"
    out=$(python3 -c 'import json; print(json.dumps({"method":"ping","pad":"x" * (1200 * 1024)}))' | \
        CNTCTR_DB="$d/cap/kb.db" env -u CNTCTR_CODE_SOCK CNTCTR_CODE_MAX_MB=4 "$BIN" _test-code-rpc - 2>&1); rc=$?
    same "code-daemon CODE-DAEMON-04 oversized outbound frame rejected" "$((rc != 0))" 1
    check "code-daemon CODE-DAEMON-04 oversized outbound frame names limit" "$out" "line limit"
    CNTCTR_DB="$d/cap/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop >/dev/null 2>&1

    # 15. CODE-DAEMON-05 & CODE-DAEMON-06: SemVer prerelease numeric ordering, daemon-side drain check, older code stop rejected
    mkdir -p "$d/sv"
    out=$(CNTCTR_DB="$d/sv/kb.db" env -u CNTCTR_CODE_SOCK \
        CNTCTR_TEST_DAEMON_VERSION=0.5.5-alpha.2 CNTCTR_TEST_CLIENT_VERSION=0.5.5-alpha.2 \
        "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon CODE-DAEMON-06 start alpha.2 daemon exit 0" "$rc" 0
    old_pid=$(printf '%s' "$out" | jq -r '.pid // 0' 2>/dev/null)
    out=$(CNTCTR_DB="$d/sv/kb.db" env -u CNTCTR_CODE_SOCK \
        CNTCTR_TEST_DAEMON_VERSION=0.5.5-alpha.10 CNTCTR_TEST_CLIENT_VERSION=0.5.5-alpha.10 \
        "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon CODE-DAEMON-06 alpha.10 upgrades alpha.2 exit 0" "$rc" 0
    new_pid=$(printf '%s' "$out" | jq -r '.pid // 0' 2>/dev/null)
    same "code-daemon CODE-DAEMON-06 alpha.10 replaced alpha.2 PID" "$((new_pid != old_pid && new_pid > 1))" 1
    out=$(CNTCTR_DB="$d/sv/kb.db" env -u CNTCTR_CODE_SOCK \
        CNTCTR_TEST_CLIENT_VERSION=0.5.5-alpha.2 "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon CODE-DAEMON-06 alpha.2 rejected vs alpha.10" "$((rc != 0))" 1
    check "code-daemon CODE-DAEMON-06 alpha.2 version_mismatch" "$out" "version_mismatch"

    # Older client code stop is refused (rc != 0) and daemon stays alive
    out=$(CNTCTR_DB="$d/sv/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT \
        CNTCTR_TEST_CLIENT_VERSION=0.5.5-alpha.2 "$BIN" code stop 2>&1); rc=$?
    same "code-daemon CODE-DAEMON-06 older code stop fails" "$((rc != 0))" 1
    check "code-daemon CODE-DAEMON-06 older code stop names version_mismatch" "$out" "version_mismatch"
    same "code-daemon CODE-DAEMON-06 older code stop keeps daemon alive" "$(kill -0 "$new_pid" 2>/dev/null && echo yes || echo no)" "yes"

    # Direct raw older-client drain RPC is rejected by daemon itself
    out=$(python3 -c '
import json, os, socket, sys
sock, db = sys.argv[1], os.path.realpath(os.path.dirname(sys.argv[2])) + "/" + os.path.basename(sys.argv[2])
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock)
f = s.makefile("rwb", buffering=0)
f.write((json.dumps({"id":0,"method":"hello","proto":1,"version":"0.5.5-alpha.2","db":db}) + "\n").encode())
_ = f.readline()
f.write((json.dumps({"id":1,"method":"drain"}) + "\n").encode())
resp = f.readline().decode().strip()
s.close()
print(resp)
' "$d/sv/code.sock" "$d/sv/kb.db" 2>&1)
    same "code-daemon CODE-DAEMON-06 raw older drain rejected ok=false" "$(printf '%s' "$out" | jq -r '.ok' 2>/dev/null)" "false"
    check "code-daemon CODE-DAEMON-06 raw older drain error" "$out" "version_mismatch"
    same "code-daemon CODE-DAEMON-06 raw older drain keeps daemon alive" "$(kill -0 "$new_pid" 2>/dev/null && echo yes || echo no)" "yes"
    CNTCTR_DB="$d/sv/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT CNTCTR_TEST_CLIENT_VERSION=0.5.5-alpha.10 "$BIN" code stop >/dev/null 2>&1

    # 16. CODE-DAEMON-01 & CODE-DAEMON-07: open non-work/status connection neither postpones idle exit nor blocks clean shutdown
    mkdir -p "$d/st"
    out=$(CNTCTR_DB="$d/st/kb.db" env -u CNTCTR_CODE_SOCK CNTCTR_CODE_DAEMON_IDLE_SEC=1 \
        "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon CODE-DAEMON-07 setup exit 0" "$rc" 0
    dpid=$(printf '%s' "$out" | jq -r '.pid // 0' 2>/dev/null)
    python3 -c '
import json, os, socket, sys
sock, db, rpath = sys.argv[1], os.path.realpath(os.path.dirname(sys.argv[2])) + "/" + os.path.basename(sys.argv[2]), sys.argv[3]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock)
f = s.makefile("rwb", buffering=0)
f.write((json.dumps({"id":0,"method":"hello","proto":1,"version":"0.5.5","db":db}) + "\n").encode())
_ = f.readline()
f.write((json.dumps({"id":1,"method":"status"}) + "\n").encode())
_ = f.readline()
with open(rpath, "w") as rf: rf.write("open\n")
# Hold connection open until daemon shuts it down (EOF)
s.settimeout(5.0)
data = s.recv(16)
s.close()
sys.exit(0 if data == b"" else 1)
' "$d/st/code.sock" "$d/st/kb.db" "$d/st/open.ready" &
    local st_job=$!
    same "code-daemon CODE-DAEMON-07 status conn open" "$(_cd_wait_file "$d/st/open.ready" && echo yes || echo no)" "yes"
    same "code-daemon CODE-DAEMON-07 daemon idle-exits despite open status conn" "$(_cd_wait_dead "$dpid" && echo yes || echo no)" "yes"
    local st_rc=0
    wait "$st_job" || st_rc=$?
    same "code-daemon CODE-DAEMON-01 shutdown cleanly closed open worker conn" "$st_rc" 0

    # 17. CODE-DAEMON-03: startup lock reservation stays held by grandchild across launcher cancel until listen()
    mkdir -p "$d/r3"
    CNTCTR_DB="$d/r3/kb.db" env -u CNTCTR_CODE_SOCK CNTCTR_TEST_DAEMON_PRE_BIND_BARRIER="$d/r3/bar" \
        "$BIN" _test-code-rpc --cancel-after 150 '{"method":"ping"}' > "$d/r3/c1.out" 2>&1 &
    local c1_job=$!
    same "code-daemon CODE-DAEMON-03 grandchild reached pre-bind barrier" "$(_cd_wait_file "$d/r3/bar.ready" && echo yes || echo no)" "yes"
    local gc_pid
    gc_pid=$(/bin/cat "$d/r3/bar.ready" | tr -d '[:space:]')
    local c1_rc=0
    wait "$c1_job" || c1_rc=$?
    same "code-daemon CODE-DAEMON-03 launcher 1 cancelled cleanly" "$((c1_rc != 0))" 1
    # Verify code.lock is STILL held by grandchild even after launcher 1 exited
    local still_locked
    still_locked=$(python3 -c '
import fcntl, os, sys
fd = os.open(sys.argv[1], os.O_RDWR)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    print("unlocked")
except BlockingIOError:
    print("locked")
finally:
    os.close(fd)
' "$d/r3/code.lock")
    same "code-daemon CODE-DAEMON-03 grandchild still holds code.lock after launcher exit" "$still_locked" "locked"
    # Launch client 2 while grandchild still holds lock; release barrier and verify client 2 connects to gc_pid
    CNTCTR_DB="$d/r3/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' > "$d/r3/c2.out" 2>&1 &
    local c2_job=$!
    : > "$d/r3/bar.go"
    local c2_rc=0
    wait "$c2_job" || c2_rc=$?
    same "code-daemon CODE-DAEMON-03 client 2 succeeds after grandchild finishes listen" "$c2_rc" 0
    same "code-daemon CODE-DAEMON-03 client 2 connected to original grandchild PID (no second daemon)" \
        "$(jq -r '.pid // 0' "$d/r3/c2.out" 2>/dev/null)" "$gc_pid"
    CNTCTR_DB="$d/r3/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop >/dev/null 2>&1

    # 18. Round-2 CODE-DAEMON-02: writable ancestor dir & group-writable 0775 final dir rejected; 0755 accepted
    mkdir -p "$d/anc/sub"
    chmod 0700 "$d/anc/sub"
    chmod 0777 "$d/anc"
    out=$(CNTCTR_DB="$d/anc/sub/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    chmod 0700 "$d/anc"
    same "code-daemon R2-02 rejects world-writable ancestor dir" "$((rc != 0))" 1
    check "code-daemon R2-02 ancestor error names offending dir" "$out" "/anc"

    mkdir -p "$d/gw"
    chmod 0775 "$d/gw"
    out=$(CNTCTR_DB="$d/gw/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    chmod 0700 "$d/gw"
    same "code-daemon R2-02 rejects group-writable 0775 final dir" "$((rc != 0))" 1
    check "code-daemon R2-02 0775 error names offending dir" "$out" "/gw"

    mkdir -p "$d/ok755"
    chmod 0755 "$d/ok755"
    out=$(CNTCTR_DB="$d/ok755/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon R2-02 accepts same-UID 0755 final dir" "$rc" 0
    CNTCTR_DB="$d/ok755/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop >/dev/null 2>&1

    # 19. Round-2 CODE-DAEMON-03: manually supplied unlocked CNTCTR_CODE_LOCK_FD must not bypass code.lock
    mkdir -p "$d/f3"
    python3 -c '
import fcntl, os, subprocess, sys, time
sock, db, lpath, binp = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
canon_db = os.path.realpath(os.path.dirname(db)) + "/" + os.path.basename(db)
hold = os.open(lpath, os.O_CREAT | os.O_RDWR, 0o600)
fcntl.flock(hold, fcntl.LOCK_EX)
# Open a separate unlocked description on the same lock inode and pass it as fd 7 (distinct from hold)
unlocked = os.open(lpath, os.O_RDWR)
os.dup2(unlocked, 7)
os.set_inheritable(7, True)
if unlocked != 7: os.close(unlocked)
env = dict(os.environ)
env["CNTCTR_CODE_LOCK_FD"] = "7"
env["CNTCTR_CODE_DAEMON_IDLE_SEC"] = "5"
env.pop("CNTCTR_CODE_SOCK", None)
proc = subprocess.Popen([binp, "_code-daemon", sock, canon_db], env=env, pass_fds=(7,),
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
os.close(7)
# Poll briefly to prove daemon did NOT bind while lock is held by `hold`
bound_early = False
for _ in range(15):
    if os.path.exists(sock):
        bound_early = True
        break
    time.sleep(0.02)
# Release hold -> daemon must now acquire lock and bind
fcntl.flock(hold, fcntl.LOCK_UN)
os.close(hold)
bound_after = False
for _ in range(100):
    if os.path.exists(sock):
        bound_after = True
        break
    time.sleep(0.02)
print("early=" + str(bound_early) + " after=" + str(bound_after))
sys.exit(0 if (not bound_early and bound_after) else 1)
' "$d/f3/code.sock" "$d/f3/kb.db" "$d/f3/code.lock" "$BIN" > "$d/f3/res.out" 2>&1; rc=$?
    same "code-daemon R2-03 unlocked inherited fd does not bypass code.lock" "$rc" 0
    CNTCTR_DB="$d/f3/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop >/dev/null 2>&1

    # 20. Round-2 CODE-DAEMON-06: SemVer build metadata (+build.1 vs +build.2) has equal precedence (compatible, no drain)
    mkdir -p "$d/bm"
    out=$(CNTCTR_DB="$d/bm/kb.db" env -u CNTCTR_CODE_SOCK \
        CNTCTR_TEST_DAEMON_VERSION=0.5.5+build.1 CNTCTR_TEST_CLIENT_VERSION=0.5.5+build.1 \
        "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon R2-06 start +build.1 daemon exit 0" "$rc" 0
    dpid=$(printf '%s' "$out" | jq -r '.pid // 0' 2>/dev/null)
    out=$(CNTCTR_DB="$d/bm/kb.db" env -u CNTCTR_CODE_SOCK \
        CNTCTR_TEST_CLIENT_VERSION=0.5.5+build.2 "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon R2-06 +build.2 compatible with +build.1 exit 0" "$rc" 0
    dpid2=$(printf '%s' "$out" | jq -r '.pid // 0' 2>/dev/null)
    same "code-daemon R2-06 +build.2 did not drain +build.1 daemon" "$dpid2" "$dpid"
    CNTCTR_DB="$d/bm/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT CNTCTR_TEST_CLIENT_VERSION=0.5.5+build.2 "$BIN" code stop >/dev/null 2>&1

    # 21. Round-2 CODE-DAEMON-09: fd opened above lowered soft RLIMIT_NOFILE is closed in spawned daemon
    mkdir -p "$d/hf"
    python3 -c '
import os, resource, select, subprocess, sys
db, binp = sys.argv[1], sys.argv[2]
r, w = os.pipe()
os.dup2(w, 300)
os.set_inheritable(300, True)
os.close(w)
soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
resource.setrlimit(resource.RLIMIT_NOFILE, (min(128, soft), hard))
env = dict(os.environ)
env["CNTCTR_DB"] = db
env.pop("CNTCTR_CODE_SOCK", None)
res = subprocess.run([binp, "_test-code-rpc", "{\"method\":\"ping\"}"], env=env, pass_fds=(300,),
                     capture_output=True, text=True)
os.close(300)
if res.returncode != 0:
    print("rpc failed:", res.stderr)
    sys.exit(1)
rd, _, _ = select.select([r], [], [], 2.0)
data = os.read(r, 16) if rd else None
os.close(r)
sys.exit(0 if data == b"" else 1)
' "$d/hf/kb.db" "$BIN" > "$d/hf/res.out" 2>&1; rc=$?
    same "code-daemon R2-09 daemon closes high fd above lowered soft RLIMIT_NOFILE" "$rc" 0
    CNTCTR_DB="$d/hf/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop >/dev/null 2>&1

    # 22. Round-3 CODE-DAEMON-02: untrusted ancestor with missing parent components creates nothing; normal missing parents work
    mkdir -p "$d/uanc"
    chmod 0777 "$d/uanc"
    out=$(CNTCTR_DB="$d/uanc/m1/m2/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon R3-02 untrusted ancestor with missing parents fails" "$((rc != 0))" 1
    check "code-daemon R3-02 untrusted ancestor error names offending dir" "$out" "/uanc"
    same "code-daemon R3-02 untrusted ancestor created no missing dir" "$([ -e "$d/uanc/m1" ] && echo yes || echo no)" "no"
    chmod 0700 "$d/uanc"

    out=$(CNTCTR_DB="$d/np1/np2/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon R3-02 normal missing multi-level parents succeed" "$rc" 0
    same "code-daemon R3-02 normal missing final dir mode 0700" "$(_cd_stat_mode "$d/np1/np2")" "700"
    same "code-daemon R3-02 normal missing socket mode 0600" "$(_cd_stat_mode "$d/np1/np2/code.sock")" "600"
    CNTCTR_DB="$d/np1/np2/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop >/dev/null 2>&1

    # 23. Round-4 CODE-DAEMON-10 (no UAF on mkdirat/openat error paths under ASan) & CODE-DAEMON-11 (umask 0277/0477)
    mkdir -p "$d/ro"
    chmod 0500 "$d/ro"
    out=$(CNTCTR_DB="$d/ro/cantcreate/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    chmod 0700 "$d/ro"
    same "code-daemon R4-10 mkdirat failure exits non-zero cleanly" "$((rc != 0))" 1
    refute "code-daemon R4-10 mkdirat failure has no ASan error" "$out" "AddressSanitizer"
    check "code-daemon R4-10 mkdirat error names component" "$out" "cantcreate"

    mkdir -p "$d/nf"
    printf 'file\n' > "$d/nf/blocked"
    out=$(CNTCTR_DB="$d/nf/blocked/sub/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}' 2>&1); rc=$?
    same "code-daemon R4-10 openat non-dir failure exits non-zero cleanly" "$((rc != 0))" 1
    refute "code-daemon R4-10 openat failure has no ASan error" "$out" "AddressSanitizer"
    check "code-daemon R4-10 openat error names component" "$out" "blocked"

    out=$( (umask 0277 && CNTCTR_DB="$d/u277/sub/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}') 2>&1 ); rc=$?
    same "code-daemon R4-11 umask 0277 creates dir and succeeds" "$rc" 0
    same "code-daemon R4-11 umask 0277 final dir mode 0700" "$(_cd_stat_mode "$d/u277/sub")" "700"
    CNTCTR_DB="$d/u277/sub/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop >/dev/null 2>&1

    out=$( (umask 0477 && CNTCTR_DB="$d/u477/sub/kb.db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc '{"method":"ping"}') 2>&1 ); rc=$?
    same "code-daemon R4-11 umask 0477 creates dir and succeeds" "$rc" 0
    same "code-daemon R4-11 umask 0477 final dir mode 0700" "$(_cd_stat_mode "$d/u477/sub")" "700"
    CNTCTR_DB="$d/u477/sub/kb.db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop >/dev/null 2>&1

    # 24. Round-5 CODE-DAEMON-11: even with require_trusted=0 (db_path dir), refuse mkdirat under 0777 parent and create nothing
    mkdir -p "$d/r5s" "$d/r5db"
    chmod 0700 "$d/r5s"
    chmod 0777 "$d/r5db"
    out=$(CNTCTR_CODE_DAEMON_IDLE_SEC=1 "$BIN" _code-daemon "$d/r5s/code.sock" "$d/r5db/missing/kb.db" 2>&1); rc=$?
    same "code-daemon R5-11 require_trusted=0 refuses 0777 parent" "$((rc != 0))" 1
    check "code-daemon R5-11 error names offending parent" "$out" "/r5db"
    same "code-daemon R5-11 created no dir under 0777 parent" "$([ -e "$d/r5db/missing" ] && echo yes || echo no)" "no"
    chmod 0700 "$d/r5db"
}
if [ "${ONLY:-}" = code-daemon ]; then
    code_daemon_run
    printf '%d passed, %d failed\n' "$pass" "$fail"
    [ "$fail" -eq 0 ]; exit $?
fi

# ---- Code Mode Phase 5: fake MCP fixture, downstream MCP stdio client, per-instance catalogs, atomic recheck, LRU pool & daemon wiring ----
code_mcp_run() {
    local d="$TMPD/cm" fixture py out rc projA projB reg reg2 pid1 pid2 dpid
    mkdir -p "$d"
    fixture="$(pwd)/fixtures/fake-mcp.py"
    py="$(command -v python3)"

    _cm_wait_file() {
        local f=$1 i=0
        while [ ! -f "$f" ] && [ "$i" -lt 250 ]; do
            sleep 0.02
            i=$((i + 1))
        done
        [ -f "$f" ]
    }
    _cm_wait_dead() {
        local p=$1 i=0
        while kill -0 "$p" 2>/dev/null && [ "$i" -lt 250 ]; do
            sleep 0.02
            i=$((i + 1))
        done
        ! kill -0 "$p" 2>/dev/null
    }
    _cm_add() {
        local db=$1 cwd=$2; shift 2
        (cd "$cwd" && CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ \
            env -u TMUX_PANE -u CNTCTR_PANE -u CNTCTR_ROOT -u CNTCTR_CODE_SOCK \
            "$BIN" code server add "$@")
    }
    _cm_rpc() {
        local db=$1; shift
        CNTCTR_DB="$db" env -u CNTCTR_CODE_SOCK "$BIN" _test-code-rpc "$@"
    }
    _cm_stop() {
        local db=$1
        CNTCTR_DB="$db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop >/dev/null 2>&1 || true
    }

    # 1. Strict protocol order in fake-mcp.py directly & paginated discover through daemon
    mkdir -p "$d/p1/projA"
    projA=$(CNTCTR_DB="$d/p1/kb.db" "$BIN" _test-code-kb resolve-cwd "$d/p1/projA")
    out=$(python3 -c '
import json, subprocess, sys
p = subprocess.Popen([sys.argv[1], sys.argv[2], "--paginate"],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
def send(obj):
    p.stdin.write(json.dumps(obj) + "\n")
    p.stdin.flush()
    return json.loads(p.stdout.readline())
# Reject tools/list before initialize
r1 = send({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}})
# Initialize
r2 = send({"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}})
# Reject tools/list after initialize but BEFORE notifications/initialized
r3 = send({"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}})
# Reject tools/call before notifications/initialized
r4 = send({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ping","arguments":{}}})
# Send notifications/initialized
p.stdin.write(json.dumps({"jsonrpc":"2.0","method":"notifications/initialized"}) + "\n")
p.stdin.flush()
# Now tools/list returns page 1 with nextCursor, then page 2
r5 = send({"jsonrpc":"2.0","id":5,"method":"tools/list","params":{}})
cur = r5.get("result", {}).get("nextCursor", "")
r6 = send({"jsonrpc":"2.0","id":6,"method":"tools/list","params":{"cursor":cur}}) if cur else {}
p.stdin.close()
p.wait(timeout=5)
print(json.dumps({
    "pre_init_err": "error" in r1,
    "init_ok": "result" in r2 and bool(r2["result"].get("protocolVersion")),
    "pre_notif_list_err": "error" in r3,
    "pre_notif_call_err": "error" in r4,
    "has_cursor": bool(cur),
    "p2_done": "result" in r6 and not r6["result"].get("nextCursor"),
    "total_tools": len(r5.get("result",{}).get("tools",[])) + len(r6.get("result",{}).get("tools",[]))
}))
' "$py" "$fixture" 2>&1); rc=$?
    same "code-mcp fixture strict init order exit 0" "$rc" 0
    same "code-mcp fixture rejects tools/list before initialize" "$(printf '%s' "$out" | jq -r '.pre_init_err // false' 2>/dev/null)" "true"
    same "code-mcp fixture accepts initialize" "$(printf '%s' "$out" | jq -r '.init_ok // false' 2>/dev/null)" "true"
    same "code-mcp fixture rejects tools/list before notifications/initialized" "$(printf '%s' "$out" | jq -r '.pre_notif_list_err // false' 2>/dev/null)" "true"
    same "code-mcp fixture rejects tools/call before notifications/initialized" "$(printf '%s' "$out" | jq -r '.pre_notif_call_err // false' 2>/dev/null)" "true"
    same "code-mcp fixture paginates with nextCursor" "$(printf '%s' "$out" | jq -r '.has_cursor // false' 2>/dev/null)" "true"
    same "code-mcp fixture page 2 finishes cleanly" "$(printf '%s' "$out" | jq -r '.p2_done // false' 2>/dev/null)" "true"

    _cm_add "$d/p1/kb.db" "$d/p1/projA" fake --cmd "$py" --arg "$fixture" --arg "--paginate" --arg "--both-hints" \
        --env FAKE_ENV_TAG=secret_env_val --trust annotations >/dev/null 2>&1
    same "code-mcp register paginated fake server" "$?" 0
    out=$(_cm_rpc "$d/p1/kb.db" "$(jq -nc --arg p "$projA" '{method:"discover",project:$p,server:"fake"}')" 2>&1); rc=$?
    same "code-mcp discover paginated server exit 0" "$rc" 0
    same "code-mcp discover ok" "$(printf '%s' "$out" | jq -r '.ok // false' 2>/dev/null)" "true"
    same "code-mcp discover collected all 9 tools across pages" "$(printf '%s' "$out" | jq -r '.tools | length' 2>/dev/null)" "9"

    # 2. Class mapping & --trust none (preserves destructiveHint!)
    same "code-mcp trust=annotations ping=read" "$(printf '%s' "$out" | jq -r '.tools[] | select(.name=="ping") | .class' 2>/dev/null)" "read"
    same "code-mcp trust=annotations write_item=write" "$(printf '%s' "$out" | jq -r '.tools[] | select(.name=="write_item") | .class' 2>/dev/null)" "write"
    same "code-mcp trust=annotations unannotated_op=write" "$(printf '%s' "$out" | jq -r '.tools[] | select(.name=="unannotated_op") | .class' 2>/dev/null)" "write"
    same "code-mcp trust=annotations --both-hints nuke=destructive" "$(printf '%s' "$out" | jq -r '.tools[] | select(.name=="nuke") | .class' 2>/dev/null)" "destructive"

    # Status hides env values
    out=$(_cm_rpc "$d/p1/kb.db" '{"method":"status"}' 2>&1)
    refute "code-mcp status never leaks env value" "$out" "secret_env_val"
    check "code-mcp status shows server_count=1" "$(printf '%s' "$out" | jq -r '.server_count' 2>/dev/null)" "1"

    # Register trust=none server and verify ping->write while nuke STAYS destructive
    _cm_add "$d/p1/kb.db" "$d/p1/projA" untrusted --cmd "$py" --arg "$fixture" --arg "--both-hints" --trust none >/dev/null 2>&1
    out=$(_cm_rpc "$d/p1/kb.db" "$(jq -nc --arg p "$projA" '{method:"discover",project:$p,server:"untrusted"}')" 2>&1); rc=$?
    same "code-mcp discover trust=none exit 0" "$rc" 0
    same "code-mcp trust=none ping becomes write" "$(printf '%s' "$out" | jq -r '.tools[] | select(.name=="ping") | .class' 2>/dev/null)" "write"
    same "code-mcp trust=none nuke STAYS destructive" "$(printf '%s' "$out" | jq -r '.tools[] | select(.name=="nuke") | .class' 2>/dev/null)" "destructive"

    # find RPC returns catalog & grant status without spawning
    reg=$(CNTCTR_DB="$d/p1/kb.db" "$BIN" _test-code-kb server-get "$projA" fake | jq -r '.reg_id')
    CNTCTR_DB="$d/p1/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg" fake "*" access read "" orch "seed" 0 >/dev/null
    out=$(_cm_rpc "$d/p1/kb.db" "$(jq -nc --arg p "$projA" '{method:"find",project:$p,server:"fake"}')" 2>&1); rc=$?
    same "code-mcp find RPC exit 0" "$rc" 0
    same "code-mcp find reports ping granted=true" "$(printf '%s' "$out" | jq -r '.tools[] | select(.name=="ping") | .granted' 2>/dev/null)" "true"
    same "code-mcp find reports write_item granted=false" "$(printf '%s' "$out" | jq -r '.tools[] | select(.name=="write_item") | .granted' 2>/dev/null)" "false"

    # Verify scrubbed env + no leaked daemon socket fds in tool server + expand RPC
    out=$(SECRET_DOWNSTREAM_LEAK=should_not_appear _cm_rpc "$d/p1/kb.db" \
        "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"console.log(\"hello_expand\"); return await tools.fake.ping();"}')" 2>&1); rc=$?
    same "code-mcp run ping exit 0" "$rc" 0
    same "code-mcp run ping is_error=false" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "false"
    same "code-mcp run ping env_tag from --env" "$(printf '%s' "$out" | jq -r '.result | fromjson | .env_tag' 2>/dev/null)" "secret_env_val"
    same "code-mcp downstream does not inherit SECRET_DOWNSTREAM_LEAK" "$(printf '%s' "$out" | jq -r '.result | fromjson | .leaked_secret' 2>/dev/null)" "false"
    same "code-mcp downstream has no leaked daemon socket fds" "$(printf '%s' "$out" | jq -r '.result | fromjson | .leaked_sock_fds' 2>/dev/null)" "0"
    local run_id
    run_id=$(printf '%s' "$out" | jq -r '.run_id // ""' 2>/dev/null)
    same "code-mcp run returns non-empty run_id" "$([ -n "$run_id" ] && echo yes || echo no)" "yes"
    out=$(_cm_rpc "$d/p1/kb.db" "$(jq -nc --arg p "$projA" --arg r "$run_id" '{method:"expand",project:$p,run_id:$r,part:"logs",offset:0,limit:1024}')" 2>&1); rc=$?
    same "code-mcp expand RPC exit 0" "$rc" 0
    check "code-mcp expand returns stored logs" "$(printf '%s' "$out" | jq -r '.slice // ""' 2>/dev/null)" "hello_expand"
    _cm_stop "$d/p1/kb.db"

    # 3. Shared vs --project vs --isolated & per-instance catalogs + list_changed refresh
    mkdir -p "$d/p3/projA" "$d/p3/projB"
    projA=$(CNTCTR_DB="$d/p3/kb.db" "$BIN" _test-code-kb resolve-cwd "$d/p3/projA")
    projB=$(CNTCTR_DB="$d/p3/kb.db" "$BIN" _test-code-kb resolve-cwd "$d/p3/projB")

    _cm_add "$d/p3/kb.db" "$d/p3/projA" shared --cmd "$py" --arg "$fixture" --trust annotations >/dev/null 2>&1
    _cm_add "$d/p3/kb.db" "$d/p3/projA" local --project --cmd "$py" --arg "$fixture" --trust annotations >/dev/null 2>&1
    _cm_add "$d/p3/kb.db" "$d/p3/projA" iso --isolated --cmd "$py" --arg "$fixture" --arg "--isolated-tag" --trust annotations >/dev/null 2>&1

    local reg_sh reg_loc reg_iso
    reg_sh=$(CNTCTR_DB="$d/p3/kb.db" "$BIN" _test-code-kb server-get "$projA" shared | jq -r '.reg_id')
    reg_loc=$(CNTCTR_DB="$d/p3/kb.db" "$BIN" _test-code-kb server-get "$projA" local | jq -r '.reg_id')
    reg_iso=$(CNTCTR_DB="$d/p3/kb.db" "$BIN" _test-code-kb server-get "$projA" iso | jq -r '.reg_id')
    CNTCTR_DB="$d/p3/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg_sh" shared "*" access read "" orch "seed" 0 >/dev/null
    CNTCTR_DB="$d/p3/kb.db" "$BIN" _test-code-kb grant-put "$projB" "$reg_sh" shared "*" access read "" orch "seed" 0 >/dev/null
    CNTCTR_DB="$d/p3/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg_loc" local "*" access read "" orch "seed" 0 >/dev/null
    CNTCTR_DB="$d/p3/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg_iso" iso "*" access read "" orch "seed" 0 >/dev/null
    CNTCTR_DB="$d/p3/kb.db" "$BIN" _test-code-kb grant-put "$projB" "$reg_iso" iso "*" access read "" orch "seed" 0 >/dev/null

    # Shared: same pid across projA & projB
    out=$(_cm_rpc "$d/p3/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.shared.ping();"}')" 2>&1)
    pid1=$(printf '%s' "$out" | jq -r '.result | fromjson | .pid // 0' 2>/dev/null)
    out=$(_cm_rpc "$d/p3/kb.db" "$(jq -nc --arg p "$projB" '{method:"run",project:$p,caller:"t",script:"return await tools.shared.ping();"}')" 2>&1)
    pid2=$(printf '%s' "$out" | jq -r '.result | fromjson | .pid // 0' 2>/dev/null)
    same "code-mcp user-shared server shares PID across projA and projB" "$((pid1 > 1 && pid1 == pid2))" 1

    # --project: cwd == projA
    out=$(_cm_rpc "$d/p3/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.local.ping();"}')" 2>&1)
    same "code-mcp --project runs with cwd == projA" "$(printf '%s' "$out" | jq -r '.result | fromjson | .cwd // ""' 2>/dev/null)" "$projA"

    # --isolated: distinct PIDs, distinct per-instance catalogs, and list_changed refreshes only projA
    out=$(_cm_rpc "$d/p3/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.iso.ping();"}')" 2>&1)
    pid1=$(printf '%s' "$out" | jq -r '.result | fromjson | .pid // 0' 2>/dev/null)
    out=$(_cm_rpc "$d/p3/kb.db" "$(jq -nc --arg p "$projB" '{method:"run",project:$p,caller:"t",script:"return await tools.iso.ping();"}')" 2>&1)
    pid2=$(printf '%s' "$out" | jq -r '.result | fromjson | .pid // 0' 2>/dev/null)
    same "code-mcp --isolated spawns distinct PIDs for projA and projB" "$((pid1 > 1 && pid2 > 1 && pid1 != pid2))" 1

    local catA catB genA1 genB1 genA2 genB2
    catA=$(CNTCTR_DB="$d/p3/kb.db" "$BIN" _test-code-kb catalog-get "$reg_iso" "$projA")
    catB=$(CNTCTR_DB="$d/p3/kb.db" "$BIN" _test-code-kb catalog-get "$reg_iso" "$projB")
    check "code-mcp isolated projA catalog has tag_projA" "$catA" "tag_projA"
    refute "code-mcp isolated projA catalog omits tag_projB" "$catA" "tag_projB"
    check "code-mcp isolated projB catalog has tag_projB" "$catB" "tag_projB"
    refute "code-mcp isolated projB catalog omits tag_projA" "$catB" "tag_projA"
    genA1=$(sq "$d/p3/kb.db" "SELECT meta_gen FROM code_catalogs WHERE reg_id='$reg_iso' AND owner_project='$projA'")
    genB1=$(sq "$d/p3/kb.db" "SELECT meta_gen FROM code_catalogs WHERE reg_id='$reg_iso' AND owner_project='$projB'")

    # Trigger notifications/tools/list_changed on projA adding tool 'dyn_alpha'
    out=$(_cm_rpc "$d/p3/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.iso.emit_changed({add_tool:\"dyn_alpha\"});"}')" 2>&1); rc=$?
    same "code-mcp emit_changed call exit 0" "$rc" 0
    local lc_ok=0 i
    for i in $(seq 1 100); do
        genA2=$(sq "$d/p3/kb.db" "SELECT meta_gen FROM code_catalogs WHERE reg_id='$reg_iso' AND owner_project='$projA'")
        if [ "${genA2:-0}" -gt "${genA1:-0}" ]; then lc_ok=1; break; fi
        sleep 0.02
    done
    same "code-mcp list_changed bumps projA meta_gen on control queue" "$lc_ok" 1
    catA=$(CNTCTR_DB="$d/p3/kb.db" "$BIN" _test-code-kb catalog-get "$reg_iso" "$projA")
    genB2=$(sq "$d/p3/kb.db" "SELECT meta_gen FROM code_catalogs WHERE reg_id='$reg_iso' AND owner_project='$projB'")
    check "code-mcp list_changed added dyn_alpha to projA catalog" "$catA" "dyn_alpha"
    same "code-mcp list_changed did not bump or overwrite projB catalog" "$genB2" "$genB1"
    _cm_stop "$d/p3/kb.db"

    # 4. Lazy cold-start discovery off run thread + zero-spawn denials (ungranted, scope-excluded, static deny)
    mkdir -p "$d/p4/projA"
    projA=$(CNTCTR_DB="$d/p4/kb.db" "$BIN" _test-code-kb resolve-cwd "$d/p4/projA")
    _cm_add "$d/p4/kb.db" "$d/p4/projA" ungranted --cmd "$py" --arg "$fixture" --trust annotations >/dev/null 2>&1
    _cm_add "$d/p4/kb.db" "$d/p4/projA" lazy --cmd "$py" --arg "$fixture" --trust annotations >/dev/null 2>&1
    reg=$(CNTCTR_DB="$d/p4/kb.db" "$BIN" _test-code-kb server-get "$projA" lazy | jq -r '.reg_id')
    CNTCTR_DB="$d/p4/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg" lazy "*" access read "" orch "seed" 0 >/dev/null
    CNTCTR_DB="$d/p4/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg" lazy "echo" access deny "" human "no echo" 0 >/dev/null

    # Ungranted server -> denied, 0 servers spawned
    out=$(_cm_rpc "$d/p4/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.ungranted.ping();"}')" 2>&1)
    same "code-mcp ungranted server denied" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "true"
    check "code-mcp ungranted server recorded in denied" "$(printf '%s' "$out" | jq -r '.denied // ""' 2>/dev/null)" "ungranted.ping"
    same "code-mcp ungranted denial spawned 0 servers" "$(_cm_rpc "$d/p4/kb.db" '{"method":"status"}' | jq -r '.server_count')" "0"

    # Uncatalogued granted server excluded by scope -> denied, 0 servers spawned
    out=$(_cm_rpc "$d/p4/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",scope:["other.*"],script:"return await tools.lazy.ping();"}')" 2>&1)
    same "code-mcp scope-excluded uncatalogued denied" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "true"
    check "code-mcp scope-excluded recorded in denied" "$(printf '%s' "$out" | jq -r '.denied // ""' 2>/dev/null)" "outside run scope"
    same "code-mcp scope-excluded spawned 0 servers" "$(_cm_rpc "$d/p4/kb.db" '{"method":"status"}' | jq -r '.server_count')" "0"

    # Uncatalogued granted server matched by static deny -> denied, 0 servers spawned
    out=$(_cm_rpc "$d/p4/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.lazy.echo({msg:\"hi\"});"}')" 2>&1)
    same "code-mcp static-deny uncatalogued denied" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "true"
    check "code-mcp static-deny recorded in denied" "$(printf '%s' "$out" | jq -r '.denied // ""' 2>/dev/null)" "no echo"
    same "code-mcp static-deny spawned 0 servers" "$(_cm_rpc "$d/p4/kb.db" '{"method":"status"}' | jq -r '.server_count')" "0"

    # Now call permitted tool on uncatalogued server -> lazy-discovers off run thread and succeeds!
    out=$(_cm_rpc "$d/p4/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.lazy.ping();"}')" 2>&1); rc=$?
    same "code-mcp lazy cold-start discovery exit 0" "$rc" 0
    same "code-mcp lazy cold-start is_error=false" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "false"
    same "code-mcp lazy cold-start result ok=true" "$(printf '%s' "$out" | jq -r '.result | fromjson | .ok' 2>/dev/null)" "true"
    same "code-mcp lazy cold-start persisted catalog" "$(sq "$d/p4/kb.db" "SELECT count(*) FROM code_catalogs WHERE reg_id='$reg' AND owner_project=''")" "1"
    _cm_stop "$d/p4/kb.db"

    # 5. Atomic live recheck: class change on restart, same-class schema change on restart, mid-queue revocation
    mkdir -p "$d/p5/projA"
    projA=$(CNTCTR_DB="$d/p5/kb.db" "$BIN" _test-code-kb resolve-cwd "$d/p5/projA")

    # 5a. --mutate-class-on-restart: ping flips from read to destructive on 2nd start
    _cm_add "$d/p5/kb.db" "$d/p5/projA" mcls --cmd "$py" --arg "$fixture" --arg "--mutate-class-on-restart" --arg "$d/p5/cls.state" --trust annotations >/dev/null 2>&1
    reg=$(CNTCTR_DB="$d/p5/kb.db" "$BIN" _test-code-kb server-get "$projA" mcls | jq -r '.reg_id')
    CNTCTR_DB="$d/p5/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg" mcls "ping" access allow "read" orch "seed" 0 >/dev/null
    CNTCTR_DB="$d/p5/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg" mcls "crash_now" access allow "read" orch "seed" 0 >/dev/null
    _cm_rpc "$d/p5/kb.db" "$(jq -nc --arg p "$projA" '{method:"discover",project:$p,server:"mcls"}')" >/dev/null 2>&1
    out=$(_cm_rpc "$d/p5/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.mcls.ping();"}')" 2>&1)
    same "code-mcp mutate-class 1st start ping ok" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "false"
    # Crash server so next call restarts it (2nd start flips ping -> destructive; cached DB catalog still has ping=read!)
    _cm_rpc "$d/p5/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"try { await tools.mcls.crash_now(); } catch(e) { return e.message; }"}')" >/dev/null 2>&1
    out=$(_cm_rpc "$d/p5/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.mcls.ping();"}')" 2>&1)
    same "code-mcp mutate-class 2nd start ping denied" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "true"
    check "code-mcp mutate-class recorded in denied" "$(printf '%s' "$out" | jq -r '.denied // ""' 2>/dev/null)" "mcls.ping"
    check "code-mcp mutate-class recorded in calls as denied" "$(printf '%s' "$out" | jq -r '.calls // ""' 2>/dev/null)" "denied"

    # 5b. --mutate-schema-on-restart: echo stays read, msg changes from string to integer
    _cm_add "$d/p5/kb.db" "$d/p5/projA" msch --cmd "$py" --arg "$fixture" --arg "--mutate-schema-on-restart" --arg "$d/p5/sch.state" --arg "--call-log" --arg "$d/p5/sch.calls" --trust annotations >/dev/null 2>&1
    reg2=$(CNTCTR_DB="$d/p5/kb.db" "$BIN" _test-code-kb server-get "$projA" msch | jq -r '.reg_id')
    CNTCTR_DB="$d/p5/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg2" msch "*" access read "" orch "seed" 0 >/dev/null
    _cm_rpc "$d/p5/kb.db" "$(jq -nc --arg p "$projA" '{method:"discover",project:$p,server:"msch"}')" >/dev/null 2>&1
    out=$(_cm_rpc "$d/p5/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.msch.echo({msg:\"hi\"});"}')" 2>&1)
    same "code-mcp mutate-schema 1st start echo(string) ok" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "false"
    _cm_rpc "$d/p5/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"try { await tools.msch.crash_now(); } catch(e) { return e.message; }"}')" >/dev/null 2>&1
    : > "$d/p5/sch.calls"
    # Old cached catalog still says msg:string; live recheck on restart must reject before stdio write!
    out=$(_cm_rpc "$d/p5/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.msch.echo({msg:\"hi\"});"}')" 2>&1)
    same "code-mcp mutate-schema 2nd start echo(string) rejected" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "true"
    check "code-mcp mutate-schema error mentions invalid arguments/integer" "$(printf '%s' "$out" | jq -r '.result // ""' 2>/dev/null)" "integer"
    same "code-mcp mutate-schema rejected before reaching server" "$(grep -c '^echo$' "$d/p5/sch.calls" 2>/dev/null || true)" "0"

    # 5c. Mid-queue grant revocation: barrier pauses init while call is queued, grant revoked before stdio write
    : > "$d/p5/rev.calls"
    _cm_add "$d/p5/kb.db" "$d/p5/projA" mrev --cmd "$py" --arg "$fixture" --arg "--init-barrier" --arg "$d/p5/revbar" --arg "--call-log" --arg "$d/p5/rev.calls" --trust annotations >/dev/null 2>&1
    local reg_rev
    reg_rev=$(CNTCTR_DB="$d/p5/kb.db" "$BIN" _test-code-kb server-get "$projA" mrev | jq -r '.reg_id')
    CNTCTR_DB="$d/p5/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg_rev" mrev "*" access read "" orch "seed" 0 >/dev/null
    _cm_rpc "$d/p5/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.mrev.ping();"}')" > "$d/p5/rev.out" 2>&1 &
    local rev_job=$!
    same "code-mcp mid-queue revocation reached init barrier" "$(_cm_wait_file "$d/p5/revbar.ready" && echo yes || echo no)" "yes"
    CNTCTR_DB="$d/p5/kb.db" "$BIN" _test-code-kb grant-del "$projA" "$reg_rev" "*" access 0 >/dev/null
    : > "$d/p5/revbar.go"
    wait "$rev_job" || true
    out=$(/bin/cat "$d/p5/rev.out")
    same "code-mcp mid-queue revocation denied call" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "true"
    check "code-mcp mid-queue revocation recorded in denied" "$(printf '%s' "$out" | jq -r '.denied // ""' 2>/dev/null)" "mrev.ping"
    same "code-mcp mid-queue revocation never sent tools/call to server" "$(grep -c '^ping$' "$d/p5/rev.calls" 2>/dev/null || true)" "0"
    _cm_stop "$d/p5/kb.db"

    # 6. Crash & circuit breaker (3 crashes in 5 min opens breaker; restart resets it; concurrent timeout+crash zero ASan UAF)
    mkdir -p "$d/p6/projA"
    projA=$(CNTCTR_DB="$d/p6/kb.db" "$BIN" _test-code-kb resolve-cwd "$d/p6/projA")
    _cm_add "$d/p6/kb.db" "$d/p6/projA" flaky --cmd "$py" --arg "$fixture" --trust annotations >/dev/null 2>&1
    reg=$(CNTCTR_DB="$d/p6/kb.db" "$BIN" _test-code-kb server-get "$projA" flaky | jq -r '.reg_id')
    CNTCTR_DB="$d/p6/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg" flaky "*" access read "" orch "seed" 0 >/dev/null

    out=$(_cm_rpc "$d/p6/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.flaky.ping();"}')" 2>&1)
    pid1=$(printf '%s' "$out" | jq -r '.result | fromjson | .pid // 0' 2>/dev/null)
    # Crash #1 (with concurrent sleep_tool + short call timeout race to stress ASan refcounting)
    out=$(_cm_rpc "$d/p6/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",call_sec:1,script:"const rs = await Promise.allSettled([tools.flaky.sleep_tool({ms:5000}), tools.flaky.crash_now({delay_ms:100})]); return rs.map(r => r.status === \"rejected\" ? r.reason.message : \"ok\");"}')" 2>&1)
    same "code-mcp crash #1 Promise.allSettled completed without ASan error" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "false"
    check "code-mcp crash #1 reports server crashed" "$out" "server crashed"
    refute "code-mcp crash #1 no AddressSanitizer" "$out" "AddressSanitizer"

    # Relaunches with new PID
    out=$(_cm_rpc "$d/p6/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.flaky.ping();"}')" 2>&1)
    pid2=$(printf '%s' "$out" | jq -r '.result | fromjson | .pid // 0' 2>/dev/null)
    same "code-mcp relaunched after crash #1 with new PID" "$((pid2 > 1 && pid2 != pid1))" 1

    # Crash #2 & Crash #3 -> breaker opens
    _cm_rpc "$d/p6/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"try { await tools.flaky.crash_now(); } catch(e) { return e.message; }"}')" >/dev/null 2>&1
    _cm_rpc "$d/p6/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"try { await tools.flaky.crash_now(); } catch(e) { return e.message; }"}')" >/dev/null 2>&1
    out=$(_cm_rpc "$d/p6/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.flaky.ping();"}')" 2>&1)
    same "code-mcp circuit breaker opens after 3 crashes" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "true"
    check "code-mcp circuit breaker error mentions 3 crashes / stays down" "$(printf '%s' "$out" | jq -r '.result // ""' 2>/dev/null)" "3 crashes"
    same "code-mcp circuit breaker does not spawn server" "$(_cm_rpc "$d/p6/kb.db" '{"method":"status"}' | jq -r '.server_count')" "0"

    # restart RPC resets breaker -> next call succeeds
    out=$(_cm_rpc "$d/p6/kb.db" "$(jq -nc --arg p "$projA" '{method:"restart",project:$p,server:"flaky"}')" 2>&1); rc=$?
    same "code-mcp restart RPC exit 0" "$rc" 0
    out=$(_cm_rpc "$d/p6/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.flaky.ping();"}')" 2>&1)
    same "code-mcp ping succeeds after restart resets breaker" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "false"
    _cm_stop "$d/p6/kb.db"

    # 7. Global cap & LRU eviction (CNTCTR_CODE_MAX_SERVERS=2; all busy names CNTCTR_CODE_MAX_SERVERS)
    mkdir -p "$d/p7/projA"
    projA=$(CNTCTR_DB="$d/p7/kb.db" "$BIN" _test-code-kb resolve-cwd "$d/p7/projA")
    local s
    for s in s1 s2 s3; do
        _cm_add "$d/p7/kb.db" "$d/p7/projA" "$s" --cmd "$py" --arg "$fixture" --trust annotations >/dev/null 2>&1
        reg=$(CNTCTR_DB="$d/p7/kb.db" "$BIN" _test-code-kb server-get "$projA" "$s" | jq -r '.reg_id')
        CNTCTR_DB="$d/p7/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg" "$s" "*" access read "" orch "seed" 0 >/dev/null
    done
    out=$(CNTCTR_CODE_MAX_SERVERS=2 _cm_rpc "$d/p7/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.s1.ping();"}')" 2>&1)
    pid1=$(printf '%s' "$out" | jq -r '.result | fromjson | .pid // 0' 2>/dev/null)
    out=$(CNTCTR_CODE_MAX_SERVERS=2 _cm_rpc "$d/p7/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.s2.ping();"}')" 2>&1)
    pid2=$(printf '%s' "$out" | jq -r '.result | fromjson | .pid // 0' 2>/dev/null)
    local lru_status
    lru_status=$(_cm_rpc "$d/p7/kb.db" '{"method":"status"}')
    same "code-mcp LRU setup has 2 servers" "$(printf '%s' "$lru_status" | jq -r '.server_count')" "2"
    [ "$(printf '%s' "$lru_status" | jq -r '.server_count')" = 2 ] || printf 'DIAG LRU status: %s\n' "$lru_status" >&2

    # Calling s3 evicts LRU idle s1 (pid1 dies), keeps s2 (pid2 stays alive), server_count stays 2
    out=$(_cm_rpc "$d/p7/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.s3.ping();"}')" 2>&1)
    same "code-mcp s3 call succeeds after evicting LRU s1" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "false"
    same "code-mcp evicted LRU s1 process exited (reaped)" "$(_cm_wait_dead "$pid1" && echo yes || echo no)" "yes"
    same "code-mcp MRU s2 stayed alive" "$(kill -0 "$pid2" 2>/dev/null && echo yes || echo no)" "yes"
    same "code-mcp server_count stays at cap 2" "$(_cm_rpc "$d/p7/kb.db" '{"method":"status"}' | jq -r '.server_count')" "2"

    # All busy (s2 & s3 held by sleep_tool barriers) -> s1 fails naming CNTCTR_CODE_MAX_SERVERS
    local req_b2 req_b3
    req_b2=$(jq -nc --arg p "$projA" --arg rf "$d/p7/b2.ready" --arg gf "$d/p7/b.go" \
        '{method:"run",project:$p,caller:"t",script:("return await tools.s2.sleep_tool({ms:15000,ready_file:" + ($rf|tojson) + ",go_file:" + ($gf|tojson) + "});")}')
    req_b3=$(jq -nc --arg p "$projA" --arg rf "$d/p7/b3.ready" --arg gf "$d/p7/b.go" \
        '{method:"run",project:$p,caller:"t",script:("return await tools.s3.sleep_tool({ms:15000,ready_file:" + ($rf|tojson) + ",go_file:" + ($gf|tojson) + "});")}')
    _cm_rpc "$d/p7/kb.db" "$req_b2" > "$d/p7/b2.out" 2>&1 &
    local b2_job=$!
    _cm_rpc "$d/p7/kb.db" "$req_b3" > "$d/p7/b3.out" 2>&1 &
    local b3_job=$!
    same "code-mcp all-busy s2 barrier ready" "$(_cm_wait_file "$d/p7/b2.ready" && echo yes || echo no)" "yes"
    same "code-mcp all-busy s3 barrier ready" "$(_cm_wait_file "$d/p7/b3.ready" && echo yes || echo no)" "yes"

    out=$(_cm_rpc "$d/p7/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.s1.ping();"}')" 2>&1)
    same "code-mcp all-busy s1 fails" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "true"
    check "code-mcp all-busy error names CNTCTR_CODE_MAX_SERVERS" "$(printf '%s' "$out" | jq -r '.result // ""' 2>/dev/null)" "CNTCTR_CODE_MAX_SERVERS"
    : > "$d/p7/b.go"
    wait "$b2_job" "$b3_job"
    _cm_stop "$d/p7/kb.db"

    # 8. Idle eviction (CNTCTR_CODE_IDLE_SEC=1), concurrent run cap (CNTCTR_CODE_MAX_RUNS=2), daemon queue cap (CNTCTR_CODE_DAEMON_QUEUE_BYTES)
    mkdir -p "$d/p8/projA"
    projA=$(CNTCTR_DB="$d/p8/kb.db" "$BIN" _test-code-kb resolve-cwd "$d/p8/projA")
    _cm_add "$d/p8/kb.db" "$d/p8/projA" idle1 --cmd "$py" --arg "$fixture" --trust annotations >/dev/null 2>&1
    reg=$(CNTCTR_DB="$d/p8/kb.db" "$BIN" _test-code-kb server-get "$projA" idle1 | jq -r '.reg_id')
    CNTCTR_DB="$d/p8/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg" idle1 "*" access read "" orch "seed" 0 >/dev/null

    out=$(CNTCTR_CODE_IDLE_SEC=1 CNTCTR_CODE_DAEMON_IDLE_SEC=15 CNTCTR_CODE_MAX_RUNS=2 \
        _cm_rpc "$d/p8/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.idle1.ping();"}')" 2>&1)
    pid1=$(printf '%s' "$out" | jq -r '.result | fromjson | .pid // 0' 2>/dev/null)
    same "code-mcp idle-evict server started" "$((pid1 > 1))" 1
    local idle_evicted=0
    for i in $(seq 1 150); do
        if [ "$(_cm_rpc "$d/p8/kb.db" --no-autostart '{"method":"status"}' | jq -r '.server_count // -1' 2>/dev/null)" = "0" ]; then
            idle_evicted=1; break
        fi
        sleep 0.05
    done
    same "code-mcp idle eviction stops server after CNTCTR_CODE_IDLE_SEC=1" "$idle_evicted" 1
    same "code-mcp idle evicted server process reaped" "$(_cm_wait_dead "$pid1" && echo yes || echo no)" "yes"

    # Concurrent run cap: CNTCTR_CODE_MAX_RUNS=2
    local req_r1 req_r2
    req_r1=$(jq -nc --arg p "$projA" --arg rf "$d/p8/r1.ready" --arg gf "$d/p8/r.go" \
        '{method:"run",project:$p,caller:"t",script:("return await tools.idle1.sleep_tool({ms:15000,ready_file:" + ($rf|tojson) + ",go_file:" + ($gf|tojson) + "});")}')
    req_r2=$(jq -nc --arg p "$projA" --arg rf "$d/p8/r2.ready" --arg gf "$d/p8/r.go" \
        '{method:"run",project:$p,caller:"t",script:("return await tools.idle1.sleep_tool({ms:15000,ready_file:" + ($rf|tojson) + ",go_file:" + ($gf|tojson) + "});")}')
    _cm_rpc "$d/p8/kb.db" "$req_r1" > "$d/p8/r1.out" 2>&1 &
    local r1_job=$!
    _cm_rpc "$d/p8/kb.db" "$req_r2" > "$d/p8/r2.out" 2>&1 &
    local r2_job=$!
    same "code-mcp max-runs slot 1 ready" "$(_cm_wait_file "$d/p8/r1.ready" && echo yes || echo no)" "yes"
    same "code-mcp max-runs slot 2 ready" "$(_cm_wait_file "$d/p8/r2.ready" && echo yes || echo no)" "yes"
    out=$(_cm_rpc "$d/p8/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return 1;"}')" 2>&1); rc=$?
    same "code-mcp 3rd concurrent run rejected under CNTCTR_CODE_MAX_RUNS=2" "$((rc != 0))" 1
    check "code-mcp max-runs error names CNTCTR_CODE_MAX_RUNS" "$out" "CNTCTR_CODE_MAX_RUNS"
    : > "$d/p8/r.go"
    wait "$r1_job" "$r2_job"
    _cm_stop "$d/p8/kb.db"

    # Daemon-wide reply queue cap: CNTCTR_CODE_DAEMON_QUEUE_BYTES=65536
    mkdir -p "$d/p8q/projA"
    projA=$(CNTCTR_DB="$d/p8q/kb.db" "$BIN" _test-code-kb resolve-cwd "$d/p8q/projA")
    _cm_add "$d/p8q/kb.db" "$d/p8q/projA" qsrv --cmd "$py" --arg "$fixture" --trust annotations >/dev/null 2>&1
    reg=$(CNTCTR_DB="$d/p8q/kb.db" "$BIN" _test-code-kb server-get "$projA" qsrv | jq -r '.reg_id')
    CNTCTR_DB="$d/p8q/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg" qsrv "*" access read "" orch "seed" 0 >/dev/null
    out=$(CNTCTR_CODE_DAEMON_QUEUE_BYTES=65536 _cm_rpc "$d/p8q/kb.db" \
        "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.qsrv.big_result({bytes:80000});"}')" 2>&1)
    same "code-mcp daemon queue cap rejects oversized reply" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "true"
    check "code-mcp daemon queue cap error names CNTCTR_CODE_DAEMON_QUEUE_BYTES" "$(printf '%s' "$out" | jq -r '.result // ""' 2>/dev/null)" "CNTCTR_CODE_DAEMON_QUEUE_BYTES"
    out=$(_cm_rpc "$d/p8q/kb.db" "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.qsrv.ping();"}')" 2>&1)
    same "code-mcp server stays healthy after daemon queue cap rejection" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "false"
    _cm_stop "$d/p8q/kb.db"

    # 9. Review Focus #3: misbehaving servers (--banner, --spam-stderr, --hang-init) & reader line cap (big_result)
    mkdir -p "$d/p9/projA"
    projA=$(CNTCTR_DB="$d/p9/kb.db" "$BIN" _test-code-kb resolve-cwd "$d/p9/projA")
    _cm_add "$d/p9/kb.db" "$d/p9/projA" noisy --cmd "$py" --arg "$fixture" --arg "--banner" --arg "--spam-stderr" --trust annotations >/dev/null 2>&1
    _cm_add "$d/p9/kb.db" "$d/p9/projA" hung --cmd "$py" --arg "$fixture" --arg "--hang-init" --arg "--pid-file" --arg "$d/p9/hung.pid" --trust annotations >/dev/null 2>&1
    local reg_noisy reg_hung
    reg_noisy=$(CNTCTR_DB="$d/p9/kb.db" "$BIN" _test-code-kb server-get "$projA" noisy | jq -r '.reg_id')
    reg_hung=$(CNTCTR_DB="$d/p9/kb.db" "$BIN" _test-code-kb server-get "$projA" hung | jq -r '.reg_id')
    CNTCTR_DB="$d/p9/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg_noisy" noisy "*" access read "" orch "seed" 0 >/dev/null
    CNTCTR_DB="$d/p9/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg_hung" hung "*" access read "" orch "seed" 0 >/dev/null

    # Start daemon with CNTCTR_CODE_MAX_MB=4 (line_cap = 1 MiB)
    out=$(CNTCTR_CODE_MAX_MB=4 _cm_rpc "$d/p9/kb.db" \
        "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.noisy.ping();"}')" 2>&1); rc=$?
    same "code-mcp --banner and --spam-stderr succeed exit 0" "$rc" 0
    same "code-mcp --banner and --spam-stderr ping ok" "$(printf '%s' "$out" | jq -r '.result | fromjson | .ok' 2>/dev/null)" "true"

    # big_result exceeding min(max_mb/4, 16 MiB) = 1 MiB fails with "result too large"
    out=$(_cm_rpc "$d/p9/kb.db" \
        "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.noisy.big_result({bytes:1200000});"}')" 2>&1)
    same "code-mcp big_result exceeding line cap fails" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "true"
    check "code-mcp big_result error says result too large" "$(printf '%s' "$out" | jq -r '.result // ""' 2>/dev/null)" "result too large"
    # Server stays alive for subsequent call
    out=$(_cm_rpc "$d/p9/kb.db" \
        "$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.noisy.ping();"}')" 2>&1)
    same "code-mcp server survives big_result rejection" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "false"

    # --hang-init times out cleanly without blocking the QuickJS run thread (noisy.ping completes in parallel!) or leaving a zombie
    local req_hung
    req_hung=$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",call_sec:1,script:"const pHung = tools.hung.ping().then(() => \"hung_ok\", e => \"hung_err:\" + e.message); const fast = await tools.noisy.ping(); const hres = await pHung; return {fast_ok: fast.ok, hres};"}')
    out=$(_cm_rpc "$d/p9/kb.db" "$req_hung" 2>&1)
    same "code-mcp --hang-init does not block run thread or other servers" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "false"
    same "code-mcp --hang-init fast sibling call succeeded" "$(printf '%s' "$out" | jq -r '.result | fromjson | .fast_ok' 2>/dev/null)" "true"
    check "code-mcp --hang-init timed out cleanly" "$(printf '%s' "$out" | jq -r '.result | fromjson | .hres' 2>/dev/null)" "hung_err:"
    if [ -f "$d/p9/hung.pid" ]; then
        local hpid
        hpid=$(/bin/cat "$d/p9/hung.pid" | tr -d '[:space:]')
        same "code-mcp --hang-init child killed and reaped (no zombie)" "$(_cm_wait_dead "$hpid" && echo yes || echo no)" "yes"
    else
        bad "code-mcp --hang-init pid file missing"
    fi
    _cm_stop "$d/p9/kb.db"

    # 10. Phase 5 review fixes: CODE-MCP-01 (expected_meta_gen + list_changed between enqueue and send),
    #     CODE-MCP-02 (server-initiated ping + unknown method -32601), CODE-MCP-03 (unsupported protocolVersion)
    mkdir -p "$d/p10/projA"
    projA=$(CNTCTR_DB="$d/p10/kb.db" "$BIN" _test-code-kb resolve-cwd "$d/p10/projA")

    # 10a. CODE-MCP-03: unsupported protocolVersion rejected BEFORE notifications/initialized or tools/list
    : > "$d/p10/badproto.methods"
    _cm_add "$d/p10/kb.db" "$d/p10/projA" badproto --cmd "$py" --arg "$fixture" \
        --arg "--proto-version" --arg "1999-01-01" \
        --arg "--method-log" --arg "$d/p10/badproto.methods" --trust annotations >/dev/null 2>&1
    local reg_bp
    reg_bp=$(CNTCTR_DB="$d/p10/kb.db" "$BIN" _test-code-kb server-get "$projA" badproto | jq -r '.reg_id')
    CNTCTR_DB="$d/p10/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg_bp" badproto "*" access read "" orch "seed" 0 >/dev/null

    local req_bp
    req_bp=$(jq -nc --arg p "$projA" '{method:"discover",project:$p,server:"badproto"}')
    out=$(_cm_rpc "$d/p10/kb.db" "$req_bp" 2>&1); rc=$?
    same "code-mcp CODE-MCP-03 discover rejects unsupported protocolVersion" "$((rc != 0))" 1
    check "code-mcp CODE-MCP-03 error mentions unsupported protocolVersion" "$out" "unsupported protocolVersion"
    check "code-mcp CODE-MCP-03 error names bad version 1999-01-01" "$out" "1999-01-01"
    same "code-mcp CODE-MCP-03 server received initialize" "$(grep -c '^initialize$' "$d/p10/badproto.methods" 2>/dev/null || true)" "1"
    same "code-mcp CODE-MCP-03 did NOT send notifications/initialized" "$(grep -c '^notifications/initialized$' "$d/p10/badproto.methods" 2>/dev/null || true)" "0"
    same "code-mcp CODE-MCP-03 did NOT send tools/list" "$(grep -c '^tools/list$' "$d/p10/badproto.methods" 2>/dev/null || true)" "0"

    # 10b. CODE-MCP-02: server-initiated ping (empty result) and unknown method (-32601), serialized with child-stdin writes
    : > "$d/p10/sreq.replies"
    _cm_add "$d/p10/kb.db" "$d/p10/projA" sreq --cmd "$py" --arg "$fixture" \
        --arg "--server-requests" --arg "$d/p10/sreq.replies" --trust annotations >/dev/null 2>&1
    local reg_sr
    reg_sr=$(CNTCTR_DB="$d/p10/kb.db" "$BIN" _test-code-kb server-get "$projA" sreq | jq -r '.reg_id')
    CNTCTR_DB="$d/p10/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg_sr" sreq "*" access read "" orch "seed" 0 >/dev/null

    local req_sr
    req_sr=$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"const [p, e] = await Promise.all([tools.sreq.ping(), tools.sreq.echo({msg:\"concurrent\"})]); return {p, e};"}')
    out=$(_cm_rpc "$d/p10/kb.db" "$req_sr" 2>&1); rc=$?
    same "code-mcp CODE-MCP-02 run with server-initiated requests exit 0" "$rc" 0
    same "code-mcp CODE-MCP-02 run is_error=false" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "false"
    same "code-mcp CODE-MCP-02 concurrent echo succeeded" "$(printf '%s' "$out" | jq -r '.result | fromjson | .e.msg // ""' 2>/dev/null)" "concurrent"
    same "code-mcp CODE-MCP-02 ping reply has empty object result" "$(printf '%s' "$out" | jq -c '.result | fromjson | .p.srv_ping_reply.result' 2>/dev/null)" "{}"
    same "code-mcp CODE-MCP-02 ping reply has no error" "$(printf '%s' "$out" | jq -r '.result | fromjson | .p.srv_ping_reply | has("error")' 2>/dev/null)" "false"
    same "code-mcp CODE-MCP-02 unknown method reply has id srv-req-2" "$(printf '%s' "$out" | jq -r '.result | fromjson | .p.srv_unknown_reply.id // ""' 2>/dev/null)" "srv-req-2"
    same "code-mcp CODE-MCP-02 unknown method reply has code -32601" "$(printf '%s' "$out" | jq -r '.result | fromjson | .p.srv_unknown_reply.error.code // 0' 2>/dev/null)" "-32601"
    same "code-mcp CODE-MCP-02 tools/list server-initiated ping 9000 replied with empty result" \
        "$(jq -sc 'map(select(.id == 9000)) | .[0].result' "$d/p10/sreq.replies" 2>/dev/null)" "{}"

    # 10c. CODE-MCP-01: list_changed between enqueue and send (CTRL_CALL queued ahead of CTRL_REFRESH)
    #      AND expected_meta_gen recheck rejects mutated schema before stdio write
    : > "$d/p10/lc.calls"
    : > "$d/p10/gate.calls"
    _cm_add "$d/p10/kb.db" "$d/p10/projA" lc --cmd "$py" --arg "$fixture" \
        --arg "--mutate-on-list-barrier" --arg "$d/p10/lcbar" \
        --arg "--call-log" --arg "$d/p10/lc.calls" --trust annotations >/dev/null 2>&1
    _cm_add "$d/p10/kb.db" "$d/p10/projA" gate --cmd "$py" --arg "$fixture" \
        --arg "--call-log" --arg "$d/p10/gate.calls" --trust annotations >/dev/null 2>&1
    local reg_lc reg_gate
    reg_lc=$(CNTCTR_DB="$d/p10/kb.db" "$BIN" _test-code-kb server-get "$projA" lc | jq -r '.reg_id')
    reg_gate=$(CNTCTR_DB="$d/p10/kb.db" "$BIN" _test-code-kb server-get "$projA" gate | jq -r '.reg_id')
    CNTCTR_DB="$d/p10/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg_lc" lc "*" access read "" orch "seed" 0 >/dev/null
    CNTCTR_DB="$d/p10/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg_gate" gate "*" access read "" orch "seed" 0 >/dev/null

    # Initial discover (1st tools/list -> meta_gen=1, echo.msg=string) + warm gate server
    local req_lc_disc req_gate_warm
    req_lc_disc=$(jq -nc --arg p "$projA" '{method:"discover",project:$p,server:"lc"}')
    _cm_rpc "$d/p10/kb.db" "$req_lc_disc" >/dev/null 2>&1
    req_gate_warm=$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.gate.ping();"}')
    _cm_rpc "$d/p10/kb.db" "$req_gate_warm" >/dev/null 2>&1
    : > "$d/p10/lc.calls"
    : > "$d/p10/gate.calls"

    # Pause lc's ctrl_thread inside 2nd discover (tools/list barrier)
    _cm_rpc "$d/p10/kb.db" "$req_lc_disc" > "$d/p10/lc_disc.out" 2>&1 &
    local lc_disc_job=$!
    same "code-mcp CODE-MCP-01 list barrier reached" "$(_cm_wait_file "$d/p10/lcbar.ready" && echo yes || echo no)" "yes"

    # Enqueue CTRL_CALL(lc.echo({msg:"stale"})) with expected_meta_gen=1 while ctrl_thread is paused;
    # gate.ping() confirms JS already called tools.lc.echo(...) before we release lcbar.go!
    local req_lc_call
    req_lc_call=$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"const pEcho = tools.lc.echo({msg:\"stale\"}); await tools.gate.ping(); return await pEcho;"}')
    _cm_rpc "$d/p10/kb.db" "$req_lc_call" > "$d/p10/lc_call.out" 2>&1 &
    local lc_call_job=$!
    local gate_seen=0
    for i in $(seq 1 150); do
        if grep -q '^ping$' "$d/p10/gate.calls" 2>/dev/null; then gate_seen=1; break; fi
        sleep 0.02
    done
    same "code-mcp CODE-MCP-01 echo call enqueued behind paused ctrl_thread" "$gate_seen" 1
    # Release barrier: fake-mcp mutates echo.msg -> integer, emits notifications/tools/list_changed,
    # and returns old tools/list (echo.msg=string) so CTRL_CALL runs ahead of CTRL_REFRESH!
    : > "$d/p10/lcbar.go"
    wait "$lc_disc_job" || true
    wait "$lc_call_job" || true
    out=$(/bin/cat "$d/p10/lc_call.out")
    same "code-mcp CODE-MCP-01 list_changed between enqueue and send rejected stale echo" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "true"
    check "code-mcp CODE-MCP-01 stale echo error mentions integer schema" "$(printf '%s' "$out" | jq -r '.result // ""' 2>/dev/null)" "integer"
    same "code-mcp CODE-MCP-01 stale echo never reached server stdin" "$(grep -c '^echo$' "$d/p10/lc.calls" 2>/dev/null || true)" "0"

    # Also verify a call with the new integer schema succeeds now!
    local req_lc_ok
    req_lc_ok=$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"return await tools.lc.echo({msg:42});"}')
    out=$(_cm_rpc "$d/p10/kb.db" "$req_lc_ok" 2>&1)
    same "code-mcp CODE-MCP-01 fresh echo(integer) succeeds after list_changed refresh" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "false"
    same "code-mcp CODE-MCP-01 fresh echo(integer) returned 42" "$(printf '%s' "$out" | jq -r '.result | fromjson | .msg // 0' 2>/dev/null)" "42"

    # 10d. CODE-MCP-01 single-run emit_changed({mutate_echo_int:true}) followed immediately by echo({msg:"stale"})
    : > "$d/p10/lc2.calls"
    _cm_add "$d/p10/kb.db" "$d/p10/projA" lc2 --cmd "$py" --arg "$fixture" \
        --arg "--call-log" --arg "$d/p10/lc2.calls" --trust annotations >/dev/null 2>&1
    local reg_lc2
    reg_lc2=$(CNTCTR_DB="$d/p10/kb.db" "$BIN" _test-code-kb server-get "$projA" lc2 | jq -r '.reg_id')
    CNTCTR_DB="$d/p10/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg_lc2" lc2 "*" access read "" orch "seed" 0 >/dev/null
    local req_lc2_disc req_lc2_run
    req_lc2_disc=$(jq -nc --arg p "$projA" '{method:"discover",project:$p,server:"lc2"}')
    _cm_rpc "$d/p10/kb.db" "$req_lc2_disc" >/dev/null 2>&1
    : > "$d/p10/lc2.calls"
    req_lc2_run=$(jq -nc --arg p "$projA" '{method:"run",project:$p,caller:"t",script:"await tools.lc2.emit_changed({mutate_echo_int:true}); return await tools.lc2.echo({msg:\"stale\"});"}')
    out=$(_cm_rpc "$d/p10/kb.db" "$req_lc2_run" 2>&1)
    same "code-mcp CODE-MCP-01 in-run emit_changed+echo rejects stale string arg" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "true"
    check "code-mcp CODE-MCP-01 in-run emit_changed+echo error mentions integer" "$(printf '%s' "$out" | jq -r '.result // ""' 2>/dev/null)" "integer"
    same "code-mcp CODE-MCP-01 in-run emit_changed+echo never sent echo to server" "$(grep -c '^echo$' "$d/p10/lc2.calls" 2>/dev/null || true)" "0"

    # 10e-g. CODE-MCP-04: a failed catalog refresh keeps the instance stale (no lost invalidation).
    #        fake-mcp --fail-list-after-changed N fails the next N tools/list after emit_changed;
    #        the per-process tools/list log gives deterministic refresh counts (no sleeps).
    local rn reg_rn req_disc req_emit req_stale req_ok req_ping tl
    for rn in rf rs rb; do
        : > "$d/p10/$rn.calls"; : > "$d/p10/$rn.methods"
    done
    _cm_add "$d/p10/kb.db" "$d/p10/projA" rf --cmd "$py" --arg "$fixture" --arg "--fail-list-after-changed" --arg 1 \
        --arg "--call-log" --arg "$d/p10/rf.calls" --arg "--method-log" --arg "$d/p10/rf.methods" --trust annotations >/dev/null 2>&1
    _cm_add "$d/p10/kb.db" "$d/p10/projA" rs --cmd "$py" --arg "$fixture" --arg "--fail-list-after-changed" --arg 2 \
        --arg "--call-log" --arg "$d/p10/rs.calls" --arg "--method-log" --arg "$d/p10/rs.methods" --trust annotations >/dev/null 2>&1
    _cm_add "$d/p10/kb.db" "$d/p10/projA" rb --cmd "$py" --arg "$fixture" --arg "--fail-list-after-changed" --arg 99 \
        --arg "--call-log" --arg "$d/p10/rb.calls" --arg "--method-log" --arg "$d/p10/rb.methods" --trust annotations >/dev/null 2>&1
    for rn in rf rs rb; do
        reg_rn=$(CNTCTR_DB="$d/p10/kb.db" "$BIN" _test-code-kb server-get "$projA" $rn | jq -r '.reg_id')
        CNTCTR_DB="$d/p10/kb.db" "$BIN" _test-code-kb grant-put "$projA" "$reg_rn" $rn "*" access read "" orch "seed" 0 >/dev/null
        req_disc=$(jq -nc --arg p "$projA" --arg s "$rn" '{method:"discover",project:$p,server:$s}')
        _cm_rpc "$d/p10/kb.db" "$req_disc" >/dev/null 2>&1
    done
    _cm_tl() { grep -c '^tools/list$' "$d/p10/$1.methods" 2>/dev/null || true; }
    _cm_js() { _cm_rpc "$d/p10/kb.db" "$(jq -nc --arg p "$projA" --arg s "$1" '{method:"run",project:$p,caller:"t",script:$s}')" 2>&1; }

    # 10e. one failed refresh: the next call must refresh again (not dispatch on old metadata)
    _cm_js 'return await tools.rf.emit_changed({mutate_echo_int:true});' >/dev/null
    out=$(_cm_js 'return await tools.rf.echo({msg:"stale"});')
    same "code-mcp CODE-MCP-04 failed refresh then call is rejected on refreshed schema" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "true"
    check "code-mcp CODE-MCP-04 rejection mentions integer schema" "$(printf '%s' "$out" | jq -r '.result // ""' 2>/dev/null)" "integer"
    same "code-mcp CODE-MCP-04 stale echo never reached server" "$(grep -c '^echo$' "$d/p10/rf.calls" 2>/dev/null || true)" "0"
    same "code-mcp CODE-MCP-04 tools/list: initial + 1 failure + 1 retry" "$(_cm_tl rf)" "3"

    # 10f. refresh keeps failing: call denied as stale; recovery after a successful retry
    _cm_js 'return await tools.rs.emit_changed({mutate_echo_int:true});' >/dev/null
    out=$(_cm_js 'return await tools.rs.echo({msg:"stale"});')
    same "code-mcp CODE-MCP-04 persistent refresh failure denies the call" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "true"
    check "code-mcp CODE-MCP-04 denial says stale catalog" "$(printf '%s' "$out" | jq -r '.result // ""' 2>/dev/null)" "stale catalog"
    same "code-mcp CODE-MCP-04 denied call never reached server" "$(grep -c '^echo$' "$d/p10/rs.calls" 2>/dev/null || true)" "0"
    # ping is valid under old and new schema: it drives the successful retry; echo(42) then proves the new schema is live
    out=$(_cm_js 'return await tools.rs.ping();')
    same "code-mcp CODE-MCP-04 retry call (ping) succeeds once refresh recovers" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "false"
    out=$(_cm_js 'return await tools.rs.echo({msg:42});')
    same "code-mcp CODE-MCP-04 recovers after successful retry" "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" "false"
    same "code-mcp CODE-MCP-04 recovered echo returned 42" "$(printf '%s' "$out" | jq -r '.result | fromjson | .msg // 0' 2>/dev/null)" "42"
    same "code-mcp CODE-MCP-04 tools/list: initial + 2 failures + 1 success" "$(_cm_tl rs)" "4"

    # 10g. bounded budget: 3 failed refreshes fail the instance closed (restart), never retry forever
    out=$(_cm_js 'return await tools.rb.ping();')
    local pid_rb1 pid_rb2
    pid_rb1=$(printf '%s' "$out" | jq -r '.result | fromjson | .pid // 0' 2>/dev/null)
    _cm_js 'return await tools.rb.emit_changed({mutate_echo_int:true});' >/dev/null
    out=$(_cm_js 'return await tools.rb.echo({msg:"stale"});')
    check "code-mcp CODE-MCP-04 budget call 1 denied as stale" "$(printf '%s' "$out" | jq -r '.result // ""' 2>/dev/null)" "stale catalog"
    out=$(_cm_js 'return await tools.rb.echo({msg:"stale"});')
    check "code-mcp CODE-MCP-04 budget call 2 denied as stale" "$(printf '%s' "$out" | jq -r '.result // ""' 2>/dev/null)" "stale catalog"
    same "code-mcp CODE-MCP-04 budget spent after 3 failed refreshes (no 4th attempt)" "$(_cm_tl rb)" "4"
    same "code-mcp CODE-MCP-04 stale server killed when budget spent" "$(_cm_wait_dead "$pid_rb1" && echo yes || echo no)" "yes"
    out=$(_cm_js 'return await tools.rb.ping();')
    pid_rb2=$(printf '%s' "$out" | jq -r '.result | fromjson | .pid // 0' 2>/dev/null)
    same "code-mcp CODE-MCP-04 next call restarts a fresh server" "$([ "$pid_rb2" != 0 ] && [ "$pid_rb2" != "$pid_rb1" ] && echo yes || echo no)" "yes"
    same "code-mcp CODE-MCP-04 restart did one fresh tools/list" "$(_cm_tl rb)" "5"
    same "code-mcp CODE-MCP-04 stale echo never reached any rb server" "$(grep -c '^echo$' "$d/p10/rb.calls" 2>/dev/null || true)" "0"

    _cm_stop "$d/p10/kb.db"
}
if [ "${ONLY:-}" = code-mcp ]; then
    code_mcp_run
    printf '%d passed, %d failed\n' "$pass" "$fail"
    [ "$fail" -eq 0 ]; exit $?
fi

# ---- Code Mode Phase 6: admin MCP tools, full `cntctr code` CLI, human-rule & orchestrator guardrails ----
code_admin_run() {
    local d="$TMPD/code_admin" db out rc projA projC projQ fixture py orch workr orchQ cmdline reg_fk reg_fake
    mkdir -p "$d/projA" "$d/projC" "$d/proj's dir" "$d/nosess"
    db="$d/kb.db"
    fixture="$(pwd)/fixtures/fake-mcp.py"
    py="$(command -v python3)"
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$BIN" > "$TMPD/bin/cntctr"; chmod +x "$TMPD/bin/cntctr"
    local r
    for r in "$d/projA" "$d/projC" "$d/proj's dir"; do
        git -C "$r" init -q
        git -C "$r" -c user.name=T -c user.email=t@example.invalid commit --allow-empty -qm init
    done
    projA=$(CNTCTR_DB="$db" "$BIN" _test-code-kb resolve-cwd "$d/projA")
    projC=$(CNTCTR_DB="$db" "$BIN" _test-code-kb resolve-cwd "$d/projC")
    projQ=$(CNTCTR_DB="$db" "$BIN" _test-code-kb resolve-cwd "$d/proj's dir")
    local projQs=${projQ//\'/\'\'}   # SQL-quoted

    _ca_cli() { local dir=$1; shift; (cd "$dir" && CNTCTR_DB="$db" CNTCTR_TEST_ANCESTOR_STOP_PID=$$ env -u TMUX_PANE -u CNTCTR_PANE -u CNTCTR_ROOT -u CNTCTR_CODE_SOCK "$BIN" code "$@" 2>&1); }
    _ca_pty() { local ans=$1 dir=$2; shift 2; python3 tests/pty_answer.py "$ans" "$dir" "$db" "$$" "$@"; }
    _ca_pane() {
        local p
        p=$(t new-window -d -P -F '#{pane_id}' -c "$2" cat)
        t set -p -t "$p" @cntctr_name "$1"; t set -p -t "$p" @cntctr_harness test; t set -p -t "$p" @cntctr_srv $$
        [ -n "${3:-}" ] && t set -p -t "$p" @cntctr_parent "$3"
        echo "$p"
    }
    # the MCP process is a child of this shell, not of the pane: tell cntctr the pane's root process is us (test hook)
    _ca_mcp() { CNTCTR_TEST_PANE_ROOT_PID=$$ CNTCTR_DB="$db" call "$@"; }
    _ca_wait_file() { local f=$1 i=0; while [ ! -f "$f" ] && [ "$i" -lt 500 ]; do sleep 0.02; i=$((i + 1)); done; [ -f "$f" ]; }
    _ca_pcount() { pgrep -f -- "$1" 2>/dev/null | wc -l | tr -d ' '; }
    _ca_isc() { [ "$(iserr "$1")" = true ] && echo err || echo ok; }
    _ca_stop() { CNTCTR_DB="$db" env -u CNTCTR_CODE_SOCK -u CNTCTR_ROOT "$BIN" code stop >/dev/null 2>&1 || true; }
    _ca_q() { sq "$db" "$1"; }

    orch=$(_ca_pane orch1 "$d/projA")
    workr=$(_ca_pane worker1 "$d/projA" "$orch")
    orchQ=$(_ca_pane orchq "$d/proj's dir")

    # 0. Tool schemas: three admin tools, each carries KFROM; listed only to an orchestrator (a worker or a paneless server never sees them)
    _ca_list() { CNTCTR_TEST_PANE_ROOT_PID=$$ CNTCTR_DB="$db" SKIP=1 session "$1" 2 "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | tail -n 1; }
    same "code-admin a plain (paneless) tools/list has no admin tool" "$(rpc "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | tail -n 1 | jq -r '[.result.tools[].name | select(. == "code_server" or . == "code_grant" or . == "code_revoke")] | length')" 0
    same "code-admin a spawned worker's tools/list has no admin tool" "$(_ca_list "$workr" | jq -r '[.result.tools[].name | select(. == "code_server" or . == "code_grant" or . == "code_revoke")] | length')" 0
    out=$(_ca_list "$orch")
    for r in code_server code_grant code_revoke; do
        same "code-admin tools/list has $r with from" "$(printf '%s' "$out" | jq -r --arg n "$r" '[.result.tools[] | select(.name == $n) | .inputSchema.properties | has("from")] | first // false')" "true"
    done

    # 1. Human setup: project-local `fake` + human rules; user-scoped `fk`
    out=$(_ca_cli "$d/projA" server add fake --project --cmd "$py" --arg "$fixture" --arg --pid-file --arg "$d/fake.pid" --trust annotations)
    check "code-admin human adds project-local fake" "$out" "added server fake"
    out=$(_ca_cli "$d/projA" grant fake.write_item deny --reason "no writes"); rc=$?
    same "code-admin human deny write_item (no prompt, new rule)" "$rc" 0
    out=$(_ca_cli "$d/projA" grant fake.ping class:destructive); rc=$?
    same "code-admin human class:destructive ping (new rule)" "$rc" 0
    same "code-admin human rows carry granted_by=human" "$(_ca_q "SELECT group_concat(granted_by) FROM code_grants WHERE tool_pattern IN ('write_item','ping')")" "human,human"
    reg_fake=$(_ca_q "SELECT reg_id FROM code_servers WHERE name='fake'")
    _ca_cli "$d/projA" server add fk --cmd "$py" --arg "$fixture" --arg --pid-file --arg "$d/fk.pid" --arg --call-log --arg "$d/fk.calls" --trust annotations >/dev/null

    # 2. CLI before any daemon: destructive allow needs a TTY, an agent ancestor is refused, probe failure fails closed
    out=$(_ca_cli "$d/projC" grant fk.nuke allow); rc=$?
    same "code-admin CLI destructive grant without TTY refused" "$((rc != 0))" 1
    same "code-admin CLI refused destructive grant stored nothing" "$(_ca_q "SELECT count(*) FROM code_grants WHERE project='$projC'")" 0
    cat > "$d/wrap.c" <<'EOF'
#include <stdlib.h>
#include <sys/wait.h>
int main(int argc, char **argv) {
    if (argc < 2) return 1;
    int s = system(argv[1]);
    return WIFEXITED(s) ? WEXITSTATUS(s) : 1;
}
EOF
    cc -o "$d/claude" "$d/wrap.c"
    out=$(_ca_pty y "$d/projC" "$d/claude" "'$BIN' code grant fk.nuke allow")
    check "code-admin fake claude ancestor refused even with a PTY" "$out" "ancestor process 'claude'"
    same "code-admin claude ancestor stored nothing" "$(_ca_q "SELECT count(*) FROM code_grants WHERE project='$projC'")" 0
    _ca_cli "$d/projC" server add ghost --project --cmd /nonexistent/ghost-bin >/dev/null
    out=$(_ca_pty y "$d/projC" "$BIN" code grant ghost.anything allow)
    refute "code-admin unprobeable server grant fails closed" "$out" "RC=0"
    same "code-admin unprobeable server stored nothing" "$(_ca_q "SELECT count(*) FROM code_grants WHERE server='ghost'")" 0
    out=$(_ca_pty n "$d/projC" "$BIN" code grant fk.nuke allow)
    check "code-admin PTY n aborts destructive grant" "$out" "PROMPTED=1"
    refute "code-admin PTY n exit status nonzero" "$out" "RC=0"
    same "code-admin PTY n stored nothing" "$(_ca_q "SELECT count(*) FROM code_grants WHERE project='$projC'")" 0
    out=$(_ca_pty y "$d/projC" "$BIN" code grant fk.nuke allow)
    check "code-admin PTY y grants destructive nuke" "$out" "RC=0"
    same "code-admin CLI grant is human, destructive, bound to reg_id" "$(_ca_q "SELECT granted_by||'|'||class_at_grant||'|'||(reg_id=(SELECT reg_id FROM code_servers WHERE name='fk')) FROM code_grants WHERE project='$projC' AND tool_pattern='nuke'")" "human|destructive|1"
    same "code-admin CLI never autostarted the daemon" "$([ -S "$d/code.sock" ] && echo yes || echo no)" "no"
    check "code-admin CLI probe discovered fk catalog" "$(_ca_cli "$d/projC" grants fk)" "nuke"
    out=$(_ca_cli "$d/projC" revoke fk.nuke); rc=$?
    same "code-admin CLI revokes a human allow row" "$rc" 0
    same "code-admin revoke removed the row" "$(_ca_q "SELECT count(*) FROM code_grants WHERE project='$projC'")" 0

    # 2b. all-projects policy through the CLI: read or deny, user-scoped servers, human only
    mkdir -p "$d/projD"; git -C "$d/projD" init -q; git -C "$d/projD" -c user.name=T -c user.email=t@example.invalid commit --allow-empty -qm init
    out=$(_ca_cli "$d/projD" grant fk.echo allow --all-projects); rc=$?
    same "code-admin all-projects allow is refused" "$((rc != 0))" 1
    check "code-admin all-projects allow refusal says read or deny only" "$out" "read or deny only"
    out=$(_ca_cli "$d/projD" grant 'fk.*' class:write --all-projects); rc=$?
    same "code-admin all-projects class rule is refused" "$((rc != 0))" 1
    out=$(_ca_cli "$d/projD" grant 'cntctr.*' read --all-projects); rc=$?
    same "code-admin all-projects cntctr server is refused" "$((rc != 0))" 1
    out=$(_ca_cli "$d/projA" grant 'fake.*' read --all-projects); rc=$?
    same "code-admin all-projects project-local-only server is refused" "$((rc != 0))" 1
    out=$(_ca_cli "$d/projD" revoke 'cntctr.*' --all-projects); rc=$?
    same "code-admin revoke --all-projects of the cntctr server is refused" "$((rc != 0))" 1
    check "code-admin ...with the same explicit message as grant" "$out" "built-in cntctr server is granted per project"
    same "code-admin refused all-projects grants stored nothing" "$(_ca_q "SELECT count(*) FROM code_grants WHERE project='*'")" 0
    out=$(_ca_cli "$d/projD" grant 'fk.*' read --all-projects --reason "everywhere"); rc=$?
    same "code-admin all-projects read grant succeeds" "$rc" 0
    check "code-admin all-projects grant says all projects" "$out" "in all projects"
    same "code-admin all-projects row is human, project '*', bound to the user-scoped fk" "$(_ca_q "SELECT project||'|'||granted_by||'|'||level||'|'||(reg_id=(SELECT reg_id FROM code_servers WHERE name='fk' AND scope_project='')) FROM code_grants WHERE project='*'")" "*|human|read|1"
    check "code-admin grants lists the all-projects rule, marked, from another project" "$(_ca_cli "$d/projA" grants fk)" "fk.* access read by=human reason=everywhere [all-projects]"
    check "code-admin code_status shows the all-projects rule, marked" "$(txt "$(_ca_mcp "$orch" code_status '{}')")" "[all-projects]"
    out=$(_ca_mcp "$orch" code_revoke '{"server":"fk","tool_pattern":"*"}')
    same "code-admin MCP revoke cannot remove the all-projects rule" "$(_ca_isc "$out")" err
    check "code-admin MCP revoke names the human all-projects rule" "$(txt "$out")" "all-projects rule a human set"
    same "code-admin the all-projects rule survived the MCP revoke" "$(_ca_q "SELECT count(*) FROM code_grants WHERE project='*'")" 1
    out=$(_ca_cli "$d/projD" revoke 'fk.*'); rc=$?
    same "code-admin revoke without --all-projects does not touch it" "$((rc != 0))" 1
    check "code-admin revoke without the flag points at --all-projects" "$out" "--all-projects"
    out=$(_ca_cli "$d/projD" revoke 'fk.*' --all-projects); rc=$?
    same "code-admin revoke --all-projects removes it" "$rc" 0
    same "code-admin all-projects rule is gone" "$(_ca_q "SELECT count(*) FROM code_grants WHERE project='*'")" 0

    # 3. Authority: workers, paneless from=<orchestrator>
    out=$(_ca_mcp "$orch" code_server '{"action":"list"}')
    same "code-admin orchestrator code_server list ok" "$(_ca_isc "$out")" ok
    out=$(_ca_mcp "$workr" code_server '{"action":"list"}')
    same "code-admin worker code_server list denied" "$(_ca_isc "$out")" err
    check "code-admin worker denial names orchestrator" "$(txt "$out")" "orchestrator"
    out=$(_ca_mcp "$workr" code_server '{"action":"discover","name":"fake"}')
    same "code-admin worker code_server discover denied" "$(_ca_isc "$out")" err
    same "code-admin worker discover started no fake-mcp process" "$([ -e "$d/fake.pid" ] && echo started || echo none)" "none"
    same "code-admin worker discover did not autostart the daemon" "$([ -S "$d/code.sock" ] && echo yes || echo no)" "no"
    out=$(_ca_mcp "$workr" code_grant '{"server":"fake","tool_pattern":"ping","level":"read"}')
    same "code-admin worker code_grant denied" "$(_ca_isc "$out")" err
    out=$(_ca_mcp "$workr" code_revoke '{"server":"fake","tool_pattern":"ping"}')
    same "code-admin worker code_revoke denied" "$(_ca_isc "$out")" err
    out=$(printf '%s\n' "$INIT" "$(jq -nc '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"code_server",arguments:{action:"list",from:"orch1"}}}')" |
        CNTCTR_DB="$db" CNTCTR_CLAUDE_SESSIONS_DIR="$d/nosess" env -u TMUX_PANE -u CNTCTR_PANE "$BIN" | tail -n 1)
    same "code-admin paneless from=<orchestrator> code_server denied" "$(_ca_isc "$out")" err
    check "code-admin paneless code_server denial says the process has no pane of its own" "$(txt "$out")" "no agent pane of its own"
    out=$(printf '%s\n' "$INIT" "$(jq -nc '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"code_grant",arguments:{server:"fake",tool_pattern:"ping",level:"read",from:"orch1"}}}')" |
        CNTCTR_DB="$db" CNTCTR_CLAUDE_SESSIONS_DIR="$d/nosess" env -u TMUX_PANE -u CNTCTR_PANE "$BIN" | tail -n 1)
    same "code-admin paneless from=<orchestrator> code_grant denied" "$(_ca_isc "$out")" err
    check "code-admin paneless code_grant denial says the process has no pane of its own" "$(txt "$out")" "no agent pane of its own"
    same "code-admin paneless attempt granted nothing" "$(_ca_q "SELECT count(*) FROM code_grants WHERE level='read'")" 0

    # a reviewer pane with no @cntctr_parent is still not an orchestrator
    local revp
    revp=$(_ca_pane revr "$d/projA")
    _ca_q "INSERT INTO tools(project,name,version,status,author,description,input_schema,interpreter,script,reviewer_pane) VALUES ('rev-proj','rev_tool',1,'pending','a','d','{}','sh','true','$revp')"
    out=$(_ca_mcp "$revp" code_server '{"action":"list"}')
    same "code-admin reviewer pane without a parent denied" "$(_ca_isc "$out")" err
    check "code-admin reviewer denial names the reviewer" "$(txt "$out")" "reviewer"
    _ca_q "DELETE FROM tools WHERE project='rev-proj'"

    # 3b. CODE-ADMIN-01: the env pane is only a hint; the MCP process must descend from that pane's root process
    out=$(CNTCTR_DB="$db" call "$orch" code_server '{"action":"list"}')
    same "code-admin pane env without process-to-pane evidence denied" "$(_ca_isc "$out")" err
    check "code-admin unverified pane denial says not a descendant" "$(txt "$out")" "not a descendant"
    out=$(CNTCTR_TEST_PANE_ROOT_PID=1 CNTCTR_DB="$db" call "$orch" code_server '{"action":"list"}')
    same "code-admin wrong pane root pid denied" "$(_ca_isc "$out")" err
    out=$(printf '%s\n' "$INIT" "$(jq -nc '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:"code_server",arguments:{action:"list"}}}')" |
        CNTCTR_DB="$db" CNTCTR_PANE="$orch" env -u TMUX_PANE "$BIN" | tail -n 1)
    same "code-admin CNTCTR_PANE=<orchestrator> from a non-descendant denied" "$(_ca_isc "$out")" err
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb resolve-project %999999 2>&1); rc=$?
    same "code-admin project path query failure is an error, not the process cwd" "$((rc != 0))" 1
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb resolve-project "$orch" 2>&1); rc=$?
    same "code-admin project path of a live pane resolves" "$rc" 0
    check "code-admin pane project is the pane's repo" "$out" "projA"

    # 4. Human rules are immutable to the orchestrator
    out=$(_ca_mcp "$orch" code_grant '{"server":"fake","tool_pattern":"write_item","level":"allow"}')
    same "code-admin MCP allow over human deny refused" "$(_ca_isc "$out")" err
    check "code-admin refusal says a human set the rule" "$(txt "$out")" "human"
    same "code-admin human deny row unchanged" "$(_ca_q "SELECT level||granted_by FROM code_grants WHERE tool_pattern='write_item'")" "denyhuman"
    out=$(_ca_mcp "$orch" code_grant '{"server":"fake","tool_pattern":"ping","level":"class:write"}')
    same "code-admin MCP class rule over human class rule refused" "$(_ca_isc "$out")" err
    same "code-admin human class row unchanged" "$(_ca_q "SELECT level||granted_by FROM code_grants WHERE tool_pattern='ping'")" "class:destructivehuman"
    out=$(_ca_mcp "$orch" code_revoke '{"server":"fake","tool_pattern":"write_item"}')
    same "code-admin MCP revoke of human deny refused" "$(_ca_isc "$out")" err
    out=$(_ca_mcp "$orch" code_revoke '{"server":"fake","tool_pattern":"ping","kind":"class"}')
    same "code-admin MCP revoke of human class rule refused" "$(_ca_isc "$out")" err
    same "code-admin both human rows survive" "$(_ca_q "SELECT count(*) FROM code_grants WHERE granted_by='human' AND server='fake'")" 2
    out=$(_ca_mcp "$orch" code_server "$(jq -nc --arg py "$py" --arg fx "$fixture" '{action:"add",name:"fake",command:$py,args:[$fx]}')")
    same "code-admin MCP replace of server with human rules refused" "$(_ca_isc "$out")" err
    check "code-admin replace refusal says ask the user" "$(txt "$out")" "a human set rules on this server; ask the user"
    out=$(_ca_mcp "$orch" code_server '{"action":"remove","name":"fake"}')
    same "code-admin MCP remove of server with human rules refused" "$(_ca_isc "$out")" err
    same "code-admin server row unchanged after refusals" "$(_ca_q "SELECT reg_id FROM code_servers WHERE name='fake'")" "$reg_fake"
    same "code-admin refusals never started fake-mcp" "$([ -e "$d/fake.pid" ] && echo started || echo none)" "none"

    # 4b. CODE-ADMIN-09: a human ALLOW row is as immutable as a deny; revoke commits are guarded too
    _ca_cli "$d/projA" server add fkh --project --cmd "$py" --arg "$fixture" --arg --tag --arg fkh --trust annotations >/dev/null
    _ca_cli "$d/projA" grant fkh.echo allow >/dev/null
    same "code-admin human allow row recorded" "$(_ca_q "SELECT level||'|'||granted_by FROM code_grants WHERE server='fkh' AND tool_pattern='echo'")" "allow|human"
    out=$(_ca_mcp "$orch" code_grant '{"server":"fkh","tool_pattern":"echo","level":"allow","reason":"overwrite"}')
    same "code-admin MCP cannot overwrite a human allow row" "$(_ca_isc "$out")" err
    check "code-admin overwrite refusal says a human set the rule" "$(txt "$out")" "a human set this rule"
    out=$(_ca_mcp "$orch" code_revoke '{"server":"fkh","tool_pattern":"echo"}')
    same "code-admin MCP cannot revoke a human allow row" "$(_ca_isc "$out")" err
    same "code-admin human allow row unchanged" "$(_ca_q "SELECT level||'|'||granted_by||'|'||reason FROM code_grants WHERE server='fkh' AND tool_pattern='echo'")" "allow|human|"
    _ca_mcp "$orch" code_grant '{"server":"fkh","tool_pattern":"ping","level":"read"}' >/dev/null
    (CNTCTR_TEST_BARRIER="$d/br" CNTCTR_TEST_BARRIER_AT=revoke-precommit _ca_mcp "$orch" code_revoke '{"server":"fkh","tool_pattern":"ping"}' > "$d/br.out") &
    local br_job=$!
    same "code-admin revoke barrier reached" "$(_ca_wait_file "$d/br.ready" && echo yes || echo no)" yes
    _ca_q "UPDATE code_grants SET granted_by='human' WHERE server='fkh' AND tool_pattern='ping'" >/dev/null
    : > "$d/br.go"
    wait "$br_job"
    same "code-admin revoke of a rule that turned human before commit is refused" "$(_ca_isc "$(cat "$d/br.out")")" err
    check "code-admin revoke refusal says a human set the rule" "$(txt "$(cat "$d/br.out")")" "a human set this rule"
    same "code-admin the now-human rule survived the racing revoke" "$(_ca_q "SELECT count(*) FROM code_grants WHERE server='fkh' AND tool_pattern='ping'")" 1
    _ca_cli "$d/projA" grant fkh.ping deny >/dev/null 2>&1 || true
    (CNTCTR_TEST_BARRIER="$d/bcr" CNTCTR_TEST_BARRIER_AT=revoke-precommit _ca_pty y "$d/projA" "$BIN" code revoke fkh.ping > "$d/bcr.out") &
    local bcr_job=$!
    same "code-admin CLI revoke barrier reached after confirmation" "$(_ca_wait_file "$d/bcr.ready" && echo yes || echo no)" yes
    _ca_q "UPDATE code_grants SET reason='edited meanwhile' WHERE server='fkh' AND tool_pattern='ping'" >/dev/null
    : > "$d/bcr.go"
    wait "$bcr_job"
    check "code-admin CLI revoke of a protected rule edited after confirm: re-confirmed" "$(cat "$d/bcr.out")" "PROMPTED=2"
    same "code-admin re-confirmed revoke removed the rule" "$(_ca_q "SELECT count(*) FROM code_grants WHERE server='fkh' AND tool_pattern='ping'")" 0
    _ca_pty y "$d/projA" "$BIN" code server remove --project fkh >/dev/null

    # 4c. CODE-ADMIN-06: control characters in tool names never reach catalogs, grants or prose
    out=$(_ca_mcp "$orch" code_server "$(jq -nc --arg py "$py" --arg fx "$fixture" '{action:"add",name:"ev",command:$py,args:[$fx,"--evil-tool-names"],trust:"annotations"}')")
    same "code-admin MCP add ev" "$(_ca_isc "$out")" ok
    out=$(_ca_mcp "$orch" code_server '{"action":"discover","name":"ev"}')
    same "code-admin discover of a server with hostile tool names ok" "$(_ca_isc "$out")" ok
    refute "code-admin discover output has no control-character tool name" "$(txt "$out")" "bad"
    same "code-admin catalog skipped hostile and over-long tool names" "$(_ca_q "SELECT count(*) FROM code_catalogs WHERE tools_json LIKE '%bad%' OR tools_json LIKE '%ctl%' OR tools_json LIKE '%xxxxxxxxxxxxxxxxxxxxxxxx%'")" 0
    out=$(_ca_mcp "$orch" code_grant "$(jq -nc '{server:"ev",tool_pattern:"bad\ntool",level:"allow"}')")
    same "code-admin grant pattern with a newline rejected" "$(_ca_isc "$out")" err
    out=$(_ca_mcp "$orch" code_grant "$(jq -nc '{server:"ev",tool_pattern:"a\u007fb*",level:"read"}')")
    same "code-admin grant pattern with DEL rejected" "$(_ca_isc "$out")" err
    same "code-admin hostile patterns stored nothing" "$(_ca_q "SELECT count(*) FROM code_grants WHERE server='ev'")" 0
    _ca_mcp "$orch" code_server '{"action":"remove","name":"ev"}' >/dev/null

    # 4d. CODE-ADMIN-08: a failed grant lookup is a distinct error, not an ordinary denial
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check "" reg-x tool read)
    check "code-admin grant check with invalid parameters returns -1" "$out" "rc=-1 "
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-check no-such-project reg-x tool read)
    check "code-admin an ordinary denial stays rc=1" "$out" "rc=1 "

    # 5. Server scope & naming
    out=$(_ca_mcp "$orch" code_server "$(jq -nc --arg py "$py" '{action:"add",name:"fk",command:$py}')")
    same "code-admin MCP cannot shadow a user-scoped server" "$(_ca_isc "$out")" err
    check "code-admin shadow refusal mentions user-scoped" "$(txt "$out")" "user-scoped"
    same "code-admin shadow attempt left one fk row" "$(_ca_q "SELECT count(*)||'|'||min(scope_project) FROM code_servers WHERE name='fk'")" "1|"
    out=$(_ca_mcp "$orch" code_server '{"action":"remove","name":"fk"}')
    same "code-admin MCP cannot remove a user-scoped server" "$(_ca_isc "$out")" err
    out=$(_ca_mcp "$orch" code_server '{"action":"restart","name":"fk"}')
    same "code-admin MCP cannot restart a user-scoped server" "$(_ca_isc "$out")" err
    same "code-admin user-scoped fk survives" "$(_ca_q "SELECT count(*) FROM code_servers WHERE name='fk' AND scope_project=''")" 1
    for r in cntctr bad.name "has space"; do
        out=$(_ca_mcp "$orch" code_server "$(jq -nc --arg n "$r" --arg py "$py" '{action:"add",name:$n,command:$py}')")
        same "code-admin MCP add rejects name '$r'" "$(_ca_isc "$out")" err
    done
    out=$(_ca_mcp "$orch" code_server '{"action":"add","name":"spacey","command":"/bin/echo hi"}')
    same "code-admin MCP add rejects whitespace in command" "$(_ca_isc "$out")" err
    out=$(_ca_mcp "$orch" code_server "$(jq -nc --arg py "$py" '{action:"add",name:"loc",command:$py,env:{SECRET:"zzz-secret-value"}}')")
    same "code-admin MCP add project-local server" "$(_ca_isc "$out")" ok
    same "code-admin MCP add defaults trust=none and project scope" "$(_ca_q "SELECT trust||'|'||(scope_project='$projA') FROM code_servers WHERE name='loc'")" "none|1"
    same "code-admin MCP add records created_by" "$(_ca_q "SELECT created_by FROM code_servers WHERE name='loc'")" "orch1"
    out=$(_ca_mcp "$orch" code_server '{"action":"list"}')
    check "code-admin list shows env key" "$(txt "$out")" "SECRET"
    refute "code-admin list hides env value" "$(txt "$out")" "zzz-secret-value"
    check "code-admin list shows loc" "$(txt "$out")" "loc"
    local reg_loc1 reg_loc2
    reg_loc1=$(_ca_q "SELECT reg_id FROM code_servers WHERE name='loc'")
    _ca_mcp "$orch" code_server "$(jq -nc --arg py "$py" '{action:"add",name:"loc",command:$py,trust:"annotations"}')" >/dev/null
    reg_loc2=$(_ca_q "SELECT reg_id FROM code_servers WHERE name='loc'")
    same "code-admin MCP update of own project-local row replaces reg_id" "$([ "$reg_loc1" != "$reg_loc2" ] && echo yes || echo no)" "yes"
    out=$(_ca_mcp "$orch" code_server '{"action":"remove","name":"loc"}')
    same "code-admin MCP remove own project-local server" "$(_ca_isc "$out")" ok
    same "code-admin loc removed" "$(_ca_q "SELECT count(*) FROM code_servers WHERE name='loc'")" 0
    _ca_cli "$d/projC" server add shd2 --cmd /bin/echo >/dev/null
    CNTCTR_DB="$db" "$BIN" _test-code-kb server-put "$projC" shd2 /bin/echo '[]' '{}' 0 none human 0 >/dev/null
    out=$(_ca_mcp "$orch" code_server '{"action":"list"}')
    check "code-admin MCP list counts other projects' shadows" "$(txt "$out")" "shadowed in 1 projects"
    refute "code-admin MCP list hides other projects' roots" "$(txt "$out")" "$projC"
    check "code-admin CLI list keeps the shadowing roots" "$(_ca_cli "$d/projA" server list)" "$projC"
    _ca_cli "$d/projC" server remove --project shd2 >/dev/null
    _ca_cli "$d/projC" server remove shd2 >/dev/null
    _ca_cli "$d/projA" server add shdw --project --cmd /bin/echo >/dev/null
    out=$(_ca_cli "$d/projC" server add shdw --cmd /bin/echo)
    check "code-admin user-scoped add reports shadowed project rows" "$out" "shadowed in 1 project"
    out=$(_ca_cli "$d/projA" server list)
    check "code-admin server list shows shadowed rows" "$out" "shadowed"
    _ca_cli "$d/projA" server remove --project shdw >/dev/null
    _ca_cli "$d/projA" server remove shdw >/dev/null

    # 6. Orchestrator grants: discovery, class_at_grant, typo suggestions, virtual cntctr
    out=$(_ca_mcp "$orch" code_grant '{"server":"fk","tool_pattern":"write_item","level":"allow","reason":"needed"}')
    same "code-admin MCP allow write_item discovers and grants" "$(_ca_isc "$out")" ok
    same "code-admin MCP grant records class_at_grant, granter, reg_id" "$(_ca_q "SELECT class_at_grant||'|'||granted_by||'|'||(reg_id=(SELECT reg_id FROM code_servers WHERE name='fk')) FROM code_grants WHERE project='$projA' AND tool_pattern='write_item' AND server='fk'")" "write|orch1|1"
    out=$(_ca_mcp "$orch" code_grant '{"server":"fk","tool_pattern":"wriet_item","level":"allow"}')
    same "code-admin MCP unknown tool rejected" "$(_ca_isc "$out")" err
    check "code-admin unknown tool suggests write_item" "$(txt "$out")" "write_item"
    same "code-admin unknown tool stored nothing" "$(_ca_q "SELECT count(*) FROM code_grants WHERE tool_pattern='wriet_item'")" 0
    out=$(_ca_mcp "$orch" code_grant '{"server":"fk","tool_pattern":"write_*","level":"allow"}')
    same "code-admin MCP allow glob rejected (exact tool only)" "$(_ca_isc "$out")" err
    out=$(_ca_mcp "$orch" code_grant '{"server":"fk","tool_pattern":"echo*","level":"read"}')
    same "code-admin MCP read glob accepted" "$(_ca_isc "$out")" ok
    out=$(_ca_mcp "$orch" code_grant '{"server":"cntctr","tool_pattern":"*","level":"read"}')
    same "code-admin virtual cntctr read grant" "$(_ca_isc "$out")" ok
    out=$(_ca_mcp "$orch" code_grant '{"server":"cntctr","tool_pattern":"note","level":"allow"}')
    same "code-admin virtual cntctr allow note" "$(_ca_isc "$out")" ok
    same "code-admin virtual cntctr rows bind reg_id cntctr" "$(_ca_q "SELECT group_concat(reg_id||':'||tool_pattern||':'||class_at_grant) FROM (SELECT * FROM code_grants WHERE server='cntctr' ORDER BY tool_pattern)")" "cntctr:*:,cntctr:note:write"
    out=$(_ca_mcp "$orch" code_grant '{"server":"cntctr","tool_pattern":"nope","level":"allow"}')
    same "code-admin virtual cntctr unknown tool rejected" "$(_ca_isc "$out")" err
    out=$(_ca_mcp "$orch" code_grant '{"server":"nosuch","tool_pattern":"x","level":"read"}')
    same "code-admin MCP unknown server rejected" "$(_ca_isc "$out")" err
    out=$(_ca_mcp "$orch" code_server '{"action":"discover","name":"fk"}')
    same "code-admin orchestrator discover ok" "$(_ca_isc "$out")" ok
    check "code-admin discover lists tools with class" "$(txt "$out")" "nuke"
    out=$(_ca_mcp "$orch" code_revoke '{"server":"fk","tool_pattern":"echo*"}')
    same "code-admin MCP revokes its own rule" "$(_ca_isc "$out")" ok
    same "code-admin revoked rule gone" "$(_ca_q "SELECT count(*) FROM code_grants WHERE tool_pattern='echo*'")" 0

    # 6b. discover (CLI) and restart (MCP for project-local, CLI for user-scoped) stop the right process
    out=$(_ca_cli "$d/projC" server discover fk)
    check "code-admin CLI discover lists tools with classes" "$out" "nuke  destructive"
    out=$(_ca_mcp "$orch" code_server "$(jq -nc --arg py "$py" --arg fx "$fixture" --arg pf "$d/rs1.pid" '{action:"add",name:"rs1",command:$py,args:[$fx,"--pid-file",$pf],trust:"annotations"}')")
    same "code-admin MCP add rs1" "$(_ca_isc "$out")" ok
    out=$(_ca_mcp "$orch" code_server '{"action":"discover","name":"rs1"}')
    same "code-admin MCP discover rs1 starts it" "$(_ca_isc "$out")" ok
    local pid_rs1 pid_fk i
    pid_rs1=$(tr -d '[:space:]' < "$d/rs1.pid")
    same "code-admin rs1 is running" "$(kill -0 "$pid_rs1" 2>/dev/null && echo yes || echo no)" "yes"
    out=$(_ca_mcp "$workr" code_server '{"action":"restart","name":"rs1"}')
    same "code-admin worker restart denied" "$(_ca_isc "$out")" err
    same "code-admin denied restart left rs1 running" "$(kill -0 "$pid_rs1" 2>/dev/null && echo yes || echo no)" "yes"
    out=$(_ca_mcp "$orch" code_server '{"action":"restart","name":"rs1"}')
    same "code-admin MCP restart own project-local server" "$(_ca_isc "$out")" ok
    for i in $(seq 100); do kill -0 "$pid_rs1" 2>/dev/null || break; sleep 0.05; done
    same "code-admin restart stopped the rs1 process" "$(kill -0 "$pid_rs1" 2>/dev/null && echo yes || echo no)" "no"
    pid_fk=$(tr -d '[:space:]' < "$d/fk.pid")
    out=$(_ca_cli "$d/projA" server restart fk)
    check "code-admin CLI restart reports restarted" "$out" "restarted server fk"
    for i in $(seq 100); do kill -0 "$pid_fk" 2>/dev/null || break; sleep 0.05; done
    same "code-admin CLI restart stopped the fk process" "$(kill -0 "$pid_fk" 2>/dev/null && echo yes || echo no)" "no"
    _ca_mcp "$orch" code_server '{"action":"remove","name":"rs1"}' >/dev/null

    # 6c. CODE-ADMIN-02: restart is bound to the checked registration and exact instance, never to name+scope
    _ca_cli "$d/projA" server add iso --isolated --cmd "$py" --arg "$fixture" --arg --tag --arg isoU --trust annotations >/dev/null
    _ca_mcp "$orch" code_server '{"action":"discover","name":"iso"}' >/dev/null
    _ca_cli "$d/projC" server discover iso >/dev/null
    same "code-admin two isolated user-scoped iso instances (projA, projC)" "$(_ca_pcount '--tag isoU')" 2
    # insert the shadow straight into the store: one setup step, and no CLI/daemon traffic between the instances
    # being started and the restart under test
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-put "$projA" iso "$py" "$(jq -nc --arg fx "$fixture" '[$fx,"--tag","isoL"]')" '{}' 0 annotations human 0)
    check "code-admin project-local iso shadows the user-scoped one" "$out" "rc=0 "
    _ca_mcp "$orch" code_server '{"action":"discover","name":"iso"}' >/dev/null
    same "code-admin project-local iso instance running" "$(_ca_pcount '--tag isoL')" 1
    same "code-admin user-scoped isolated iso instance of projA still running beside it" "$(_ca_pcount '--tag isoU')" 2
    out=$(_ca_mcp "$orch" code_server '{"action":"restart","name":"iso"}')
    same "code-admin restart of project-local iso ok" "$(_ca_isc "$out")" ok
    for i in $(seq 100); do [ "$(_ca_pcount '--tag isoL')" = 0 ] && break; sleep 0.05; done
    same "code-admin restart stopped the project-local instance" "$(_ca_pcount '--tag isoL')" 0
    same "code-admin project-local restart left same-name user-scoped isolated instances alone" "$(_ca_pcount '--tag isoU')" 2
    _ca_mcp "$orch" code_server '{"action":"discover","name":"iso"}' >/dev/null
    same "code-admin project-local iso running again" "$(_ca_pcount '--tag isoL')" 1
    out=$(_ca_cli "$d/projC" server restart iso)
    check "code-admin CLI restart of user-scoped iso in projC" "$out" "restarted server iso"
    for i in $(seq 100); do [ "$(_ca_pcount '--tag isoU')" = 1 ] && break; sleep 0.05; done
    same "code-admin user-scoped restart stopped only that project's instance" "$(_ca_pcount '--tag isoU')" 1
    same "code-admin user-scoped restart left the project-local instance alone" "$(_ca_pcount '--tag isoL')" 1

    # 6d. CODE-ADMIN-05: remove's daemon reload carries the OLD reg_id and stops only that registration's instances
    out=$(_ca_mcp "$orch" code_server '{"action":"remove","name":"iso"}')
    same "code-admin MCP removes the project-local iso" "$(_ca_isc "$out")" ok
    for i in $(seq 100); do [ "$(_ca_pcount '--tag isoL')" = 0 ] && break; sleep 0.05; done
    same "code-admin project-local remove stopped its own instance" "$(_ca_pcount '--tag isoL')" 0
    same "code-admin project-local remove left the same-name user-scoped isolated instance alone" "$(_ca_pcount '--tag isoU')" 1
    out=$(CNTCTR_DB="$db" "$BIN" _test-code-kb server-put "$projA" iso "$py" "$(jq -nc --arg fx "$fixture" '[$fx,"--tag","isoL"]')" '{}' 0 annotations human 0)
    check "code-admin project-local iso back (no reload)" "$out" "rc=0 "
    _ca_mcp "$orch" code_server '{"action":"discover","name":"iso"}' >/dev/null
    same "code-admin project-local iso running for the user-scoped remove" "$(_ca_pcount '--tag isoL')" 1
    out=$(_ca_cli "$d/projC" server remove iso)
    check "code-admin CLI removes the user-scoped iso" "$out" "removed server iso (user)"
    for i in $(seq 100); do [ "$(_ca_pcount '--tag isoU')" = 0 ] && break; sleep 0.05; done
    same "code-admin user-scoped remove stopped the user-scoped instances" "$(_ca_pcount '--tag isoU')" 0
    same "code-admin user-scoped remove left the project-local instance alone" "$(_ca_pcount '--tag isoL')" 1
    _ca_mcp "$orch" code_server '{"action":"remove","name":"iso"}' >/dev/null

    # 6e. CODE-ADMIN-03 (round 2): the guard snapshot is injective for arbitrary stored text
    local nl=$'\n' us=$'\x1f' snapA snapB snapB2 snapR
    snapR="x${nl}p2${us}access${us}read${us}${us}orch${us}1000${us}y"   # a naive concatenation of {p1:"x"; p2:"y"} equals this single row
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put snap-proj reg-snap srv p1 access read "" orch "$snapR" 0 >/dev/null
    _ca_q "UPDATE code_grants SET granted_at=1000 WHERE project='snap-proj'"
    snapA=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-snapshot snap-proj reg-snap "")
    _ca_q "DELETE FROM code_grants WHERE project='snap-proj'"
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put snap-proj reg-snap srv p1 access read "" orch "x" 0 >/dev/null
    CNTCTR_DB="$db" "$BIN" _test-code-kb grant-put snap-proj reg-snap srv p2 access read "" orch "y" 0 >/dev/null
    _ca_q "UPDATE code_grants SET granted_at=1000 WHERE project='snap-proj'"
    snapB=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-snapshot snap-proj reg-snap "")
    snapB2=$(CNTCTR_DB="$db" "$BIN" _test-code-kb grant-snapshot snap-proj reg-snap "")
    same "code-admin snapshot of equal state is stable" "$([ -n "$snapB" ] && [ "$snapB" = "$snapB2" ] && echo yes || echo no)" yes
    same "code-admin snapshots differ where naive delimiter concatenation would collide" "$([ -n "$snapA" ] && [ "$snapA" != "$snapB" ] && echo yes || echo no)" yes
    _ca_q "DELETE FROM code_grants WHERE project='snap-proj'"

    # 7. Destructive escalation with shell-quoted command (apostrophe path), then human runs it
    out=$(_ca_mcp "$orchQ" code_grant '{"server":"fk","tool_pattern":"nuke","level":"allow"}')
    same "code-admin destructive allow by orchestrator is not applied" "$(_ca_q "SELECT count(*) FROM code_grants WHERE tool_pattern='nuke' AND project='$projQs'")" 0
    check "code-admin escalation names the human terminal" "$(txt "$out")" "Run in your own terminal"
    cmdline=$(txt "$out" | sed -n 's/^  \(cd .*\)$/\1/p' | head -n 1)
    check "code-admin escalation command is cd && cntctr code grant" "$cmdline" "cntctr code grant 'fk.nuke' allow"
    check "code-admin escalation shell-quotes the apostrophe path" "$cmdline" "proj'\\''s dir"
    check "code-admin escalation posted to the board" "$(txt "$(_ca_mcp "$orchQ" board '{}')")" "cntctr code grant"
    out=$(_ca_pty y "$d" sh -c "$cmdline")
    check "code-admin pasted escalation command succeeds under PTY y" "$out" "RC=0"
    same "code-admin pasted command granted nuke in the apostrophe project" "$(_ca_q "SELECT granted_by||'|'||class_at_grant FROM code_grants WHERE project='$projQs' AND tool_pattern='nuke'")" "human|destructive"

    # 8. Policy: destructive-orchestrator allow lets the orchestrator grant; changes need a TTY y/N
    out=$(_ca_cli "$d/projA" policy destructive-orchestrator allow); rc=$?
    same "code-admin policy change without TTY refused" "$((rc != 0))" 1
    out=$(_ca_pty y "$d/projA" "$BIN" code policy destructive-orchestrator allow)
    check "code-admin policy change under PTY y" "$out" "RC=0"
    out=$(_ca_mcp "$orch" code_grant '{"server":"fk","tool_pattern":"nuke","level":"allow"}')
    same "code-admin allowed policy lets orchestrator grant destructive" "$(_ca_isc "$out")" ok
    same "code-admin policy-allowed grant records the orchestrator" "$(_ca_q "SELECT granted_by||'|'||class_at_grant FROM code_grants WHERE project='$projA' AND tool_pattern='nuke'")" "orch1|destructive"
    # 8b. CODE-ADMIN-03: the decision is bound to what commits (policy, effective registration, rule state)
    _ca_mcp "$orch" code_revoke '{"server":"fk","tool_pattern":"nuke"}' >/dev/null
    (CNTCTR_TEST_BARRIER="$d/bp" CNTCTR_TEST_BARRIER_AT=grant-precommit _ca_mcp "$orch" code_grant '{"server":"fk","tool_pattern":"nuke","level":"allow"}' > "$d/bp.out") &
    local bp_job=$!
    same "code-admin policy-flip barrier reached" "$(_ca_wait_file "$d/bp.ready" && echo yes || echo no)" yes
    _ca_q "INSERT OR REPLACE INTO meta(k,v) VALUES('code_destructive_orchestrator:$projA','escalate')" >/dev/null
    : > "$d/bp.go"
    wait "$bp_job"
    check "code-admin policy flipped before commit escalates instead of granting" "$(txt "$(cat "$d/bp.out")")" "NOT granted"
    same "code-admin policy-flip stored no destructive grant" "$(_ca_q "SELECT count(*) FROM code_grants WHERE project='$projA' AND tool_pattern='nuke'")" 0
    _ca_q "INSERT OR REPLACE INTO meta(k,v) VALUES('code_destructive_orchestrator:$projA','allow')" >/dev/null

    local old_fk
    old_fk=$(_ca_q "SELECT reg_id FROM code_servers WHERE name='fk' AND scope_project=''")
    (CNTCTR_TEST_BARRIER="$d/bs" CNTCTR_TEST_BARRIER_AT=grant-precommit _ca_pty y "$d/projC" "$BIN" code grant fk.nuke allow > "$d/bs.out") &
    local bs_job=$!
    same "code-admin shadow barrier reached after confirmation" "$(_ca_wait_file "$d/bs.ready" && echo yes || echo no)" yes
    _ca_cli "$d/projC" server add fk --project --cmd "$py" --arg "$fixture" --arg --tag --arg fkshadow --trust annotations >/dev/null
    : > "$d/bs.go"
    wait "$bs_job"
    out=$(cat "$d/bs.out")
    check "code-admin shadow added after confirm: grant re-confirmed" "$out" "PROMPTED=2"
    same "code-admin shadowed grant binds the project-local registration" "$(_ca_q "SELECT reg_id=(SELECT reg_id FROM code_servers WHERE name='fk' AND scope_project='$projC') FROM code_grants WHERE project='$projC' AND tool_pattern='nuke'")" 1
    same "code-admin nothing bound to the replaced user-scoped registration in projC" "$(_ca_q "SELECT count(*) FROM code_grants WHERE project='$projC' AND reg_id='$old_fk'")" 0
    _ca_pty y "$d/projC" "$BIN" code server remove --project fk >/dev/null

    _ca_cli "$d/projC" grant fk.zap deny >/dev/null
    (CNTCTR_TEST_BARRIER="$d/bc" CNTCTR_TEST_BARRIER_AT=grant-precommit _ca_pty y "$d/projC" "$BIN" code grant fk.zap read > "$d/bc.out") &
    local bc_job=$!
    same "code-admin protected-rule barrier reached after confirmation" "$(_ca_wait_file "$d/bc.ready" && echo yes || echo no)" yes
    _ca_q "UPDATE code_grants SET reason='edited meanwhile' WHERE project='$projC' AND tool_pattern='zap'" >/dev/null
    : > "$d/bc.go"
    wait "$bc_job"
    check "code-admin protected rule edited after confirm: re-confirmed" "$(cat "$d/bc.out")" "PROMPTED=2"
    same "code-admin re-confirmed replace landed" "$(_ca_q "SELECT level||'|'||granted_by FROM code_grants WHERE project='$projC' AND tool_pattern='zap'")" "read|human"
    _ca_cli "$d/projC" revoke fk.zap >/dev/null

    out=$(_ca_pty y "$d/projA" "$BIN" code policy destructive-orchestrator escalate)
    check "code-admin policy back to escalate" "$out" "RC=0"
    out=$(_ca_pty y "$d/projA" "$BIN" code policy destructive-orchestrator bogus)
    refute "code-admin policy rejects unknown value" "$out" "RC=0"

    # 9. CLI replace/revoke of human rules needs TTY y/N, and daemon-independent persistence
    out=$(_ca_cli "$d/projA" revoke fake.write_item); rc=$?
    same "code-admin CLI revoke of human deny without TTY refused" "$((rc != 0))" 1
    same "code-admin human deny survives refused revoke" "$(_ca_q "SELECT count(*) FROM code_grants WHERE tool_pattern='write_item' AND server='fake'")" 1
    out=$(_ca_cli "$d/projA" server remove --project fake); rc=$?
    same "code-admin CLI remove of server with human rules without TTY refused" "$((rc != 0))" 1
    out=$(_ca_pty n "$d/projA" "$BIN" code server remove --project fake)
    check "code-admin CLI remove prompts and PTY n aborts" "$out" "PROMPTED=1"
    same "code-admin PTY n keeps the server" "$(_ca_q "SELECT count(*) FROM code_servers WHERE name='fake'")" 1
    same "code-admin daemon is up before the stop attempts" "$([ -S "$d/code.sock" ] && echo yes || echo no)" yes
    out=$(_ca_pty y "$d/projC" "$d/claude" "'$BIN' code stop")
    check "code-admin code stop refused under a claude ancestor" "$out" "ancestor process 'claude'"
    out=$(CNTCTR_DB="$db" CNTCTR_ROOT="$d" env -u TMUX_PANE -u CNTCTR_PANE -u CNTCTR_CODE_SOCK "$BIN" code stop 2>&1); rc=$?
    same "code-admin code stop refused with CNTCTR_ROOT" "$((rc != 0))" 1
    check "code-admin code stop names CNTCTR_ROOT" "$out" "CNTCTR_ROOT"
    same "code-admin daemon survived refused stops" "$([ -S "$d/code.sock" ] && echo yes || echo no)" yes
    check "code-admin code status stays readable under a claude ancestor" "$(_ca_pty n "$d/projC" "$d/claude" "'$BIN' code status --short")" "RC=0"
    _ca_stop
    same "code-admin daemon stopped" "$([ -S "$d/code.sock" ] && echo yes || echo no)" "no"
    check "code-admin registrations survive daemon stop" "$(_ca_cli "$d/projA" server list)" "fk"
    check "code-admin grants survive daemon stop" "$(_ca_cli "$d/projA" grants fk)" "write_item"
    out=$(_ca_mcp "$orch" code_server '{"action":"list"}')
    check "code-admin MCP list after restart sees registrations" "$(txt "$out")" "fk"
    out=$(_ca_pty y "$d/projA" "$BIN" code server remove --project fake)
    check "code-admin PTY y removes server with human rules" "$out" "RC=0"
    check "code-admin remove reports dropped grants" "$out" "dropped 2 grants in 1 projects"
    _ca_stop
}
if [ "${ONLY:-}" = code-admin ]; then
    code_admin_run
    printf '%d passed, %d failed\n' "$pass" "$fail"
    [ "$fail" -eq 0 ]; exit $?
fi

# ---- Code Mode Phase 7: agent MCP tools (code_find/run/expand/status) and the tools.cntctr.* reverse RPC ----
code_e2e_run() {
    local d="$TMPD/code_e2e" db out rc projA projB fixture py orch orch2 workr i
    mkdir -p "$d/projA" "$d/projB" "$d/nosess"
    db="$d/kb.db"
    fixture="$(pwd)/fixtures/fake-mcp.py"
    py="$(command -v python3)"
    local r
    for r in "$d/projA" "$d/projB"; do
        git -C "$r" init -q
        git -C "$r" -c user.name=T -c user.email=t@example.invalid commit --allow-empty -qm init
    done
    projA=$(CNTCTR_DB="$db" "$BIN" _test-code-kb resolve-cwd "$d/projA")
    projB=$(CNTCTR_DB="$db" "$BIN" _test-code-kb resolve-cwd "$d/projB")

    _ce_cli() { local dir=$1; shift; (cd "$dir" && CNTCTR_DB="$db" env -u TMUX_PANE -u CNTCTR_PANE -u CNTCTR_ROOT -u CNTCTR_CODE_SOCK "$BIN" code "$@" 2>&1); }
    _ce_pane() {
        local p
        p=$(t new-window -d -P -F '#{pane_id}' -c "$2" cat)
        t set -p -t "$p" @cntctr_name "$1"; t set -p -t "$p" @cntctr_harness test; t set -p -t "$p" @cntctr_srv $$
        [ -n "${3:-}" ] && t set -p -t "$p" @cntctr_parent "$3"
        echo "$p"
    }
    _ce_mcp() { CNTCTR_TEST_PANE_ROOT_PID=$$ CNTCTR_DB="$db" call "$@"; }
    # a paneless MCP process (Codex-style) started in <dir>, attributing itself with from=<name>
    # stdin stays open until the answer arrives (a closed stdin cancels the call, as for a real harness that goes away)
    _ce_paneless() {
        local dir=$1 tool=$2 args=$3 from=$4 fifo callj last="" l n=2
        fifo=$(mktemp -u "$TMPD/pfifo.XXXXXX"); mkfifo "$fifo"
        callj=$(jq -nc --arg t "$tool" --argjson a "$args" --arg f "$from" '{jsonrpc:"2.0",id:2,method:"tools/call",params:{name:$t,arguments:($a + {from:$f})}}')
        (cd "$dir" && CNTCTR_DB="$db" CNTCTR_CLAUDE_SESSIONS_DIR="$d/nosess" env -u TMUX_PANE -u CNTCTR_PANE "$BIN" < "$fifo") | {
            exec 3> "$fifo"
            printf '%s\n' "$INIT" "$callj" >&3
            while [ "$n" -gt 0 ] && IFS= read -r l; do last=$l; n=$((n - 1)); done
            exec 3>&-
            printf '%s\n' "$last"
        }
        rm -f "$fifo"
    }
    _ce_isc() { [ "$(iserr "$1")" = true ] && echo err || echo ok; }
    _ce_q() { sq "$db" "$1"; }
    _ce_stop() { _ce_cli "$d" stop >/dev/null 2>&1 || true; }
    _ce_wait_file() { local f=$1 i=0; while [ ! -f "$f" ] && [ "$i" -lt 500 ]; do sleep 0.02; i=$((i + 1)); done; [ -f "$f" ]; }
    _ce_run() { _ce_mcp "$1" code_run "$(jq -nc --arg s "$2" '{script:$s}')"; }
    _ce_j() { printf '%s' "$(txt "$1")" | jq -r "$2" 2>/dev/null; }

    orch=$(_ce_pane orch1 "$d/projA")
    orch2=$(_ce_pane orch2 "$d/projA")
    workr=$(_ce_pane worker1 "$d/projA" "$orch")

    # tools/list as <pane>'s agent (the MCP process stands in for the pane's root, a test hook), and just its code_* names
    _ce_list() { CNTCTR_TEST_PANE_ROOT_PID=$$ CNTCTR_DB="$db" SKIP=1 session "$1" 2 "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | tail -n 1; }
    _ce_names() { printf '%s' "$1" | jq -r '[.result.tools[].name | select(startswith("code_"))] | sort | join(",")'; }
    local orchB; orchB=$(_ce_pane orchb "$d/projB")

    # a real process tree: an MCP server that is a descendant of a pane's root process, with no pane id in its environment
    # (Codex starts MCP servers without TMUX_PANE unless env_vars passes it), finds its pane by walking up and passes is_orchestrator
    _ce_tree() {   # $1 = cwd, $2 = parent pane for a worker or "": the code_* names of tools/list as seen from inside a new pane
        local out="$d/tree.$RANDOM" w
        w=$(t new-window -d -P -F '#{pane_id}' -c "$1" sh -c "sleep 1; { printf '%s\\n' '$INIT' '{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}'; sleep 2; } | env -u TMUX_PANE -u CNTCTR_PANE CNTCTR_CLAUDE_SESSIONS_DIR='$d/nosess' CNTCTR_DB='$db' '$BIN' > '$out.tmp'; mv '$out.tmp' '$out'")
        [ -n "$2" ] && t set -p -t "$w" @cntctr_parent "$2"
        local i=0; while [ ! -s "$out" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
        _ce_names "$(tail -n 1 "$out")"
        t kill-pane -t "$w" 2>/dev/null; rm -f "$out"
    }

    # 0. code tools show only where they work: nothing to use yet, so only an orchestrator sees the admin tools
    same "code-e2e a plain project (no pane, no server) lists none of the 7 code tools" "$(_ce_names "$(rpc "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | tail -n 1)")" ""
    same "code-e2e an orchestrator with no usable server lists only the admin tools" "$(_ce_names "$(_ce_list "$orch")")" "code_grant,code_revoke,code_server"
    same "code-e2e a spawned worker lists no code tool (no server, never admin)" "$(_ce_names "$(_ce_list "$workr")")" ""

    # 1. setup: project-local fake in projA, user-scoped fk; catalogs cached by the CLI probe (no daemon)
    _ce_cli "$d/projA" server add fake --project --cmd "$py" --arg "$fixture" --arg --pid-file --arg "$d/fake.pid" --trust annotations >/dev/null
    _ce_cli "$d/projA" server add fk --cmd "$py" --arg "$fixture" --arg --pid-file --arg "$d/fk.pid" --trust annotations >/dev/null
    _ce_cli "$d/projA" server discover fake >/dev/null
    _ce_cli "$d/projA" server discover fk >/dev/null
    _ce_cli "$d/projA" server add lazy --project --cmd "$py" --arg "$fixture" --trust annotations >/dev/null
    rm -f "$d/fake.pid" "$d/fk.pid"   # the CLI probe started and stopped the servers once; only agent tools count from here
    same "code-e2e daemon is off before any agent tool runs" "$([ -S "$d/code.sock" ] && echo yes || echo no)" "no"
    local watch_sh; watch_sh="$(pwd)/watch.sh"
    _ce_watch() { (cd "$d/projA" && CNTCTR_DB="$db" CNTCTR_BIN="$BIN" env -u TMUX_PANE -u CNTCTR_PANE -u CNTCTR_ROOT -u CNTCTR_CODE_SOCK "$watch_sh" --once 2>&1 | sed -n '/^== code mode ==/,/^== knowledge/p'); }
    out=$(_ce_watch)
    check "code-e2e watch.sh --once has a code mode section" "$out" "== code mode =="
    check "code-e2e watch.sh --once says code: off while the daemon is stopped" "$out" "code: off"
    same "code-e2e watch.sh --once did not start the daemon" "$([ -S "$d/code.sock" ] && echo yes || echo no)" "no"

    # 2. code_find is passive: cached catalogs only, no server started
    out=$(_ce_mcp "$orch" code_find '{"query":"echo"}')
    same "code-e2e code_find ok" "$(_ce_isc "$out")" ok
    check "code-e2e code_find lists fake.echo with class" "$(txt "$out")" "fake.echo [read]"
    check "code-e2e code_find shows denied before any grant" "$(txt "$out")" "denied"
    out=$(_ce_mcp "$orch" code_find '{}')
    check "code-e2e unindexed server is marked as such" "$(txt "$out")" "lazy (unindexed;"
    check "code-e2e unindexed hint names the discover command" "$(txt "$out")" "cntctr code server discover lazy"
    same "code-e2e code_find started no tool server" "$([ -e "$d/fake.pid" ] || [ -e "$d/fk.pid" ] && echo started || echo none)" "none"
    check "code-e2e code status shows 0 servers after find" "$(_ce_cli "$d/projA" status)" "0 servers"
    out=$(_ce_mcp "$orch" code_find '{"query":"fake.echo"}')
    check "code-e2e exact fake.echo hit includes the full inputSchema" "$(txt "$out")" '"msg"'
    out=$(_ce_mcp "$orch" code_find '{"query":"no_such_tool_zz"}')
    check "code-e2e code_find with no hit says so" "$(txt "$out")" "no tools"

    # 3. grants, then an end-to-end run with Promise.all, 100 log lines, previews and paging
    _ce_cli "$d/projA" grant 'fake.*' read >/dev/null
    _ce_cli "$d/projA" grant 'fk.*' read >/dev/null
    _ce_cli "$d/projA" grant 'cntctr.*' read >/dev/null
    # 3a. a granted server shows the 4 agent tools to everyone in the project, the 3 admin tools only to the orchestrator
    out=$(_ce_list "$orch")
    _ce_instr() { CNTCTR_TEST_PANE_ROOT_PID=$$ CNTCTR_DB="$db" SKIP=1 session "$1" 1 "$INIT" | tail -n 1 | jq -r '.result.instructions'; }
    same "code-e2e a process in a pane finds its pane without TMUX_PANE and lists all 7 (orchestrator)" "$(_ce_tree "$d/projA" "")" "code_expand,code_find,code_grant,code_revoke,code_run,code_server,code_status"
    same "code-e2e ...and a worker pane (@cntctr_parent set) lists only the 4 agent tools" "$(_ce_tree "$d/projA" "$orch")" "code_expand,code_find,code_run,code_status"
    local instr; instr=$(_ce_instr "$workr")
    check "code-e2e initialize instructions mention code_find where code mode works" "$instr" "code_find"
    check "code-e2e ...and code_run" "$instr" "code_run"
    check "code-e2e ...and the read grant" "$instr" "read grant"
    same "code-e2e initialize instructions in a plain project do not mention code mode" "$(CNTCTR_DB="$db" session "" 1 "$INIT" | tail -n 1 | jq -r '.result.instructions' | grep -c 'code_find')" 0
    same "code-e2e an orchestrator with a granted server lists all 7 code tools" "$(_ce_names "$out")" "code_expand,code_find,code_grant,code_revoke,code_run,code_server,code_status"
    same "code-e2e a spawned worker lists the 4 agent tools, never the admin tools" "$(_ce_names "$(_ce_list "$workr")")" "code_expand,code_find,code_run,code_status"
    for r in code_find code_run code_expand code_status code_server code_grant code_revoke; do
        same "code-e2e tools/list has $r with from" "$(printf '%s' "$out" | jq -r --arg n "$r" '[.result.tools[] | select(.name == $n) | .inputSchema.properties | has("from")] | first // false')" "true"
    done
    check "code-e2e code_run description states default-deny for read tools" "$(printf '%s' "$out" | jq -r '.result.tools[] | select(.name=="code_run") | .description')" "default-deny"
    check "code-e2e code_find description says it never starts servers" "$(printf '%s' "$out" | jq -r '.result.tools[] | select(.name=="code_find") | .description')" "never starts"
    # 3b. projB has no rule: fk (user-scoped, effective there) is unusable; a cntctr.* grant alone (the built-in server) does not count
    same "code-e2e projB (fk but no rule) lists only the admin tools to its orchestrator" "$(_ce_names "$(_ce_list "$orchB")")" "code_grant,code_revoke,code_server"
    _ce_cli "$d/projB" grant 'cntctr.*' read >/dev/null
    same "code-e2e a cntctr.* grant alone does not make projB's agent tools appear" "$(_ce_names "$(_ce_list "$orchB")")" "code_grant,code_revoke,code_server"
    _ce_q "DELETE FROM code_grants WHERE project='$projB' AND reg_id='cntctr'" >/dev/null
    # hidden is not disabled: a stale call still gets the normal, clear answer
    out=$(_ce_run "$orchB" 'return await tools.fk.ping();')
    same "code-e2e a hidden code_run still answers (denied) in a project with no rule" "$(_ce_isc "$out")" err
    check "code-e2e ...and the denial names the grant command" "$(_ce_j "$out" '.denied')" "cntctr code grant"
    check "code-e2e ...and the all-projects form for a read tool" "$(_ce_j "$out" '.denied')" "--all-projects"
    # P8AB-01: a project-local server cannot take an all-projects rule, so its denial does not suggest one
    _ce_cli "$d/projB" server add locb --project --cmd "$py" --arg "$fixture" --trust annotations >/dev/null
    _ce_cli "$d/projB" server discover locb >/dev/null
    out=$(_ce_run "$orchB" 'return await tools.locb.ping();')
    same "code-e2e a denied call on a project-local server errs" "$(_ce_isc "$out")" err
    check "code-e2e ...and suggests the per-project grant" "$(_ce_j "$out" '.denied')" "cntctr code grant"
    same "code-e2e ...but not --all-projects (the CLI would refuse it)" "$(_ce_j "$out" '.denied' | grep -c -- '--all-projects')" 0
    _ce_cli "$d/projB" server remove locb >/dev/null
    check "code-e2e code_status in an unusable project says what to do and the Codex restart" "$(txt "$(_ce_mcp "$orchB" code_status '{}')")" "Codex session must be restarted"
    out=$(_ce_run "$orch" 'const [p, e] = await Promise.all([tools.fake.ping(), tools.fake.echo({msg:"hi"})]); for (let i = 0; i < 100; i++) console.log("line " + i + " " + "x".repeat(200)); return {p, e, tag: "zzdistinct123"};')
    same "code-e2e code_run succeeds" "$(_ce_isc "$out")" ok
    local run1
    run1=$(_ce_j "$out" '.run_id')
    same "code-e2e code_run returns a run id" "$([ -n "$run1" ] && [ "$run1" != null ] && echo yes || echo no)" yes
    local wout; wout=$(_ce_watch)
    check "code-e2e watch.sh --once shows the running server" "$wout" "fake"
    same "code-e2e Promise.all result carries both calls" "$(_ce_j "$out" '.result | fromjson | .e.msg')" "hi"
    same "code-e2e logs preview is bounded" "$([ "$(_ce_j "$out" '.logs | length')" -le 16384 ] && echo yes || echo no)" yes
    check "code-e2e logs preview points at code_expand" "$(_ce_j "$out" '.logs')" "code_expand"
    for r in result logs calls denied; do
        same "code-e2e response has a $r part" "$(printf '%s' "$(txt "$out")" | jq -r "has(\"$r\")")" "true"
    done
    check "code-e2e fake-mcp now runs (the run started it)" "$([ -e "$d/fake.pid" ] && echo started || echo none)" "started"
    # a second agent in the same project pages the whole log
    local off=0 total=0 got=0 nxt page_n=0
    while :; do
        out=$(_ce_mcp "$orch2" code_expand "$(jq -nc --arg r "$run1" --argjson o "$off" '{run:$r,part:"logs",offset:$o,limit:4000}')")
        same "code-e2e code_expand page ok" "$(_ce_isc "$out")" ok
        total=$(_ce_j "$out" '.total_len')
        got=$((got + $(printf '%s' "$(txt "$out")" | jq -j '.slice' | wc -c | tr -d ' ')))
        nxt=$(_ce_j "$out" '.next_offset')
        page_n=$((page_n + 1))
        [ "$nxt" = null ] || [ -z "$nxt" ] && break
        off=$nxt
        [ "$page_n" -gt 40 ] && break
    done
    same "code-e2e expand pages cover exactly the stored logs" "$got" "$total"
    same "code-e2e logs needed several bounded pages" "$([ "$page_n" -ge 5 ] && echo yes || echo no)" yes
    out=$(_ce_mcp "$orch2" code_expand "$(jq -nc --arg r "$run1" '{run:$r,part:"bogus"}')")
    same "code-e2e code_expand rejects an unknown part" "$(_ce_isc "$out")" err
    out=$(_ce_mcp "$orch2" code_expand '{"run":"r-nope","part":"logs"}')
    same "code-e2e unknown run id is an error" "$(_ce_isc "$out")" err
    check "code-e2e unknown run says not found" "$(txt "$out")" "run r-nope not found"

    # 4. denials: read, write, worker advice
    out=$(_ce_run "$orch" 'return await tools.fake.write_item({title:"t"});')
    same "code-e2e write_item with only a read grant fails" "$(_ce_isc "$out")" err
    check "code-e2e write denial suggests the exact grant command" "$(_ce_j "$out" '.denied')" "cntctr code grant 'fake.write_item' allow"
    out=$(_ce_run "$orch" 'return await tools.lazy.ping();')
    check "code-e2e read denial for a server with no rule suggests grant <server>.* read" "$(_ce_j "$out" '.denied')" "cntctr code grant 'lazy.*' read"
    check "code-e2e denial command starts with cd <quoted root>" "$(_ce_j "$out" '.denied')" "cd '$projA' &&"
    out=$(_ce_run "$workr" 'return await tools.fake.write_item({title:"t"});')
    check "code-e2e worker denial tells the worker to ask its parent" "$(txt "$out")" "ask your parent"
    out=$(_ce_run "$orch" 'return await tools.fake.write_item({title:"t"});')
    refute "code-e2e orchestrator denial does not tell it to ask a parent" "$(txt "$out")" "ask your parent"
    out=$(_ce_run "$orch" 'return await tools.cntctr.code_run({script:"1"});')
    same "code-e2e tools.cntctr.code_run is rejected end to end (daemon virtual table; client allowlist is proved by the rev: checks)" "$(_ce_isc "$out")" err
    out=$(_ce_run "$orch" 'return await tools.cntctr.code_grant({server:"fake",tool_pattern:"x",level:"read"});')
    same "code-e2e tools.cntctr.code_grant is rejected end to end (daemon virtual table; client allowlist is proved by the rev: checks)" "$(_ce_isc "$out")" err
    same "code-e2e that attempt granted nothing" "$(_ce_q "SELECT count(*) FROM code_grants WHERE tool_pattern='x'")" 0
    out=$(_ce_run "$orch" 'return await tools.cntctr.some_fleet_tool({});')
    same "code-e2e fleet tools via tools.cntctr are rejected end to end (daemon virtual table; client allowlist is proved by the rev: checks)" "$(_ce_isc "$out")" err

    # 5. tools.cntctr.* bridge
    out=$(_ce_run "$orch" 'return await tools.cntctr.recall({});')
    same "code-e2e tools.cntctr.recall works once cntctr.* read is granted" "$(_ce_isc "$out")" ok
    out=$(_ce_run "$orch" 'return await tools.cntctr.project({});')
    same "code-e2e tools.cntctr.project({}) succeeds" "$(_ce_isc "$out")" ok
    check "code-e2e project reports the canonical root" "$(_ce_j "$out" '.result')" "$projA"
    out=$(_ce_run "$orch" 'return await tools.cntctr.project({key:"hijack"});')
    same "code-e2e tools.cntctr.project({key}) is rejected" "$(_ce_isc "$out")" err
    same "code-e2e rejected project write changed nothing" "$(_ce_q "SELECT count(*) FROM projects WHERE key='hijack'")" 0
    _ce_cli "$d/projA" grant cntctr.send allow >/dev/null
    out=$(_ce_run "$orch" 'return await tools.cntctr.send({to:"x", text:"hi", wait:true});')
    same "code-e2e tools.cntctr.send wait:true is rejected" "$(_ce_isc "$out")" err
    check "code-e2e send rejection names wait" "$(txt "$out")" "wait"

    # 5b. CODE-AGENT-06: a script reading the board must not consume the orchestrator's mail or move its seen cursor
    local bkey mid seen0 seen1 bo
    bkey=$(txt "$(_ce_mcp "$orch" project '{}')" | sed -n 's/^project \(.*\) (root .*/\1/p')
    same "code-e2e board scope resolved" "$([ -n "$bkey" ] && echo yes || echo no)" yes
    mid=$(sqx "$db" "INSERT INTO posts(scope,sender,text,at) VALUES('$bkey','sender',CAST('[cntctr from=sender id=ab5b0006]
mail for the orchestrator zzmail06
[cntctr end id=ab5b0006]' AS TEXT),strftime('%s','now')); INSERT INTO mail(post,name,pane,task,hooked,presentations,socket) VALUES(last_insert_rowid(),'orch1','','ab5b0006',1,0,''); SELECT last_insert_rowid();")
    sqx "$db" "INSERT INTO posts(scope,sender,text,at) VALUES('$bkey','someone-else','board news zznews06',strftime('%s','now'))" >/dev/null
    seen0=$(t show -sv @cntctr_seen_orch1 2>/dev/null)
    same "code-e2e the mail starts unread" "$(sqx "$db" "SELECT delivered FROM mail WHERE post=$mid")" 0
    for bo in '{}' '{peek:false}' '{peek:0}' '{peek:"no"}'; do
        out=$(_ce_run "$orch" "await tools.cntctr.board($bo); return 1;")
        same "code-e2e script board($bo) ran" "$(_ce_isc "$out")" ok
    done
    out=$(_ce_run "$orch" "await tools.cntctr.board({id:$mid}); return 1;")
    same "code-e2e script board({id}) ran" "$(_ce_isc "$out")" ok
    out=$(_ce_run "$orch" 'await tools.cntctr.board({mode:"mail"}); return 1;')
    same "code-e2e script board({mode:mail}) ran" "$(_ce_isc "$out")" ok
    # name-addressed mail (no pane/socket): board shows it, but the daemon's pane injection (redeliver_for) cannot attach and deliver it behind the test's back
    # delivered=1 is then only ever set by board's read path (kb_mail_finish READ)
    same "code-e2e scripts calling board did not mark the mail read" "$(sqx "$db" "SELECT delivered FROM mail WHERE post=$mid")" 0
    seen1=$(t show -sv @cntctr_seen_orch1 2>/dev/null)
    same "code-e2e scripts calling board left the seen cursor untouched" "$seen1" "$seen0"
    out=$(_ce_mcp "$orch" board '{}')
    check "code-e2e a direct board call afterwards still shows the news" "$(txt "$out")" "zznews06"
    check "code-e2e a direct board call afterwards still shows the mail" "$(txt "$out")" "zzmail06"
    same "code-e2e the direct call (not the scripts) is what marks the mail read" "$(sqx "$db" "SELECT delivered FROM mail WHERE post=$mid")" 1

    # 6. alias mutation cannot move authority off the canonical root
    out=$(_ce_mcp "$orch" project '{"key":"other-alias"}')
    out=$(_ce_run "$orch" 'return await tools.fake.echo({msg:"after-alias"});')
    same "code-e2e grants still apply after the project alias is reassigned" "$(_ce_isc "$out")" ok
    out=$(_ce_mcp "$orch2" code_expand "$(jq -nc --arg r "$run1" '{run:$r,part:"result"}')")
    same "code-e2e expand still finds the run after the alias change" "$(_ce_isc "$out")" ok
    same "code-e2e runs are stored under the canonical root" "$(_ce_q "SELECT count(DISTINCT project) FROM code_runs WHERE project NOT IN ('$projA', '$projB')")" 0

    # 7. paneless from=<victim>: authority is the local cwd, never the victim's project
    out=$(_ce_paneless "$d/projB" code_run '{"script":"return await tools.fk.ping();"}' orch1)
    same "code-e2e paneless run in projB with from=<projA agent> is denied (projB has no grant)" "$(_ce_isc "$out")" err
    check "code-e2e paneless denial is a grant denial for projB" "$(printf '%s' "$out" | jq -r '.result.content[0].text | fromjson | .denied')" "cd '$projB'"
    out=$(_ce_paneless "$d/projB" code_expand "$(jq -nc --arg r "$run1" '{run:$r,part:"result"}')" orch1)
    same "code-e2e paneless expand of projA's run id fails" "$(_ce_isc "$out")" err
    check "code-e2e paneless expand says not found" "$(printf '%s' "$out" | jq -r '.result.content[0].text')" "run $run1 not found"
    _ce_cli "$d/projB" grant 'cntctr.*' read >/dev/null
    _ce_cli "$d/projB" grant cntctr.post allow >/dev/null
    local posts_before
    posts_before=$(_ce_q "SELECT count(*) FROM posts")
    out=$(_ce_paneless "$d/projB" code_run '{"script":"return await tools.cntctr.board({});"}' orch1)
    same "code-e2e paneless tools.cntctr.board is refused" "$(printf '%s' "$out" | jq -r '.result.content[0].text | fromjson | .is_error')" "true"
    check "code-e2e paneless board refusal requires a bound pane" "$(printf '%s' "$out" | jq -r '.result.content[0].text')" "bound pane"
    out=$(_ce_paneless "$d/projB" code_run '{"script":"return await tools.cntctr.post({text:\"cross\"});"}' orch1)
    same "code-e2e paneless tools.cntctr.post is refused" "$(printf '%s' "$out" | jq -r '.result.content[0].text | fromjson | .is_error')" "true"
    same "code-e2e refused post wrote nothing anywhere" "$(_ce_q "SELECT count(*) FROM posts")" "$posts_before"
    out=$(_ce_paneless "$d/projB" code_run '{"script":"return await tools.cntctr.project({});"}' orch1)
    check "code-e2e paneless project runs against the local cwd" "$(printf '%s' "$out" | jq -r '.result.content[0].text | fromjson | .result')" "$projB"

    # 7b. the user-wide read policy (the way to enable a paneless Codex): projB has no rule of its own, a local deny still wins
    _ce_cli "$d/projB" grant 'fk.*' read --all-projects >/dev/null
    same "code-e2e an all-projects read makes projB's agent tools appear" "$(_ce_names "$(_ce_list "$orchB")")" "code_expand,code_find,code_grant,code_revoke,code_run,code_server,code_status"
    same "code-e2e ...for a paneless (Codex-style) server in projB too" "$(_ce_names "$(cd "$d/projB" && CNTCTR_DB="$db" CNTCTR_CLAUDE_SESSIONS_DIR="$d/nosess" SKIP=1 session "" 2 "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | tail -n 1)")" "code_expand,code_find,code_run,code_status"
    out=$(_ce_paneless "$d/projB" code_run '{"script":"return await tools.fk.ping();"}' orch1)
    same "code-e2e all-projects read lets a paneless run use fk in projB" "$(_ce_isc "$out")" ok
    out=$(_ce_paneless "$d/projB" code_run '{"script":"return await tools.fk.ping();"}' "")
    same "code-e2e ...with no from= at all (no agent to name outside tmux)" "$(_ce_isc "$out")" ok
    out=$(_ce_paneless "$d/projB" code_status '{}' "")
    same "code-e2e ...and code_status answers without from=" "$(_ce_isc "$out")" ok
    out=$(_ce_paneless "$d/projB" code_grant '{"server":"fk","tool_pattern":"*","level":"read"}' "")
    check "code-e2e ...but the admin tools still refuse without a pane" "$(printf '%s' "$out" | jq -r '.result.content[0].text')" "no agent pane of its own"
    out=$(_ce_paneless "$d/projB" code_run '{"script":"return await tools.fk.ping();"}' orch1)
    same "code-e2e ...and the run really called fk" "$(printf '%s' "$out" | jq -r '.result.content[0].text | fromjson | .is_error')" "false"
    _ce_cli "$d/projB" grant fk.ping deny >/dev/null
    out=$(_ce_paneless "$d/projB" code_run '{"script":"return await tools.fk.ping();"}' orch1)
    same "code-e2e a project-local deny beats the all-projects read" "$(_ce_isc "$out")" err
    _ce_q "DELETE FROM code_grants WHERE project='$projB' AND tool_pattern='ping'" >/dev/null
    _ce_cli "$d/projB" revoke 'fk.*' --all-projects >/dev/null
    out=$(_ce_paneless "$d/projB" code_run '{"script":"return await tools.fk.ping();"}' orch1)
    same "code-e2e revoking the all-projects rule denies projB again" "$(_ce_isc "$out")" err
    same "code-e2e ...and hides projB's agent tools again" "$(_ce_names "$(_ce_list "$orchB")")" "code_grant,code_revoke,code_server"

    # 7c. every server or grant change, from the CLI or MCP, wakes a running session (list_changed)
    local lcfifo="$d/lc.fifo" lcout="$d/lc.out" lcn=0
    mkfifo "$lcfifo"
    (CNTCTR_TEST_PANE_ROOT_PID=$$ CNTCTR_DB="$db" TMUX_PANE=$orchB "$BIN" < "$lcfifo" > "$lcout" 2>/dev/null) &
    local lcpid=$!
    exec 8> "$lcfifo"
    printf '%s\n' "$INIT" >&8
    _ce_lc() {   # <label> <command...>: run it, expect one more list_changed
        local label=$1 want i=0; shift
        want=$((lcn + 1))
        "$@" >/dev/null 2>&1
        while [ "$(grep -c 'notifications/tools/list_changed' "$lcout" 2>/dev/null)" -lt "$want" ] && [ "$i" -lt 250 ]; do sleep 0.02; i=$((i + 1)); done
        same "code-e2e list_changed fires on $label" "$([ "$(grep -c 'notifications/tools/list_changed' "$lcout" 2>/dev/null)" -ge "$want" ] && echo yes || echo no)" yes
        lcn=$(grep -c 'notifications/tools/list_changed' "$lcout" 2>/dev/null)
    }
    for i in $(seq 100); do [ -s "$lcout" ] && break; sleep 0.05; done
    lcn=$(grep -c 'notifications/tools/list_changed' "$lcout" 2>/dev/null || true)
    _ce_lc "a CLI server add" _ce_cli "$d/projB" server add ntf --project --cmd "$py" --arg "$fixture" --trust annotations
    _ce_lc "a CLI grant" _ce_cli "$d/projB" grant 'ntf.*' read
    _ce_lc "a CLI all-projects grant" _ce_cli "$d/projB" grant 'fk.*' read --all-projects
    _ce_lc "a CLI all-projects revoke" _ce_cli "$d/projB" revoke 'fk.*' --all-projects
    _ce_lc "an MCP code_grant" _ce_mcp "$orchB" code_grant '{"server":"ntf","tool_pattern":"ping","level":"deny"}'
    _ce_lc "an MCP code_revoke" _ce_mcp "$orchB" code_revoke '{"server":"ntf","tool_pattern":"ping"}'
    _ce_lc "a CLI revoke" _ce_cli "$d/projB" revoke 'ntf.*'
    _ce_lc "an MCP code_server remove" _ce_mcp "$orchB" code_server '{"action":"remove","name":"ntf"}'
    exec 8>&-
    wait "$lcpid" 2>/dev/null
    rm -f "$lcfifo"

    # 8. expiry and recall isolation
    out=$(_ce_run "$orch" 'return {tag: "zzdistinct123"};')
    local run2
    run2=$(_ce_j "$out" '.run_id')
    out=$(_ce_mcp "$orch" recall '{"query":"zzdistinct123"}')
    refute "code-e2e recall never sees code_runs" "$(txt "$out")" "zzdistinct123"
    _ce_q "UPDATE code_runs SET expires=0 WHERE id='$run2'"
    out=$(_ce_mcp "$orch" code_expand "$(jq -nc --arg r "$run2" '{run:$r,part:"result"}')")
    same "code-e2e expired run is an error" "$(_ce_isc "$out")" err
    check "code-e2e expired run says so" "$(txt "$out")" "run $run2 has expired"

    # 9. wall timeout is clamped and enforced per request
    out=$(_ce_mcp "$orch" code_run "$(jq -nc '{script:"return await tools.fake.sleep_tool({ms:60000});",timeout:2}')")
    same "code-e2e a 2 s timeout stops a long call" "$(_ce_isc "$out")" err

    # 10. cancellation mid-run cleans up the reverse workers (ASan would report a UAF)
    local fifo="$d/cancel.fifo" ready="$d/cancel.ready" go="$d/cancel.go" sess_pid sess_rc
    rm -f "$ready" "$go"
    mkfifo "$fifo"
    CNTCTR_TEST_PANE_ROOT_PID=$$ CNTCTR_DB="$db" TMUX_PANE="$orch" "$BIN" < "$fifo" > "$d/cancel.out" 2> "$d/cancel.err" & sess_pid=$!
    exec 7> "$fifo"
    printf '%s\n' "$INIT" >&7
    local cancel_call
    cancel_call=$(jq -nc --arg rf "$ready" --arg gf "$go" '{jsonrpc:"2.0",id:5,method:"tools/call",params:{name:"code_run",arguments:{script:("const r = tools.cntctr.recall({}); const s = tools.fake.sleep_tool({ms:60000, ready_file:" + ($rf|tojson) + ", go_file:" + ($gf|tojson) + "}); return await Promise.all([r, s]);")}}}')
    printf '%s\n' "$cancel_call" >&7
    same "code-e2e long run reached the tool server" "$(_ce_wait_file "$ready" && echo yes || echo no)" yes
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":5}}' >&7
    : > "$go"
    exec 7>&-
    wait "$sess_pid"; sess_rc=$?
    same "code-e2e cancelled run: the MCP process exits cleanly" "$sess_rc" 0
    refute "code-e2e cancelled run: no sanitizer report" "$(cat "$d/cancel.err")" "Sanitizer"
    rm -f "$fifo"

    # 11. code_status: daemon, running server, memory, this project's grants
    out=$(_ce_mcp "$orch" code_status '{}')
    same "code-e2e code_status ok" "$(_ce_isc "$out")" ok
    check "code-e2e code_status names the daemon pid" "$(txt "$out")" "pid "
    check "code-e2e code_status lists the running fake server" "$(txt "$out")" "fake"
    check "code-e2e code_status shows memory" "$(txt "$out")" "MB"
    check "code-e2e code_status lists this project's grants" "$(txt "$out")" "fake.* access read"
    refute "code-e2e code_status never prints env values or other projects' roots" "$(txt "$out")" "$projB"
    _ce_stop

    # 12. reverse-RPC handler (no daemon): allowlist before dispatch, identity, bounded concurrency, late replies
    _ce_rev() { CNTCTR_DB="$db" CNTCTR_TEST_PANE_ROOT_PID=$$ "$BIN" _test-code-rev "$@" 2>&1; }
    out=$(_ce_rev "$orch" code_run '{"script":"1"}')
    check "code-e2e rev: code_run is not on the allowlist" "$out" "not allowed"
    out=$(_ce_rev "$orch" code_grant '{}')
    check "code-e2e rev: code_grant is not on the allowlist" "$out" "not allowed"
    out=$(_ce_rev "$orch" some_fleet_tool '{}')
    check "code-e2e rev: fleet tools are not on the allowlist" "$out" "not allowed"
    out=$(_ce_rev "$orch" project '{"key":"hijack"}')
    check "code-e2e rev: project with a key is rejected" "$out" "get-only"
    for kv in '{"key":""}' '{"key":null}' '{"key":false}' '{"key":0}' '{"key":"x"}'; do
        out=$(_ce_rev "$orch" project "$kv")
        check "code-e2e rev: project with key present ($kv) is refused as get-only" "$out" "get-only"
    done
    _ce_q "INSERT OR REPLACE INTO projects(root,key) VALUES('$projA','alias-keep')" >/dev/null
    for kv in '{"key":""}' '{"key":null}' '{"key":"clobber"}'; do _ce_rev "$orch" project "$kv" >/dev/null; done
    same "code-e2e rev: refused project calls left the project alias untouched" "$(_ce_q "SELECT key FROM projects WHERE root='$projA'")" "alias-keep"
    out=$(_ce_rev "$orch" project '{}')
    same "code-e2e rev: project with no key still works" "$(printf '%s' "$out" | jq -r '.ok')" "true"
    out=$(_ce_run "$orch" 'return await tools.cntctr.project({key:""});')
    same "code-e2e end to end project({key:\"\"}) is rejected" "$(_ce_isc "$out")" err
    same "code-e2e end to end project({key:\"\"}) left the alias untouched" "$(_ce_q "SELECT key FROM projects WHERE root='$projA'")" "alias-keep"
    # CODE-AGENT-06: a script-supplied peek never reaches the board tool, and the handler's own peek is what keeps it read-only
    # the one-shot rev caller resolves its own project (the alias set above) and takes its pane's @cntctr_name: address the mail there, by name, so no pane can attach it
    local rk
    rk=$(_ce_rev "$orch" project '{}' | sed -n 's/.*project \([^ ]*\) (root.*/\1/p')
    _ce_q "UPDATE posts SET scope='$rk' WHERE rowid=$mid; UPDATE mail SET name='orch1', pane='', socket='', state='pending', delivered=0, shown=0, lease_until=0 WHERE post=$mid" >/dev/null
    out=$(_ce_rev "$orch" board "{\"id\":$mid,\"peek\":false}")
    same "code-e2e rev: board through the handler answers" "$(printf '%s' "$out" | jq -r '.ok')" "true"
    same "code-e2e rev: board with a script-supplied peek:false still does not mark mail read" "$(_ce_q "SELECT delivered FROM mail WHERE post=$mid")" 0
    out=$(_ce_rev "$orch" send '{"to":"x","text":"hi","wait":true}')
    check "code-e2e rev: send wait:true is rejected" "$out" "wait"
    for r in board post send reply; do
        out=$(_ce_rev - "$r" '{"to":"x","text":"t","id":"1"}')
        check "code-e2e rev: paneless $r needs a bound pane" "$out" "bound pane"
    done
    out=$(cd "$d/projB" && _ce_rev - project '{}')
    check "code-e2e rev: paneless project uses the local cwd" "$(printf '%s' "$out" | jq -r '.result')" "$projB"
    out=$(cd "$d/projB" && _ce_rev "$orch" project '{"from":"orch2"}')
    check "code-e2e rev: a bound pane's project is the pane's, not the process cwd" "$(printf '%s' "$out" | jq -r '.result')" "$projA"
    out=$(_ce_rev "$orch" burst 10)
    check "code-e2e rev: burst of 10 all answered" "$out" "replies=10"
    check "code-e2e rev: at most 4 workers ran at once" "$out" "peak=4"
    out=$(_ce_rev "$orch" late 6)
    check "code-e2e rev: replies after the connection closed do not touch freed state" "$out" "late=ok"
    check "code-e2e rev: nothing leaked past the owner's release" "$out" "replies=6"
}
if [ "${ONLY:-}" = code-e2e ]; then
    code_e2e_run
    printf '%d passed, %d failed\n' "$pass" "$fail"
    [ "$fail" -eq 0 ]; exit $?
fi

if [ "${ONLY:-}" != "m3" ]; then

u28_run
u22_run
u23_run
u24_run
code_kb_run
code_js_run
code_daemon_run
code_mcp_run
code_admin_run
code_e2e_run

# ---- MCP protocol ----
out=$(rpc "$INIT")
check "initialize echoes protocol version" "$out" '"protocolVersion":"2025-06-18"'
check "initialize names the server" "$out" '"serverInfo":{"name":"cntctr"'
out=$(rpc '{"jsonrpc":"2.0","id":7,"method":"ping"}')
same "ping" "$out" '{"jsonrpc":"2.0","id":7,"result":{}}'
out=$(rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
for tool in spawn send gather reply list kill note recall read forget project distill post board tool_define tool_verdict tool_revoke use code_find code_run code_expand code_status code_server code_grant code_revoke; do
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
stale_name_run
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
    '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send","arguments":{"to":"b","text":"first of two","wait":true,"timeout":10,"cross":true}}}' \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"send","arguments":{"to":"c","text":"second of two","wait":true,"timeout":10,"cross":true}}}' \
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
daemon_send '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"gather","arguments":{"tasks":[{"kind":"send","to":"ga","text":"cancel one","cross":true},{"kind":"send","to":"gb","text":"cancel two","cross":true}],"timeout":30}}}'
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
f10_run

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
{ printf '%s\n' "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send","arguments":{"to":"b","text":"cancel me","wait":true,"timeout":30,"cross":true}}}'
  sleep 1
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2}}'
  sleep 1
} | TMUX_PANE=$R "$BIN" >/dev/null &
expect_screen "cancellable send delivered" "$B" "cancel me"
sleep 1.5
call "$B" reply "{\"id\":\"$(lastid "$B")\",\"text\":\"answer after cancel\"}" >/dev/null
wait
expect_screen "reply to cancelled send lands in sender pane" "$R" "answer after cancel"

printf '%s\n' "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send","arguments":{"to":"b","text":"leader leaves","wait":true,"timeout":30,"cross":true}}}' |
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
out=$(call "$L" spawn '{"harness":"agy","name":"m3","task":"x","model":"gemini-4-neon-high","effort":"high"}')
expect_screen "agy gets model and effort" "$(txt "$out" | sed 's/.* in \(%[0-9]*\) .*/\1/')" "flags:  --model gemini-4-neon-high --effort high --settings"
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
expect_screen "codex standard task" "$(pane_of "$out")" "flags:  -m gpt-6.2-sol -c model_reasoning_effort=\"medium\""
out=$(call "$L" spawn '{"harness":"codex","name":"r5r","task":"Review the retry loop."}')
expect_screen "codex review task" "$(pane_of "$out")" "flags:  -m gpt-6.2-sol -c model_reasoning_effort=\"high\""
out=$(call "$L" spawn '{"harness":"codex","name":"r5h","task":"Design the architecture for cross-machine sync."}')
expect_screen "codex hard task" "$(pane_of "$out")" "flags:  -m gpt-6.2-sol -c model_reasoning_effort=\"high\""
out=$(CNTCTR_ROUTE_CODEX_HARD=gpt-9-sol:xhigh call "$L" spawn '{"harness":"codex","name":"r5o","task":"x","tier":"hard"}')
expect_screen "route env overrides model and effort" "$(pane_of "$out")" "flags:  -m gpt-9-sol -c model_reasoning_effort=\"xhigh\""
out=$(CNTCTR_ROUTE_CODEX_HARD=gpt-9-sol call "$L" spawn '{"harness":"codex","name":"r5p","task":"x","tier":"hard"}')
expect_screen "route env model alone keeps the table effort" "$(pane_of "$out")" "flags:  -m gpt-9-sol -c model_reasoning_effort=\"high\""
out=$(CNTCTR_ROUTE_CODEX_HARD="gpt-9-sol:evil;x" call "$L" spawn '{"harness":"codex","name":"r5q","task":"x","tier":"hard"}')
expect_screen "route env with a bad effort is ignored whole" "$(pane_of "$out")" "flags:  -m gpt-6.2-sol -c model_reasoning_effort=\"high\""
out=$(CNTCTR_ROUTE_CODEX_HARD="gpt-9-sol;" call "$L" spawn '{"harness":"codex","name":"r5u","task":"x","tier":"hard"}')
expect_screen "route env model with a tmux separator is ignored" "$(pane_of "$out")" "flags:  -m gpt-6.2-sol -c model_reasoning_effort=\"high\""
long130=$(printf 'm%.0s' $(seq 1 130))
out=$(CNTCTR_ROUTE_CODEX_HARD="$long130" call "$L" spawn '{"harness":"codex","name":"r5v","task":"x","tier":"hard"}')
expect_screen "route env model over 127 bytes is ignored, not cut" "$(pane_of "$out")" "flags:  -m gpt-6.2-sol -c model_reasoning_effort=\"high\""
out=$(call "$L" spawn '{"harness":"agy","name":"r6b","task":"rename foo to bar"}')
expect_screen "agy light task stays on medium" "$(pane_of "$out")" "flags:  --model gemini-4-hydrogen-medium --effort medium"
out=$(call "$L" spawn '{"harness":"agy","name":"r6","task":"Design the architecture for the new sync layer."}')
expect_screen "agy complex task uses Gemini 4 Neon" "$(pane_of "$out")" "flags:  --model gemini-4-neon-high --effort high --settings"
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
remote_repo="y-$(basename "$TMPD")"
git -C "$TMPD/repo" remote add origin "git@GitHub.com:X/$remote_repo.git"
KR=$(t new-window -d -n kr -c "$TMPD/repo" -P -F '#{pane_id}' cat)
t set -p -t "$KR" @cntctr_name kr
check "project key from the origin remote" "$(txt "$(call "$KR" project '{}')")" "project github.com/X/$remote_repo (root "
git -C "$TMPD/repo" remote set-url origin "https://github.com/X/$remote_repo.git/"
check "https remote normalizes the same" "$(txt "$(call "$KR" project '{}')")" "project github.com/X/$remote_repo (root "
same "project override" "$(txt "$(call "$KR" project '{"key":"foo"}')" | cut -d' ' -f1-2)" "project foo"
same "override persists" "$(txt "$(call "$KR" project '{}')" | cut -d' ' -f1-2)" "project foo"
call "$KR" project '{"key":""}' >/dev/null
check "empty key removes the override" "$(txt "$(call "$KR" project '{}')")" "project github.com/X/$remote_repo"
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
out=$(CNTCTR_DB=/nonexistent/x.db call "$KA" send '{"to":"kb","text":"mail requires a durable store"}')
same "send reports an unavailable durable mail store" "$(txt "$out")" "could not store message for kb"
refute "unavailable store leaves the pane clear of uncharged mail" "$(screen "$KB")" "mail requires a durable store"
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

# Mail for an author with no pane keeps the reviewer's socket: a same-name agent on another socket never sees it.
FV=$(newpane fv)
row "$PK" pvmail 1 pending pvauthor "pane-less author" "$FV"
call "$FV" tool_verdict '{"name":"pvmail","version":1,"verdict":"approve"}' >/dev/null
pvid=$(sqx "$CNTCTR_DB" "SELECT post FROM mail WHERE name='pvauthor' ORDER BY post DESC LIMIT 1")
same "pane-less mail has no pane and keeps the reviewer's socket" \
    "$(sqx "$CNTCTR_DB" "SELECT quote(pane)||'|'||socket FROM mail WHERE post=$pvid")" "''|$(t display -p '#{socket_path}')"
t2 new-session -d -s pvother -c "$PWD" cat
pv_sock=$(t2 display -p '#{socket_path}')
pv_other=$(t2 display -p '#{pane_id}')
t2 set -p -t "$pv_other" @cntctr_name pvauthor
same "same-name caller on another socket cannot list pane-less mail" "$(txt "$(TMUX="$pv_sock,0,0" call_raw "$pv_other" board '{"mode":"mail"}')")" "0 total mail"
same "same-name caller on another socket cannot read pane-less mail" "$(txt "$(TMUX="$pv_sock,0,0" call_raw "$pv_other" board "{\"id\":$pvid}")")" "mail not found"
same "other socket leaves pane-less mail pending" "$(mstate "$pvid")" "pending/0/0"
t2 kill-server
FW=$(newpane pvauthor)
check "same-name caller on the original socket lists pane-less mail" "$(txt "$(call "$FW" board '{"mode":"mail"}')")" "id=$pvid"
check "same-name caller on the original socket reads pane-less mail" "$(txt "$(call "$FW" board "{\"id\":$pvid}")")" "pvmail"
same "original socket finishes pane-less mail" "$(sqx "$CNTCTR_DB" "SELECT delivered FROM mail WHERE post=$pvid")" "1"

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
python3 - "$TMPD/net-port" <<'PYTHON' &
import socket
import sys
import time

with socket.socket() as server:
    server.bind(("127.0.0.1", 0))
    server.listen()
    with open(sys.argv[1], "w") as port:
        print(server.getsockname()[1], file=port)
    time.sleep(30)
PYTHON
LP=$!
for _ in $(seq 40); do [ -s "$TMPD/net-port" ] && break; sleep 0.05; done
net_port=$(cat "$TMPD/net-port" 2>/dev/null)
deft neto "nc -z -w1 127.0.0.1 $net_port && echo open"
same "network denied by default" "$(iserr "$(use neto)")" true
deft neta "nc -z -w1 127.0.0.1 $net_port && echo open" '{"net":true}'
same "declared net works" "$(txt "$(use neta)")" open
kill "$LP" 2>/dev/null
wait "$LP" 2>/dev/null
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
FM2=$(newpane known2); t set -p -t "$FM2" @cntctr_harness claude; t set -p -t "$FM2" @cntctr_model claude-sonnet-5-5
same "a collision on one agy tier tries the other agy tiers first" "$(CNTCTR_ROUTE_AGY_REVIEW=claude-sonnet-5-5 publish "$FM2" fm2 'echo f')" "fm2 v1 pending"
waitfor "fm2 approved" '[ "$(st fm2)" = active ]'
same "the reviewer stays on agy with another model" "$(sq "$CNTCTR_DB" "select reviewer_model from tools where name='fm2'")" gemini-4-neon-high
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
if [ "$(st lcb1)$(st lcb2)$(st lcb3)" = activeactiveactive ]; then wait "$lc2"
else kill "$lc2" 2>/dev/null; wait "$lc2" 2>/dev/null; fi
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

# T2: initialize reports serverInfo.version 0.5.5; --version prints the same
out=$(rpc "$INIT" | tail -n 1)
check "T2 initialize reports serverInfo.version 0.5.5" "$out" '"serverInfo":{"name":"cntctr","version":"0.5.5"}'
ver=$("$BIN" --version 2>&1)
check "T2 --version prints 0.5.5" "$ver" "cntctr 0.5.5"

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

# T12b (CODE-AGENT-07): a fleet tool's board read peeks (mail stays unread, seen cursor stays) even if it passes peek:false;
# a direct board call with peek:true is not a peek (stripped), so it consumes. Name-addressed mail: no pane can attach and deliver it behind the test.
m3_def12b='{"name":"m3_t12b","description":"reads board, then returns nothing","input_schema":{"type":"object"},"interpreter":"sh","script":"cntctr call board \"{\\\"peek\\\":false}\" >/dev/null; echo done"}'
call "$M3_P12_B" tool_define "$m3_def12b" >/dev/null
m3_key12=$(txt "$(call "$M3_P12_B" project '{}')" | sed -n 's/^project \(.*\) (root .*/\1/p')
m3_mid12=$(sqx "$CNTCTR_DB" "INSERT INTO posts(scope,sender,text,at) VALUES('$m3_key12','sender',CAST('[cntctr from=sender id=ab120012]
mail zzmail12
[cntctr end id=ab120012]' AS TEXT),strftime('%s','now')); INSERT INTO mail(post,name,pane,task,hooked,presentations,socket) VALUES(last_insert_rowid(),'m3_p12_b','','ab120012',1,0,''); SELECT last_insert_rowid();")
m3_seen12=$(t show -sv @cntctr_seen_m3_p12_b 2>/dev/null)
call "$M3_P12_B" use '{"tool":"m3_t12b"}' >/dev/null
same "T12b fleet board read leaves the mail unread" "$(sqx "$CNTCTR_DB" "SELECT delivered FROM mail WHERE post=$m3_mid12")" 0
same "T12b fleet board read leaves the seen cursor" "$(t show -sv @cntctr_seen_m3_p12_b 2>/dev/null)" "$m3_seen12"
call "$M3_P12_B" board '{"peek":true}' >/dev/null
same "T12b a direct board call with peek:true still consumes the mail" "$(sqx "$CNTCTR_DB" "SELECT delivered FROM mail WHERE post=$m3_mid12")" 1

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

# T29: byte budget of built-in tools/list plus instructions. A plain project (no usable code server, not an orchestrator) keeps the
# original budget; an orchestrator in a project with a granted server also sees the 7 code tools, so it gets its own.
tools_bytes=$(rpc "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | tail -n 1 | jq -c '.result.tools' | wc -c | tr -d ' ')
guide_bytes=$(rpc "$INIT" | tail -n 1 | jq -r '.result.instructions' | awk '{print} /^Knowledge index/{exit}' | wc -c | tr -d ' ')
total_bytes=$((tools_bytes + guide_bytes))
[ "$total_bytes" -le 13455 ] && ok_ || bad "T29 byte budget holds" "got $total_bytes > 13455"
same "T29 the plain project lists none of the 7 code tools" "$(rpc "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | tail -n 1 | jq -r '[.result.tools[].name | select(startswith("code_"))] | length')" 0
M3_P29=$(m3_newpane m3_p29)
M3_ROOT29=$(CNTCTR_DB="$CNTCTR_DB" "$BIN" _test-code-kb resolve-cwd "$M3_DIR")
sqx "$CNTCTR_DB" "INSERT INTO code_servers(scope_project,name,reg_id,command,created_at) VALUES('$M3_ROOT29','t29srv','t29reg','/bin/echo',0); INSERT INTO code_grants(project,reg_id,server,tool_pattern,kind,level,granted_by,granted_at) VALUES('$M3_ROOT29','t29reg','t29srv','*','access','read','human',0)" >/dev/null
orch29_list=$(CNTCTR_TEST_PANE_ROOT_PID=$$ SKIP=1 session "$M3_P29" 2 "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | tail -n 1)
orch29_guide=$(CNTCTR_TEST_PANE_ROOT_PID=$$ SKIP=1 session "$M3_P29" 1 "$INIT" | tail -n 1 | jq -r '.result.instructions' | awk '{print} /^Knowledge index/{exit}' | wc -c | tr -d ' ')
sqx "$CNTCTR_DB" "DELETE FROM code_grants WHERE reg_id='t29reg'; DELETE FROM code_servers WHERE reg_id='t29reg'" >/dev/null
same "T29 an orchestrator with a granted server lists all 7 code tools" "$(printf '%s' "$orch29_list" | jq -r '[.result.tools[].name | select(startswith("code_"))] | length')" 7
orch29_total=$(( $(printf '%s' "$orch29_list" | jq -c '.result.tools' | wc -c | tr -d ' ') + orch29_guide ))
[ "$orch29_total" -le 16430 ] && ok_ || bad "T29 orchestrator byte budget holds" "got $orch29_total > 16430"

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
out37a=$(txt "$(call "" list "{\"from\":\"$U37\"}")")   # from= is for a caller without a pane (Codex); with a pane it is ignored
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

if BIN="$BIN" bash "$(dirname "$0")/test-cli.sh"; then ok_; else bad 'standalone CLI checks'; fi
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
