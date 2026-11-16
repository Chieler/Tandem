# Council and sol-loop implementation plan

> **Execution:** Implemented with Terra and Gemini through cntctr, as requested by the user. Terra authored sol-loop and installation documentation; Gemini authored council. Each reviewed the other model's work; Gemini approved the final integrated change. The controller ran the live workflow tests.

**Goal:** Make council and sol-loop discoverable across the three harnesses using shared, versioned skills and cntctr delegation.

**Architecture:** Canonical Markdown skills live in this repository. A release copies them into a versioned installed bundle; harness discovery entries expose that bundle. Review protocol stays in the skills and transport stays in cntctr.

**Tech Stack:** Agent Skills Markdown/YAML, existing cntctr MCP tools, documented shell copy/link commands.

**Spec:** `docs/superpowers/specs/2026-11-16-review-skills-design.md`

## Global constraints

- Default budget: 3 review rounds and 30 minutes of wall-clock time, whichever limit comes first, configurable by the user. No automatic security/concurrency escalation.
- Three independent council seats: Claude, Codex/Sol, agy/Gemini. One persistent Sol reviewer for sol-loop.
- Explicit model and effort settings; no silent substitutions. Missing results and budget expiry are not approval.
- No C/server, hooks, database or router changes; no live home installation as part of authoring.
- No discovery link points at the development checkout. Preserve unrelated installed skills and retain the previous bundle.
- Bundle version `X.Y.Z` matches the cntctr release version. Do not overwrite a published bundle.
- Preserve the upstream MIT notice and pin the source revision.

## Review focus

- Existing skill directory or foreign symlink: installation instructions preserve it and require an explicit resolution.
- Timed-out or late seat: retain pending IDs without re-dispatch; check `list` for permission, limited or dead states. Partial findings remain useful, but no approval is invented.
- Code changes after approval: all required approvals must cover the final behavior diff.
- Fresh harness session: discovery resolves the installed release, not a working checkout or stale copy.
- Completed Sol task: follow-up creates a new task on the same worker instead of adding to a closed task ID.

## Task 1: Adapt and verify sol-loop

**Files:** Create `skills/sol-loop/SKILL.md`, `skills/LICENSE`, `skills/UPSTREAM.md`.

**Interfaces:** Consumes cntctr `spawn`, `send`, `list`, `kill`, and optionally `board`. Produces the complete standalone Sol review skill and the shared upstream provenance records.

- [x] Pin an upstream commit and read its complete sol-loop source and license. Record source URLs, revision and deliberate cntctr-specific differences in `skills/UPSTREAM.md`; copy the MIT notice verbatim to `skills/LICENSE`.
- [x] Prepare one disposable repository with a seeded bug and a relevant failing check. Define small failure scenarios using existing tools and controlled worker replies, not a new mock framework or pre-skill baseline campaign.
- [x] Write the minimal adapted skill with precise invocation frontmatter, explicit Seats block, fixed review scope, findings ledger, one persistent reviewer, new task IDs per completed round, 3-round/30-minute defaults and owned-worker cleanup. Use `send(wait=true, timeout=min(remaining whole seconds, 60))`, retain pending IDs across short waits, and check `list` on incomplete results. Remove T3 branches and automatic five-round escalation. Require reporting requested versus verified settings and authorization for external writes.
- [x] Run `rtk proxy python3 /Users/chielerli/.codex/skills/.system/skill-creator/scripts/quick_validate.py skills/sol-loop` and inspect all references and provenance. Expected: valid skill, no unresolved references or missing upstream notice.
- [x] Run one full live corrected-loop scenario from the chosen orchestrator, with runtime model/effort evidence. Expected: minimal bug fix and passing relevant check; same reviewer reused; final approval covers the corrected diff. Run small controlled failure scenarios with shortened waits/budgets: unavailable model, late reply, unchanged disagreement and expiry remain unresolved and do not touch unrelated files. Save concise evidence; label protocol walkthroughs separately from live checks.

## Task 2: Adapt and verify council

