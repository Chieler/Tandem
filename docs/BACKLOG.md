# Backlog

Releases:
- `v0.1.0`: tag on main, before fleet tools.
- `0.2.0`: on main, tag `v0.2.0` (2026-11-08); live in all harnesses as `~/.local/bin/cntctr-0.2.0`.
- `0.3.0`: on main, tag `v0.3.0` (2026-11-12); live in all harnesses as `~/.local/bin/cntctr-0.3.0`.
- `0.4.0`: on main, tag `v0.4.0` (2026-11-13); Claude Code hooks, agents scoped by spawn tree.
Source: orchestrator feedback, 2026-11-07, ranked by cost.

## 0.2.0

- [x] Gather waits on all tasks at once; dead and usage-limited workers reported at once (`limited` with reset time)
- [x] No lost replies: on timeout or cancel, late replies reach the caller's pane
- [x] `gather wait=false`
- [x] `list` reports idle, busy, permission, limited or dead, open task ids, idle time
- [x] Board posts pull-only (unread count on tool results); `urgent` still interrupts
- [x] `to: "parent"`
- [x] Errors name the missing field and give an example call
- [x] agy spawns skip the folder-trust prompt (`--settings` trustedWorkspaces)
- [x] Guide text: `note supersedes=[id]` already hides stale notes from recall

### Deferred (build only if the problem comes back)
- Progress heartbeat: 3 h client timeout covers it; Claude Code's log shows progress resets its timer, but `progressToken` support is unverified
- Watcher thread (async limit notices, `done_when`, idle board delivery): gather `limited`, `list` and the unread count cover it
- Fallback agent on usage limit: the orchestrator re-sends after `limited`
- Roles: no observed failure
- `reply_format` validation: put the format in the task text
- `constraints`: put limits in the task text
- False `limited` when a worker's own output quotes limit text (e.g. editing cntctr.c); anchor LIMITS regexes once real screen samples exist
- kb_unread builds a text list nobody reads; replace with one SELECT max(rowid), sum(sender != me)

## 0.3.0
- [x] Merge 0.2.0 and fleet tools with one version and isolated test sockets
- [x] Addressed or urgent delivery only; announcements stay on the board
- [x] Separate unread result blocks; durable reply fallback and FIFO redelivery
- [x] End markers and `send re=<open id>` addenda
- [x] Complete large-output cache files and stderr tails
- [x] Reviewer-only verdict listing, review task closure, dynamic fences and visibility notifications
- [x] Board truncation counts, tab-safe agent lists, private FIFO directories, board index, word routing and agent cap
- [x] macOS hard-link and Unix-socket sandbox restrictions
- [x] Tool wording, argument examples and capped knowledge index

### Open after 0.3.0

- Bind identity to the connection instead of trusting `from` or `TMUX_PANE`; agents currently share one user and trust each other.
- Kill fleet tools on client disconnect; their timeout currently bounds execution.
- Anchor permission detection to the active dialog after collecting real screen samples; board fallback protects false positives.
- Protect against hard links already present before the sandbox starts; creating them requires an actor outside the sandbox.
- Verify bwrap Unix-socket isolation and hard-link behavior on Linux (not testable on macOS).
- Detect wait-graph deadlocks; all waits currently have finite timeouts.
- Reproduce the root cause of truncated pastes with a real Claude Code pane during adversarial review.
- Clean stale review findings from shared insights against the released code.
- [ ] Shared resource claims for rate-limited APIs (maybe a fleet tool, not core)

## 0.4.0
- [x] Claude Code hooks: waiting mail attached at the next prompt, turn held at its end for a wake; hooks never type into a pane or answer a permission prompt
- [x] `@cntctr_srv` pane marker: hook paths act only when a live 0.4.0 server serves the pane; schema stamp never lowered
- [x] `list` shows owner and directory, your own spawn tree by default; send, gather and kill outside the tree need `cross=true`
- [x] `from=` never overrides the caller's own pane

### Open after 0.4.0
- Toolcheck reviewers share the author's tree: the author can message or kill a pending reviewer without cross (commit e929339 had kept them apart).
- Any agent in a tree can kill the tree's root, a hand-started session, without cross; refuse a target with no `@cntctr_parent` unless cross is set.
- An orphan's `to=parent` error says "you have no parent"; name the dead parent and point to the root by name.
- `@cntctr_root` is set after new-window returns; set it in the start command like `@cntctr_name`.
- `@cntctr_srv`: a dead marker is replaced by an unconditional set (last writer wins); no re-claim after its owner leaves; the COMMIT-fail branch is untested.
- Any caller can mark any message id answered.
- Hooks point at a versioned binary: re-run `cntctr hooks install` after each upgrade.
- agy hooks (`~/.gemini/config/hooks.json`); Codex hooks in 0.5.0 (UserPromptSubmit and Stop only, command on an unversioned path so trust survives upgrades).

## Done
- [x] Claude Code 30-minute idle timeout: cntctr entry `timeout` 3 h (2026-11-07)
- [x] Versioned installs: `v0.1.0` tag, `~/.local/bin/cntctr-0.1.0` live in all harnesses (2026-11-07)
- [x] QoL split from fleet tools into its own release (2026-11-07)
