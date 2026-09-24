---
name: jev
description: Control the local TypeSafe JEV model router for Claude Code.
---

# /jev

Run the matching local command and report its output. The router is opt-in and
only sends task text to TypeSafe while enabled (or during an explicit test).

| Arguments | Command |
| --- | --- |
| `on` | `bash ~/.claude/jev-router/jev.sh on` |
| `off` | `bash ~/.claude/jev-router/jev.sh off` |
| `status` or empty | `bash ~/.claude/jev-router/jev.sh status` |
| `log [n]` | `bash ~/.claude/jev-router/jev.sh log [n]` |
| `debug on` / `debug off` | `bash ~/.claude/jev-router/jev.sh debug on|off` |
| `test <task>` | `bash ~/.claude/jev-router/jev.sh test <task>` |

The router classifies user prompts, direct slash/MCP prompt expansions,
programmatic Skill calls, and Agent tasks. A `PreToolUse` hook changes the
`Agent` tool's `model` argument before execution. Inside subagents, the same
hook also routes any nested Agent task.

For the current conversation, the hook provides a recommendation because
`UserPromptSubmit` cannot switch the active model. If it recommends a cheaper
model and the task is independent of the conversation, you may delegate via
`Agent(model=...)`. Never claim the main model changed merely because the hook
recommended one. `fable` is a supported Claude Code subagent model alias.

The router skips internal `/jev` invocations and routine file/shell tools.
Its logs contain short task hashes, not prompt text. A missing key or API
failure leaves Claude Code's normal behavior intact.
