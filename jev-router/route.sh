#!/usr/bin/env bash
# Claude Code hook entry point. All events share the same routing implementation.
[ "${JEV_ROUTER_ACTIVE:-0}" = 1 ] && exit 0
DIR="${JEV_ROUTER_DIR:-$HOME/.claude/jev-router}"
[ -f "$DIR/enabled" ] || [ "${JEV_ROUTER_TEST:-0}" = 1 ] || exit 0
[ -r "$DIR/router-core.sh" ] || exit 0
export JEV_ROUTER_ACTIVE=1
umask 077
# shellcheck source=router-core.sh
. "$DIR/router-core.sh"
jev_main || : # A router failure must never block Claude Code.
exit 0