**Files:** Create `skills/council/SKILL.md`; update `skills/UPSTREAM.md` with the council adaptation.

**Interfaces:** Consumes cntctr `gather` spawn/send tasks and the same lifecycle tools as Task 1. Produces a standalone three-seat council skill with no dependency on loading sol-loop.

- [x] Read the complete council source at the pinned revision. Define small scenarios for one missing seat, a late reply, a permission-blocked seat and a fix made after earlier approval; no separate live baseline is required.
- [x] Write the skill with three explicit fresh seats, identical read-only round briefs, parallel dispatch, collection before fixes, evidence-backed findings, the same finite defaults, and cleanup of invocation-owned workers. Use `gather(wait=true, timeout=min(remaining whole seconds, 60))`; collect pending replies by ID without re-dispatch and inspect `list` states after an incomplete wait. Include model/effort verification limits and incomplete-result reporting. Keep shared rules self-contained and short instead of introducing a generic protocol engine.
- [x] Run `rtk proxy python3 /Users/chielerli/.codex/skills/.system/skill-creator/scripts/quick_validate.py skills/council` and inspect references and provenance. Expected: valid skill, no T3 tool probes or unsupported fallback promises.
- [x] Run one full live disposable seeded-bug scenario with three independent seats from the same orchestrator used for sol-loop. Verify that the orchestrator alone edits, final verdicts refer to the corrected diff, and nits do not enlarge scope. Use small controlled failure scenarios through existing tools to check that an absent/stale seat cannot complete consensus and permission blocks are reported accurately. Do not bypass prompts; record any manual walkthrough separately from live evidence.

## Task 3: Document and verify versioned installation

**Files:** Modify `README.md` in Install/Use; adjust either skill only for compatibility facts found here.

**Interfaces:** Consumes the two completed skill directories and provenance files. Produces manual bundle installation, discovery, activation, upgrade and rollback instructions.

- [x] Record installed harness versions. Check each harness's actual discovery of shared skill directories and symlinks. Prefer `~/.agents/skills`; add only adapters demonstrated necessary. Use the two live runs from Tasks 1 and 2 to verify candidate model IDs and explicit `effort=high` against account behavior. For agy, verify the effort-bearing model name works with the explicit effort flag; omission is not a workaround because cntctr supplies routed effort. Block on incompatibility; do not claim verified execution from a router entry.
- [x] Add exact commands to copy both skills, `LICENSE` and `UPSTREAM.md` into `~/.local/share/cntctr/skills/X.Y.Z/`, then activate supported discovery links. `X.Y.Z` matches the cntctr release version. Explain inspection of existing destinations, no reuse of published bundle versions, release provenance, reload requirements and how to preserve collisions. No force-overwrite commands.
- [x] Extend the existing README manual binary/MCP installation and upgrade steps: validate skills, copy the matching versioned bundle, activate both skills, confirm discovery and retain the previous version. Include rollback commands and example invocations from each harness. Do not change hooks or update unrelated release history. State that no push, merge or PR mutation is implied by invoking a review.
- [x] Rehearse the documented commands under a temporary home/directory prefix: first installation, upgrade, rollback, existing-directory collision and foreign-link collision. Expected: correct link targets after each deliberate activation, intact old bundles and untouched unrelated entries.
- [x] Smoke-check fresh-session discovery from all three harnesses and record actual resolved paths and versions. Reuse the live workflow/model evidence from Tasks 1 and 2; do not repeat full review workflows per harness. A live install into personal skill paths remains a release action, not an implicit authoring step.

## Completion

- [x] Review the diff against the spec and check that all five review-focus conditions have evidence. Run `rtk git diff --check` and both skill validators. No unrelated full C test run is required.
- [x] Report created/modified files, provenance revision, model and discovery compatibility, behavioral results, and any remaining release-only checks. Distinguish full live workflows, controlled failure scenarios and manual protocol walkthroughs.
- [x] Commit only the scoped files if committing is part of the execution request; do not publish or install into the user's home automatically.
