# Upstream provenance

The sol-loop skill is adapted from [t3dotgg/tstack](https://github.com/t3dotgg/tstack) at commit `11e37a74d0a6868c121cd0910ab2b3bd9873b92a` (upstream HEAD checked 2026-11-16).

- Source: https://github.com/t3dotgg/tstack/blob/11e37a74d0a6868c121cd0910ab2b3bd9873b92a/skills/sol-loop/SKILL.md
- License: https://github.com/t3dotgg/tstack/blob/11e37a74d0a6868c121cd0910ab2b3bd9873b92a/LICENSE; the upstream MIT notice is reproduced in `LICENSE`.

The adaptation replaces T3 capability and delegation branches with cntctr MCP transport and one persistent Codex reviewer. It sets an explicit model and effort, distinguishes requested from verified settings, uses new task IDs for completed rounds, and adds bounded waits, pending reply collection, state reporting and owned-worker cleanup. It fixes review scope, adds a 30-minute ceiling alongside three rounds, removes automatic five-round escalation, and requires authorization for external writes. Minimal fixes, evidence-based disagreement and honest reporting remain central.
