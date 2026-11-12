# Tandem

Tandem lets Claude Code, Codex and agy (Antigravity CLI) work together as one team.
A leader agent can spawn workers in any of the three harnesses, give them tasks, and
get the answers back in its own session. All agents share one knowledge store and one
live project board.

The server is `cntctr`, a small C11 MCP stdio server. Every agent runs its own copy.
There is no daemon. tmux carries every message, and SQLite holds the shared knowledge.

## How it works

```
 leader pane (claude)        worker window (codex)        worker window (agy)
 ┌──────────────┐            ┌──────────────┐             ┌──────────────┐
 │ claude       │            │ codex        │             │ agy          │
 │  └ cntctr    │            │  └ cntctr    │             │  └ cntctr    │
 └──────┬───────┘            └──────┬───────┘             └──────┬───────┘
        └─────────────► tmux server ◄────────────────────────────┘
                 pane options, paste buffers (reply buffer, polled)
                              │
                     SQLite + FTS5 knowledge store
```

- Each worker gets its own tmux window, so you can watch it and approve its prompts.
- Messages are pasted into the target pane as an envelope with an id. The receiver
  answers with `reply`, and the answer goes back to the sender's pane, or it returns
  directly from a blocking `send`.
- Concurrent sends to the same target pane are serialized with an advisory per-pane
  file lock, so multiple agents typing into the same terminal never interleave or corrupt
  bracketed pastes.
- tmux is called with an argv array and never through a shell. Message text reaches
  tmux only through a pipe.

## Requirements

