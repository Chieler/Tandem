# cntctr

Lets Claude Code, Codex, and agy talk to each other directly. An agent can
spawn another agent in a tmux window, send it messages, and get replies back
in its own session, either right away (async) or by blocking until the answer
arrives. There are no files and no daemon. tmux carries every message.

## Requirements

- tmux (tested with 3.7c)
- json-c: `brew install json-c`
- Run your agents inside tmux.

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
| light | smoke test, rename, typo, format, lookup, list, summarize, count | claude-sonnet-5 low | gpt-6-luna low | gemini-3.8-flash-low |
| standard | anything else | claude-sonnet-5-5 medium | gpt-6-luna medium | gemini-3.8-flash-medium |
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
