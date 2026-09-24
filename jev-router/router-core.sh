#!/usr/bin/env bash
# Shared Jev request, cache, mapping and logging for all hook events.
CONFIG="$DIR/config.json"
LOG="$DIR/log.jsonl"

jev_cfg() { jq -r "$1" "$CONFIG" 2>/dev/null; }
jev_now() { date +%s; }
jev_ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000' 2>/dev/null || printf '%s000' "$(jev_now)"; }
jev_hash() { printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; }
jev_rank() { case "$1" in haiku) printf 1;; sonnet) printf 2;; opus) printf 3;; fable) printf 4;; *) printf 0;; esac; }
jev_model() { case "$1" in haiku|sonnet|opus|fable) printf '%s' "$1";; *) return 1;; esac; }

jev_log() {
  # No prompt or API response is persisted. The hash is only a correlation key.
  jq -cn --arg ts "$(date -u +%FT%TZ)" --arg event "$EVENT" \
    --arg task "${TASK_HASH:0:12}" --arg jev "${ROUTE:-}" \
    --arg selected "${SELECTED:-}" --arg requested "${REQUESTED:-}" \
    --arg result "$1" --arg cache "${CACHE_STATUS:-}" \
    --arg agent "${AGENT_TYPE:-}" --arg tool_use_id "${TOOL_USE_ID:-}" \
    --argjson ms "${LATENCY:-0}" \
    --argjson tokens "${TOKENS:-0}" \
    '{ts:$ts,event:$event,task:$task,jev:$jev,selected:$selected,requested:$requested,result:$result,cache:$cache,agent_type:$agent,tool_use_id:$tool_use_id,ms:$ms,input_tokens:$tokens}' \
    >> "$LOG" 2>/dev/null || :
}

jev_error() { ROUTE= SELECTED=; jev_log "error:$1"; }

jev_secret_risk() {
  # Conservative screen: skip routing when task text looks like credentials.
  printf '%s' "$1" | LC_ALL=C grep -Eiq \
    -- '-----BEGIN [A-Z ]*PRIVATE KEY-----|(^|[^[:alnum:]_])(api[_-]?key|secret|password|token|authorization)[[:space:]_:-]*[=:][[:space:]]*[^[:space:]]+|gh[pousr]_[[:alnum:]_]{20,}|sk-[[:alnum:]_-]{20,}'
}

