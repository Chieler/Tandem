---
name: council
description: Use when the user requests a council review or multi-model review of code changes across providers.
---

# Council

Get three independent reviews of a fixed change scope across different providers, make minimal warranted fixes, and seek approval of the resulting diff. The orchestrator owns changes; reviewers are read-only.

## Seats

| Seat | cntctr harness | Requested model | Requested effort |
| --- | --- | --- | --- |
| Claude | `claude` | `claude-opus-5-5` | `high` |
| Codex | `codex` | router `hard` tier: the best Sol model | `high` (tier default) |
| agy | `agy` | `gemini-4-hydrogen-high` | `high` |

User overrides win. Pass model and effort explicitly to `spawn` in `gather` for the Claude and agy seats. Spawn the Codex seat with `tier="hard"` and no `model`, so it always gets the router's best Sol model; never name a Sol version here, and record the requested tier and any user overrides as the requested settings. The resolved Codex model and effort stay unverified unless runtime evidence exposes them: `gather` returns no launch summary, and the reviewer's own status line counts as evidence. Do not substitute another model. Describe the agy seat by the model it actually runs (Hydrogen or Neon); do not claim a model without runtime proof. An unavailable or incompatible seat blocks approval. Record requested settings separately from actual settings verified by runtime evidence; otherwise mark actual model and effort unverified. Router configuration alone is not runtime evidence.

## Scope and budget

Default to at most 3 review rounds and 30 minutes wall-clock, whichever comes first, including fixes and checks. Only an explicit user override changes these limits; security or concurrency concerns do not automatically extend them. A round is one review request to each required seat, including a follow-up. Before starting work or a tool wait, check remaining time. Start no wait with less than one whole second remaining. The deadline is cooperative, not preemption of a running process.

Record repository, intent, base revision, in-scope paths, out-of-scope work, working-tree and untracked changes, and relevant check results. Inspect status; do not stash, discard, or include unrelated work. Use the PR merge-base or an appropriate local base; if no remote exists, use the user's base or HEAD for uncommitted changes. Resolve ambiguous mixed scope with the user. Capture the initial diff size and checks, including pre-existing failures. Keep the same base and scope throughout; include untracked files explicitly. Keep scoped changes stable while a round is running.

## Run the review

1. Use cntctr MCP tools. Give `from` as your agent name if cntctr cannot identify your pane. Spawn three uniquely named reviewers (independent fresh delegates, one for each seat) using `gather` with `kind=spawn`, harness (`claude`, `codex`, `agy`), the seat settings (explicit model and effort for Claude and agy; `tier="hard"` with no `model` or `effort` for Codex, unless the user overrides them), and the repository as `cwd`. Bootstrap each with a brief read-only readiness task; save each reviewer's name and returned task ID. Use `wait=true` and `timeout=min(remaining whole seconds, 60)`. Wait for completed readiness replies before the first review. If any seat fails bootstrapping or cannot be reached, report that seat incomplete. Do not spawn a replacement or another reviewer silently; an unavailable seat blocks consensus.
2. Send the review in parallel to all three reviewers using `gather` with `kind=send`, `to=<reviewer-name>`, `text=<brief>`, omitting `re`, `wait=true`, and `timeout=min(remaining whole seconds, 60)`. Retain returned message/task IDs for all seats, especially pending IDs on timeout. Every completed round's follow-up is another new parallel task set, also omitting `re`: `re` adds context to an open task and cannot reopen a completed reply. Count each review request across the three seats as one round.
3. For every `gather` wait, use `wait=true` and a timeout no greater than `min(remaining whole seconds, 60)`. On an incomplete wait where some or all seats do not answer before the timeout, retain all pending task/message IDs. Check `list` to inspect worker states: report `permission`, `limited`, `dead`, failed and timed-out states accurately rather than treating them all as timeouts. A permission prompt requires user action; surface it promptly, without bypassing it or waiting silently until expiry. Collect correlated late replies from the pane or `board` matching reviewer name and message/task ID. Do not redispatch a seat merely because a short wait expired, and do not count a prior task's answer for the current diff. Continue bounded collection only while time remains. Preserve partial findings. A missing, timed-out, or incomplete reply is never approval.
4. Give all three reviewers the identical complete brief each round, with the same scope and current diff identity:

   > Review only; do not edit, commit, push, post, or start agents. Repository: <absolute path>. Intent: <intent>. Base: <revision>. Scope: <paths and untracked files>; excluded changes: <details>. Inspect the diff from that base and the listed untracked files, plus relevant surrounding code. Checks and known failures: <results>. Find correctness problems in the intended change and suggest the smallest fix. Classify findings as blocker, should, or nit. Return `VERDICT: APPROVE` or `VERDICT: CHANGES`, and stable IDs with severity, file:line, explanation and proposed minimal fix. Report model, effort and usage only if actually exposed.

5. Collect the complete round from all three seats before editing. Keep a unified ledger with each stable ID, seat, severity, location, explanation, proposed fix, outcome and evidence. Verify findings independently. Fix agreed in-scope issues minimally and run relevant checks; support disagreements with concrete code or test evidence. Decline out-of-scope findings and nits with reasons. Avoid adding unrelated changes. Record diff size and check results after fixes.
6. If behavior changed or any blocker/should remains open from any seat, and budget remains, send a new parallel round to the same three reviewers via `gather`. Include the original brief, current diff identity, changes since the prior round, ledger and fix/check evidence; request review of changed code and open findings, with each old ID marked resolved or still open with a reason. Previous approval never covers a changed behavior diff: any code change after a seat's approval requires that seat to re-evaluate the updated diff. If the same disagreement persists through two replies with a seat, stop and report both positions and evidence for the user to decide. Nits alone do not require another round.

## Finish

Consensus requires a complete `APPROVE` from every required seat for the current behavior diff, no open blocker or should, and no remaining concern of your own. An absent, dead, or outstanding seat, budget expiry, unresolved disagreement, permission prompt, or model failure are incomplete or unresolved, not approval; a late reply collected and correlated within budget can count for its round and current diff. Do not start a new review after expiry.

Report overall verdict, exact scope and current diff identity, rounds, requested versus verified model and effort per seat, findings and dispositions by seat, checks, initial and final diff size, exposed usage (or unavailable), unresolved issues and any external actions. Terminate only the reviewers created for this invocation when finished or stopped, using `kill` on their saved names; report cleanup failure. Do not use cross-tree access. Obtain task authorization before pushing, merging, posting comments or changing a PR description; review alone grants none.
