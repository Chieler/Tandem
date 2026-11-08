# Backlog

Releases: `v0.1.0` (tag on main, before fleet tools) and `0.2.0` (feat/fleet-tools plus the items below).
Source: orchestrator feedback, 2026-11-07, ranked by cost.

## 0.2.0

### Phase 1: gather that survives long waits
- [ ] Progress heartbeat during blocking waits (MCP `notifications/progress`, not typed into panes)
- [ ] Await all gather tasks at once and record replies as they arrive
- [ ] Return partial results on timeout; on cancel, deliver every late reply to the caller's pane
- [ ] `wait=false` returns a gather id; replies are typed into the caller's pane as they arrive; status tool shows results so far

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
- [ ] Guide text: `note supersedes=[id]` already hides stale notes from recall
- [ ] Shared resource claims for rate-limited APIs (maybe a fleet tool, not core)

## Done
- [x] Claude Code 30-minute idle timeout: cntctr entry `timeout` 3 h (2026-11-07)
- [x] Versioned installs: `v0.1.0` tag, `~/.local/bin/cntctr-0.1.0` live in all harnesses (2026-11-07)
