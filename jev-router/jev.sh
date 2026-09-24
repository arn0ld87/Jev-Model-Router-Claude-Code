#!/usr/bin/env bash
# Control and inspect the installed router. No command exposes the API key.
set -u
DIR="${JEV_ROUTER_DIR:-$HOME/.claude/jev-router}"
CONFIG="$DIR/config.json"
LOG="$DIR/log.jsonl"

usage() { printf 'usage: jev.sh on|off|status|log [n]|debug on|off|test <task>\n'; }
case "${1:-status}" in
  on)
    mkdir -p "$DIR"
    touch "$DIR/enabled"
    printf 'JEV router: ON (task text may be sent to TypeSafe).\n'
    ;;
  off)
    rm -f "$DIR/enabled"
    printf 'JEV router: OFF.\n'
    ;;
  debug)
    case "${2:-}" in on) value=true;; off) value=false;; *) usage; exit 1;; esac
    [ -r "$CONFIG" ] || { printf 'Missing config.json\n' >&2; exit 1; }
    temp=$(mktemp "$DIR/.config.XXXXXXXX") || exit 1
    if jq --argjson value "$value" '.debug=$value' "$CONFIG" > "$temp"; then
      chmod 600 "$temp" && mv "$temp" "$CONFIG"
      printf 'JEV debug: %s\n' "${2}"
    else
      rm -f "$temp"
      exit 1
    fi
    ;;
  status)
    if [ -f "$DIR/enabled" ]; then printf 'JEV router: ON\n'; else printf 'JEV router: OFF\n'; fi
    [ -r "$CONFIG" ] || { printf 'config.json: missing\n'; exit 0; }
    jq -r '"session model: \(.session_model // "opus")\ndebug: \(.debug // false)\ncache TTL: \(.cache_ttl_seconds // 30)s"' "$CONFIG"
    if [ -f "$LOG" ]; then
      jq -s -r '
        def count_if(f): map(select(f))|length;
        def mismatch_count:
          . as $all |
          [$all[] | select(.event=="agent_task" and .result=="routed" and (.tool_use_id // "")!="")] as $routes |
          [$all[] | select(.event=="agent_observed" and (.tool_use_id // "")!="")] as $observed |
          [$routes[] as $route | $observed[] |
            select(.tool_use_id==$route.tool_use_id and .selected!="" and .selected!=$route.selected)] | length;
        "JEV requests: \(count_if(.cache=="miss" or (has("event")|not)))",
        "cache hits: \(count_if(.cache=="hit"))",
        "API errors: \(count_if(.result=="error:api" or .result=="error:invalid_response"))",
        "local skips/errors: \(count_if((.result // "" | startswith("error:")) and .cache!="miss"))",
        "observed tool-input mismatches: \(mismatch_count)",
        "average JEV latency: \((map(select(.cache=="miss" and .ms>0)|.ms)|if length>0 then add/length|floor else 0 end)) ms",
        "JEV requests by event:",
        (map(select(.cache=="miss" or (has("event")|not)) | .event //= "legacy_user_prompt")|group_by(.event)|map("  \(.[0].event): \(length)")|.[]),
        "recommendations:",
        (map(.jev //= (.route // ""))|map(select(.jev!=""))|group_by(.jev)|map("  \(.[0].jev): \(length)")|.[]),
        "selected Agent models:",
        (map(select(.event=="agent_task" and .result=="routed"))|group_by(.selected)|map("  \(.[0].selected): \(length)")|.[])
      ' "$LOG"
      session=$(jq -r '.session_model // "opus"' "$CONFIG")
      if [ "$session" = opus ]; then
        jq -s -r '"estimated avoided Opus Agent calls: \([.[]|select(.event=="agent_task" and .result=="routed" and (.selected=="haiku" or .selected=="sonnet"))]|length) (based on selected tool input, not billed usage)"' "$LOG"
      fi
    fi
    ;;
  log)
    n="${2:-20}"
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -gt 0 ] && [ "$n" -le 500 ] || { usage; exit 1; }
    [ -f "$LOG" ] || { printf 'No log yet.\n'; exit 0; }
    jq -s -r --argjson n "$n" '
      .[-$n:][] |
      [.ts, (.event // "legacy_user_prompt"), (.task // "legacy"), (.jev // .route // ""), (.selected // ""), (.requested // ""), (.result // .decision // ""), (.cache // ""), ((.ms // 0)|tostring)+"ms"] | @tsv
    ' "$LOG"
    ;;
  test)
    shift
    [ "$#" -gt 0 ] || { usage; exit 1; }
    [ -r "$DIR/route.sh" ] || { printf 'route.sh missing\n' >&2; exit 1; }
    jq -cn --arg p "$*" '{hook_event_name:"UserPromptSubmit",session_id:"jev-test",prompt:$p}' |
      JEV_ROUTER_TEST=1 bash "$DIR/route.sh"
    ;;
  *)
    usage
    exit 1
    ;;
esac
