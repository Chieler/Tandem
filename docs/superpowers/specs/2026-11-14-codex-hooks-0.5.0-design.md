# cntctr 0.5.0: Codex hooks

Inputs: `.worktrees/_audit/codex-hooks-summary.md` (Codex 0.167.2 and 0.169.0 source, two independent read-only checks), 0.4.0 design `2026-11-12-hooks-0.4.0-design.md` (H0 to H10).

## Goal

0.4.0 kept Codex on the tmux path (H0): every send pastes the full envelope and state comes from the screen. Codex 0.169.0 has hooks with the same shape as Claude Code's. 0.5.0 gives Codex the 0.4.0 hook channel for two events, UserPromptSubmit and Stop, and keeps the paste path as the fallback. Judged against loss, flood and wrong tool, as in 0.4.0.

## Facts used (from the source checks)

- `~/.codex/hooks.json` has Claude Code's structure: `{"hooks": {"<Event>": [{"hooks": [{"type": "command", "command": ..., "timeout": ...}]}]}}`. User hooks need no project trust.
- Stdin: `session_id`, `turn_id`, `cwd`; UserPromptSubmit adds `prompt`; Stop adds `stop_hook_active`, `last_assistant_message`.
- UserPromptSubmit: `hookSpecificOutput.additionalContext` becomes developer context; `hookEventName` is required (live check L3: without it Codex warns "hook returned invalid user prompt submit JSON output" and drops the answer); over about 2,500 tokens Codex spills it to a file.
- Stop: `{"decision":"block","reason":...}` continues the turn with the reason as a user message. Stop rejects unknown keys. `stop_hook_active` stays true for the rest of the turn once a Stop was blocked. Stop fires only at a normal end.
- Default hook timeout 600 s; a timeout or crash counts as failed and the turn goes on.
- Trust: `[hooks.state."<source>:<event>:<group>:<index>"] trusted_hash` in `~/.codex/config.toml`, hashed over the whole handler (command, timeout, statusMessage). Untrusted hooks never run. The user trusts them at the "Hooks need review" screen of an interactive start.
- Hooks inherit the full environment, `TMUX_PANE` and `CNTCTR_PANE` included. Stdio MCP servers get only an allowlist, without `TMUX_PANE`.

## Decisions

### C1 Parse and answer (hooks.c)
`hook_parse` accepts `codex` with events `UserPromptSubmit` and `Stop`, reading the Claude Code keys (`session_id`, `prompt`, `stop_hook_active`). `hook_answer` for codex: attach on UserPromptSubmit as `hookSpecificOutput.additionalContext`; hold on Stop as `decision: block` plus `reason`; nothing else. Size cap 8192 bytes, as for Claude Code (under the 2,500-token spill). Neutral answer `{}`.

### C2 Server side (cntctr.c)
Codex is a hooked harness: `hook_cmd` reads codex events, `hook_row_has` accepts codex, `stop_normal` treats every codex Stop as normal (Codex sends Stop only at a normal end). A turn starts at UserPromptSubmit (no change). The Claude Code session-file lookup stays claude-only; a codex hook takes its pane from `CNTCTR_PANE` or `TMUX_PANE`, then the ancestor walk. No SessionStart is installed for codex, so the server start time is read once as for agy (existing path in `hook_decide`). Codex's sticky `stop_hook_active` gives what H5 wants already: at most one hold per turn.

### C3 Install (hooks.c)
`cntctr hooks install|remove codex` edits `~/.codex/hooks.json` with the Claude Code structure, events `UserPromptSubmit` and `Stop`, each entry with `"timeout": 5` (the hook ends itself after 1.8 s; 5 s bounds a hang instead of 600 s). The command is the running binary's path, as for claude and agy. Install from `~/.local/bin/cntctr`, the unversioned copy that each release overwrites: the command text, and so the trust hash, stays the same across upgrades. After a write, install prints: start `codex` once and choose to trust the cntctr hooks at "Hooks need review". cntctr never writes `[hooks.state]` and never passes `--dangerously-bypass-hook-trust`. `hooks status` lists codex.

### C4 Hand-started Codex sessions
A hand-started Codex's MCP server has no `TMUX_PANE`, so it never sets `@cntctr_srv` and its hooks act on nothing (paste path stays). Fix by configuration, not code: `env_vars = ["TMUX", "TMUX_PANE"]` under `[mcp_servers.cntctr]` in `~/.codex/config.toml`. Spawned agents keep the `-c mcp_servers.cntctr.env_vars=[...CNTCTR_*]` override. README documents both.

## Tests (test.sh, private tmux server)

- U4 changes: codex events now record; a codex agent with a prompt and a Stop on record has hooks; a send to it while idle pastes only the one-line wake, and the prompt-hook answer for that line holds the envelope.
- hook_parse/hook_answer for codex: attach JSON on UserPromptSubmit, block JSON on Stop, `{}` for other events and for a too-large answer.
- U28 for codex in a temporary HOME: install keeps other hooks, adds two entries with `timeout` 5, a second install changes nothing, remove takes out only cntctr's entries.

## Live checks (gate the release; need the user's trust click once)

- L1 a codex hook process sees the TUI pane's `TMUX_PANE` and has a `codex` ancestor (hooks run in the TUI process, not a shared daemon).
- L2 `{}` on UserPromptSubmit adds no context.
- L3 a send to an idle hooked codex agent: one line typed, full envelope in the model's context, reply arrives.
- L4 a spawned codex worker that stops without replying is held once with the reminder; a second Stop of the turn passes and its parent gets the notice.

## Not in 0.5.0
- `codex queue` delivery: the hook channel covers it; the queue fails before a session's first turn.
- Codex PermissionRequest and tool events for state: no permission-end event exists; screen state stays.
- 0.4.0 spawn-tree items (reviewer trees, killing a root, orphan error text, `@cntctr_root` timing): separate change.

## Added 2026-11-14: release config and spawn-tree rules

The user moved two items into 0.5.0.

### C4 at release
The release step adds `env_vars = ["TMUX", "TMUX_PANE"]` under `[mcp_servers.cntctr]` in `~/.codex/config.toml` (backup first), along with the binary repoint. Spawned codex agents keep their `-c` override.

### S1 Toolcheck reviewers are outside every tree (wrong tool)
A toolcheck reviewer (`is_reviewer`) shares the author's spawn tree, so the author can message or kill a pending reviewer without `cross`. `scope_error` refuses a reviewer target unless `cross` is set. cntctr's own cleanup (`review_cleanup`) does not go through `scope_error` and is unchanged.

### S2 A hand-started root is not killed from inside its tree (loss)
Any agent in a tree can kill the tree's root, a session the user started by hand. `kill` refuses a target that has no `@cntctr_parent` unless `cross` is set. The error says the target is a session started by hand and that `cross=true` is for when the user asked.

### S3 Orphan error names the dead parent (loss)
`to=parent` from an orphan says "you have no parent". When `@cntctr_parent` is set but that pane is dead, the error names the dead parent (its `@cntctr_name` if still readable, else its pane id) and the root by name when the root is alive: `your parent X is gone; your root is Y (send to="Y")`. "Only spawned agents have one" stays for a pane with no `@cntctr_parent`.

### S4 `@cntctr_root` set at start (loss)
`@cntctr_root` is set after `new-window` returns, so an agent that acts at once can run without it. Set it in the same tmux call that creates the window, as `@cntctr_name` is set.

### Tests
One test.sh case each: S1 author send/kill to reviewer refused without cross, allowed with; S2 worker kill of root refused, allowed with cross, kill of a worker sibling unchanged; S3 error text with dead parent; S4 root option present right after spawn.
