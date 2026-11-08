# Backlog

Releases:
- `v0.1.0`: tag on main, before fleet tools.
- `0.2.0`: branch feat/qol, off main. The items below, tested on their own.
- `0.3.0`: branch feat/fleet-tools, rebased onto 0.2.0 after it ships.
Source: orchestrator feedback, 2026-11-07, ranked by cost.

## 0.2.0

### Phase 1: gather that survives long waits
- [ ] Progress heartbeat during blocking waits (MCP `notifications/progress`, not typed into panes)
- [ ] Await all gather tasks at once and record replies as they arrive
- [ ] Return partial results on timeout; on cancel, deliver every late reply to the caller's pane
- [ ] `wait=false` returns a gather id; replies are typed into the caller's pane as they arrive; status tool shows results so far
- [ ] Detect an agent that hit its usage limit (pane text, like the permission-prompt check); tell the orchestrator at once instead of waiting out the timeout
- [ ] Optional fallback: re-send a limited agent's task to another agent or harness

### Phase 2: agent status
- [ ] `list` reports idle or busy, current task id, time since last activity
- [ ] "Done" event when an agent replies or writes a declared output file

### Phase 3: delivery
- [ ] Board posts go to a pull inbox; only direct sends and `urgent` posts interrupt
- [ ] Role aliases (`to: orchestrator`)

### Phase 4: smaller items
- [ ] Structured reply format set in the send call
- [ ] Task constraints repeated with every message in a task thread
- [ ] Errors name the missing field and give an example call
- [ ] agy spawns skip the folder-trust prompt (`--settings` trustedWorkspaces)
- [ ] Guide text: `note supersedes=[id]` already hides stale notes from recall

## 0.3.0
- [ ] Rebase feat/fleet-tools onto 0.2.0
- [ ] Shared resource claims for rate-limited APIs (maybe a fleet tool, not core)

## Done
- [x] Claude Code 30-minute idle timeout: cntctr entry `timeout` 3 h (2026-11-07)
- [x] Versioned installs: `v0.1.0` tag, `~/.local/bin/cntctr-0.1.0` live in all harnesses (2026-11-07)
- [x] QoL split from fleet tools into its own release (2026-11-07)
