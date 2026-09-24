#!/usr/bin/env bash
# CLI behind the /jev skill: toggle the router, inspect it, dry-run a prompt.
DIR="${JEV_ROUTER_DIR:-$HOME/.claude/jev-router}"

case "${1:-status}" in
  on)
    touch "$DIR/enabled"
    echo "Jev-Router: ON — every prompt in new turns is classified by Jev (prompt text goes to api.typesafe.ai)."
    ;;
  off)
    rm -f "$DIR/enabled"
    echo "Jev-Router: OFF — no prompt leaves the machine."
    ;;
  status)
    if [ -f "$DIR/enabled" ]; then echo "Jev-Router: ON"; else echo "Jev-Router: OFF"; fi
    [ -x "$DIR/route.sh" ] && echo "route.sh: present" || echo "route.sh: MISSING or not executable ($DIR/route.sh)"
    echo "session model: $(jq -r '.session_model // "opus"' "$DIR/config.json" 2>/dev/null)"
    if [ -f "$DIR/log.jsonl" ]; then
      echo "decisions logged: $(wc -l < "$DIR/log.jsonl" | tr -d ' ')"
      echo "by tier:"; jq -r '.route' "$DIR/log.jsonl" | sort | uniq -c | sort -rn | sed 's/^/  /'
      echo "delegated: $(jq -r 'select(.decision=="delegate") | 1' "$DIR/log.jsonl" | wc -l | tr -d ' ')"
      echo "avg latency ms: $(jq -s 'if length>0 then (map(.ms) | add / length | floor) else 0 end' "$DIR/log.jsonl")"
    fi
    ;;
  test)
    shift
    PROMPT="$*"
    [ -n "$PROMPT" ] || { echo "usage: jev.sh test <prompt text>"; exit 1; }
    [ -x "$DIR/route.sh" ] || { echo "route.sh missing"; exit 1; }
    # Dry run: force the toggle on for this call only, never touching the real state
    WAS_ON=0; [ -f "$DIR/enabled" ] && WAS_ON=1
    touch "$DIR/enabled"
    OUT=$(jq -cn --arg p "$PROMPT" '{prompt:$p}' | bash "$DIR/route.sh")
    [ "$WAS_ON" = 1 ] || rm -f "$DIR/enabled"
    if [ -n "$OUT" ]; then
      printf '%s\n' "$OUT" | jq -r '.hookSpecificOutput.additionalContext'
    else
      echo "(no decision — prompt skipped: slash command, too short, router off, or API error)"
    fi
    ;;
  log)
    N="${2:-20}"
    [ -f "$DIR/log.jsonl" ] || { echo "no log yet"; exit 0; }
    tail -n "$N" "$DIR/log.jsonl" | jq -r '"\(.ts)  \(.route | ascii_upcase | .[0:6] | . + "      " | .[0:6])  conf=\(.confidence)  ctx=\(.needs_context)  \(.decision | .[0:8] | . + "        " | .[0:8])  \(.ms)ms  \(.prompt)"'
    ;;
  *)
    echo "usage: jev.sh on|off|status|test <prompt>|log [n]"
    exit 1
    ;;
esac
