#!/usr/bin/env bash
# Install or upgrade without removing .env, logs, enabled state or custom settings.
set -euo pipefail
umask 077
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="${JEV_CLAUDE_DIR:-$HOME/.claude}"
ROUTER_DIR="${JEV_ROUTER_DIR:-$CLAUDE_DIR/jev-router}"
SKILL_DIR="$CLAUDE_DIR/skills/jev"
SETTINGS="$CLAUDE_DIR/settings.json"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$ROUTER_DIR" "$SKILL_DIR"
chmod 700 "$ROUTER_DIR"

backup() {
  [ -e "$1" ] || return 0
  cp -p "$1" "$1.bak.$STAMP"
  chmod 600 "$1.bak.$STAMP"
}

for file in route.sh router-core.sh jev.sh; do
  backup "$ROUTER_DIR/$file"
  cp "$SOURCE_DIR/jev-router/$file" "$ROUTER_DIR/$file"
  chmod 700 "$ROUTER_DIR/$file"
done

if [ -f "$ROUTER_DIR/config.json" ]; then
  backup "$ROUTER_DIR/config.json"
  temp=$(mktemp "$ROUTER_DIR/.config.XXXXXXXX")
  jq -s '.[0] * .[1] | if .min_prompt_chars == 12 then .min_prompt_chars = 1 else . end' \
    "$SOURCE_DIR/jev-router/config.json" "$ROUTER_DIR/config.json" > "$temp"
  chmod 600 "$temp"
  mv "$temp" "$ROUTER_DIR/config.json"
else
  cp "$SOURCE_DIR/jev-router/config.json" "$ROUTER_DIR/config.json"
  chmod 600 "$ROUTER_DIR/config.json"
fi

backup "$SKILL_DIR/SKILL.md"
cp "$SOURCE_DIR/skills/jev/SKILL.md" "$SKILL_DIR/SKILL.md"

mkdir -p "$CLAUDE_DIR"
if [ -f "$ROUTER_DIR/log.jsonl" ]; then chmod 600 "$ROUTER_DIR/log.jsonl"; fi
if [ -f "$SETTINGS" ]; then
  backup "$SETTINGS"
else
  printf '{}\n' > "$SETTINGS"
fi
temp=$(mktemp "$CLAUDE_DIR/.settings.XXXXXXXX")
jq --slurpfile new "$SOURCE_DIR/hook-settings.json" '
  .hooks //= {} |
  .hooks |= with_entries(
    .value |= (
      map(.hooks |= map(select((.command // "" | contains("/jev-router/route.sh")) | not)))
      | map(select(.hooks | length > 0))
    )
  ) |
  reduce ($new[0].hooks | to_entries[]) as $item (.;
    .hooks[$item.key] = ((.hooks[$item.key] // []) + $item.value)
  )
' "$SETTINGS" > "$temp"
chmod 600 "$temp"
mv "$temp" "$SETTINGS"
printf 'JEV installed in %s. Existing .env, log.jsonl and enabled state were preserved.\n' "$ROUTER_DIR"
