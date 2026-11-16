# Review skills implementation and validation

Date: 2026-11-16. Implemented by Terra and Gemini, coordinated through cntctr. Final integrated review: Gemini, APPROVE; Task 3 Spec PASS and Quality APPROVE. Product commits: `288832b` (Sol), `e1bc3e5` (council), `a3fbd75` (late-reply correction), `136d508` (release documentation).

## Delivered

- `skills/sol-loop/SKILL.md`: one persistent Sol reviewer and findings ledger.
- `skills/council/SKILL.md`: three independent Claude, Codex/Sol and agy/Gemini reviewers.
- `skills/LICENSE` and `skills/UPSTREAM.md`: exact MIT notice and upstream revision `11e37a74d0a6868c121cd0910ab2b3bd9873b92a`.
- README manual bundle installation, native adapters, upgrades, rollback, collision handling and invocation examples.

Both workflows default to three rounds or 30 minutes, whichever comes first, use waits of at most 60 seconds, retain pending IDs and require current-diff approvals. Missing results, permission blocks, model failures and unresolved disagreements do not count as approval. No C, hook, database or model-router changes.

## Live workflow checks

| Check | Observed result |
| --- | --- |
| Sol-loop, two rounds on one worker | Seeded total ignored quantity: expected 23, actual 7. Reviewer returned CHANGES/SOL-001; controller made the one-line multiplication fix; two tests passed and the same reviewer approved the corrected diff. |
| Council, two rounds with three independent workers | Seeded count returned number of groups, expected 3 items, actual 2. All seats reported the bug. After collecting all replies, controller made the one-line sum fix. All three approved the corrected diff and verified two passing tests. |
| Late reply after a short wait | Sol/council replies collected from the board by matching original task IDs, without re-dispatch or premature approval. |
| Unavailable model | Intentionally invalid Codex model produced an unsupported-model error and no verdict. Outcome remained incomplete; no fallback selected. |
| Trust prompt | Initial temporary-repository launch stopped at folder trust. Prompt was not bypassed; owned worker was stopped. Successful runs launched from the already trusted implementation checkout and reviewed the disposable target by absolute path. |

Reviewers were read-only; the controller alone fixed fixture code. Fixtures were disposable repositories under `/private/tmp`; no production files were changed by workflow tests. The controller loaded the new skill text directly before installation. Owned reviewer workers were cleaned up after testing.

Runtime settings: Sol UI showed GPT-6.1-Sol/high. Gemini UI and worker showed Gemini 3.8 Flash/high. Claude confirmed `claude-opus-5-5`; high effort was requested but not independently exposed, so remains unverified. Usage was not exposed and was not estimated.

## Discovery and installation checks

- Codex 0.169.0: a fresh local app-server `skills/list` response returned both skills as enabled, with resolved paths into the copied temporary bundle. A fresh worker also listed their project paths.
- Claude Code 2.1.325: a fresh startup catalog listed both skills through isolated `.claude/skills` directory links. Physical link targets were the copied bundle, not the development checkout.
- agy 1.5.9: fresh startups and its native `/skills` menu omitted skill-directory links and SKILL.md file links. A fresh session listed both skills after replacement with real project `.agents/skills` copies. The native menu identifies global `~/.gemini/antigravity-cli/skills` and shared `~/.gemini/skills` locations. The README uses release-managed real copies plus LICENSE for agy.
- The exact three README shell blocks were extracted and run with a temporary child-process home: first installation, upgrade, rollback, retained old/new bundles, and foreign directory/symlink preservation all passed. Link targets and agy skill/license contents matched their intended bundle. The rehearsal caught and corrected a quoting problem before the final commit; the corrected commands passed again independently.
- Both skill frontmatter validators passed. License bytes exactly matched the pinned upstream revision. Branch whitespace checks passed. The five implementation paths were exactly README plus the four planned skill/provenance files. The unrelated C test suite was not run.

## Manual protocol walkthroughs

These were synthetic walkthroughs, not live workflow results: stale approvals on an older diff cannot approve a newer diff; round/time exhaustion with open findings remains incomplete; repeated evidence-backed disagreement stops unresolved; permission-blocked seats require user action without bypass. A real trust-prompt observation and real unavailable-model/late-reply checks supplement these walkthroughs; they do not turn the synthetic cases into live passes.

## Decisions and remaining release checks

- The controller owned live tests while workers authored and reviewed the scoped files. Temporary workers and isolated discovery entries were removed; personal skill directories were untouched.
- agy requires real-copy adapters on the tested version. Release activation must update these from the same immutable bundle as the other harnesses; independent edits would drift. A future loader change may make simpler links possible, but needs a fresh discovery check.
- Personal global activation was intentionally not performed. At actual release, build/register the matching binary, activate the matching bundle, restart all harnesses and confirm both skills in their native catalogs, especially agy's global adapter. The documented upgrade/rollback commands preserve prior bundles and reject unexpected destinations.
- No push, merge, PR mutation or publishing was performed. Implementation remains in the isolated worktree for review/integration.
