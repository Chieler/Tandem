#!/bin/bash
# End-to-end tests for cntctr. Runs against a private tmux server, never yours.
set -u
BIN=$(cd "$(dirname "${BIN:-./cntctr}")" && pwd)/$(basename "${BIN:-./cntctr}")
TMPD=$(mktemp -d)
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"test"}}}'
mkdir "$TMPD/bin" "$TMPD/home"
export HOME="$TMPD/home"   # fleet tools keep their cache under ~/.cache
export BIN INIT CNTCTR_ENTER_DELAY_MS=50 LC_ALL=en_US.UTF-8 PATH="$TMPD/bin:$PATH" CNTCTR_DB="$TMPD/kb.db" CNTCTR_MEM_URL=
unset TMUX_PANE

t() { tmux -L cntctr-test -f /dev/null "$@"; }
t kill-server 2>/dev/null
t new-session -d -s test -x 200 -y 50 cat
export TMUX="$(t display -p '#{socket_path}'),0,0"
trap 't kill-server 2>/dev/null; sqlite3 "$CNTCTR_DB" "select review_root from tools where review_root > \"\"" 2>/dev/null | xargs rm -rf; rm -rf "$TMPD"' EXIT

pass=0 fail=0
ok_() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$@"; }
same() { [ "$2" = "$3" ] && ok_ || bad "$1" "  want: $3" "  got:  $2"; }
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
call() {
    SKIP=1 session "$1" 2 "$INIT" "$(printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$2" "$3")" | tail -n 1
}
txt() { printf '%s' "$1" | jq -r '.result.content[0].text'; }
iserr() { printf '%s' "$1" | jq -r '.result.isError'; }

