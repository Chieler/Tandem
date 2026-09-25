# cntctr — Design Spec

Date: 2026-09-25
Status: Approved in conversation (sections 1–3); pending written-spec review.

## Context

The user runs Codex, agy (Antigravity CLI), and Claude Code as separate terminal agents. Today, moving work between them means manual copy/paste or handing off through files, which leaves stray artifacts behind. The goal is a direct, low-overhead channel so agents can talk to each other:

- **Primary use:** delegation. A leader agent spawns workers in their own preferred harness, hands them tasks, and gets results back. This enables multi-subagent development across harnesses.
- **Secondary use:** peer messaging between any two agents.
- **Constraints:** written in C or Python (C chosen). Minimal compute overhead. No files left in the user's repo. Local machine only.

Success looks like this: a Claude leader can spawn a Codex worker, send it a task, and receive the answer inside its own session. It can do that either asynchronously or as a blocking call. The user watches every agent live in tmux, and no file ever acts as the message channel.

## Decisions

| Topic | Decision |
|---|---|
| Interaction model | Delegate-and-return is primary; peer messaging uses the same primitive. |
| Result delivery | Async by default. `wait=true` blocks until a reply arrives or the timeout expires. On timeout, the call falls back to async. |
| Worker origin | The leader spawns workers on demand, and multiple instances of the same harness are allowed. |
| Agent interface | MCP tools, installed once per harness. |
| Transport, registry, and state | tmux only: pane user options, paste buffers, and `wait-for` channels. No daemon and no files. |
| Language | C11. Links `json-c` (already installed through Homebrew) via `pkg-config`. |
| Process model | One stdio MCP server per agent, required by the stdio transport. Each `tools/call` runs on its own detached pthread, and stdout writes are serialized with a mutex. |
| Permissions | Workers launch with normal permissions, and the user approves prompts in each pane. |
| Worker layout | One tmux window per worker, created with `-d` so focus stays on the leader. |

## Architecture

```
 leader pane (claude)          worker window (codex)          worker window (agy)
 ┌───────────────┐             ┌───────────────┐              ┌───────────────┐
 │ claude        │             │ codex         │              │ agy           │
 │  └ cntctr     │             │  └ cntctr     │              │  └ cntctr     │
 └──────┬────────┘             └──────┬────────┘              └──────┬────────┘
        │ tmux cmds (fork/execvp, argv only, text via stdin pipe)    │
        └──────────────────► tmux server ◄───────────────────────────┘
                 pane options: @cntctr_name, @cntctr_harness
                 server options: @cntctr_from_<id>, @cntctr_wait_<id>
                 buffers: cntctr-in-<id>, cntctr-reply-<id>
                 wait-for channels: cntctr-<id>
```

- `cntctr` is a stateless binary. The harness starts it as a stdio MCP child process. While idle, it sits blocked reading stdin.
- tmux runs the processes that host the agents, keeps the list of agents, stores pending replies, and provides the blocking primitive.
- The server never runs `system()` or `popen()` and never passes a shell string. Every tmux call uses `fork` and `execvp` with an argv array. Message text reaches tmux only through a pipe to `tmux load-buffer -`.

## Identity

1. Find the server's own pane: use `$TMUX_PANE` if it is set. Otherwise walk the parent-process chain until a pid matches `#{pane_pid}` in the output of `tmux list-panes -a -F '#{pane_pid} #{pane_id}'`. Codex strips environment variables from MCP servers by default, which is why the fallback exists.
2. Name: read the pane option `@cntctr_name`. If the pane is untagged, which is the case for a leader the user started by hand, the server tags it `<clientInfo.name>-<pane index>`. `clientInfo.name` comes from the MCP `initialize` request.
3. The tmux server socket comes from `$TMUX`, which is inherited. If `$TMUX` is absent, tmux uses its default socket.

## Tools

