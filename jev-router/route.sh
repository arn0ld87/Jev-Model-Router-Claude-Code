#!/usr/bin/env bash
# Jev model router — Claude Code UserPromptSubmit hook.
# Asks TypeSafe's Jev which Claude tier the request needs and injects the decision as context.
# Only runs while ~/.claude/jev-router/enabled exists (toggle: /jev on|off).
# Fail-open: any error → exit 0 with no output, the prompt goes through untouched.

DIR="${JEV_ROUTER_DIR:-$HOME/.claude/jev-router}"
CONFIG="$DIR/config.json"
LOG="$DIR/log.jsonl"

[ -f "$DIR/enabled" ] || exit 0

if [ -z "$TYPESAFE_API_KEY" ] && [ -f "$DIR/.env" ]; then
  set -a; . "$DIR/.env"; set +a
fi
[ -n "$TYPESAFE_API_KEY" ] || exit 0

INPUT=$(cat)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // empty' 2>/dev/null) || exit 0

case "$PROMPT" in /*) exit 0 ;; esac
MIN=$(jq -r '.min_prompt_chars // 12' "$CONFIG")
[ "${#PROMPT}" -ge "$MIN" ] || exit 0

MAX=$(jq -r '.max_state_chars // 12000' "$CONFIG")
STATE="User request to a coding agent (Claude Code):
${PROMPT:0:$MAX}"

BODY=$(jq -cn --arg state "$STATE" --slurpfile cfg "$CONFIG" \
  '{state: $state, model: $cfg[0].model, questions: $cfg[0].questions}') || exit 0

# Millisecond clock without python: perl ships with macOS and nearly every Linux; else whole seconds.
now_ms() {
  perl -MTime::HiRes=time -e 'printf("%d\n", time*1000)' 2>/dev/null || echo $(( $(date +%s) * 1000 ))
}
START=$(now_ms)
RESP=$(curl -s --max-time 5 -X POST https://api.typesafe.ai/v1/systemone \
  -H "Authorization: Bearer $TYPESAFE_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$BODY") || exit 0
END=$(now_ms)

ROUTE=$(printf '%s' "$RESP" | jq -r '.answers.route.choice // empty' 2>/dev/null)
[ -n "$ROUTE" ] || exit 0
CONF=$(printf '%s' "$RESP" | jq -r '.answers.route.confidence // 0')
CTX=$(printf '%s' "$RESP" | jq -r '.answers.needs_context.noul // 0')
TOKENS=$(printf '%s' "$RESP" | jq -r '.usage.input_tokens // 0')

CTX_T=$(jq -r '.context_threshold // 0.5' "$CONFIG")
CONF_T=$(jq -r '.min_confidence // 0.6' "$CONFIG")
SESSION=$(jq -r '.session_model // "opus"' "$CONFIG")

# Tier order, cheapest first. Delegate only to a tier strictly below the session model.
rank() { case "$1" in haiku) echo 1 ;; sonnet) echo 2 ;; opus) echo 3 ;; fable) echo 4 ;; *) echo 99 ;; esac; }

DECISION="handle"
if [ "$(rank "$ROUTE")" -lt "$(rank "$SESSION")" ]; then
  if awk -v c="$CTX" -v t="$CTX_T" -v f="$CONF" -v ft="$CONF_T" 'BEGIN{exit !(c < t && f >= ft)}'; then
    DECISION="delegate"
  fi
fi

jq -cn --arg ts "$(date -u +%FT%TZ)" --arg route "$ROUTE" --argjson conf "$CONF" \
  --argjson ctx "$CTX" --arg decision "$DECISION" --argjson ms "$((END-START))" \
  --argjson tokens "$TOKENS" --arg prompt "${PROMPT:0:120}" \
  '{ts:$ts, route:$route, confidence:$conf, needs_context:$ctx, decision:$decision, ms:$ms, input_tokens:$tokens, prompt:$prompt}' \
  >> "$LOG" 2>/dev/null

if [ "$DECISION" = "delegate" ]; then
  MSG="[Jev-Router] tier=$ROUTE confidence=$CONF needs_context=$CTX → DELEGATE. Hand this request to a subagent via the Agent tool with model=\"$ROUTE\" and a self-contained prompt: include the exact file paths, the docs to read, and the expected output. The subagent starts with a fresh context, so give it everything it needs. Relay the subagent's result; do not redo the work yourself. Start your reply with one short line: \"→ $ROUTE (Jev)\"."
else
  MSG="[Jev-Router] tier=$ROUTE confidence=$CONF needs_context=$CTX → handle in this session. Start your reply with one short line: \"→ $SESSION (Jev: $ROUTE, ctx $CTX)\"."
fi

jq -cn --arg msg "$MSG" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit", additionalContext:$msg}}'
exit 0
