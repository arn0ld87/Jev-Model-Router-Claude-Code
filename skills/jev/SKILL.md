---
name: jev
description: Toggle and inspect the Jev model router (TypeSafe System One model that picks the cheapest Claude tier per prompt). Use when the user types /jev on, /jev off, /jev status, /jev test <prompt>, or /jev log.
---

# /jev — Jev model router

The router is a `UserPromptSubmit` hook (`~/.claude/jev-router/route.sh`). When it is ON, every
non-slash prompt is sent to TypeSafe's Jev, which returns the cheapest Claude tier that can handle
it (`haiku` / `sonnet` / `opus` / `fable`) plus a probability that the request depends on earlier
conversation. Self-contained requests below the session model are delegated to a subagent with
that model; everything else stays in the session. Criteria, thresholds and the session model live
in `~/.claude/jev-router/config.json`.

Run exactly one command for the argument the user gave, then report its output in the language
the user writes in. Do not add commentary beyond the output unless asked.

| Argument | Command |
|----------|---------|
| `on` | `bash ~/.claude/jev-router/jev.sh on` |
| `off` | `bash ~/.claude/jev-router/jev.sh off` |
| `status` (or none) | `bash ~/.claude/jev-router/jev.sh status` |
| `test <prompt>` | `bash ~/.claude/jev-router/jev.sh test <prompt>` — dry run, prints Jev's decision, never changes the ON/OFF state |
| `log [n]` | `bash ~/.claude/jev-router/jev.sh log [n]` — last n decisions (default 20) |

Notes for you, the agent:
- `on` means prompt text leaves the machine (api.typesafe.ai). If the user is about to paste
  customer data or secrets, remind them once that the router is on.
- The hook only injects context; you still make the delegation call. When the injected line says
  DELEGATE, use the Agent tool with the named `model` and a self-contained prompt.
- The toggle takes effect on the next prompt; no restart needed.