| Tool | Args | Returns |
|---|---|---|
| `spawn` | `harness` (`claude`/`codex`/`agy`), `name`, `cwd`, `task`, `wait=false`, `timeout=600` | Message id. If `wait=true`, the reply text. |
| `send` | `to`, `text`, `wait=false`, `timeout=600` | Message id. If `wait=true`, the reply text or a timeout notice. |
| `reply` | `id`, `text` | `ok`. |
| `list` | — | Name, harness, pane id, and alive status for each tagged pane. |
| `kill` | `name` | `ok`. Closes the worker's window. |

## Message flow

### Envelopes

Delivered to the receiver:
```
[cntctr from=<sender name> id=<id>]
<text>
[when done: cntctr reply id=<id>]
```

Delivered back to the sender as a reply:
```
[cntctr reply from=<replier name> id=<id>]
<text>
```

`id` is 8 hex characters taken from `arc4random`. On `send`, the server sets the server option `@cntctr_from_<id>` to the sender's pane id. Replies are routed by pane id, not by name.

### Inject into a pane

1. Permission guard (see below).
2. `tmux load-buffer -b cntctr-in-<id> -`, with the text written to stdin.
3. `tmux paste-buffer -p -d -b cntctr-in-<id> -t <pane>`. This is a bracketed paste, so multiline text arrives as one input.
4. Sleep for `CNTCTR_ENTER_DELAY_MS` (default 150), then run `tmux send-keys -t <pane> Enter`. The delay is a tuning setting, because TUIs differ in how quickly they finish handling a paste.

### Permission-prompt guard

Before any paste, run `tmux capture-pane -p -t <pane> -S -15` and match the output against a per-harness regex list compiled into the binary. On a match, nothing is pasted, and the call fails with `<name> awaiting permission prompt; retry later`. The guard is necessary because an injected Enter would accept a dialog's default option, usually "Yes". The patterns are taken from the real prompts during implementation. Known limit: this is a heuristic. If a harness changes its prompt wording, the guard misses it until the pattern list is updated.

### Blocking send (`wait=true`)

1. Set `@cntctr_wait_<id>=1`, then inject.
2. Fork `tmux wait-for cntctr-<id>`, then `poll` and `waitpid` until the deadline.
3. If signaled: read `show-buffer -b cntctr-reply-<id>`, delete the buffer and both options, and return the text.
4. If the timeout expires: kill the child and **clear `@cntctr_wait_<id>` first, then** check whether `cntctr-reply-<id>` exists. If it exists, return it and clean up. If not, return `timed out; reply will arrive in your pane (id=<id>)`.

### reply(id, text)

1. Look up `@cntctr_from_<id>`. If it is missing, return the error `unknown id`.
2. **Write buffer `cntctr-reply-<id>` first, then** check `@cntctr_wait_<id>`.
3. If the flag is set, run `tmux wait-for -S cntctr-<id>`. If it is clear, inject the reply envelope into the sender's pane (returning `sender gone` if that pane no longer exists), then delete the buffer and the `@cntctr_from_<id>` option.

Race safety: the replier always writes the buffer before it checks the flag, and the waiter always clears the flag before it checks the buffer. Under every interleaving, exactly one side delivers the reply. It is never lost and never delivered twice.

### Spawn

`tmux new-window -d -n <name> -c <cwd> -P -F '#{pane_id}' <argv...>`. The command is passed as separate arguments, so tmux runs it directly without a shell. This will be verified on tmux 3.7c. The argv for each harness:
- claude: `claude <envelope>`
- codex: `codex <envelope>`
- agy: `agy -i <envelope>`

After the window opens, the server sets the pane options `@cntctr_name` and `@cntctr_harness`. If the name is already in use, `spawn` fails before creating anything. The permission guard does not apply here, because the task is passed as a command-line argument rather than pasted.

## Error handling

