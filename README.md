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
                 pane options, paste buffers, wait-for channels
                              │
                     SQLite + FTS5 knowledge store
```

- Each worker gets its own tmux window, so you can watch it and approve its prompts.
- Messages are pasted into the target pane as an envelope with an id. The receiver
  answers with `reply`, and the answer goes back to the sender's pane, or it returns
  directly from a blocking `send`.
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

Register the server once for each harness (use the absolute path):

    claude mcp add -s user cntctr -- /path/to/cntctr
    codex mcp add cntctr -- /path/to/cntctr
    agy mcp add cntctr /path/to/cntctr

Raise each harness's tool timeout above the longest blocking wait you plan to use:

- Claude Code: `MCP_TOOL_TIMEOUT` in milliseconds, e.g. `export MCP_TOOL_TIMEOUT=3600000`.
- Codex: in `~/.codex/config.toml`, under `[mcp_servers.cntctr]`, set `tool_timeout_sec = 3600`.
- agy: no MCP timeout setting found; keep blocking waits short or use async sends.

## Use

Start a tmux session, run your leader agent in it, and ask for what you want,
for example: "Spawn a codex worker named tests in ./api and have it write
tests for the parser. Wait for its answer."

| Tool | What it does |
|---|---|
| `spawn` | Starts `claude`, `codex` or `agy` in a new tmux window with a first task; optional `model` and `effort` |
| `send` | Types a message into another agent's terminal; `wait=true` blocks for the reply |
| `reply` | Answers a message by its id |
| `list` | Shows agents, their panes, and whether they are alive |
| `kill` | Closes an agent's pane |

`spawn` and `distill` pick each worker's model and effort from the task text, so the
leader doesn't have to (`cntctr.c:route`, tables `RULES` and `ROUTES`):

| Tier | Task words | claude | codex | agy |
|---|---|---|---|---|
| light | smoke test, rename, typo, format, lookup, list, summarize, count | claude-sonnet-5 low | gpt-6-luna low | gemini-3.8-flash-medium |
| standard | anything else | claude-opus-4-7 medium | gpt-6-luna medium | gemini-3.8-flash-medium |
| review | review, audit, verify, merge, critique | claude-opus-4-7 high | gpt-6-sol medium | gemini-3.8-flash-high |
| hard | architecture, design, race condition, concurrency, root cause, security, migration, rewrite | claude-opus-5-5 high | gpt-6-sol high | gemini-3.8-flash-high |

Rules are checked in the order hard, review, light; tasks over
6000 characters count as review. Pass `tier`, `model` or `effort` to override.

Workers run with normal permissions. Approve their prompts in their own windows
(`C-b w` to switch). cntctr will not type into a pane that is showing a
permission dialog; the sender gets `<name> awaiting permission prompt; retry later`.

Delivery tuning: `CNTCTR_ENTER_DELAY_MS` (default 150) is the pause between
pasting a message and pressing Enter.

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
| `post` | Type a note into every other live agent working in the same project, and keep it on the project's board. |
| `board` | Show the project's latest posts, oldest first. |

Every `send`, `spawn` and `reply` is logged as private history. Replies can add
`insights=[...]`. Every message includes up to 5 matching entries, and every agent gets
its project's index at startup through MCP `instructions`.

Insights, skills and docs are also copied to claude-mem (`$CNTCTR_MEM_URL`, default
`http://127.0.0.1:37701`; set it empty to turn copying off), so `recall` gets semantic
matches. If claude-mem is down, recall uses keyword search alone.

## Watch it work

    ./watch.sh          # in a spare tmux pane; refreshes every 2 s ($CNTCTR_WATCH_SECS)

It shows the live agents, the board, the newest knowledge entries (`*` = copied to
claude-mem, `x` = retired), private history, and when the librarian last ran. To check
each feature with real agents, ask your leader to:

1. `note` an insight. It appears under knowledge, marked `*` if claude-mem is running.
2. Spawn a worker with a task that mentions the insight's words. The task and reply appear
   under history, and the worker's window shows a `[cntctr knowledge: ...]` block.
3. Have the worker reply with `insights=[...]`. They appear under knowledge.
4. `post` something. It shows up in every other agent's window in the project and on the board.
5. `distill`. A `librarian-N` agent appears, `last distill` updates, and new or merged
   entries appear as it works; merged ones turn `x`.

## Test

    make test

Tests run against a private tmux server (`tmux -L cntctr-test`) and need `jq`.

## Layout

| File | Purpose |
|---|---|
| `cntctr.c` | MCP server: JSON-RPC loop, tools, tmux helpers, model router |
| `kb.c`, `kb.h` | Knowledge store: entries, FTS5 search, history, board |
| `watch.sh` | Live dashboard |
| `test.sh` | End-to-end tests with fake harnesses |
| `docs/superpowers/` | Design specs and implementation plans |
