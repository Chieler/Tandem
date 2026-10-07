#!/bin/bash
# Live view of cntctr: agents, the board, the knowledge store and the librarian.
# Run it in a spare tmux pane. --once prints one frame and exits.
db=${CNTCTR_DB:-$HOME/.local/share/cntctr/kb.db}
q() { sqlite3 -separator '  ' "$db" "$1" 2>/dev/null; }
short="substr(replace(%s, char(10), ' '), 1, 110)"

frame() {
    printf 'cntctr  %s  %s\n' "$db" "$(date '+%H:%M:%S')"
    printf '\n== agents (name harness pane state cwd) ==\n'
    tmux list-panes -a -F '#{@cntctr_name} #{@cntctr_harness} #{pane_id} #{?pane_dead,dead,alive} #{pane_current_path}' 2>/dev/null |
        grep -v '^ '
    printf '\n== board (latest 10, all projects) ==\n'
    q "SELECT * FROM (SELECT rowid, datetime(at, 'unixepoch', 'localtime') || '  [' || scope || ']  ' || sender || ': ' ||
       $(printf "$short" text) FROM posts ORDER BY rowid DESC LIMIT 10) ORDER BY rowid" | cut -d' ' -f3-
    printf '\n== knowledge (latest 12; * = mirrored to claude-mem, x = retired) ==\n'
    q "SELECT datetime(updated, 'unixepoch', 'localtime'), CASE WHEN superseded_by IS NOT NULL THEN 'x' WHEN mem_id THEN '*' ELSE ' ' END,
       layer, agent, scope, title || ' — ' || $(printf "$short" summary) FROM entries WHERE layer != 'history'
       ORDER BY updated DESC, rowid DESC LIMIT 12"
    printf '\n== history (latest 8, private) ==\n'
    q "SELECT datetime(created, 'unixepoch', 'localtime'), title || ' — ' || $(printf "$short" summary) FROM entries
       WHERE layer = 'history' ORDER BY rowid DESC LIMIT 8"
    printf '\n== librarian ==\n'
    q "SELECT 'last distill ' || substr(k, 14) || ': ' || datetime(v, 'localtime') FROM meta WHERE k LIKE 'last_distill:%'"
    q "SELECT 'entries: ' || group_concat(layer || ' ' || n, ', ') FROM
       (SELECT layer, count(*) n FROM entries WHERE superseded_by IS NULL GROUP BY layer)"
}

[ "${1:-}" = --once ] && { frame; exit; }
while :; do
    out=$(frame)
    clear
    printf '%s\n' "$out"
    sleep "${CNTCTR_WATCH_SECS:-2}"
done