jev_route() {
  local key file cached now ttl max state body response start end tmp
  now=$(jev_now)
  ttl=$(jev_cfg '.cache_ttl_seconds // 30')
  max=$(jev_cfg '.max_state_chars // 12000')
  [[ "$ttl" =~ ^[0-9]+$ ]] || ttl=30
  [[ "$max" =~ ^[0-9]+$ ]] || max=12000
  [ "$max" -gt 0 ] || max=12000
  [ "$max" -le 12000 ] || max=12000
  key=$(jev_hash "${SESSION_ID}|${TASK}") || { jev_error hash; return 1; }
  TASK_HASH="$key"
  file="$DIR/cache/$key.json"
  if [ "$ttl" -gt 0 ] && [ -r "$file" ]; then
    cached=$(jq -c --argjson now "$now" --argjson ttl "$ttl" \
      'select(.ts|type=="number") | select($now-.ts < $ttl) | select(.route=="haiku" or .route=="sonnet" or .route=="opus" or .route=="fable")' "$file" 2>/dev/null)
    if [ -n "$cached" ]; then
      ROUTE=$(jq -r '.route' <<< "$cached")
      CONF=$(jq -r '.confidence' <<< "$cached")
      CTX=$(jq -r '.needs_context' <<< "$cached")
      TOKENS=0 LATENCY=0 CACHE_STATUS=hit
      return 0
    fi
  fi
  if [ -z "${TYPESAFE_API_KEY:-}" ] && [ -r "$DIR/.env" ]; then
    # Never source a group/world-readable credentials file.
    local env_mode
    env_mode=$(stat -f %Lp "$DIR/.env" 2>/dev/null || stat -c %a "$DIR/.env" 2>/dev/null)
    [ "$env_mode" = 600 ] || { jev_error insecure_env; return 1; }
    . "$DIR/.env"
  fi
  [ -n "${TYPESAFE_API_KEY:-}" ] || { jev_error missing_key; return 1; }
  state=$(printf 'task_type: %s\nagent_type: %s\nrequested_model: %s\nconfigured_session_model: %s\ntask: %s' \
    "$EVENT" "$AGENT_TYPE" "$REQUESTED" "$(jev_cfg '.session_model // "opus"')" "${TASK:0:$max}")
  body=$(jq -cn --arg state "$state" --slurpfile cfg "$CONFIG" \
    '{state:$state,model:$cfg[0].model,questions:$cfg[0].questions}') || { jev_error config; return 1; }
  start=$(jev_ms)
  CACHE_STATUS=miss
  # Keep both credentials and task payload out of process arguments.
  response=$(curl -fsS --connect-timeout 2 --max-time 5 -X POST https://api.typesafe.ai/v1/systemone \
    -H 'Content-Type: application/json' --data-binary @/dev/fd/3 --config - \
    3<<< "$body" 2>/dev/null <<CURL_CONFIG
header = "Authorization: Bearer $TYPESAFE_API_KEY"
CURL_CONFIG
  ) || { jev_error api; return 1; }
  end=$(jev_ms)
  LATENCY=$((end-start))
  ROUTE=$(jq -er '.answers.route.choice | select(.=="haiku" or .=="sonnet" or .=="opus" or .=="fable")' <<< "$response" 2>/dev/null) || { jev_error invalid_response; return 1; }
  CONF=$(jq -er '.answers.route.confidence // 0 | tonumber | select(.>=0 and .<=1)' <<< "$response" 2>/dev/null) || { jev_error invalid_response; return 1; }
  CTX=$(jq -er '.answers.needs_context.noul // 0 | tonumber | select(.>=0 and .<=1)' <<< "$response" 2>/dev/null) || { jev_error invalid_response; return 1; }
  TOKENS=$(jq -r '.usage.input_tokens // 0 | numbers' <<< "$response" 2>/dev/null)
  [[ "$TOKENS" =~ ^[0-9]+$ ]] || TOKENS=0
  CACHE_STATUS=miss
  if [ "$ttl" -gt 0 ]; then
    mkdir -p "$DIR/cache" 2>/dev/null || :
    tmp=$(mktemp "$DIR/cache/.jev.XXXXXXXX" 2>/dev/null) || return 0
    jq -cn --argjson ts "$now" --arg route "$ROUTE" --argjson confidence "$CONF" \
      --argjson needs_context "$CTX" \
      '{ts:$ts,route:$route,confidence:$confidence,needs_context:$needs_context}' > "$tmp" && \
      chmod 600 "$tmp" && mv -f "$tmp" "$file" || rm -f "$tmp"
  fi
  return 0
}

jev_emit_context() {
  local msg="$1"
  if [ "$(jev_cfg '.debug // false')" = true ]; then
    msg="$msg [JEV debug: event=$EVENT task=${TASK_HASH:0:12} recommendation=$ROUTE selected=$SELECTED confidence=$CONF context_dependency=$CTX requested=$REQUESTED cache=$CACHE_STATUS latency=${LATENCY}ms]"
  fi
  jq -cn --arg event "$HOOK" --arg msg "$msg" \
    '{hookSpecificOutput:{hookEventName:$event,additionalContext:$msg}}'
}

