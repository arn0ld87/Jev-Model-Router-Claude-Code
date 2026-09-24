#!/usr/bin/env bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT
export PATH="$TEMP_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
mkdir -p "$TEMP_DIR/bin" "$TEMP_DIR/router"
cp "$ROOT/jev-router/"{route.sh,router-core.sh,jev.sh,config.json} "$TEMP_DIR/router/"
touch "$TEMP_DIR/router/enabled"
export JEV_ROUTER_DIR="$TEMP_DIR/router"
export TYPESAFE_API_KEY="test-only-placeholder"
export MOCK_COUNT="$TEMP_DIR/curl-count"
export MOCK_ROUTE=haiku

# The fixture consumes the body on fd 3, as real curl does.
printf '%s\n' '#!/usr/bin/env bash' \
  'payload=$(</dev/fd/3)' \
  'jq -e . <<< "$payload" >/dev/null || exit 9' \
  'printf x >> "$MOCK_COUNT"' \
  'case "${MOCK_FAILURE:-}" in api) exit 22;; invalid) printf "not json"; exit 0;; esac' \
  'jq -cn --arg route "${MOCK_ROUTE:-haiku}" '\''{answers:{route:{choice:$route,confidence:0.93},needs_context:{noul:0.18}},usage:{input_tokens:24}}'\''' \
  > "$TEMP_DIR/bin/curl"
chmod +x "$TEMP_DIR/bin/curl"

assert() {
  local label="$1" expression="$2" json="$3"
  if ! jq -e "$expression" <<< "$json" >/dev/null; then
    printf 'FAIL: %s\n' "$label" >&2
    if [ -f "$JEV_ROUTER_DIR/log.jsonl" ]; then
      jq -s '.[-2:]' "$JEV_ROUTER_DIR/log.jsonl" >&2
    fi
    exit 1
  fi
  printf 'PASS: %s\n' "$label"
}
count_calls() { [ -f "$MOCK_COUNT" ] && wc -c < "$MOCK_COUNT" | tr -d ' ' || printf 0; }
hook() { printf '%s' "$1" | bash "$JEV_ROUTER_DIR/route.sh"; }

user=$(hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"Wo liegt die Config?"}')
assert 'user prompt recommendation' '.hookSpecificOutput.additionalContext | contains("haiku")' "$user"
[ "$(count_calls)" = 1 ]

short=$(hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"teste"}')
assert 'short prompt is classified' '.hookSpecificOutput.hookEventName=="UserPromptSubmit"' "$short"
[ "$(count_calls)" = 2 ]

slash=$(hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"/review"}')
[ -z "$slash" ]
expanded=$(hook '{"hook_event_name":"UserPromptExpansion","session_id":"s1","expansion_type":"slash_command","command_name":"review","prompt":"/review"}')
assert 'slash command expansion' '.hookSpecificOutput.hookEventName=="UserPromptExpansion"' "$expanded"
[ "$(count_calls)" = 3 ]

internal=$(hook '{"hook_event_name":"UserPromptExpansion","session_id":"s1","command_name":"jev","prompt":"/jev status"}')
[ -z "$internal" ] && [ "$(count_calls)" = 3 ]
printf 'PASS: internal command excluded\n'

agent=$(hook '{"hook_event_name":"PreToolUse","session_id":"s1","tool_use_id":"tool-1","tool_name":"Agent","tool_input":{"prompt":"Wo liegt die Config?","description":"search","subagent_type":"Explore","model":"opus","run_in_background":false}}')
assert 'Agent model changed and other fields preserved' '.hookSpecificOutput.updatedInput | .model=="haiku" and .description=="search" and .subagent_type=="Explore" and .run_in_background==false' "$agent"
[ "$(count_calls)" = 3 ]
printf 'PASS: User to Agent cache reuse\n'
observed=$(hook '{"hook_event_name":"PostToolUse","session_id":"s1","tool_use_id":"tool-1","tool_name":"Agent","tool_input":{"prompt":"Wo liegt die Config?","model":"opus"}}')
[ -z "$observed" ] && [ "$(count_calls)" = 3 ]
printf 'PASS: Agent observation without a second JEV call\n'

export MOCK_ROUTE=sonnet
nested=$(hook '{"hook_event_name":"PreToolUse","session_id":"s1","agent_id":"child-a","agent_type":"general-purpose","tool_name":"Agent","tool_input":{"prompt":"Implementiere Pagination samt Tests","subagent_type":"general-purpose"}}')
assert 'nested Agent independently classified' '.hookSpecificOutput.updatedInput.model=="sonnet"' "$nested"
[ "$(count_calls)" = 4 ]

primitive=$(hook '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Read","tool_input":{"file_path":"a"}}')
[ -z "$primitive" ] && [ "$(count_calls)" = 4 ]
printf 'PASS: primitive tool skipped\n'

