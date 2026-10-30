# Fleet Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let agents define script-backed MCP tools and skills mid-session, review them on a project copy, and propagate them live to every agent in the project.

**Architecture:** Tool rows live in a new `tools` table in `kb.db` (`kb.c`). A new `fleet.c` runs a tool in a sandbox (`sandbox-exec` / `bwrap`) and serves a socketpair on fd 3 for calls back into cntctr. `cntctr.c` gains the MCP built-ins, review spawning, FIFO notifications, and the `cntctr tools` / `cntctr call` CLI.

**Tech Stack:** C11, json-c, SQLite (FTS5), tmux, `sandbox-exec` (macOS), `bwrap` (Linux), bash + jq for `test.sh`.

**Spec:** `docs/superpowers/specs/2026-10-30-fleet-tools-design.md`. Read it before each task; this plan names sections instead of repeating them.

## Global Constraints

- C11, `-Wall -Wextra -Werror -fsanitize=address,undefined` must stay clean (`make test` builds `cntctr-test`).
- Match existing style: `fmt()`, `ok()`/`fail()`, `sarg()`/`barg()`, `TMUX()`/`TMUXE()`, short comments, no new dependencies.
- Every state change in `kb.c` runs in one `BEGIN IMMEDIATE` transaction. Notifications go out only after commit.
- Guards use `self_pane`, never `from=`.
- Name regex `^[a-z][a-z0-9_]{1,40}$`; description ≤ 500 chars; schema ≤ 8 KB; script ≤ 64 KB; interpreters `sh bash python3 node`; timeout default 60, max 600 s; stdout cap 256 KB, stderr cap 16 KB.
- Review deadline 20 min. Promote flag: ≥ 20 calls, < 5% failures, ≥ 3 distinct callers.
- Sandbox fails closed. `.git` is never writable by a tool.
- Tests go in `test.sh` with the existing helpers (`call`, `session`, `txt`, `iserr`, `check`, `same`, `refute`, `newpane`, `expect_screen`).

## Review Focus

- A tool whose script prints nothing, or invalid UTF-8: the result is an empty or replaced string, never a crash. Test in Task 2.
- Args JSON larger than the pipe buffer while the script writes first: no deadlock. Test in Task 2.
- Two agents calling the same write tool at once: both finish; no cntctr lock is held. Test in Task 2.
- A project with no git (plain dir): define, run, publish and review copy all work (`rev-parse` fails cleanly). Test in Task 4.
- A cntctr killed mid-review: its review copy is swept on the next expiry run. Test in Task 4.

---

### Task 1: Tools table, drafts, and listing

**Files:**
- Modify: `kb.h`, `kb.c` (schema + functions)
- Modify: `cntctr.c` (`tool_define` without publish, `tools/list` merge, `dispatch` fallback)
- Test: `test.sh` (new section `# ---- fleet tools ----` before `# ---- summary ----`)

**Interfaces:**
- Produces in `kb.h`:
  ```c
  struct kb_tool { char project[1024], name[64], status[16], interpreter[16], author[128];
                   int version, net, timeout; char *description, *input_schema, *script; };
  void kb_tool_free(struct kb_tool *t);
  int kb_tool_save_draft(sqlite3 *db, const char *project, const char *author, const char *author_model,
                         const char *name, const char *description, const char *schema,
                         const char *interpreter, const char *script, int net, int timeout); /* 0 or -1 */
  /* 0 found, 1 revoked (t->status "revoked"), -1 unknown */
  int kb_tool_resolve(sqlite3 *db, const char *project, const char *name,
                      const char *caller_name, const char *caller_pane, struct kb_tool *t);
  char *kb_tool_names(sqlite3 *db, const char *project, const char *caller_name, const char *caller_pane);
  /* newline-separated names with any candidate row; caller resolves each */
  ```
- Produces in `cntctr.c`: `static int tool_define(json_object *a, char **res)`; `static char *gate_check(json_object *a)` (NULL or error text); `static json_object *tools_list(void)` (built-ins + fleet entries, description prefixed `[fleet] ` and `[net] `).

- [ ] **Step 1: Write failing tests**

