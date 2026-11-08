# cntctr 0.2.0: long gathers, agent status, quiet delivery

## Purpose

An orchestrator running Claude, Codex and agy workers reported what cost it the most in one session (2026-11-07):

1. Claude Code killed a gather after 30 silent minutes, and every reply in it was lost.
2. It could not tell whether a worker was busy, stuck, done or out of usage without reading tmux panes.
3. Board posts were typed into every pane and interrupted workers mid-task; a message meant for one orchestrator reached another.
4. Smaller costs: free-form replies, workers drifting from task limits, vague errors, stale notes.

Workers that hit their harness usage limit (for example Claude's 5-hour window) also go silent, and the orchestrator waits out the full timeout.

0.2.0 fixes these on branch `feat/qol`, off `main` (`v0.1.0`). It ships and is tested alone. Fleet tools (`feat/fleet-tools`) are rebased onto it afterwards as 0.3.0. Tracking: `docs/BACKLOG.md`.

## Outcomes

- A gather of any length up to its timeout survives the client, and no reply is ever lost: on timeout or cancel, late replies reach the caller's pane.
- A gather reports each worker's result as `answered`, `timed_out`, `dead`, `limited` or `failed`, so partial results are usable.
- A worker that hits its usage limit is reported at once, and its task moves to a fallback agent when the orchestrator named one.
- `list` shows each agent's state, open tasks and idle time.
- Board posts never interrupt a busy agent unless marked urgent.
- Workers reach the orchestrator that spawned them with `to: "parent"`.

## Background: what exists

- `await_reply` (`cntctr.c:await_reply`) blocks on one task in 5 s slices (`WAIT_SLICE`), checking for a lost signal and a dead pane. `tool_gather` dispatches every task, then awaits them one after another.
- `tool_reply`: when the sender is not waiting, the reply is typed into the sender's pane. Late replies already use this path.
- `@cntctr_to_<id>` holds the pane of each unanswered task (`track_to`); `@cntctr_wait_<id>` marks a sender blocked in `await_reply`.
- `awaiting_permission` reads the last 15 lines of a pane with `capture-pane` and matches regexes.
- Each tools/call runs on its own thread (`start_call`); `emit` serializes stdout with `out_mu`.
- Claude and agy run one cntctr process per pane. Codex runs one shared process outside any pane. The caller's pane is resolved per call (`caller_pane`: `$TMUX_PANE`, the nearest ancestor pane, or `from`).
- `note supersedes=[ids]` and `forget` already hide entries from `recall`.

## 1. Gather

### Waiting

`tool_gather` sends every task, then runs one loop over all pending tasks. Each 5 s round checks every pending task for:

- a reply buffer (answered),
- a dead pane (`dead`),
- the usage-limit screen (`limited`, see below).

The loop ends when no task is pending or the shared deadline passes. Pending tasks then become `timed_out`. `await_reply` keeps serving `send` and `spawn` with `wait=true`; both loops share one per-task check function.

### Heartbeat

If the tools/call request carries `params._meta.progressToken`, a blocking wait (gather, `send`/`spawn` with `wait=true`) emits every 60 s:

```json
{"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":<token>,"progress":<answered>,"total":<tasks>,"message":"2/3 answered"}}
```

Nothing is typed into any pane. `CNTCTR_HEARTBEAT_SECS` overrides 60 for tests. Without a token there is no heartbeat; the client's `timeout` setting (README) is the fallback.

### No lost replies

On timeout or cancel, cntctr clears `@cntctr_wait_<id>` for every pending task. A later `reply` then finds no waiter and types the reply into the caller's pane through the existing path. A reply that races the clear is claimed once, as today (`delete-buffer` decides).

### Async gather

`wait=false` sends every task and returns at once:

```json
{"complete":false,"results":[{"kind":"send","agent":"codex-2","status":"sent","id":"1a2b3c4d"}, ...]}
```

Replies arrive in the caller's pane as they come. Section 2's status covers progress; there is no `gather_status` tool.

### Result shape

Unchanged except new statuses and fields:

| status | fields |
|---|---|
| `answered` | `text`, and `json` when the task had `reply_format` |
| `timed_out` | — (reply will arrive in the pane) |
| `dead` | `error` |
| `limited` | `resets` (text from the screen), `fallback` (agent name and new id, if re-sent) |
| `failed` | `error` |

### Usage limit

A pane is `limited` when its last 15 lines match one of these case-insensitive regexes, kept beside `PROMPTS`:

| harness | screen text (observed) | regex |
|---|---|---|
| Claude Code | `You've hit your session limit · resets 10:40pm (America/Chicago)`, `You've hit your weekly limit` | `hit your (session\|weekly\|usage) limit` |
| Claude Code | `Usage limit reached · continuing automatically at 10:40pm · esc to cancel` | `usage limit reached` |
| Codex | `Usage limit reached` / `Request a limit increase from your owner to continue using codex.` | `usage limit reached` |
| agy | `⚠ Individual quota reached. ... Resets in 143h57m55s.` | `individual quota reached` |

`resets` is the text after `resets`, `Resets in` or `continuing automatically at` on the matched screen, trimmed; empty if none.

Claude Code can resume on its own after the reset, so a `limited` task may still answer later. Its reply then reaches the caller's pane like any late reply.

Each gather or send task may carry `fallback`: an agent name, a role, or a harness (`claude`, `codex`, `agy`).

- Agent name or role: the task text is sent to that agent with a new id.
- Harness: a new agent of that harness is spawned with the task, named `<original>-fb`.
- The result entry keeps `status: "limited"` and gains `fallback: {"agent": ..., "id": ...}`. A blocking gather keeps waiting on the new id within the same deadline; its answer fills `text`.
- A fallback that is itself limited is not followed further.

Without `fallback`, a limited task ends at once with `limited`.

### Watcher thread

Each cntctr process starts one watcher thread on its first tools/call. The watcher serves every pane this process has handled a call for (its "served panes"; one for Claude and agy, several for Codex's shared process). Every 30 s:

1. For each open async task (`@cntctr_to_<id>` set, `@cntctr_from_<id>` is a served pane, no `@cntctr_wait_<id>`): if the target pane is `limited`, apply the fallback if any, and type into the sender pane:
   `[cntctr] codex-2 hit usage limit (resets 3:00am); task 1a2b3c4d not done[; re-sent to claude-3 as 5e6f7a8b]`
   Each task is reported once (`@cntctr_limited_<id>`).
2. For each open task with `done_when` (section 2), report the file when it appears.
3. Deliver unread board posts to each served pane that is idle (section 3).

The watcher exits with the process. It never types into a pane that is `busy` or `permission`; notices wait for the next round where the pane is idle. Dedup lives in tmux options (`@cntctr_limited_<id>`, `@cntctr_done_<id>`, `@cntctr_seen_<name>`), so two processes serving one pane deliver once.

## 2. Status

`list` output gains fields after the existing four:

```
codex-2 codex %14 alive busy tasks=1a2b3c4d idle=12s
agy-1 agy %15 alive limited tasks=9f8e7d6c resets="resets 3:00am"
claude-4 claude %16 alive idle idle=4m
```

- **state**: `busy`, `idle`, `limited`, `permission`, or `dead`. Check order: dead, limited, permission, busy, idle. `busy` markers, observed live on 2026-11-08:

  | harness | busy when the last lines contain |
  |---|---|
  | Claude Code | `esc to interrupt` (status line) |
  | Codex | `esc to interrupt` (`• Working (40s • esc to interrupt)`) |
  | agy | `esc to cancel` (model working) or `task(s) · /tasks` (a background shell task is running, e.g. `● sleep 45 running`) |

  Anything else is `idle`.
- **tasks**: ids from `@cntctr_to_<id>` whose value is this pane.
- **idle**: now minus `#{window_activity}`.
- **resets**: only when `limited`.

`send` and gather tasks accept `done_when: "<path>"` (relative paths resolve against the worker's pane cwd). Stored as `@cntctr_done_<id>`. The sender's watcher types `[cntctr] codex-2 task 1a2b3c4d done: wrote ideas_claude.md` once the file exists, then clears the option. A reply also clears it.

Not built: last tool call, files written (harness-specific screen parsing).

## 3. Delivery

### Board

- `post` stores the post as today. It types into panes only with `urgent: true` (today's behaviour).
- The watcher delivers an agent's unread posts as one batch when its pane is `idle`:
  `[cntctr board] 3 new posts:\n- claude-1: ...\n- ...`
- Every tool result gains a last line `(N unread board posts; call board)` while N > 0.
- `@cntctr_seen_<name>` holds the newest post id the agent has seen. `board` and batch delivery advance it. An agent's own posts count as seen.

### Routing

- `spawn` sets `@cntctr_parent` on the new pane to the spawner's pane.
- `spawn` accepts `role` (e.g. `reviewer`), stored as `@cntctr_role`.
- `find_agent(to)` resolves, in order: `parent` (the caller's `@cntctr_parent`), an agent name, a role. Two live agents with the role fail with `role reviewer is ambiguous: claude-2, codex-3`.
- Every target (send, gather, fallback) goes through `find_agent`.

## 4. Smaller items

### Structured replies

`send` and gather tasks accept `reply_format`: an array of required keys. The envelope adds:
`Reply with a JSON object with keys: verdict, evidence, files.`
Stored as `@cntctr_fmt_<id>`. `reply` parses the text when the option is set; invalid JSON or missing keys fail with
`reply text must be a JSON object with keys verdict, evidence, files; missing: files`
and the reply is not delivered, so the worker retries. Gather returns the parsed object as `json`.

### Constraints

`spawn` and `send` accept `constraints` (string), stored on the target pane as `@cntctr_rules`. Every later envelope to that pane starts with `[constraints: <text>]`. `constraints: ""` clears it. The newest value wins.

### Errors

Every missing-argument error names the missing field(s) and ends with an example call, e.g.
`reply needs 'id' (missing). Example: reply {"id":"1a2b3c4d","text":"done"}`.
All `needs` errors in `cntctr.c` are covered.

### Stale notes

No code. The `note` and `recall` descriptions and the server instructions say: when a note goes stale, write the replacement with `supersedes=[old id]`, or `forget` it; recall hides both.

## Errors

| case | behaviour |
|---|---|
| tmux option write fails | the call fails as today; no partial task state |
| fallback target missing | task ends `limited` with `error: fallback <x> not found` |
| watcher cannot read a pane | skip it this round |
| `done_when` path never appears | nothing; the task stays open in `list` |
| `reply_format` set but worker cannot comply | worker sees the error each try; orchestrator sees the task open |

## Verification

All tests in `test.sh` on real tmux, with fake agent panes printing scripted screens (busy marker, limit message, permission prompt). `make test` must pass on `feat/qol`.

- Gather: three fake workers answer in different orders; results map to the right tasks.
- Partial results: one worker never answers, `timeout=2`; result has `timed_out`, and the later reply lands in the caller's pane.
- Cancel: send `notifications/cancelled` mid-gather; later replies land in the pane.
- Heartbeat: call with `_meta.progressToken`, `CNTCTR_HEARTBEAT_SECS=1`; at least one `notifications/progress` with that token before the result.
- Limit: a worker pane shows the limit text; blocking gather returns `limited` well before its timeout; with `fallback` the task reaches the fallback agent and its answer fills `text`.
- Async limit notice: async send to a pane that becomes limited; the caller pane gets one notice.
- Status: `list` shows `busy`, `idle`, `limited`, `permission`, task ids, idle time.
- `done_when`: file created; one notice in the sender pane.
- Board: non-urgent post is not typed into a busy pane; it is delivered once the pane is idle; tool results show the unread count; `urgent` types at once.
- Routing: worker sends `to: "parent"` and reaches its spawner while another orchestrator runs; ambiguous role fails with both names.
- `reply_format`: missing key fails the reply; valid reply reaches gather as `json`.
- `constraints`: second send to the agent carries the constraint line; `""` clears it.
- Errors: each tool's missing-field error names the field and has an example.

Then a live run from `~/.local/bin/cntctr-0.2.0` with real Claude, Codex and agy workers before the fleet-tools rebase.
