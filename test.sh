#!/bin/bash
# End-to-end tests for cntctr. Runs against a private tmux server, never yours.
set -u
BIN=$(cd "$(dirname "${BIN:-./cntctr}")" && pwd)/$(basename "${BIN:-./cntctr}")
TMPD=$(mktemp -d)
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"test"}}}'
mkdir "$TMPD/bin"
export BIN INIT CNTCTR_ENTER_DELAY_MS=50 LC_ALL=en_US.UTF-8 PATH="$TMPD/bin:$PATH" CNTCTR_DB="$TMPD/kb.db" CNTCTR_MEM_URL=
unset TMUX_PANE

t() { tmux -L cntctr-test -f /dev/null "$@"; }
t kill-server 2>/dev/null
t new-session -d -s test -x 200 -y 50 cat
export TMUX="$(t display -p '#{socket_path}'),0,0"
trap 't kill-server 2>/dev/null; rm -rf "$TMPD"' EXIT

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
        head -n "$n"
        exec 3>&-
    }
    rm -f "$fifo"
}
call() {
    session "$1" 2 "$INIT" "$(printf '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":%s}}' "$2" "$3")" | tail -n 1
}
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
    echo "$pane"
}

# ---- MCP protocol ----
out=$(rpc "$INIT")
check "initialize echoes protocol version" "$out" '"protocolVersion":"2025-06-18"'
check "initialize names the server" "$out" '"serverInfo":{"name":"cntctr"'
out=$(rpc '{"jsonrpc":"2.0","id":7,"method":"ping"}')
same "ping" "$out" '{"jsonrpc":"2.0","id":7,"result":{}}'
out=$(rpc '{"jsonrpc":"2.0","id":2,"method":"tools/list"}')
for tool in spawn send gather reply list kill note recall read forget project distill post board; do check "tools/list has $tool" "$out" "\"name\":\"$tool\""; done
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
expect_screen "codex light task" "$(pane_of "$out")" "flags:  -m gpt-6-luna -c model_reasoning_effort=\"low\""
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
same "board of another project" "$(txt "$(call "$KR" board '{}')")" "no posts"
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

# quiet posts: stored, not typed; counted on tool results
QW=$(newpane qw)
call "$S" board '{}' >/dev/null   # earlier posts in this project count as seen
call "$QW" board '{}' >/dev/null
out=$(txt "$(call "$S" post '{"text":"quiet news"}')")
check "quiet post is stored" "$out" "posted to the board"
sleep 0.5
refute "quiet post is not typed" "$(screen "$QW")" "quiet news"
out=$(txt "$(call "$QW" list '{}')")
check "tool results count unread posts" "$out" "(1 unread board post; call board)"
out=$(txt "$(call "$S" list '{}')")
refute "own posts are not unread" "$out" "unread board post"
out=$(txt "$(call "$QW" gather '{"tasks":[{"kind":"send","to":"missing-x","text":"y"}],"timeout":1}')")
printf '%s' "$out" | jq -e . >/dev/null && ok_ || bad "JSON results get no unread line"
out=$(txt "$(call "$QW" board '{}')")
check "board shows the post" "$out" "quiet news"
refute "board result has no unread line" "$out" "unread board post"
out=$(txt "$(call "$QW" list '{}')")
refute "board marks posts seen" "$out" "unread board post"
call "$S" post '{"text":"urgent news","urgent":true}' >/dev/null
expect_screen "urgent post is typed at once" "$QW" "urgent news"

# ---- summary ----
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
