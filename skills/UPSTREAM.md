# Upstream provenance

The `sol-loop` and `council` skills are adapted from [t3dotgg/tstack](https://github.com/t3dotgg/tstack) at commit `11e37a74d0a6868c121cd0910ab2b3bd9873b92a` (upstream HEAD checked 2026-11-16).

- License: https://github.com/t3dotgg/tstack/blob/11e37a74d0a6868c121cd0910ab2b3bd9873b92a/LICENSE; the upstream MIT notice is reproduced in `LICENSE`.

## sol-loop

- Source: https://github.com/t3dotgg/tstack/blob/11e37a74d0a6868c121cd0910ab2b3bd9873b92a/skills/sol-loop/SKILL.md

The adaptation replaces T3 capability and delegation branches with cntctr MCP transport and one persistent Codex reviewer. It sets an explicit model and effort, distinguishes requested from verified settings, uses new task IDs for completed rounds, and adds bounded waits, pending reply collection, state reporting and owned-worker cleanup. It fixes review scope, adds a 30-minute ceiling alongside three rounds, removes automatic five-round escalation, and requires authorization for external writes. Minimal fixes, evidence-based disagreement and honest reporting remain central.

## council

- Source: https://github.com/t3dotgg/tstack/blob/11e37a74d0a6868c121cd0910ab2b3bd9873b92a/skills/council/SKILL.md

The adaptation replaces T3 capability probes and subagent tool delegation branches with cntctr MCP `gather` transport across three explicit fresh reviewer seats (Claude `claude-opus-5-5`, Codex via the router's `hard` tier (currently `gpt-6.2-sol`), and agy `gemini-3.8-flash-high`) at `effort=high`. It distinguishes requested from runtime-verified model/effort settings and records the agy seat as Flash. It enforces collection of all seat replies before making fixes (reversing upstream's advice to edit while other delegates run), requires consensus across all three seats on the current behavior diff (preventing earlier diff approvals from covering subsequent changes), adds bounded `<= 60s` waits with pending ID retention and `list` status inspection (permission, limited, dead), applies a 3-round and 30-minute cooperative budget ceiling without automatic 5-round escalation, requires task authorization for external writes, and cleans up invocation-owned workers with `kill`.
