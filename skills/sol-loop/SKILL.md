---
name: sol-loop
description: Use when the user requests a Sol loop or an iterative review of code changes by Sol.
---

# Sol loop

Get one independent Sol review of a fixed change scope, make minimal warranted fixes, and seek approval of the resulting diff. The orchestrator owns changes; the reviewer is read-only.

## Seats

| Seat | cntctr harness | Requested model | Requested effort |
| --- | --- | --- | --- |
| Sol | `codex` | router `hard` tier: the best Sol model | `high` (tier default) |

User overrides win. Spawn the Sol seat with `tier="hard"` and no `model`, so it always gets the router's best Sol model; never name a Sol version here. Record the requested tier and any user overrides as the requested settings. The resolved model and effort stay unverified unless runtime evidence exposes them: `spawn` with `wait=true` returns no launch summary, and the reviewer's own status line counts as evidence. Do not substitute another model. An unavailable or incompatible seat blocks approval. Record requested settings separately from actual settings verified by runtime evidence; otherwise mark actual model and effort unverified. Router configuration alone is not runtime evidence.

## Scope and budget

Default to at most 3 review rounds and 30 minutes wall-clock, whichever comes first, including fixes and checks. Only an explicit user override changes these limits; security or concurrency concerns do not automatically extend them. A round is one review request, including a follow-up. Before starting work or a tool wait, check remaining time. Start no wait with less than one whole second remaining. The deadline is cooperative, not preemption of a running process.

Record repository, intent, base revision, in-scope paths, out-of-scope work, working-tree and untracked changes, and relevant check results. Inspect status; do not stash, discard, or include unrelated work. Use the PR merge-base or an appropriate local base; if no remote exists, use the user's base or HEAD for uncommitted changes. Resolve ambiguous mixed scope with the user. Capture the initial diff size and checks, including pre-existing failures. Keep the same base and scope throughout; include untracked files explicitly. Keep scoped changes stable while a round is running.

## Run the review

1. Use cntctr MCP tools. Give `from` as your agent name if cntctr cannot identify your pane. Spawn one uniquely named reviewer with `harness=codex`, `tier="hard"` (no `model` or `effort` unless the user overrides them), and the repository as `cwd`. Bootstrap with a brief read-only readiness task; save the name and any returned task ID, and wait for its completed reply before the first review. If bootstrapping fails, report the seat incomplete. Do not spawn a replacement or another reviewer silently.
2. Send the review as a **new task** with `send` to that reviewer, omitting `re`, `wait=true`, and `timeout=min(remaining whole seconds, 60)`. Associate an immediate answer with that call; retain any returned message/task ID, especially the pending ID on timeout. Every completed round's follow-up is another new task, also omitting `re`: `re` adds context to an open task and cannot reopen a completed reply. Count each review request as a round.
3. For the bootstrap or review wait, use `wait=true` and a timeout no greater than `min(remaining whole seconds, 60)`. On an incomplete wait, retain the pending ID; check `list` and collect a correlated late reply from the pane or `board`, matching reviewer and message/task ID. Do not redispatch merely because a short wait expired, and do not count a prior task's answer for the current diff. Continue bounded collection only while time remains. Report `permission`, `limited`, `dead`, failed and timed-out states accurately. A permission prompt requires user action; surface it promptly, without bypassing it or waiting silently until expiry. Preserve partial findings. A missing or incomplete reply is never approval.
4. Give the reviewer this complete brief each round, with the same scope and current diff identity:

   > Review only; do not edit, commit, push, post, or start agents. Repository: <absolute path>. Intent: <intent>. Base: <revision>. Scope: <paths and untracked files>; excluded changes: <details>. Inspect the diff from that base and the listed untracked files, plus relevant surrounding code. Checks and known failures: <results>. Find correctness problems in the intended change and suggest the smallest fix. Classify findings as blocker, should, or nit. Return `VERDICT: APPROVE` or `VERDICT: CHANGES`, and stable IDs with severity, file:line, explanation and proposed minimal fix. Report model, effort and usage only if actually exposed.

5. Collect the complete round before editing. Keep a ledger with each stable ID, severity, location, explanation, proposed fix, outcome and evidence. Verify findings independently. Fix agreed in-scope issues minimally and run relevant checks; support disagreements with concrete code or test evidence. Decline out-of-scope findings and nits with reasons. Avoid adding unrelated changes. Record diff size and check results after fixes.
6. If behavior changed or a blocker/should remains open, and budget remains, send a new task to the same reviewer. Include the original brief, current diff identity, changes since the prior round, ledger and fix/check evidence; request review of changed code and open findings, with each old ID marked resolved or still open with a reason. Previous approval never covers a changed behavior diff. If the same disagreement persists through two replies, stop and report both positions and evidence for the user to decide. Nits alone do not require another round.

## Finish

Consensus requires a complete `APPROVE` for the current behavior diff, no open blocker or should, and no remaining concern of your own. Budget expiry, missing replies, unresolved disagreement, permission or model failure are incomplete or unresolved, not approval. Do not start a new review after expiry.

Report verdict and exact scope/current diff, rounds, requested versus verified model and effort, findings and dispositions, checks, initial and final diff size, exposed usage (or unavailable), unresolved issues and any external actions. Terminate only the reviewer created for this invocation when finished or stopped, using `kill` on its saved name; report cleanup failure. Do not use cross-tree access. Obtain task authorization before pushing, merging, posting comments or changing a PR description; review alone grants none.