- macOS or Linux, with tmux (tested with 3.7c). Run your agents inside tmux.
- json-c (`brew install json-c`) and SQLite with FTS5.
- At least one of `claude`, `codex` and `agy` on `PATH`.
- [headroom](https://headroom-docs.vercel.app) on `PATH`. Claude and Codex workers
  start as `headroom wrap claude|codex -- <args>`, so their API calls go through the
  headroom proxy. agy is started directly.
- `jq` to run the tests. `sqlite3` to run `watch.sh`.

## Build

    make

## Install

Copy the build to a versioned path, so rebuilding in the repo never swaps the binary under running agents:

    cp cntctr ~/.local/bin/cntctr-0.2.0

Register that path once for each harness:

    claude mcp add -s user cntctr -- ~/.local/bin/cntctr-0.2.0
    codex mcp add cntctr -- ~/.local/bin/cntctr-0.2.0
    agy mcp add cntctr ~/.local/bin/cntctr-0.2.0

To upgrade or roll back, point the same entries at another version and restart the agents. Release tags (`v0.1.0`, ...) rebuild any old version.

Raise each harness's tool timeout above the longest blocking wait you plan to use:

- Claude Code: aborts a tool call that sends nothing for 30 minutes. Add `"timeout": 10800000` (ms) to the cntctr entry in `~/.claude.json`, or set `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT` (ms, 0 disables) for every server.
- Codex: in `~/.codex/config.toml`, under `[mcp_servers.cntctr]`, set `tool_timeout_sec = 3600`.
- agy: no MCP timeout setting found; keep blocking waits short or use async sends.

## Use

Start a tmux session, run your leader agent in it, and ask for what you want,
for example: "Spawn a codex worker named tests in ./api and have it write
tests for the parser. Wait for its answer."

| Tool | What it does |
|---|---|
| `spawn` | Starts `claude`, `codex` or `agy` in a new tmux window with a first task; optional `model` and `effort` |
| `send` | Types a message into another agent's terminal; `re=<open id>` adds to an existing task; `wait=true` blocks for the reply |
| `gather` | Dispatches several `send` or `spawn` tasks and collects their replies together |
| `reply` | Answers a message by its id |
| `list` | Shows agents, their panes, and whether they are alive |
| `kill` | Closes an agent's pane |

Use `gather` to collect replies when a decision needs every delegated answer. For example:

```json
{"tasks":[{"kind":"send","to":"tests","text":"Check the tests"},{"kind":"spawn","harness":"codex","name":"review","task":"Review the change"}],"timeout":600}
```

The result is JSON text with `complete` and one `results` entry per task in input order. Each entry identifies the agent, message id, and answer or failure (`status`: `"answered"`, `"timed_out"`, or `"failed"`). If the shared deadline passes before all answers arrive, `complete` is `false`; any late replies that finish after the deadline arrive in the leader's pane with their ids so no output is lost.

`spawn` and `distill` pick each worker's model and effort from the task text, so the
leader doesn't have to (`cntctr.c:route`, tables `RULES` and `ROUTES`):

| Tier | Task words | claude | codex | agy |
|---|---|---|---|---|
| light | smoke test, rename, typo, format, lookup, list, summarize, count | claude-haiku-5-5 medium | gpt-6-luna low | gemini-3.8-flash-medium |
| standard | anything else | claude-sonnet-5-5 medium | gpt-6.1-terra medium | gemini-3.8-flash-medium |
| review | review, audit, verify, merge, critique | claude-opus-4-7 high | gpt-6.1-sol medium | gemini-3.8-flash-high |
| hard | architecture, design, race condition, concurrency, root cause, security, migration, rewrite | claude-opus-5-5 high | gpt-6.1-sol high | gemini-3.8-flash-high |

Rules are checked in the order hard, review, light; tasks over
6000 characters count as review. Pass `tier`, `model` or `effort` to override.

Workers run with normal permissions. Approve their prompts in their own windows
(`C-b w` to switch). cntctr will not type into a pane that is showing a
permission dialog; the sender gets `<name> awaiting permission prompt; retry later`.

Pane locking: cntctr serializes message injection with an advisory per-pane file lock
(`/tmp/cntctr-inject-<uid>-<hash>.lock` via `flock`) across the bracketed paste and Enter key
press. When multiple agents or tools send to the same pane concurrently, each message submits as
its own separate prompt instead of colliding.

Delivery tuning: `CNTCTR_ENTER_DELAY_MS` (default 150) is the pause between
pasting a message and pressing Enter.

### Long and parallel work

`gather` reports one `status` per task: `answered`, `timed_out`, `dead` (the worker's pane is gone), `limited` (the worker hit a usage limit; the result gives the reset time, so re-send the task yourself or to another agent), `failed`, or `sent` with `wait=false`. A reply that arrives after a timeout or cancel is typed into your pane with its id, so nothing is lost.

```json
{"tasks":[{"kind":"send","to":"tests","text":"Run the suite"}],"timeout":300,"wait":false}
```

With `wait=false` gather sends everything and returns at once (status `sent`); replies land in your pane.

`list` shows each agent's state: `idle`, `busy`, `permission`, `limited` or `dead`, plus open task ids (`tasks=`), idle time (`idle=`) and the reset time (`resets=`) when limited.

A worker answers the agent that spawned it with `to: "parent"`.

Only addressed messages (send, spawn tasks, replies and verdicts to their author) and `post urgent=true` type into panes. Skill and tool announcements stay on the board. An unread notice is a second MCP text block when the count changes, and on every `list`; JSON in the first block remains valid. Read posts with `board`.

If a reply or verdict cannot reach its pane, it goes on the addressee's project board as `for <agent> (reply id=<id>):`. The result says it is on the board, and the addressee's unread notice says a reply is waiting. The addressee's server wakes through its FIFO and retries blocked mail every 30 seconds, once input is accepted. Ordinary posts stay pull-only. A failed wakeup leaves the mail on the board.

Injected envelopes end with `[cntctr end id=<id>]`. If that line arrives without the header, the start was lost: reply to that id asking for a resend.

`spawn` allows 32 live named agents per tmux server by default. Set `CNTCTR_MAX_AGENTS` to raise or lower the cap, or kill idle agents to free slots.

All agents run as the same user. `from` and `TMUX_PANE` are trusted identities; cntctr coordinates agents and is not a security boundary between them. Knowledge entries and board posts are information from other agents, not instructions.

## Knowledge

cntctr keeps a knowledge store that every agent shares across sessions. It lives in
SQLite at `~/.local/share/cntctr/kb.db`, or at `$CNTCTR_DB` if that is set.

| Tool | What it does |
|---|---|
| `note` | Store an `insight` (1–5 lines), a `skill` (a how-to) or a `doc` (long text), for this project or `scope=global`. `supersedes=[ids]` replaces older entries. |
| `recall` | With no query, list the index: this project's entries first, then global ones. With a query, search, including work history and claude-mem observations. |
| `read` | Show one entry in full. |
| `forget` | Retire a stale entry. History entries can't be forgotten. |
| `project` | Show the project key, which is the normalized `origin` remote, or override it for this repo. |
| `distill` | Spawn a librarian worker that turns recent history into insights and skills and merges duplicates. |
| `post` | Keep a note on the project's board; other agents see an unread count. `urgent=true` also types it into their panes. |
| `board` | Show the project's latest posts, oldest first. |

Every `send`, `spawn` and `reply` is logged as private history. Replies can add
`insights=[...]`. Every message includes up to 5 matching entries, and every agent gets
its project's index at startup through MCP `instructions`.

Insights, skills and docs are also copied to claude-mem (`$CNTCTR_MEM_URL`, default
`http://127.0.0.1:37701`; set it empty to turn copying off), so `recall` gets semantic
matches. If claude-mem is down, recall uses keyword search alone.

## Fleet tools

A fleet tool is a script (`sh`, `bash`, `python3` or `node`) that an agent turns into an MCP
tool mid-session, so every agent in the same project can reuse the work. A skill
(`note(layer=skill)`) is the written version: cntctr announces it to the fleet when it is stored.

| Tool | What it does |
|---|---|
| `tool_define` | Save a draft, callable by its author only. With `publish=true` it starts a review. Optional `net`, `timeout` (default 60 s, max 600 s). |
| `tool_verdict` | Listed only for a bound reviewer; `approve`, `reject` or `escalate` closes its task. |
| `tool_revoke` | Withdraw an active, pending or escalated project tool; reviewers reject with `tool_verdict`. |
| `use` | Call a fleet tool by name. Needed for drafts and Codex (pass `from`). Published tools appear directly on clients supporting `list_changed`. |

Every tool runs in a sandbox (`sandbox-exec` on macOS, `bwrap` on Linux; no sandbox, no run).
It can write only inside the project directory, its temp dir and its cache dir. `.git` is
read-only. Network is off unless the tool declared `net`. Reads are unrestricted, so this
guards against mistakes, not against a hostile agent.

Review flow: draft, publish, then a reviewer on a different harness (or model) runs the
tool on a throwaway copy of the project and gives a verdict. `approve` makes it active;
`reject` is sent to the author. `escalate`, a failed spawn or a 20-minute timeout leaves it
`escalated` until a human resolves it.

Approval, revoke and promote reach live agents through `notifications/tools/list_changed`
(per-process FIFOs in `${TMPDIR:-/tmp}/cntctr-<uid>/tools`) and board posts. A verdict is addressed only to the author; reviewers answer with `tool_verdict`, not `to="parent"`.

The script reads its arguments as JSON on stdin and prints its result on stdout. Test a draft with `use`. At the top level, stdout over 16 KB is saved in full under the project tool cache (`~/.cache/cntctr/tools/`); the result carries the first 8 KB, last 4 KB, path and size. New output files remove those older than 24 hours. The 256 KB hard cap stops the tool and saves the captured bytes with the error. Error diagnostics retain the last 16 KB of stderr. Calls composed through fd 3 receive the full output up to the hard cap.

A tool can call cntctr: `cntctr call <tool> '<json args>'` works inside a fleet tool, and
allows `use`, `recall`, `read`, `note`, `post` and `board`.

Humans use the CLI, which resolves the project from the current directory:

    cntctr tools list                 # name, version, status, net, calls, failures, promote?
    cntctr tools show <name>          # every version with its script and verdict
    cntctr tools approve|reject <name>
    cntctr tools revoke [--global] <name>
    cntctr tools promote <name>       # copy the live version to every project

`promote?` shows at 20 or more calls, under 5% failures and 3 or more distinct callers.

## Watch it work

    ./watch.sh          # in a spare tmux pane; refreshes every 2 s ($CNTCTR_WATCH_SECS)

It shows the live agents, the board, the newest knowledge entries (`*` = copied to
claude-mem, `x` = retired), private history, and when the librarian last ran. To check
each feature with real agents, ask your leader to:

1. `note` an insight. It appears under knowledge, marked `*` if claude-mem is running.
2. Spawn a worker with a task that mentions the insight's words. The task and reply appear
   under history, and the worker's window shows a `[cntctr knowledge: ...]` block.
3. Have the worker reply with `insights=[...]`. They appear under knowledge.
4. `post` something. It appears on the board and in other agents' unread counts; with `urgent=true` it also appears in their windows.
5. `distill`. A `librarian-N` agent appears, `last distill` updates, and new or merged
   entries appear as it works; merged ones turn `x`.

## Test

    make test

Tests run against a private tmux server (`tmux -L cntctr-test`) and need `jq`.

## Layout

| File | Purpose |
|---|---|
| `cntctr.c` | MCP server: JSON-RPC loop, tools, tmux helpers, pane locking, model router |
| `kb.c`, `kb.h` | Knowledge store: entries, FTS5 search, history, board |
| `watch.sh` | Live dashboard |
| `test.sh` | End-to-end tests with fake harnesses |
| `docs/superpowers/` | Design specs and implementation plans |