```bash
# ---- fleet tools ----
FA=$(newpane fa)
FB=$(newpane fb)
def='{"name":"hello","description":"Say hello","input_schema":{"type":"object","properties":{"who":{"type":"string"}},"required":["who"]},"interpreter":"sh","script":"read a; echo \"hi $a\""}'
same "define saves a draft" "$(txt "$(call "$FA" tool_define "$def")")" "saved draft hello"
lst() { session "$1" 2 "$INIT" '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' | tail -n 1; }
check "draft listed for its author" "$(lst "$FA")" '"name":"hello"'
check "fleet tool is marked" "$(lst "$FA")" '[fleet] Say hello'
refute "draft hidden from others" "$(lst "$FB")" '"name":"hello"'
bad_def() { jq -c "$1" <<<"$def"; }
same "required must name a property" "$(txt "$(call "$FA" tool_define "$(bad_def '.input_schema.required=["x"]')")")" "input_schema: required names missing property x"
same "built-in names are reserved" "$(txt "$(call "$FA" tool_define "$(bad_def '.name="send"')")")" "send is a built-in tool"
same "name must match the pattern" "$(txt "$(call "$FA" tool_define "$(bad_def '.name="Bad-Name"')")")" "name must match ^[a-z][a-z0-9_]{1,40}$"
same "description cap" "$(txt "$(call "$FA" tool_define "$(bad_def ".description=\"$(printf 'x%.0s' $(seq 501))\"")")")" "description is over 500 characters"
same "unknown interpreter" "$(txt "$(call "$FA" tool_define "$(bad_def '.interpreter="ruby"')")")" "interpreter must be sh, bash, python3 or node"
same "timeout cap" "$(txt "$(call "$FA" tool_define "$(bad_def '.timeout=601')")")" "timeout must be 1..600"
```

