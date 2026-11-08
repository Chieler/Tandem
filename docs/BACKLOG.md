# Backlog

Releases:
- `v0.1.0`: tag on main, before fleet tools.
- `0.2.0`: branch feat/qol, off main. The items below, tested on their own.
- `0.3.0`: branch feat/fleet-tools, rebased onto 0.2.0 after it ships.
Source: orchestrator feedback, 2026-11-07, ranked by cost.

## 0.2.0

- [ ] Gather waits on all tasks at once; dead and usage-limited workers reported at once (`limited` with reset time)
- [ ] No lost replies: on timeout or cancel, late replies reach the caller's pane
- [ ] `gather wait=false`
- [ ] `list` reports idle, busy, permission, limited or dead, open task ids, idle time
- [ ] Board posts pull-only (unread count on tool results); `urgent` still interrupts
- [ ] `to: "parent"`
- [ ] Errors name the missing field and give an example call
- [ ] agy spawns skip the folder-trust prompt (`--settings` trustedWorkspaces)
- [ ] Guide text: `note supersedes=[id]` already hides stale notes from recall

### Deferred (build only if the problem comes back)
- Progress heartbeat: 3 h client timeout covers it; Claude Code's log shows progress resets its timer, but `progressToken` support is unverified
- Watcher thread (async limit notices, `done_when`, idle board delivery): gather `limited`, `list` and the unread count cover it
- Fallback agent on usage limit: the orchestrator re-sends after `limited`
- Roles: no observed failure
- `reply_format` validation: put the format in the task text
- `constraints`: put limits in the task text

## 0.3.0
- [ ] Rebase feat/fleet-tools onto 0.2.0
- [ ] Shared resource claims for rate-limited APIs (maybe a fleet tool, not core)

## Done
- [x] Claude Code 30-minute idle timeout: cntctr entry `timeout` 3 h (2026-11-07)
- [x] Versioned installs: `v0.1.0` tag, `~/.local/bin/cntctr-0.1.0` live in all harnesses (2026-11-07)
- [x] QoL split from fleet tools into its own release (2026-11-07)
