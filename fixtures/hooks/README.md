# Hook Event Fixtures for cntctr 0.4.0

| Fixture | Status | Source / Field Changed |
|---|---|---|
| `claude-SessionStart.json` | measured | spike-hooks-claude.md:126 |
| `claude-UserPromptSubmit-mail.json` | measured | spike-claude/hook.log:1 (prompt replaced per rule) |
| `claude-UserPromptSubmit-other.json` | measured | spike-claude/hook.log:1 (prompt replaced per rule) |
| `claude-Stop.json` | measured | spike-hooks-claude.md:52 (stop_hook_active: false) |
| `claude-Stop-active.json` | measured | spike-hooks-claude.md:55 (stop_hook_active: true) |
| `claude-PermissionRequest.json` | measured | spike-hooks-claude.md:180-189 |
| `claude-PostToolUse.json` | measured | spike-hooks-claude.md:54 |
| `agy-PreInvocation-first.json` | measured | spike-hooks-agy.md:138,403 (prompt replaced per rule) |
| `agy-PreInvocation-second.json` | built | agy-PreInvocation-first.json: invocationNum changed to 1 |
| `agy-Stop.json` | measured | spike-hooks-agy.md:137 (executionNum: 0) |
| `agy-Stop-continued.json` | measured | spike-hooks-agy.md:141 (executionNum: 1) |
| `agy-Stop-error.json` | built | agy-Stop.json: terminationReason changed to ERROR |
| `agy-Stop-cancel.json` | built | agy-Stop.json: terminationReason changed to USER_CANCELED |

Summary: 10 measured, 3 built.
Missing from spike logs: agy Stop ERROR, agy Stop USER_CANCELED, agy PreInvocation second call.