| Case | Result |
|---|---|
| Target name not found | `agent <name> not found` |
| Sender pane gone when a reply arrives | `sender gone` returned to the replier |
| Target is showing a permission prompt | `<name> awaiting permission prompt; retry later` |
| Duplicate spawn name | `agent <name> already exists` |
| Unknown harness | `unknown harness <h>` |
| tmux command fails | The tool call returns an error containing tmux's stderr |
| Unknown JSON-RPC method | `-32601` |
| Malformed JSON | `-32700`. The server keeps running. |

Known limits:
- `@cntctr_from_<id>` options for messages that never get a reply stay in memory until the tmux server exits. Each is a few bytes.
- If the user is typing in a pane at the same moment a message is injected, the two inputs interleave.
- A `wait-for -S` sent when no one is waiting leaves a tmux channel marked as signaled. This is harmless, because ids are never reused.

## MCP surface

- Handles `initialize` (echoes the client's `protocolVersion`, reports `capabilities.tools`, and records `clientInfo.name`), `notifications/initialized` (ignored), `ping`, `tools/list`, and `tools/call`.
- Uses newline-delimited JSON-RPC 2.0 on stdin and stdout. Logging goes to stderr only.

## Files

| File | Purpose |
|---|---|
| `cntctr.c` | The whole server: JSON-RPC loop, tools, tmux helpers, and pane discovery. Roughly 600–800 lines. |
| `Makefile` | `make` runs `cc -std=c11 -O2 -pthread $(pkg-config --cflags --libs json-c)`. `make test` rebuilds with `-fsanitize=address,undefined` and runs `test.sh`. |
| `test.sh` | End-to-end tests against a private tmux server. |
| `README.md` | Install lines for each harness and per-harness timeout settings. |

## Install

```
make
claude mcp add cntctr -- $PWD/cntctr
codex mcp add cntctr -- $PWD/cntctr
agy mcp add cntctr $PWD/cntctr        # exact syntax verified during implementation
```

Set each harness's tool timeout above the longest blocking `send` you expect to use:
- Claude: `MCP_TOOL_TIMEOUT`.
- Codex: `tool_timeout_sec` under `[mcp_servers.cntctr]` in `~/.codex/config.toml`.
- agy: the equivalent setting is found during implementation and documented in the README.

## Testing

`test.sh` starts a private server with `tmux -L cntctr-test`, then exports `TMUX=<socket_path>,0,0` so that every `cntctr` process uses that server. No test-only setting is needed in the binary. A fake `claude` script is placed first on `PATH`. The script reads the envelope and replies by piping JSON-RPC into `./cntctr`.

Cases:
1. `list` shows the tagged panes.
2. Async `send`: `capture-pane` of the target shows the envelope.
3. Blocking `send` followed by a reply: the call returns the reply text.
4. Blocking `send` times out, then the reply arrives late: the envelope is injected into the sender's pane.
5. Two concurrent blocking sends from one server both return (tests the threading).
6. Permission guard: with the pane showing `Do you want to proceed`, `send` errors and nothing is pasted.
7. The text `$(touch $TMP/pwned)` is delivered literally, and the file is never created.
8. Errors: sending to a missing agent, replying with an unknown id, and spawning a duplicate name each fail as specified.
9. `spawn` with the fake harness opens a window, tags it, and delivers the task.

Manual checks with the real harnesses, after `make test` passes:
- Claude as leader spawns a Codex worker, uses blocking `send`, and receives the reply.
- Claude as leader spawns an agy worker with async `send`. Confirm that agy queues input typed while it is busy.
- Capture the real permission-prompt text from each harness and add it to the regex list.
- A peer `send` from Codex to agy.

## Out of scope (v1)

Message history, broadcast, auto-approve mode, a shared HTTP daemon, and support for machines other than the local one.

## Steps after plan approval

1. `git init` in `/Users/chielerli/Programming/cntctr`.
2. Copy this spec to `docs/superpowers/specs/2026-09-25-cntctr-design.md` and commit it.
3. The user reviews the committed spec.
4. Invoke `superpowers:writing-plans` to write the implementation plan.