screen() { t capture-pane -p -J -t "$1"; }
# expect_screen <description> <pane> <text>: pass once the pane shows <text> (waits up to 5 s)
expect_screen() {
    for _ in $(seq 50); do screen "$2" | grep -qF -- "$3" && { ok_; return; }; sleep 0.1; done
    bad "$1" "  pane $2 never showed: $3"
}
# lastid <pane>: id of the newest message envelope shown in the pane
lastid() { screen "$1" | sed -n 's/.*\[cntctr from=[^ ]* id=\([0-9a-f]\{8\}\)\].*/\1/p' | tail -n 1; }
# newpane <name> [command...]: open a tagged window running cat (or <command>), print its pane id
newpane() {
    local name=$1 pane; shift
    [ $# -gt 0 ] || set -- cat
    pane=$(t new-window -d -n "$name" -P -F '#{pane_id}' "$@")
    t set -p -t "$pane" @cntctr_name "$name"
    t set -p -t "$pane" @cntctr_harness test
    echo "$pane"
}

# ---- MCP protocol ----
out=$(rpc "$INIT")
check "initialize echoes protocol version" "$out" '"protocolVersion":"2025-06-18"'
check "initialize names the server" "$out" '"serverInfo":{"name":"cntctr"'
out=$(rpc '{"jsonrpc":"2.0","id":7,"method":"ping"}')
same "ping" "$out" '{"jsonrpc":"2.0","id":7,"result":{}}'
out=$(rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
for tool in spawn send gather reply list kill note recall read forget project distill post board tool_define tool_verdict tool_revoke use; do check "tools/list has $tool" "$out" "\"name\":\"$tool\""; done
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

# ---- send ----
out=$(call "$A" send '{"to":"b","text":"hello from a"}')
check "send returns an id" "$(txt "$out")" "sent id="
id=$(txt "$out" | sed 's/sent id=//')
expect_screen "envelope header" "$B" "[cntctr from=a id=$id]"
expect_screen "message text" "$B" "hello from a"
expect_screen "reply hint" "$B" "[when done: call the reply tool of the cntctr MCP server with id=$id and your answer, plus insights=[...] with durable facts other agents should know; it is an MCP tool, not a shell command. Your agent name is b: pass from=b when you call send, spawn or kill]"
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
K=$(newpane bs sh -c 'while read l; do echo "GOT:$l"; done')
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
same "send to missing agent" "$(txt "$out")" "agent nope not found"
out=$(rpc "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send","arguments":{"to":"b","text":"x"}}}' | tail -n 1)
check "send outside tmux says to pass from" "$(txt "$out")" "pass from="

# ---- from: a shared server (Codex) names its caller ----
# nopane <tool> <args-json>: run a tool from a process that is in no pane
nopane() { rpc "$INIT" "$(printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$1" "$2")" | tail -n 1; }
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
same "reply to closed sender" "$(txt "$out")" "sender gone"
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
        for _ in $(seq 100); do [ "$(wc -l < "$f.out")" -ge 2 ] && break; sleep 0.1; done
        R=$(sed -n 2p "$f.out" | jq -r '.result.content[0].text')
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
expect_screen "agy gets model and effort" "$(txt "$out" | sed 's/.* in \(%[0-9]*\) .*/\1/')" "flags:  --model gemini-3.8-flash-high --effort high -i"
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
expect_screen "codex light task" "$(pane_of "$out")" "flags:  -m gpt-6-luna -c model_reasoning_effort=\"low\""
out=$(call "$L" spawn '{"harness":"agy","name":"r6b","task":"rename foo to bar"}')
expect_screen "agy light task stays on medium" "$(pane_of "$out")" "flags:  --model gemini-3.8-flash-medium --effort medium -i"
out=$(call "$L" spawn '{"harness":"agy","name":"r6","task":"Design the architecture for the new sync layer."}')
expect_screen "agy always uses Gemini 3.8" "$(pane_of "$out")" "flags:  --model gemini-3.8-flash-high --effort high -i"
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
same "note without summary" "$(txt "$(call "$KA" note '{"layer":"insight","title":"x"}')")" "note needs layer (insight, skill or doc), title and summary"
same "note cannot write history" "$(txt "$(call "$KA" note '{"layer":"history","title":"x","summary":"y"}')")" "note needs layer (insight, skill or doc), title and summary"

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
out=$(call "$KA" post '{"text":"heads up: main is broken"}')
check "post reaches agents in the project" "$(txt "$out")" "posted to "
check "post names who it reached" "$(txt "$out")" "pb"
check "post reports agents it could not reach" "$(txt "$out")" "skipped g (g awaiting permission prompt"
expect_screen "post arrives in another agent's pane" "$PB" "[cntctr board from=ka] heads up: main is broken"
refute "post never reaches another project" "$(screen "$KR")" "heads up"
sleep 0.3
refute "post is not echoed to the poster" "$(screen "$KA")" "heads up"
call "$PB" post '{"text":"fixed in abc123"}' >/dev/null
out=$(txt "$(call "$KA" board '{}')")
check "board shows posts" "$out" "ka: heads up: main is broken"
same "board is oldest first" "$(printf '%s\n' "$out" | tail -n 1 | cut -d' ' -f3-)" "pb: fixed in abc123"
same "board limit" "$(txt "$(call "$KA" board '{"limit":1}')" | cut -d' ' -f3-)" "pb: fixed in abc123"
refute "board of another project" "$(txt "$(call "$KR" board '{}')")" "heads up"
same "post needs text" "$(txt "$(call "$KA" post '{}')")" "post needs 'text'"
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
row() { sqlite3 "$CNTCTR_DB" "INSERT INTO tools(project,name,version,status,author,description,input_schema,interpreter,script,reviewer_pane) VALUES ('$1','$2',$3,'$4','$5','$6','{\"type\":\"object\"}','sh','true','$7')"; }
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
same "one draft per author and name" "$(sqlite3 "$CNTCTR_DB" "SELECT count(*) FROM tools WHERE name='dup' AND author='fa'")" "1"
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
sqlite3 "$CNTCTR_DB" "DELETE FROM tools WHERE project='$PK' AND name='ord'"
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
sqlite3 "$CNTCTR_DB" "UPDATE tools SET verdict_reason='bad idea' WHERE name='rv' AND project='$RK'"
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
check "stdout capped" "$(txt "$(use big)" | wc -c)" 262
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
sqlite3 "$CNTCTR_DB" "UPDATE tools SET script='exit 3' WHERE name='cntf' AND project='$RK'"
use cnt >/dev/null; use cntf >/dev/null
same "good calls are counted" "$(sqlite3 "$CNTCTR_DB" "SELECT calls || '/' || failures FROM tools WHERE name='cnt' AND project='$RK'")" "1/0"
same "failed calls are counted" "$(sqlite3 "$CNTCTR_DB" "SELECT calls || '/' || failures FROM tools WHERE name='cntf' AND project='$RK'")" "1/1"
same "draft calls are not counted" "$(sqlite3 "$CNTCTR_DB" "SELECT sum(calls) FROM tools WHERE name='fails' AND project='$RK'")" 0
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
st() { sqlite3 "$CNTCTR_DB" "select status from tools where name='$1' and version=${2:-1}"; }
hasdir() { ls "$RV" 2>/dev/null | grep -qF -- "$1"; }
haspane() { t list-panes -a -F '#{@cntctr_name}' | grep -qF -- "$1"; }
nmap() { sqlite3 "$CNTCTR_DB" "select count(*) from projects where root like '%/review/%'"; }
pubdef() { jq -nc --arg n "$1" --arg s "$2" --arg d "${3:-desc of $1}" '{name:$n,description:$d,input_schema:{type:"object"},interpreter:"sh",script:$s,publish:true}'; }
publish() { txt "$(call "$1" tool_define "$(pubdef "${@:2}")")"; }
board() { txt "$(call "${1:-$FR}" board '{"limit":200}')"; }
t set -p -t "$FR" @cntctr_harness claude

same "the gate runs before publishing" "$(publish "$FR" Bad_Name 'true')" "name must match ^[a-z][a-z0-9_]{1,40}\$"
same "a failed gate stores nothing" "$(sqlite3 "$CNTCTR_DB" "select count(*) from tools where name='Bad_Name'")" 0

# approve: the review copy has the untracked file; the tool runs there, not on the real tree
echo untracked > "$TMPD/repo/u.txt"
same "publish returns version and status" "$(publish "$FR" pw 'cat u.txt; echo touched > u.txt; pwd')" "pw v1 pending"
expect_screen "approval reaches the author" "$FR" "new fleet tool pw v1 by fr; see tools/list"
same "the reviewer ran on the copy, not the real tree" "$(cat "$TMPD/repo/u.txt")" untracked
check "the copy includes the untracked file" "$(cat "$TMPD/rev-pw.use")" untracked
check "the copy lives under the review dir" "$(cat "$TMPD/rev-pw.use")" "/cntctr-$(id -u)/review/"
check "the copy is named by project, tool and version" "$(cat "$TMPD/rev-pw.use")" "-pw-v1"
same "approved status" "$(st pw)" active
same "the draft was consumed by publishing" "$(sqlite3 "$CNTCTR_DB" "select count(*) from tools where name='pw' and status='draft'")" 0
check "the reviewer ran on a different harness's model" "$(sqlite3 "$CNTCTR_DB" "select reviewer_model from tools where name='pw'")" gemini
same "the reviewer was deadline-bound" "$(sqlite3 "$CNTCTR_DB" "select deadline - created from tools where name='pw'")" 1200
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
same "the reject reason is stored" "$(sqlite3 "$CNTCTR_DB" "select verdict_reason from tools where name='pr'")" "reviewer says reject"
expect_screen "the reason reaches the author" "$FR" "fleet tool pr v1 was rejected: reviewer says reject"
refute "a rejected tool is not listed" "$(lst "$KR")" '"name":"pr"'
tenv CNTCTR_TEST_VERDICT escalate
publish "$FR" pe 'echo e' >/dev/null
waitfor "pe escalated" '[ "$(st pe)" = escalated ]'
same "escalating clears the reviewer's authority" "$(sqlite3 "$CNTCTR_DB" "select reviewer_pane is null from tools where name='pe'")" 1
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
sqlite3 "$CNTCTR_DB" "insert into tools(project,name,version,status,author,description,input_schema,interpreter,script) values ('$RK','ub',1,'pending','fc','unbound','{\"type\":\"object\"}','sh','true')"
UB=$(t new-window -d -n ub -c "$TMPD/repo" -P -F '#{pane_id}' cat); t set -p -t "$UB" @cntctr_name toolcheck-aaaaaaaa-ub-v1
same "use before binding says to retry" "$(txt "$(call "$UB" use '{"tool":"ub"}')")" "review not bound yet; retry in a few seconds"
same "a verdict before binding says to retry" "$(txt "$(call "$UB" tool_verdict '{"name":"ub","version":1,"verdict":"approve"}')")" "review not bound yet; retry in a few seconds"

# supersede: v2 rejects the pending v1, and v1's late verdict is refused
tenv CNTCTR_TEST_VERDICT none
SR=$(newpane sr)   # superseding closes the old reviewer's pane
row "$RK" sv 1 pending fc "old" "$SR"
sqlite3 "$CNTCTR_DB" "update tools set deadline=strftime('%s','now')+1200 where name='sv'"
same "v2 is published over a pending v1" "$(publish "$FR" sv 'echo 2')" "sv v2 pending"
same "v1 was superseded" "$(st sv 1)" rejected
same "the supersede reason is stored" "$(sqlite3 "$CNTCTR_DB" "select verdict_reason from tools where name='sv' and version=1")" superseded
same "a late verdict on v1 is refused" "$(txt "$(call "$FR" tool_verdict '{"name":"sv","version":1,"verdict":"approve"}')")" "version 1 is rejected"
same "v2 is pending" "$(st sv 2)" pending

# resolution: while v2 is pending over an active v1 the reviewer gets v2 and everyone else v1
tenv CNTCTR_TEST_VERDICT approve
publish "$FR" rs 'echo 1' "rs one" >/dev/null
waitfor "rs v1 active" '[ "$(st rs 1)" = active ]'
tenv CNTCTR_TEST_VERDICT none
publish "$FR" rs 'echo 2' "rs two" >/dev/null
RP=$(sqlite3 "$CNTCTR_DB" "select reviewer_pane from tools where name='rs' and version=2")
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
sqlite3 "$CNTCTR_DB" "update tools set status='revoked', verdict_reason='gone' where name='bq' and version=1"
wait $bgp
same "a revoke during the bind leaves v1 revoked" "$(st bq 1)" revoked
waitfor "the revoked review's copy is cleaned up" '! hasdir -bq-v1'
waitfor "the revoked review's pane is closed" '! haspane -bq-v1'
same "no copy mapping is left" "$(sqlite3 "$CNTCTR_DB" "select count(*) from projects where root like '%-bq-v1' or root like '%-br-v1'")" 0

# expiry: after the publisher is gone, the next tool_* call escalates once and cleans up
publish "$FR" px 'echo x' >/dev/null
same "px is pending" "$(st px)" pending
check "px has a review copy" "$(ls "$RV")" "-px-v1"
sqlite3 "$CNTCTR_DB" "update tools set deadline=0 where name='px' and status='pending'"
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
same "the author's model is recorded" "$(sqlite3 "$CNTCTR_DB" "select author_model from tools where name='ma'")" claude-sonnet-5
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
same "the fallback reviewer uses another model" "$(sqlite3 "$CNTCTR_DB" "select reviewer_model from tools where name='fm'")" claude-opus-4-7
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
same "note from a tool is authored by the caller" "$(sqlite3 "$CNTCTR_DB" "select agent from entries where title='from tool'")" fr
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
check "call outside a tool fails" "$("$BIN" call recall '{}' 2>&1)" "cntctr call works only inside a fleet tool"
check "calls are logged as history" "$(sqlite3 "$CNTCTR_DB" "SELECT group_concat(title) FROM entries WHERE layer='history' AND title LIKE 'tool fails v0 fr %'")" "tool fails v0 fr fail"

# revoke: use refuses, the fleet is told, a later version lists, no older version comes back
tenv CNTCTR_TEST_VERDICT approve
publish "$FR" rvk 'echo one' "rvk one" >/dev/null
waitfor "rvk v1 active" '[ "$(st rvk 1)" = active ]'
same "revoke needs an active version" "$(txt "$(call "$KR" tool_revoke '{"name":"nope","reason":"x"}')")" "no active version of nope"
same "revoke answers" "$(txt "$(call "$KR" tool_revoke '{"name":"rvk","reason":"leaks keys"}')")" "revoked rvk"
same "v1 is revoked" "$(st rvk 1)" revoked
same "use says why" "$(txt "$(use rvk)")" "tool rvk was revoked: leaks keys"
expect_screen "the revoker's own pane is told" "$KR" "revoked fleet tool rvk"
expect_screen "the author's pane is told" "$FR" "revoked fleet tool rvk"
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
TD="$(dirname "$RV")/tools"
LC='{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}'
LIST='{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
revcall() { printf '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"tool_revoke","arguments":{"name":"%s","reason":"t"}}}' "$1"; }
check "initialize advertises listChanged" "$(rpc "$INIT")" '"listChanged":true'
tenv CNTCTR_TEST_VERDICT approve
session "$KA" 4 "$INIT" "$LIST" | while read -r l; do echo "$l" >> "$TMPD/lc1"; done & lc1=$!
waitfor "the listener registered a FIFO" '[ "$(grep -c . "$TMPD/lc1")" = 2 ] && ls "$TD" | grep -q "\.fifo$"'
same "the tools dir is private" "$(stat -f %Lp "$TD" 2>/dev/null || stat -c %a "$TD")" 700
publish "$FR" lcn 'echo 1' >/dev/null
waitfor "lcn approved" '[ "$(st lcn)" = active ]'
waitfor "an approval notifies another cntctr" 'grep -qxF "$LC" "$TMPD/lc1"'
sleep 1
same "one approval gives one notification" "$(grep -cxF "$LC" "$TMPD/lc1")" 1
own=$(session "$KR" 3 "$INIT" "$(revcall lcn)")
check "the revoker's own cntctr is notified" "$own" "$LC"
wait $lc1
same "a revoke notifies too" "$(grep -cxF "$LC" "$TMPD/lc1")" 2
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
off=$(session "$KA" 2 "$INIT" "$(revcall lcb2)" 2>"$TMPD/lc.err")
chmod 700 "$TD"
same "a loose tools dir sends nothing" "$(printf '%s' "$off" | grep -cF "$LC")" 0
same "a loose tools dir logs once" "$(grep -c 'notifications disabled' "$TMPD/lc.err")" 1

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
sqlite3 "$CNTCTR_DB" "update tools set calls=0 where name='hp'"   # the reviewer's trial run counted one
same "list shows the live version" "$(cli list | grep '^hp ')" "hp v2 active net=0 calls=0 failures=0 promote?=no"
out=$(cli show hp)
check "show lists an older version" "$out" "v1 revoked"
check "show lists the live version" "$out" "v2 active"
check "show prints the script" "$out" "echo two"
check "show names the models" "$out" "author model unknown, reviewer model gemini"
check "show gives the verdict" "$out" "verdict: superseded"
sqlite3 "$CNTCTR_DB" "update tools set calls=17 where name='hp' and version=2"
call "$FR" use '{"tool":"hp"}' >/dev/null
call "$KR" use '{"tool":"hp"}' >/dev/null
check "promote? stays off with two agents" "$(cli list | grep '^hp ')" "promote?=no"
call "$HQ" use '{"tool":"hp"}' >/dev/null
check "promote? turns on at 20 calls from 3 agents" "$(cli list | grep '^hp ')" "calls=20 failures=0 promote?=yes"
sqlite3 "$CNTCTR_DB" "update tools set failures=1 where name='hp' and version=2"
check "promote? needs a failure rate under 5%" "$(cli list | grep '^hp ')" "promote?=no"
sqlite3 "$CNTCTR_DB" "update tools set failures=0 where name='hp' and version=2"

# promote? counts the current version only: three agents used v1, one agent makes 20 calls of v2
publish "$FR" pc 'echo 1' >/dev/null
waitfor "pc v1 active" '[ "$(st pc 1)" = active ]'
for p in "$FR" "$KR" "$HQ"; do call "$p" use '{"tool":"pc"}' >/dev/null; done
publish "$FR" pc 'echo 2' >/dev/null
waitfor "pc v2 active" '[ "$(st pc 2)" = active ]'
call "$FR" use '{"tool":"pc"}' >/dev/null
sqlite3 "$CNTCTR_DB" "update tools set calls=20 where name='pc' and version=2"
check "promote? ignores the agents of older versions" "$(cli list | grep '^pc ')" "calls=20 failures=0 promote?=no"

same "promote copies the live version to global" "$(cli promote hp)" "promoted hp v2 to global v1"
same "promote records its source" "$(sqlite3 "$CNTCTR_DB" "select source from tools where project='global' and name='hp'")" "$RK/hp/v2"
check "a promoted tool is visible in another project" "$(lst "$FG")" "[fleet] hp two"
row "$GK" hp 1 active fc "gl hp" ""
check "a project tool shadows the global one" "$(lst "$FG")" "[fleet] gl hp"
same "promote from a second project" "$(CLID="$TMPD/gl" cli promote hp)" "promoted hp v1 to global v2"
same "promote revokes the previous global version" "$(sqlite3 "$CNTCTR_DB" "select group_concat(version || status) from (select * from tools where project='global' and name='hp' order by version)")" "1revoked,2active"
same "promote needs a live version" "$(cli promote nolive)" "no active version of nolive in this project"
sqlite3 "$CNTCTR_DB" "update tools set status='revoked', verdict_reason='x' where project='$GK' and name='hp'"
refute "a project revoke masks the global tool" "$(lst "$FG")" '"name":"hp"'

# approve and promote notify; approve resolves an escalated row and tells the project
tenv CNTCTR_TEST_VERDICT escalate
publish "$FR" he 'echo e' >/dev/null
waitfor "he escalated" '[ "$(st he)" = escalated ]'
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
same "approve resolves a pending version" "$(cli approve hpd)" "approved hpd v1"
same "a pending version became active" "$(st hpd)" active
waitfor "approving closes the reviewer's pane" '! haspane hrp'
row "$RK" hrj 1 escalated fc "esc" ""
same "reject resolves an escalated version" "$(cli reject hrj)" "rejected hrj v1"
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
expect_screen "a skill note tells the project" "$SK" "new skill Ship it ("
refute "the author's own pane is skipped" "$(screen "$FR")" "new skill Ship it"
call "$FR" note '{"layer":"insight","title":"Plain insight","summary":"no announce"}' >/dev/null
call "$FR" note '{"layer":"doc","title":"Plain doc","summary":"no announce","body":"x"}' >/dev/null
sleep 1
refute "an insight does not announce" "$(screen "$SK")" "Plain insight"
refute "a doc does not announce" "$(screen "$SK")" "Plain doc"
call "$FR" note '{"layer":"skill","title":"Global way","summary":"for all","scope":"global"}' >/dev/null
expect_screen "a global skill reaches the project" "$SK" "new skill Global way ("
expect_screen "a global skill reaches other projects" "$FG" "new skill Global way ("
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

# ---- summary ----
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
