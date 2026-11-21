# Code mode: scripted tool calls through cntctr

Status: design, approved section by section in conversation on 2026-11-20. Not implemented.

## Goal

An agent connected to cntctr (claude, codex or agy) can use any other MCP server through cntctr by writing a short script instead of calling each tool itself. The script calls tools as functions and returns only the final answer, so the agent does not load every tool schema into its context and does not see intermediate results.

This serves cntctr's three acceptance criteria:

- Info flooding: intermediate results stay inside the run; only a capped result returns.
- Wrong tool: the agent searches signatures for the tools it needs instead of seeing all of them; arguments are validated before a call is forwarded.
- Info loss: truncation is explicit and the full output stays one call away.

## Decisions (made with the user)

1. Scripts run in JavaScript on an embedded QuickJS. QuickJS is only the interpreter: no `fs`, network, `process` or `require` is exposed. The only thing a script can reach is the tool bridge.
2. A script has no authority of its own. Its authority is exactly the authority of the tool calls it makes, checked per call at the bridge. If the agent could not call a tool directly, the script cannot call it.
3. Privilege per tool comes from MCP annotations as defaults, with a registry override (below).
4. Grants persist per project and survive sessions.
5. The project's orchestrator may create grants on the user's behalf. It escalates to the user when it judges it should; by default it escalates destructive grants.
6. One daemon per user holds the downstream tool servers. It starts on demand and exits when idle. `cntctr code status` shows whether it is on.
7. Tool servers are registered per user by default and shared; grants stay per project. `--project` makes a registration project-local and `--isolated` gives each project its own process.
8. A global cap on running tool servers, with least-recently-used eviction.

## Terms

- Daemon: cntctr's own background process. Exactly one per user. Runs scripts, enforces grants, supervises tool servers. It does not count toward the cap.
- Tool server: any other MCP server (GitHub, a browser, a database) that the daemon launches as a child process. Zero or more.
- Run: one execution of a script by `code_run`.

## Agent-facing tools

cntctr adds these MCP tools. Nothing existing changes, and an agent that does not use code mode sees only these additions.

| Tool | Purpose |
|---|---|
| `code_find(query?)` | Search tool signatures across the project's registered servers. Returns name, one-line description, class (`read`, `write`, `destructive`) and whether this project has it granted. Does not return full schemas unless a single tool is asked for. |
| `code_run(script, scope?, timeout?)` | Run a script. Returns a short summary and a run id. |
| `code_expand(run, part, offset?, limit?)` | Page the full `result`, `logs`, `calls` or `denied` list of a stored run. |
| `code_status` | Daemon state, tool servers, memory, project grants in use. |
| Admin: `code_server`, `code_grant`, `code_revoke` | Register servers; create, list and revoke grants. Callable by the project's orchestrator and by a human through the CLI; denied to spawned workers and to scripts. |

`code_*` tools are not available inside scripts, so scripts cannot recurse.

### The script

```js
const found = await tools.github.search_issues({ q: "is:open label:bug" });
const titles = found.items.slice(0, 5).map(i => i.title);
return titles;          // only this goes back to the agent
```

- `tools.<server>.<tool>(args)` is an async function. `Promise.all` runs independent calls in parallel.
- cntctr's own tools are `tools.cntctr.*`, through the same grant gate.
- `console.log` is captured as logs.
- Args are validated against the tool's input schema before the call is forwarded. A bad call fails immediately with the field name and, for a mistyped tool name, the closest names.
- A denied call throws a catchable error naming the tool, its class and the exact command that would grant it. It is also listed in `denied`.
- `scope: ["github.search_*"]` on `code_run` narrows what the run may call. It can only narrow what the registry already allows.

### What comes back

`code_run` returns, with a run id:

- `result`: the script's return value, capped (default about 16 KB). A truncated part says how much is left out, for example `logs: 40 of 812 lines shown`.
- `logs`: capped the same way.
- `calls`: one line per tool call: tool, class, duration, ok or denied.
- `denied`: grant failures, each with the approval command.

`code_expand` returns the full part, in pages, from any agent in the project. Runs are stored in their own table with a retention period (default 24 h) and never appear in `recall`. An expired run says so.

## Privilege model

### Classes

When the daemon connects to a tool server it reads each tool's MCP annotations and assigns a class:

| Class | Source | Meaning |
|---|---|---|
| `read` | `readOnlyHint: true` | A script may call it once the project has the server |
| `write` | `readOnlyHint: false`, or no annotations | Needs an explicit grant |
| `destructive` | `destructiveHint: true` | Needs an explicit grant, separate from `write` |

Unannotated tools are `write`, so they fail closed.

### Registry overrides

Annotations are self-reported by the downstream server, so they are defaults, not trust. Rules are stored per project and matched most specific first; `deny` beats everything:

```
code_server add github --cmd "npx @modelcontextprotocol/server-github"
grant github.*              read     # at most read on this server
grant github.create_issue   allow
grant github.delete_repo    deny
```

An override can downgrade a server's claim (mark a tool `write` that claims read-only). `--trust none` ignores annotations for a server and treats all its tools as `write`; it is the default for servers cntctr did not see a user register by hand.

### Persistence and who may grant

Grants live in a `code_grants` table in `kb.db`, keyed by project like the existing fleet-tool records:

```
code_grants(project, server, tool_pattern, level, class_at_grant, granted_by, granted_at, reason)
```

