# Council and sol-loop skills

Status: implemented and reviewed on 2026-11-16, based on the design approved in conversation. Validation evidence is recorded in [the implementation report](../reports/2026-11-16-review-skills.md).

## Intent

Make `council` and `sol loop` available from Claude, Codex, and agy, with one maintained source of each workflow. Adapt the upstream t3dotgg/tstack skills to cntctr's existing delegation tools. Keep their useful review discipline without introducing a review engine into the server.

## Approaches and decision

- Independent harness copies are easy to install but drift when the protocol changes.
- A workflow implemented in cntctr's C server would centralize execution but add server state and release work for what are currently prose skills.
- Selected: canonical skill files in this repository, installed as a versioned bundle and exposed through each harness's supported skill discovery paths. The skill directs the workflow; cntctr supplies transport.

The user approved the third approach after a Codex/Opus discussion. Release-time copies replace the earlier suggestion of links into the development checkout. Harness links may point into an installed bundle, never into the working tree.

## Deliverables

| File | Responsibility |
| --- | --- |
| `skills/council/SKILL.md` | Discovery, reviewer seats, parallel review, findings, bounded follow-up, reporting and cleanup |
| `skills/sol-loop/SKILL.md` | Discovery, one persistent Sol reviewer, findings ledger, bounded follow-up, reporting and cleanup |
| `skills/LICENSE` | Upstream MIT copyright and permission notice |
| `skills/UPSTREAM.md` | Source repository, pinned upstream commit, adapted files and intentional differences |
| `README.md` | Install, discover, invoke, upgrade and roll back the skill bundle |

No executable installer is needed initially. Document explicit copy/link commands alongside the existing manual binary installation steps. A separate script is justified only if implementation shows these commands cannot remain small and reviewable.

## Shared protocol

1. Preserve upstream attribution and record an exact upstream revision before adapting the files. Remove T3 capability probes and delegation branches; use cntctr tools directly.
2. Bind review to a repository, intent, base revision, path scope, working-tree/untracked changes and check results. Do not mix unrelated changes into the review or discard them. Pass the same scope to every reviewer and follow-up.
3. Put explicit model and effort settings in a small Seats block in each skill. User overrides win. Do not depend on task-text routing or silently substitute a different reviewer. Report requested settings separately from settings actually verified.
4. Reviewers receive read-only briefs. The orchestrator owns fixes. Keep the reviewed changes stable while a round is running; collect that round before applying fixes. After a behavior change, previous approval does not cover the new diff.
5. Findings have stable IDs, severity, location, explanation and a proposed minimal fix. The orchestrator verifies findings, fixes agreed in-scope issues, and records evidence for disagreement or declined scope expansion. Do not turn nits into an obligation to enlarge the change.
6. Default budget: **3 review rounds and 30 minutes of wall-clock time**, whichever limit comes first, including checks and fixes. Three rounds is a ceiling, not a promise to complete three rounds within the time budget. These are workflow limits, configurable by the user, not new server settings. The time value is an implementation choice made during scoping. Check remaining time before starting work; do not initiate a new review after expiry. Tool deadlines fit inside the remaining budget. This is a cooperative workflow deadline, not preemption of a running harness or test process. Drop upstream's automatic five-round security/concurrency escalation; only an explicit user override raises these limits.
7. A round means one review request to each required seat, including a follow-up request. Only complete, current-diff approval from every required seat is consensus. Nits alone do not require another round. Missing seats, timeouts, exhausted budgets and unresolved disagreements are reported as incomplete or unresolved, never approval. Preserve useful partial findings.
8. Use `gather`/`send` with `wait=true` and `timeout=min(remaining whole seconds, 60)` to obtain structured results while staying responsive. Start no call with less than one second remaining. If a wait ends before the workflow deadline, retain pending IDs and collect correlated late replies from the pane or `board`; do not re-dispatch a review solely because its wait ended. Match replies by agent/message ID; do not count an earlier round's answer as a verdict on a later diff. Check `list` after an incomplete wait: report `permission`, `limited` and `dead` states accurately rather than treating them all as timeouts. A permission-blocked reviewer requires user action; do not bypass its prompt or wait silently until the whole budget expires. State `from` when cntctr cannot identify the calling pane.
9. Retain the created agent names and task IDs. Terminate only reviewers created for this invocation when done or stopped; do not use cross-tree access. Do not push, merge, post comments or change a PR description without task authorization.

## Council

- Three independent, freshly spawned reviewers: Claude, Codex/Sol, and agy/Gemini. The orchestrator is not one of the seats.
- Use `gather` to dispatch and collect the parallel seats. Subsequent rounds can send to those same workers; spawning a fresh reviewer means independent of the orchestrator, not mandatory respawning every round.
- Every seat must see the same round's scope and diff. Follow-ups include the findings ledger and fix/check evidence.
- Interpreting the approved design: agy supplies the Gemini seat; a single agy review is a different workflow.