- [ ] **Step 2: Run, expect FAIL** — `make test 2>&1 | grep -A3 'FAIL: define'` shows "unknown tool tool_define".
- [ ] **Step 3: Implement**
  - `kb.c` SCHEMA: append the `tools` table exactly as in spec §Data model, plus `CREATE INDEX IF NOT EXISTS tools_name ON tools(project, name, status);`. Bump nothing else.
  - `kb_tool_resolve`: implement the five-step order in spec §Resolving a name (step 1, built-ins, stays in `cntctr.c`). Use one `SELECT ... ORDER BY version DESC` per step.
  - `gate_check`: size caps, regex via `regcomp` once, built-in name check against `TOOL_FNS`, structural schema check (spec §Gate pipeline 1), interpreter allowlist, `timeout` 1..600. Error strings exactly as the tests above.
  - `tool_define`: `gate_check` always (drafts too); without `publish` call `kb_tool_save_draft` (replace the author's existing draft row for that name, version 0) and return `saved draft <name>`. Read `author_model` from the caller pane's `@cntctr_model` (empty if unset).
  - `tools_list()`: parse `TOOLS`, append one entry per resolved fleet name. Replace `json_tokener_parse(TOOLS)` in `handle`.
  - Add `{"tool_define", tool_define, 0}` to `TOOL_FNS` and its schema to `TOOLS`.
- [ ] **Step 4: Run, expect PASS** — `make test`, last line `N passed, 0 failed`.
- [ ] **Step 5: Commit** — `git commit -am "feat: fleet tool drafts and listing"`

---

### Task 2: Runner, sandbox, and `use`

**Files:**
- Create: `fleet.c`, `fleet.h`
- Modify: `Makefile` (add `fleet.c` to both targets), `cntctr.c` (`tool_use`, dispatch fallback to fleet tools)
- Test: `test.sh`

**Interfaces:**
- Produces in `fleet.h`:
  ```c
  struct fleet_run { const char *root, *interpreter, *script, *args_json, *db_path; int net, timeout;
                     /* serve one composition request line, return malloc'd reply line */
                     char *(*serve)(void *ctx, const char *line); void *ctx; };
  /* 0 ok, 1 tool error (non-zero exit, timeout, cap); *out malloc'd result or error text */
  int fleet_run(const struct fleet_run *r, char **out);
  char *fleet_cache_dir(const char *root);        /* ~/.cache/cntctr/tools/<base>-<hash>/, created */
  ```
- Consumes: `kb_tool_resolve` (Task 1).
- Produces in `cntctr.c`: `static int run_fleet_tool(const struct kb_tool *t, json_object *args, char **res)` used by `use` and by `dispatch` for non-built-in names; increments `calls`/`failures` via `kb_tool_count(db, project, name, version, ok)` (add to `kb.c`) and logs history `tool <name> v<N> <caller> ok|fail`.

- [ ] **Step 1: Write failing tests** (all through drafts, so no separate test binary)

```bash
FR=$(t new-window -d -n fr -c "$TMPD/repo" -P -F '#{pane_id}' cat); t set -p -t "$FR" @cntctr_name fr
deft() { call "$FR" tool_define "$(jq -nc --arg s "$2" --arg n "$1" '{name:$n,description:"t",input_schema:{type:"object"},interpreter:"sh",script:$s}' | jq -c ". + ${3:-{\}}")" >/dev/null; }
use() { call "$FR" use "$(jq -nc --arg t "$1" --argjson a "${2:-{\}}" '{tool:$t,args:$a}')"; }
deft hello 'read a; echo "hi $a"'
same "use runs the draft with args on stdin" "$(txt "$(use hello '{"who":"x"}')")" 'hi {"who":"x"}'
same "direct call works too" "$(txt "$(call "$FR" hello '{}')")" 'hi {}'
deft w 'echo data > made.txt; mkdir -p sub; echo ok'
same "tool writes in the project" "$(txt "$(use w)")" ok; [ -f "$TMPD/repo/made.txt" ] && ok_ || bad "made.txt missing"
deft g 'echo x > .git/evil'
same "tool cannot write .git" "$(iserr "$(use g)")" true
deft o "echo x > $TMPD/outside"
same "tool cannot write outside" "$(iserr "$(use o)")" true
ln -s "$TMPD/plain" "$TMPD/repo/link"
deft l 'echo x > link/evil'
same "symlink out is not writable" "$(iserr "$(use l)")" true
deft c 'echo x > "$TMPDIR/a" && echo y > "$XDG_CACHE_HOME/b" && cat "$TMPDIR/a"'
same "temp and cache are writable" "$(txt "$(use c)")" x
deft e 'env'
FOO_TOKEN=s OPENAI_API_KEY=s out=$(txt "$(use e)")
refute "no tokens" "$out" FOO_TOKEN; refute "no keys" "$out" API_KEY; refute "no TMUX" "$out" "TMUX="
python3 -c "import socket,time;s=socket.socket();s.bind(('127.0.0.1',47124));s.listen();time.sleep(8)" & LP=$!
deft n 'nc -z -w1 127.0.0.1 47124 && echo open'
same "network denied by default" "$(iserr "$(use n)")" true
deft n2 'nc -z -w1 127.0.0.1 47124 && echo open' '{"net":true}'
same "declared net works" "$(txt "$(use n2)")" open; kill $LP
deft big 'yes | head -c 400000'
check "stdout capped" "$(txt "$(use big)" | wc -c)" 262
deft slow 'sleep 30 & sleep 30' '{"timeout":2}'
check "timeout honored" "$(txt "$(use slow)")" "timed out after 2 s"
deft first 'echo early; cat >/dev/null; echo late'
check "write-before-read does not deadlock" "$(txt "$(use first "$(jq -nc --arg x "$(head -c 200000 /dev/zero | tr '\0' a)" '{x:$x}')")")" late
deft empty 'true'
same "empty output is fine" "$(iserr "$(use empty)")" false
deft fails 'echo boom >&2; exit 3'
check "non-zero exit is an error with stderr" "$(txt "$(use fails)")" boom
for i in sh bash python3 node; do
  call "$FR" tool_define "$(jq -nc --arg i $i '{name:("i_"+$i),description:"t",input_schema:{type:"object"},interpreter:$i,script:(if $i=="python3" then "print(1)" elif $i=="node" then "console.log(1)" else "echo 1" end)}')" >/dev/null
  same "$i runs sandboxed" "$(txt "$(use i_$i)")" 1
done
same "unknown tool" "$(txt "$(use nope)")" "unknown tool"
```

- [ ] **Step 2: Run, expect FAIL** ("unknown tool use").
- [ ] **Step 3: Implement `fleet.c`** per spec §Running a tool and §Sandbox:
  - Write script to `<tmp>/tool`; build env (copy `environ`, drop `TMUX`, `TMUX_PANE`, `SSH_AUTH_SOCK`, names ending `_KEY`/`_TOKEN`/`_SECRET`; set `TMPDIR`, `XDG_CACHE_HOME`, `npm_config_cache`, `PIP_CACHE_DIR`, `GOCACHE`, `CNTCTR_FD=3`, `CNTCTR_ROOT`).
  - Refuse if `realpath(db_path)` is under `realpath(root)` with the spec's error text.
  - macOS argv: `sandbox-exec -p <profile> <interp> <tmp>/tool`, profile exactly as spec (paths `realpath`ed, `"` escaped). Linux argv: `bwrap` flags as spec. Neither found → fail closed.
  - Child: `setsid()`, dup pipes to 0/1/2, socketpair end to 3, close fds > 3, `RLIMIT_CORE` 0, `chdir(root)`, `execvp`. Take `fork_mu` is not available here: pass all pipes `O_CLOEXEC` and dup in child (dup clears CLOEXEC).
  - Parent `poll` loop on stdin-write, stdout, stderr, fd 3; deadline via `clock_gettime(CLOCK_MONOTONIC)`; caps; `kill(-pid, SIGKILL)` on deadline/cap; reap; `rm -rf` temp via `nftw`.
  - fd 3 protocol: newline-delimited JSON; each full line → `r->serve(ctx, line)` → write reply + `\n`. (`serve` NULL in this task: reply `{"error":"not available"}`.)
- [ ] **Step 4: Implement `tool_use`** and the `dispatch` fallback: unknown built-in name → `kb_tool_resolve` → `run_fleet_tool`. "revoked" → `tool <name> was revoked: <reason>`.
- [ ] **Step 5: Run, expect PASS.** On Linux CI, run the same section (bwrap).
- [ ] **Step 6: Commit** — `git commit -am "feat: sandboxed fleet tool runner and use"`

---

### Task 3: Composition (`cntctr call`, `dispatch_as`)

**Files:** Modify `cntctr.c` (`main` argv, `dispatch_as`, serve callback, depth), `test.sh`.

**Interfaces:**
- Produces: `static int dispatch_as(const char *pane, const char *name, const char *tool, json_object *args, char **res);` — saves/restores thread-local `caller_pane`/`caller_name`; `dispatch` resolves caller as today then calls it.
- Produces: `int main(int argc, char **argv)`; `cntctr call <tool> <json>` reads `$CNTCTR_FD`, writes `{"tool":..,"args":..}\n`, prints `text`, exits 1 if `isError`.
- Thread-local `static _Thread_local int fleet_depth;` max 3.

- [ ] **Step 1: Failing tests**

```bash
deft rc 'cntctr call recall "{\"query\":\"copy-mode\"}"'
PATH="$(dirname "$BIN"):$PATH" check "tool can recall" "$(txt "$(use rc)")" "Enter in copy-mode"
deft nt 'cntctr call note "{\"layer\":\"insight\",\"title\":\"from tool\",\"summary\":\"s\",\"from\":\"someone-else\"}"'
use nt >/dev/null
check "note from a tool is authored by the caller" "$(sqlite3 "$CNTCTR_DB" "select agent from entries where title='from tool'")" fr
deft sp 'cntctr call spawn "{}"'
check "spawn is not callable from a tool" "$(txt "$(use sp)")" "tool spawn is not callable from a fleet tool"
deft deep 'cntctr call use "{\"tool\":\"deep\",\"args\":{}}"'
check "nesting stops at 3" "$(txt "$(use deep)")" "fleet tools nested too deep"
check "call outside a tool fails" "$("$BIN" call recall '{}' 2>&1)" "cntctr call works only inside a fleet tool"
```
  (Install `cntctr` in the test PATH: `ln -s "$BIN" "$TMPD/bin/cntctr"` at the top of the section.)
- [ ] **Step 2: FAIL.** **Step 3: Implement** per spec §Composition; allowed list `use recall read note post board`; strip `from` from args. **Step 4: PASS.** **Step 5: Commit** `feat: fleet tools call back into cntctr`.

---

### Task 4: Publish, review copy, reviewer, verdict, expiry

**Files:** Modify `kb.h`/`kb.c` (`kb_tool_publish`, `kb_tool_bind`, `kb_tool_verdict`, `kb_tool_expire`), `cntctr.c` (publish path, `@cntctr_model` tag in `start_spawn`, `tool_verdict`, review copy/cleanup), `test.sh`.

**Interfaces:**
- `int kb_tool_publish(sqlite3*, const char *project, const char *author, const char *name, int *version);` — promotes the author's draft row content into a new `pending` row with `deadline = now + 1200`.
- `int kb_tool_bind(sqlite3*, const char *project, const char *name, int version, const char *pane, const char *model, const char *review_root);` — returns rows changed (0 or 1).
- `int kb_tool_verdict(sqlite3*, const char *project, const char *name, int version, const char *pane, const char *verdict, const char *reason, char status[16]);` — 0 applied; -1 not applied, `status` gets the row's current status (or "unbound").
- `char *kb_tool_expire(sqlite3*, const char *project);` — `"<pane>\t<review_root>\n"` lines of rows it escalated.
- `cntctr.c`: `static char *review_copy(const struct project *p, const char *name, int version, char path[4096]);` (NULL or error), `static void review_cleanup(const char *pane, const char *root);`, `static const char *reviewer_harness(const char *author_harness);`.

- [ ] **Step 1: Failing tests.** Use the fake harness (it replies). Add a fake reviewer script `$TMPD/bin/toolcheck` behavior via env: extend the fake `claude` so that when the task contains `toolcheck`, it runs `use` then `tool_verdict` with `CNTCTR_TEST_VERDICT` (default approve). Tests from spec §Verification "Lifecycle" items 3–14, concretely:

```bash
echo untracked > "$TMPD/repo/u.txt"
deft pw 'echo touched > u.txt; echo ok'
out=$(txt "$(call "$FR" tool_define "$(jq -nc '{name:"pw",description:"t",input_schema:{type:"object"},interpreter:"sh",script:"echo touched > u.txt; echo ok",publish:true}')")")
check "publish returns version and status" "$out" "pw v1 pending"
expect_screen "approval reaches the author" "$FR" "new fleet tool pw v1"
same "reviewer ran on the copy, not the real tree" "$(cat "$TMPD/repo/u.txt")" untracked
same "review copy removed" "$(ls "$(realpath /tmp)/cntctr-$(id -u)/review" 2>/dev/null)" ""
same "copy mapping removed" "$(sqlite3 "$CNTCTR_DB" "select count(*) from projects where root like '%/review/%'")" 0
check "other agent in project sees it" "$(lst "$KR")" '"name":"pw"'   # KR is in $TMPD/repo
# reject, escalate, non-reviewer verdict, escalate-then-approve, supersede, bind race, expiry:
CNTCTR_TEST_VERDICT=reject ... ; same "rejected status" "$(sqlite3 "$CNTCTR_DB" "select status from tools where name='pr' and version=1")" rejected
same "verdict from non-reviewer" "$(txt "$(call "$FR" tool_verdict '{"name":"pw","version":1,"verdict":"approve","reason":"x"}')")" "only the assigned reviewer can give a verdict"
sqlite3 "$CNTCTR_DB" "update tools set deadline=0 where name='px' and status='pending'"
call "$FR" tool_define '{...trigger any tool_* call...}' >/dev/null
same "expired once" "$(sqlite3 "$CNTCTR_DB" "select status from tools where name='px'")" escalated
mkdir -p "$(realpath /tmp)/cntctr-$(id -u)/review/deadbeef-stray-v9"; call "$FR" use '{"tool":"hello","args":{}}' >/dev/null
[ ! -d "$(realpath /tmp)/cntctr-$(id -u)/review/deadbeef-stray-v9" ] && ok_ || bad "stray review dir not swept"
```
  Write the elided `...` cases out in full when implementing, one `same`/`check` per spec bullet: reject, escalate, escalate-then-approve refused, supersede v1 by v2 then late v1 verdict refused, "review not bound yet" (fake reviewer with `CNTCTR_TEST_FAST=1` calls verdict before sleeping, then retries), bind race (`CNTCTR_TEST_HOLD_BIND=1` makes publish sleep 1 s before `kb_tool_bind`; revoke during it), plain non-git project publish works, linked worktree copy has its own `.git` dir (`git worktree add`, publish, check `[ -d copy/.git ]` from the fake reviewer).
- [ ] **Step 2: FAIL.** **Step 3: Implement** per spec §Gate pipeline 2–5 and §Transactions. In `start_spawn` add `free(TMUXE(NULL, "set", "-p", "-t", pane, "@cntctr_model", model));` next to the harness tag. Run `kb_tool_expire` + stray sweep at the start of every `tool_*`, `use`, and CLI command. **Step 4: PASS.** **Step 5: Commit** `feat: fleet tool publish and cross-model review`.

---

### Task 5: Revoke and `announce`

**Files:** Modify `kb.c` (`kb_tool_revoke`), `cntctr.c` (`announce`, `tool_revoke`, refactor `tool_post` onto `announce`), `test.sh`.

**Interfaces:**
- `static char *announce(sqlite3 *db, const char *scope, const char *sender, const char *text, const char *skip_pane);` — `scope` NULL = every project; `skip_pane` NULL = include all; writes board post(s); returns the "posted to ..." summary. `tool_post` calls it with `(p.key, caller_name, text, caller_pane)` and existing tests must still pass unchanged.
- `int kb_tool_revoke(sqlite3*, const char *project, const char *name, const char *reason);` — rows changed.

- [ ] **Step 1: Failing tests:** revoke makes `use pw` return `tool pw was revoked: <reason>`; revoker's own pane shows `revoked fleet tool pw`; publish+approve v2 after revoke lists v2; revoke after v2 replaced v1 does not resurrect v1; all existing `# ---- board ----` tests still pass.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat: revoke fleet tools and announce changes`.

---

### Task 6: Live notifications (FIFOs + `list_changed`)

**Files:** Modify `cntctr.c` (register after `initialize`, watcher thread, `notify_all()`, unlink in `main`, caps `listChanged`), `test.sh`.

**Interfaces:** `static void fifo_register(void);`, `static void *fifo_watch(void *);`, `static void notify_all(void);` — called after every committing tool transaction (approve, revoke, promote, human approve).

- [ ] **Step 1: Failing tests** (spec §Verification "Propagation"): keep a `session` of `$KR` open reading 3 lines (`INIT`, then wait); approve a tool from another pane; assert a line `{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}` arrives. Three quick approvals → ≥ 1 notification. Stale `999999.fifo` with no reader is unlinked after a notify. `chmod 755` on the `tools` dir → that cntctr logs once to stderr and sends nothing. `initialize` result contains `"listChanged":true`.
- [ ] **Step 2–5:** FAIL → implement exactly per spec §Propagation → PASS → commit `feat: live list_changed for fleet tools`.

---

### Task 7: Human CLI, promote, `watch.sh`

**Files:** Modify `cntctr.c` (`cntctr tools list|show|approve|reject|revoke [--global]|promote`), `kb.c` (`kb_tool_resolve_human`, `kb_tool_promote`, `kb_tool_list`), `watch.sh`, `test.sh`.

- [ ] **Step 1: Failing tests:** `cd "$TMPD/repo" && "$BIN" tools list` shows `pw v2 active net=0 calls=… promote?=no`; `show pw` lists every version with models and verdicts; `approve` resolves an escalated row and notifies; `promote pw` → visible from `$KA` (other project); project tool of same name shadows global; project revoke masks global; promote from two projects → global v1 revoked, v2 active; `promote?` flag after 20 calls from 3 agents; `watch.sh --once` shows a `== fleet tools ==` block.
- [ ] **Step 2–5:** FAIL → implement → PASS → commit `feat: cntctr tools CLI and promote`.

---

### Task 8: Skills announce, `recall` finds tools, guide

**Files:** Modify `cntctr.c` (`tool_note`, `tool_recall`, `GUIDE`), `test.sh`.

- [ ] **Step 1: Failing tests:** `note layer=skill` → other pane in project shows `new skill <title> (<id>); read it with read`; `note layer=insight` does not; `recall {"query":"hello"}` contains `[tool] hello: Say hello`; `initialize` instructions contain `make it a fleet tool with tool_define`.
- [ ] **Step 2–5:** FAIL → implement (spec §Skills, §MCP interface `recall`, §Guide) → PASS → commit `feat: announce skills and surface tools in recall`.

---

### Task 9: README

**Files:** Modify `README.md` — add a "Fleet tools" section: what they are, sandbox limits, review flow, `cntctr tools` commands, `cntctr call` from scripts. Update the tools list check in `test.sh` (`for tool in ...`) to include `tool_define tool_verdict tool_revoke use`.

- [ ] Run `make test` → `0 failed`. Commit `docs: fleet tools in README`.
