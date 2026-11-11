# cntctr 0.2.0: no lost replies, agent status, quiet board

## Purpose

An orchestrator running Claude, Codex and agy workers reported what cost it the most in one session (2026-11-07):

1. Claude Code killed a gather after 30 silent minutes, and every reply in it was lost.
2. It could not tell whether a worker was busy, stuck, done or out of usage without reading tmux panes.
3. Board posts were typed into every pane and interrupted workers mid-task; a message meant for one orchestrator reached another.
4. Smaller costs: vague errors, a folder-trust prompt on every agy spawn, stale notes.

The 30-minute kill is already fixed outside cntctr: the cntctr entry in `~/.claude.json` has `"timeout": 10800000` (3 h).

0.2.0 fixes the rest on branch `feat/qol`, off `main` (`v0.1.0`). It ships and is tested alone. Fleet tools (`feat/fleet-tools`) are rebased onto it afterwards as 0.3.0. Tracking: `docs/BACKLOG.md`.

Scope rule: build only what fixes something that went wrong in real use. Deferred items and why are listed at the end.

## Outcomes

- No reply is ever lost: on timeout or cancel, late replies reach the caller's pane.
- A gather reports each worker as `answered`, `timed_out`, `dead`, `limited` or `failed`, so partial results are usable. A dead or usage-limited worker is reported at once, not after the timeout.
- `gather wait=false` sends every task and returns at once.
- `list` shows each agent's state, open tasks and idle time.
- Board posts never interrupt anyone unless marked urgent.
- Workers reach the orchestrator that spawned them with `to: "parent"`.

## Background: what exists

- `await_reply` (`cntctr.c:await_reply`) blocks on one task in 5 s slices, checking for a lost signal and a dead pane. `tool_gather` dispatches every task, then awaits them one after another.
- `tool_reply`: when the sender is not waiting (`@cntctr_wait_<id>` unset), the reply is typed into the sender's pane. Late replies already use this path; a `delete-buffer` claim makes delivery exactly-once.
- `@cntctr_to_<id>` holds the pane of each unanswered task (`track_to`).
- `awaiting_permission` reads the last 15 lines of a pane with `capture-pane` and matches regexes (`PROMPTS`).
- Claude and agy run one cntctr process per pane. Codex runs one shared process outside any pane; the caller's pane is resolved per call (`caller_pane`).
- `note supersedes=[ids]` and `forget` already hide entries from `recall`.

## 1. Screen state

`pane_state(pane)` classifies a pane from its last 15 lines. Check order: dead, limited, permission, busy, idle. The patterns live beside `PROMPTS`, with the date they were observed, because harness updates can change them.

Usage limit (case-insensitive):

| harness | screen text (observed 2026-11-08) | regex |
|---|---|---|
| Claude Code | `You've hit your session limit · resets 10:40pm (America/Chicago)`, `You've hit your weekly limit` | `hit your (session\|weekly\|usage) limit` |
| Claude Code | `Usage limit reached · continuing automatically at 10:40pm · esc to cancel` | `usage limit reached` |
| Codex | `Usage limit reached` / `Request a limit increase from your owner to continue using codex.` | `usage limit reached` |
| agy | `⚠ Individual quota reached. ... Resets in 143h57m55s.` | `individual quota reached` |

`resets` is the text after `resets`, `Resets in` or `continuing automatically at`, trimmed; empty if none. Claude Code can resume on its own after the reset, so a limited worker may still answer later; that reply reaches the caller's pane like any late reply.

Busy (observed live 2026-11-08):

| harness | busy when the last lines contain |
|---|---|
| Claude Code | `esc to interrupt` (status line) |
| Codex | `esc to interrupt` (`• Working (40s • esc to interrupt)`) |
| agy | `esc to cancel` (model turn) or `N task(s)` (background shell task, e.g. `● sleep 45 running`) |

Anything else is `idle`.

### `list`

Output gains fields after the existing four:

```
codex-2 codex %14 alive busy tasks=1a2b3c4d idle=12s
agy-1 agy %15 alive limited tasks=9f8e7d6c idle=40s resets="143h57m55s"
claude-4 claude %16 alive idle idle=240s
```

- state: `busy`, `idle`, `limited`, `permission`, `dead`.
- tasks: ids from `@cntctr_to_<id>` whose value is this pane.
- idle: seconds since `#{window_activity}`.
- resets: only when `limited`.

## 2. Waiting

Gather, blocking `send` and blocking `spawn` share one loop. Every second it checks each pending task for:

- a reply buffer: claim it (`answered`),
- a dead pane: `dead`,
- a limited pane: `limited`, with `resets`.

The loop ends when no task is pending, the deadline passes, or the call is cancelled.

### No lost replies

When the loop ends, every pending task's `@cntctr_wait_<id>` is cleared, then its buffer is claimed once more (a reply that raced the clear). From then on `tool_reply` finds no waiter and types late replies into the caller's pane through the existing path. Tasks still unanswered become `timed_out`.