## Sol-loop

- Spawn one Codex reviewer with an explicit Sol model and effort.
- Reuse that named agent through `send` for subsequent rounds. A new review round is a new task; `re` adds context to an open task and must not be used to reopen a completed reply.
- Preserve the upstream emphasis on minimal fixes, disagreement with evidence, and honest reporting of verdict, rounds, diff growth and exposed usage.

## Model and discovery compatibility

The current router includes `claude-opus-5-5`, `gpt-6.1-sol` and `gemini-3.8-flash-high`; router entries alone do not prove account availability. Candidate defaults pair each of these models with explicit `effort=high`. Verify them on the installed harnesses before release, and describe the agy seat as Flash if that is what it runs. In particular, verify agy's mapping between the effort-bearing model name and `--effort high`. Omitting effort does not disable the flag: cntctr fills an omitted effort from its router and passes it to the harness. Report effort as unverified until supported by runtime evidence; an incompatible model/effort pair blocks that seat rather than triggering omission or substitution. Do not claim a Gemini Pro or latest-flagship review based on a harness name. If a candidate is unavailable, report it rather than weakening the workflow silently.

Fresh-session project discovery was verified on Codex 0.169.0, Claude Code 2.1.325 and agy 1.5.9. Codex and Claude discover directory links into the copied bundle. agy omitted both directory and SKILL.md file links, but discovered real copies; its adapter therefore contains release-managed real files. The native agy menu names `~/.gemini/antigravity-cli/skills` as a global location. Personal global installation was not performed and remains a release-time discovery check. No reverse-engineering project or runtime capability discovery service is part of this change.

## Installation and release

- Bundle layout: `~/.local/share/cntctr/skills/X.Y.Z/`, containing both skill directories, `LICENSE` and `UPSTREAM.md`. `X.Y.Z` is the cntctr release version, matching the versioned binary and source tag. Do not overwrite a previously published bundle; a skill-only release also needs a new version.
- Preferred shared discovery entries: `~/.agents/skills/council` and `~/.agents/skills/sol-loop`, pointing into that installed bundle where supported. Claude gets entries in `~/.claude/skills`. agy needs real-copy adapters at its native `~/.gemini/antigravity-cli/skills` location, updated from the same bundle and carrying the MIT notice; verify this global location at release because authoring tested project discovery only.
- Document how to inspect an existing destination. Never replace an unrelated skill directory or link implicitly. Copy the complete bundle before activating links; keep the previous bundle for rollback.
- Extend the existing README manual installation/release steps with bundle copying and activation of both skills alongside binary/MCP configuration updates. Document upgrade and rollback for both skills together, restart/reload requirements, and verification that discovery resolves the intended release. Do not add hook changes to this release. Updating the repository alone does not update installed skills.
- A live home-directory installation is a separate release action; this implementation can verify copy/link behavior with temporary directories first.

## Validation and acceptance

1. Validate each skill's frontmatter and references. Record the upstream revision and include the MIT notice in the installed bundle.
2. Verify discovery of each skill from fresh Claude, Codex and agy sessions, recording harness versions and actual resolved paths. Temporary installation rehearsal covers activation, upgrade, rollback and collision handling without changing existing personal skills.
3. From one orchestrator, run one full live sol-loop and one full live council invocation against disposable repositories with a small seeded bug and a relevant failing check. Confirm reviewers remain read-only, the orchestrator fixes the bug, checks pass, and final verdicts cover the corrected diff. Confirm sol-loop reuses its reviewer and council obtains three independent replies. Do not repeat full flagship workflows from every harness; fresh-session discovery covers those entry points.
4. Exercise missing/unavailable reviewer, late or timed-out reply, unchanged disagreement, permission-blocked reviewer and exhausted-budget cases with small controlled scenarios using the existing tools and worker replies. Use shortened waits/budgets and invalid model requests where useful; do not build a mock transport framework or repeat full flagship reviews for these cases. Where a state cannot be triggered safely, record a manual protocol walkthrough as such, not a live pass. None may become approval, trigger automatic substitution or cause unrelated edits.
5. Test skills individually before combining the bundle. No separate pre-skill live baseline campaigns are required. Behavioral evaluation matters more than assertions that particular sentences appear in the Markdown. Do not run the unrelated C sanitizer suite solely for prose and release-documentation changes.

## Outside this change

No C/server changes, database or hook changes, model-router updates, new MCP tools, automatic PR publishing, worktree/sandbox enforcement system, broad skill synchronizer, or installation of other tstack skills. The knowledge store may retain the decision and point to the canonical files; it does not distribute executable workflow instructions.