export MOCK_ROUTE=fable
fable=$(hook '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Agent","tool_input":{"prompt":"Entwirf neue Authentifizierungsarchitektur","subagent_type":"general-purpose"}}')
assert 'fable model is passed through' '.hookSpecificOutput.updatedInput.model=="fable"' "$fable"
[ "$(count_calls)" = 5 ]

temp_config="$TEMP_DIR/config.tmp"
jq '.enabled_events.agent_task=false' "$JEV_ROUTER_DIR/config.json" > "$temp_config"
mv "$temp_config" "$JEV_ROUTER_DIR/config.json"
disabled=$(hook '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Agent","tool_input":{"prompt":"Deaktivierter Agent-Task"}}')
[ -z "$disabled" ] && [ "$(count_calls)" = 5 ]
printf 'PASS: agent event can be disabled\n'
jq '.enabled_events.agent_task=true | .min_confidence=0.99' "$JEV_ROUTER_DIR/config.json" > "$temp_config"
mv "$temp_config" "$JEV_ROUTER_DIR/config.json"
uncertain=$(hook '{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Agent","tool_input":{"prompt":"Unsicherer Agent-Task","model":"opus"}}')
[ -z "$uncertain" ] && [ "$(count_calls)" = 6 ]
printf 'PASS: low confidence preserves requested model\n'
jq '.min_confidence=0.6' "$JEV_ROUTER_DIR/config.json" > "$temp_config"
mv "$temp_config" "$JEV_ROUTER_DIR/config.json"

status=$(bash "$JEV_ROUTER_DIR/jev.sh" status)
[[ "$status" == *"JEV requests:"* ]]
[[ "$status" == *"observed tool-input mismatches: 1"* ]]
log_output=$(bash "$JEV_ROUTER_DIR/jev.sh" log 2)
[[ "$log_output" == *"agent_task"* ]]
bash "$JEV_ROUTER_DIR/jev.sh" debug on >/dev/null
[ "$(jq -r '.debug' "$JEV_ROUTER_DIR/config.json")" = true ]
bash "$JEV_ROUTER_DIR/jev.sh" debug off >/dev/null
printf 'PASS: status, log and debug commands\n'

export MOCK_FAILURE=api
failed=$(hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"API Fehlerfall"}')
[ -z "$failed" ] && printf 'PASS: API error fail-open\n'
export MOCK_FAILURE=invalid
failed=$(hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"Ungueltiges JSON"}')
[ -z "$failed" ] && printf 'PASS: invalid JSON fail-open\n'
unset MOCK_FAILURE TYPESAFE_API_KEY
failed=$(hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"Fehlender Key"}')
[ -z "$failed" ] && printf 'PASS: missing key fail-open\n'

[ "$(jq -s 'map(select(.result|startswith("error:")))|length' "$JEV_ROUTER_DIR/log.jsonl")" = 3 ]
[ "$(jq -s 'map(select(.cache=="hit"))|length' "$JEV_ROUTER_DIR/log.jsonl")" = 1 ]
if jq -s -e 'any(.[]; has("prompt"))' "$JEV_ROUTER_DIR/log.jsonl" >/dev/null; then
  printf 'FAIL: prompt leaked into log\n' >&2
  exit 1
fi
printf 'PASS: metrics and privacy\n'
before=$(count_calls)
sensitive=$(hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"set API_KEY=abcdef123456"}')
[ -z "$sensitive" ] && [ "$(count_calls)" = "$before" ]
printf 'PASS: credential-like task skipped\n'
printf 'TYPESAFE_API_KEY=fixture-only\n' > "$JEV_ROUTER_DIR/.env"
chmod 644 "$JEV_ROUTER_DIR/.env"
insecure=$(hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"Unsichere Env-Datei"}')
[ -z "$insecure" ] && [ "$(count_calls)" = "$before" ]
[ "$(jq -r 'select(.result=="error:insecure_env") | .result' "$JEV_ROUTER_DIR/log.jsonl" | wc -l | tr -d ' ')" = 1 ]
printf 'PASS: insecure .env rejected\n'
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","route":"sonnet","decision":"handle","ms":12,"prompt":"LEGACY_PRIVATE_PROMPT"}' >> "$JEV_ROUTER_DIR/log.jsonl"
legacy_status=$(bash "$JEV_ROUTER_DIR/jev.sh" status)
legacy_log=$(bash "$JEV_ROUTER_DIR/jev.sh" log 1)
[[ "$legacy_status" == *"legacy_user_prompt"* ]]
[[ "$legacy_log" != *"LEGACY_PRIVATE_PROMPT"* ]]
printf 'PASS: legacy logs remain readable without displaying prompt text\n'