- A grant is made once per project and applies to every agent and session in it. Another project starts with none.
- Grants can be listed and revoked. They never expire on their own.
- `class_at_grant` is recorded. If a granted tool's class later goes up (for example `read` to `destructive` after a server update), the grant no longer covers it and needs fresh approval.
- Only the project's orchestrator (the agent with no spawn parent) or a human may create a grant. Spawned workers and scripts may not. A denied worker call tells it to ask its parent.
- The orchestrator grants `read` and `write` on the user's behalf when a task clearly needs them and escalates `destructive` grants to the user by default (the existing `needs_human` / `escalate` path). The user can change this default.
- Every grant records who made it and why, so a grant made by an orchestrator is auditable.

Risk to state plainly: an orchestrator that has been prompt-injected could grant itself write access. The mitigations are the destructive escalation default, the audit trail, `class_at_grant`, and `deny` rules the user sets by hand.

## Daemon

### Path of a call

Agents still talk to their own per-harness cntctr stdio process. When it receives a `code_*` call it forwards it over a unix socket to the daemon with the project key and caller identity. If no daemon answers it starts one; a lockfile prevents two clients starting two.

### Process

- Socket: `~/.local/share/cntctr/code.sock`, mode 0600, peer-credential check. Newline-delimited JSON with request ids.
- One QuickJS runtime per run, created fresh and destroyed afterwards, with limits (below).
- A tool-server table: state (starting, running, idle, crashed), pid, last used, memory, owner key.
- A reader thread per tool server matches responses to requests by id and resolves the script's promise. Run execution reuses the existing thread-per-call pattern.

### The bridge

`tools.s.t(args)` goes to one function that: looks up the tool's class and the project's grants; checks the run's `scope`; validates args against the tool's schema; forwards to the tool server with a per-call timeout (default 30 s). Every call, allowed or denied, is recorded in `calls`. No path from a script to a tool server skips this function.

### Tool servers

- Registered per user and shared by default; one running process serves every project, and each project's grants decide what it may call.
- `--project` registers a server for one project only, for servers that need that project's directory or credentials. It runs as its own instance.
- `--isolated` gives each project its own process, for stateful servers such as browsers.
- A server starts lazily on its first call and is stopped after an idle period (default 15 min). The daemon exits when it holds no servers and no runs.
- Global cap `CNTCTR_CODE_MAX_SERVERS` (default 6), counting tool servers only. At the cap the least recently used idle server is stopped; if all are busy the call fails and the error names the variable.

### Failure handling

- Tool server crash: in-flight calls fail with `server crashed`; the next call relaunches it. After 3 crashes in 5 minutes it stays down and the error says so.
- Daemon crash: clients reconnect and restart it. In-flight runs fail. Grants, registrations and stored runs are in sqlite and survive.
- Upgrades: client and daemon exchange cntctr versions; on a mismatch the old daemon drains and exits and a new one starts, so a release never leaves a stale daemon.

### Visibility

- `cntctr code status`: `code: on · pid 4121 · 3 servers · 310 MB · 2 projects · up 2h`, or `code: off`. It tries one socket connect, so it cannot show a stale "on".
- `cntctr code status --short`: `code ●3` or `code ○`, for a tmux status segment `#(cntctr code status --short)`.
- A "code mode" section in `watch.sh`: each server, its projects, state, memory, last use.
- The `code_status` MCP tool, for agents.

## Limits on a run

The first three are estimates from how QuickJS behaves, to be measured when it is vendored; they are settable and are not claims.

| Limit | Default | Notes |
|---|---|---|
| Memory | 64 MB | Roughly 5-8 MB of parsed downstream JSON held at once. `CNTCTR_CODE_MAX_MB`. |
| Stack | 1 MB | Far deeper recursion than a tool script needs; overflow fails with a clear error. |
| CPU budget | 10 s | Counts only time spent running script code (interrupt handler). `CNTCTR_CODE_CPU_SEC`. |
| Wall limit | 5 min | Includes waits on tool calls. `CNTCTR_CODE_WALL_SEC`. |
| Per-call timeout | 30 s | Per tool call. |

`code_run` may ask for more, up to a hard ceiling the user sets. A run that hits a limit returns the limit, the variable to raise and the usage at cutoff.

## Storage

Three new tables in the existing `kb.db`, separate from knowledge entries so none of this appears in `recall`:

- `code_servers`: registrations (name, command, args, env, scope user/project, isolated, trust).
- `code_grants`: as above.
- `code_runs`: run id, project, caller, script hash, result, logs, calls, denied, created, expires.

## Build and tests

- QuickJS is vendored under `vendor/quickjs/` and built by the Makefile. Its sources compile without `-Werror`; cntctr's own files keep `-Wall -Wextra -Werror` and the ASan/UBSan test build. QuickJS is MIT licensed; the vendored revision is pinned and recorded, and it is cntctr's first vendored C dependency.
- A small fake MCP server in `fixtures/` that reports annotations, returns canned results, crashes on request and sleeps on request, so tests are deterministic. Tests follow the existing `test.sh` pattern and cover: class assignment, per-project grants, no escalation, scope narrowing, denial messages, argument validation, result caps and `code_expand`, CPU/wall/memory/stack limits, idle shutdown, the server cap with eviction, crash recovery, version mismatch, status output, and that grants survive a daemon restart.

## Out of scope for the first version

- Downstream servers over HTTP/SSE (stdio only).
- Streaming results back to the agent mid-run.
- Scripts persisted as reusable fleet tools (a likely follow-up: `tool_define` for a script that calls tools).
- Sharing a stateful server across projects.

## Open items

- The numeric limits and the 16 KB result cap are starting values; measure with the real QuickJS and tune.
- Idle shutdown is 15 minutes; the user accepted the idea but not a final number.
- Run retention (24 h) is a default.
- Whether `tools.cntctr.*` should expose all of cntctr's tools or a read-oriented subset in version one.
