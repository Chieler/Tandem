#!/bin/bash
set -eu
root=$(cd "$(dirname "$0")" && pwd)
BIN=${BIN:-$root/cntctr-test}
case $BIN in /*) ;; *) BIN="$root/$BIN" ;; esac
if [ "$(basename "$BIN")" = cntctr-test ]; then notify_bin=$BIN
else
    make -C "$root" cntctr-test >/dev/null
    notify_bin="$root/cntctr-test"
fi
d=$(mktemp -d)
trap 'rm -rf "$d"' EXIT
mkdir "$d/bin"
sqlite3 "$d/db" "create table projects(root text,key text); create table entries(layer text,scope text,title text,created integer); insert into entries values ('history','s','task 12345678 caller→worker→name',1000),('history','s','reply 12345678 worker→caller',1600),('history','s','task 87654321 caller→worker→name',2000);"
out=$(CNTCTR_DB="$d/db" "$BIN" stats --all)
printf '%s\n' "$out" | grep -Eq 'worker→name +2 +1 +1 +10.0 +10.0'
BIN="$BIN" bash "$root/test-usage.sh"
cat > "$d/bin/tmux" <<'SCRIPT'
#!/bin/sh
case "$1" in
 show) [ ! -f "$STATE" ] || cat "$STATE" ;;
 set) printf '%s\n' "$6" > "$STATE" ;;
esac
SCRIPT
cat > "$d/bin/notifier" <<'SCRIPT'
#!/bin/sh
printf '%s %s %s\n' "$1" "$2" "$3" >> "$LOG"
SCRIPT
chmod +x "$d/bin/tmux" "$d/bin/notifier"
export PATH="$d/bin:$PATH" STATE="$d/state" LOG="$d/log" CNTCTR_NOTIFY_COMMAND="$d/bin/notifier"
env -u CNTCTR_NOTIFY "$notify_bin" _test-notify
[ ! -e "$LOG" ]
CNTCTR_NOTIFY=1 "$notify_bin" _test-notify
for i in $(seq 1 100); do [ -f "$LOG" ] && [ "$(wc -l < "$LOG")" -eq 2 ] && break; sleep 0.02; done
[ "$(wc -l < "$LOG")" -eq 2 ]
[ "$(grep -c '^permission test-agent %42$' "$LOG")" -eq 2 ]
printf 'CLI standalone checks passed\n'
