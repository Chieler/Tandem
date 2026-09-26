#!/bin/bash
# End-to-end tests for cntctr. Runs against a private tmux server, never yours.
set -u
BIN=$(cd "$(dirname "${BIN:-./cntctr}")" && pwd)/$(basename "${BIN:-./cntctr}")
TMPD=$(mktemp -d)
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"test"}}}'
mkdir "$TMPD/bin"
export BIN INIT CNTCTR_ENTER_DELAY_MS=50 LC_ALL=en_US.UTF-8 PATH="$TMPD/bin:$PATH"
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
call() {
    printf '%s\n{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":%s}}\n' \
        "$INIT" "$2" "$3" | TMUX_PANE=$1 "$BIN" | tail -n 1
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
for tool in spawn send reply list kill; do check "tools/list has $tool" "$out" "\"name\":\"$tool\""; done
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

# ---- summary ----
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
