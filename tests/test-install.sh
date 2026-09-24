#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
export JEV_CLAUDE_DIR="$TEMP_DIR/.claude"
export JEV_ROUTER_DIR="$JEV_CLAUDE_DIR/jev-router"
mkdir -p "$JEV_ROUTER_DIR"
printf 'fixture\n' > "$JEV_ROUTER_DIR/.env"
chmod 600 "$JEV_ROUTER_DIR/.env"
printf 'old log\n' > "$JEV_ROUTER_DIR/log.jsonl"
touch "$JEV_ROUTER_DIR/enabled"
jq -n '{model:"jev-latest",min_prompt_chars:12,session_model:"sonnet",context_threshold:0.3}' > "$JEV_ROUTER_DIR/config.json"
jq -n '{theme:"dark",hooks:{UserPromptSubmit:[{hooks:[{type:"command",command:"bash $HOME/.claude/jev-router/route.sh"}]},{hooks:[{type:"command",command:"other-hook"}]}]}}' > "$JEV_CLAUDE_DIR/settings.json"

bash "$ROOT/install.sh" >/dev/null
bash "$ROOT/install.sh" >/dev/null
[ "$(jq -r '.min_prompt_chars' "$JEV_ROUTER_DIR/config.json")" = 1 ]
[ "$(jq -r '.session_model' "$JEV_ROUTER_DIR/config.json")" = sonnet ]
[ "$(jq -r '.context_threshold' "$JEV_ROUTER_DIR/config.json")" = 0.3 ]
[ "$(jq -r '.enabled_events.agent_task' "$JEV_ROUTER_DIR/config.json")" = true ]
[ -f "$JEV_ROUTER_DIR/.env" ] && [ -f "$JEV_ROUTER_DIR/enabled" ]
[ "$(wc -l < "$JEV_ROUTER_DIR/log.jsonl" | tr -d ' ')" = 1 ]
[ "$(jq -r '.theme' "$JEV_CLAUDE_DIR/settings.json")" = dark ]
[ "$(jq '[.hooks.UserPromptSubmit[].hooks[] | select(.command=="other-hook")] | length' "$JEV_CLAUDE_DIR/settings.json")" = 1 ]
[ "$(jq '[.hooks.UserPromptSubmit[].hooks[] | select(.command|contains("jev-router/route.sh"))] | length' "$JEV_CLAUDE_DIR/settings.json")" = 1 ]
[ "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command|contains("jev-router/route.sh"))] | length' "$JEV_CLAUDE_DIR/settings.json")" = 1 ]
printf 'PASS: install preserves state and merges hooks idempotently\n'