After a cancel nobody reads the result, so every answer the call holds (claimed earlier or in that last claim) is typed into the caller's pane.

Limited and dead tasks also clear their wait flag, so a limited worker that resumes after its reset still delivers.

A blocking `send`/`spawn` to a limited worker returns `agent <name> hit its usage limit (resets <time>); reply will arrive in your pane (id=<id>)`.

### Async gather

`wait=false` (default true) sends every task and returns at once, each with `status: "sent"` and its id. Replies arrive in the caller's pane.

### Result shape

Unchanged except new statuses and the `resets` field:

| status | fields |
|---|---|
| `answered` | `text` |
| `timed_out` | — (reply will arrive in the pane) |
| `dead` | `error` |
| `limited` | `resets` |
| `failed` | `error` |
| `sent` | — (`wait=false`) |

## 3. Board: pull, not push

- `post` stores the post. It types into other panes only with `urgent: true` (today's behaviour).
- Every tool result for an agent with unread posts ends with `(N unread board posts; call board)`. Results that are JSON (gather) are left untouched.
- `@cntctr_seen_<name>` holds the newest post rowid the agent has seen; `board` advances it. An agent's own posts count as seen.

## 4. Routing: `to: "parent"`

- `spawn` sets `@cntctr_parent` on the new pane to the spawner's pane.
- `send` and gather tasks accept `to: "parent"`, resolved to the caller's `@cntctr_parent`. No parent, or a dead one: `you have no parent (only spawned agents have one)`.
- Agent names keep working as before.

## 5. Smaller items

### Errors

Every missing-argument error names the missing field(s) and ends with an example call, e.g.
`reply needs 'id', 'text' (missing: id). Example: reply {"id":"1a2b3c4d","text":"done"}`.
All `needs` errors in `cntctr.c` are covered.

### agy folder trust

agy asks "Yes, I trust this folder" in any cwd missing from `trustedWorkspaces` in `~/.gemini/antigravity-cli/settings.json`; the list holds exact paths. `start_spawn` passes agy `--settings '{"trustedWorkspaces":["<realpath of cwd>"]}'`. The flag applies to that session only and is never saved, so cntctr does not write agy's config. Verified 2026-11-08: no prompt in a new folder, settings file unchanged.

### Guide text

No code. The `note` description and the server instructions say: when a note goes stale, write the replacement with `supersedes=[old id]`, or `forget` it; recall hides both. The instructions also mention `to="parent"` and that board posts are pull-only unless `urgent=true`.

## Errors

| case | behaviour |
|---|---|
| tmux option write fails | the call fails as today; no partial task state |
| pane cannot be captured | treated as dead |
| board query fails | tool result has no unread line |

## Verification

All tests in `test.sh` on real tmux, with fake agent panes printing scripted screens (busy marker, limit message, permission prompt). `make test` must pass on `feat/qol`.

- Status: `list` shows `busy`, `idle`, `limited` (with reset), task ids, idle time; limit text older than the last 15 lines is ignored.
- Gather: answers out of order map to the right tasks; a limited worker returns `limited` well before the timeout; a dying worker returns `dead`.
- Partial results: one worker never answers, short timeout; result has `timed_out`, and the later reply lands in the caller's pane.
- Cancel: `notifications/cancelled` mid-gather; an answer claimed before the cancel and one arriving after both land in the pane.
- `wait=false`: returns at once with ids; the reply lands in the pane.
- Board: a non-urgent post is not typed into any pane; tool results show the unread count; JSON results do not; `board` clears it; `urgent` types at once.
- Routing: a spawned worker's `to: "parent"` reaches its spawner; a non-spawned caller gets the no-parent error.
- Errors: each tool's missing-field error names the field and has an example.
- agy trust: the spawn argv for agy carries `--settings` with the cwd's realpath.

Then a live run from `~/.local/bin/cntctr-0.2.0` with real Claude, Codex and agy workers before the fleet-tools rebase.

## Deferred

Kept in `docs/BACKLOG.md`; build one only if its problem shows up again.

| item | why deferred | cheaper cover today |
|---|---|---|
| Progress heartbeat | 3 h client timeout fixed the 30 min kill. Claude Code's log (`no response or progress notification for 1804s`) shows progress resets its timer, but whether it sends a `progressToken` is unverified. | 3 h `timeout` |
| Watcher thread (async limit notices, `done_when`, idle board delivery) | Background thread typing into panes, dedup across processes. | gather `limited`, `list`, worker replies, unread count |
| Fallback agent on limit | Server-side re-sends mid-gather are hidden state. | Orchestrator re-sends after `limited` |
| Roles | No observed failure. | Agent names, `parent` |
| `reply_format` validation | Rejecting replies can leave a worker retrying. | Format instructions in the task text |
| `constraints` | No repeated drift yet. | Limits in the task text |
| Resource claims for rate-limited APIs | Belongs with fleet tools (0.3.0). | — |