jev_main() {
  local input tool_name enabled min selected msg threshold conf_threshold session
  command -v jq >/dev/null 2>&1 || return 0
  command -v shasum >/dev/null 2>&1 || return 0
  [ -r "$CONFIG" ] || return 0
  input=$(</dev/stdin) || return 0
  jq -e 'type=="object"' <<< "$input" >/dev/null 2>&1 || return 0
  HOOK=$(jq -r '.hook_event_name // "UserPromptSubmit"' <<< "$input")
  SESSION_ID=$(jq -r '.session_id // ""' <<< "$input")
  AGENT_TYPE=$(jq -r '.agent_type // .tool_input.subagent_type // ""' <<< "$input")
  REQUESTED= TASK= ROUTE= SELECTED= TASK_HASH= LATENCY=0 TOKENS=0 CACHE_STATUS=
  tool_name=$(jq -r '.tool_name // ""' <<< "$input")
  TOOL_USE_ID=$(jq -r '.tool_use_id // ""' <<< "$input")
  case "$HOOK" in
    UserPromptSubmit)
      EVENT=user_prompt
      TASK=$(jq -r '.prompt // ""' <<< "$input")
      # Direct commands are classified at expansion, where built-ins can be distinguished.
      [[ "$TASK" = /* ]] && return 0
      ;;
    UserPromptExpansion)
      EVENT=prompt_expansion
      TASK=$(jq -r '.prompt // ""' <<< "$input")
      AGENT_TYPE=$(jq -r '.expansion_type // ""' <<< "$input")
      [[ "$(jq -r '.command_name // ""' <<< "$input")" = jev ]] && return 0
      ;;
    PreToolUse)
      case "$tool_name" in
        Agent)
          EVENT=agent_task
          TASK=$(jq -r '.tool_input.prompt // ""' <<< "$input")
          REQUESTED=$(jq -r '.tool_input.model // ""' <<< "$input")
          AGENT_TYPE=$(jq -r '.tool_input.subagent_type // .agent_type // ""' <<< "$input")
          ;;
        Skill)
          EVENT=skill_task
          TASK=$(jq -r '.tool_input.skill // ""' <<< "$input")
          [[ "$TASK" = jev || "$TASK" = /jev ]] && return 0
          TASK="$TASK $(jq -r '.tool_input.args // ""' <<< "$input")"
          ;;
        *) return 0;;
      esac
      ;;
    PostToolUse)
      [ "$tool_name" = Agent ] || return 0
      EVENT=agent_observed
      TASK=$(jq -r '.tool_input.prompt // ""' <<< "$input")
      TASK_HASH=$(jev_hash "${SESSION_ID}|${TASK}")
      SELECTED=$(jq -r '.tool_input.model // ""' <<< "$input")
      REQUESTED="$SELECTED"
      jev_log observed_tool_input
      return 0
      ;;
    SubagentStart)
      EVENT=subagent_start
      TASK_HASH=$(jev_hash "${SESSION_ID}|$(jq -r '.agent_id // ""' <<< "$input")")
      jev_log started
      return 0
      ;;
    *) return 0;;
  esac
  enabled=$(jq -r --arg event "$EVENT" '.enabled_events[$event] | if . == null then true else . end' "$CONFIG" 2>/dev/null)
  [ "$enabled" = true ] || return 0
  min=$(jev_cfg '.min_prompt_chars // 1')
  [[ "$min" =~ ^[0-9]+$ ]] || min=1
  [ -n "${TASK//[[:space:]]/}" ] && [ "${#TASK}" -ge "$min" ] || return 0
  if jev_secret_risk "$TASK"; then
    TASK_HASH=$(jev_hash "${SESSION_ID}|${TASK}")
    jev_error sensitive_task
    return 0
  fi
  jev_route || return 0
  selected=$(jev_model "$ROUTE") || return 0
  SELECTED="$selected"
  if [ "$EVENT" = agent_task ]; then
    conf_threshold=$(jev_cfg '.min_confidence // 0.6')
    if ! awk -v f="$CONF" -v ft="$conf_threshold" 'BEGIN{exit !(f>=ft)}'; then
      SELECTED="$REQUESTED"
      jev_log low_confidence
      return 0
    fi
    jev_log routed
    # updatedInput is the whole input, preserving every parameter except model.
    jq -cn --arg model "$selected" --argjson input "$input" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",updatedInput:($input.tool_input + {model:$model}),additionalContext:("JEV selected " + $model + " for this Agent task.")}}'
    return 0
  fi
  threshold=$(jev_cfg '.context_threshold // 0.5')
  conf_threshold=$(jev_cfg '.min_confidence // 0.6')
  session=$(jev_cfg '.session_model // "opus"')
  msg="[JEV] Recommended model: $selected (confidence $CONF)."
  if [ "$(jev_rank "$selected")" -lt "$(jev_rank "$session")" ] && \
     awk -v c="$CTX" -v t="$threshold" -v f="$CONF" -v ft="$conf_threshold" 'BEGIN{exit !(c<t && f>=ft)}'; then
    msg="$msg This task can be delegated to Agent(model=\"$selected\") when appropriate."
  else
    msg="$msg Keep the current session context when it is needed."
  fi
  jev_log recommended
  jev_emit_context "$msg"
}
