# Hook Answer JSON Fixtures for cntctr 0.4.0

Empirical working answer JSON payloads from `spike-hooks-claude.md` and `spike-hooks-agy.md`.

## Claude Code (`claude`)

### SessionStart
- **Attach context** (`spike-hooks-claude.md:116-121`):
```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "The session context code word is CRIMSON-FALCON."
  }
}
```
- **Neutral answer** (`spike-hooks-claude.md:46`):
```json
{}
```

### UserPromptSubmit
- **Attach context** (`spike-hooks-claude.md:267-272`):
```json
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "MANDATORY: State the first word and the last word of the body below immediately without running any tools or shell commands:\n<content of body.txt>"
  }
}
```
- **Neutral answer** (`spike-hooks-claude.md:46`):
```json
{}
```

### Stop
- **Block the stop with a reason** (`spike-hooks-claude.md:42-44`):
```json
{
  "decision": "block",
  "reason": "You have mail. Run: cat /home/u/mail.txt and state the word."
}
```
- **Neutral answer** (`spike-hooks-claude.md:46`):
```json
{}
```

### PermissionRequest
- **Neutral answer** (`spike-hooks-claude.md:150`, `spike-claude/hook.py:60-61`):
```json
{}
```

### PostToolUse
- **Neutral answer** (`spike-hooks-claude.md:157`, `spike-claude/hook.py:63-64`):
```json
{}
```

---

## Antigravity CLI (`agy`)

### SessionStart
- **Attach context** (`spike-hooks-agy.md:74-80`, `spike-hooks-agy.md:237-243`):
```json
{
  "injectSteps": [
    {
      "systemMessage": {
        "systemMessage": "Secret code word from session context: ZEPHYR-KANGAROO-981."
      }
    }
  ]
}
```
- **Neutral answer** (`spike-hooks-agy.md:43`, `spike-hooks-agy.md:106`):
```json
{}
```

### PreInvocation
- **Attach context** (`spike-hooks-agy.md:378-384`):
```json
{
  "injectSteps": [
    {
      "systemMessage": {
        "systemMessage": "You have received an external message. Instructions: State the first word and the last word of this message.\n\n<body content>"
      }
    }
  ]
}
```
- **Neutral answer** (`spike-hooks-agy.md:399`, `spike-hooks-agy.md:106`):
```json
{}
```

### Stop
- **Block the stop with a reason** (`spike-hooks-agy.md:67-70`):
```json
{
  "decision": "continue",
  "reason": "You have mail. Run: cat /home/u/mail.txt and state the word."
}
```
- **Neutral answer** (`spike-hooks-agy.md:63`, `spike-hooks-agy.md:106`):
```json
{}
```
