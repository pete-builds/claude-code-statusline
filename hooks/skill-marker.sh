#!/usr/bin/env bash
# Write a marker file the statusline can read to display the currently active
# skill. Fires as a PostToolUse hook on the Skill tool. The statusline treats
# the marker as fresh for a short window (see MARKER_TTL_SECS in statusline.sh);
# stale markers are ignored.
#
# Marker format: single line, "<skill-name>|<epoch>". mtime is the wall-clock
# source of truth (matches the epoch); either can be used for freshness checks.

set -u

CACHE_DIR="${HOME}/.cache/claude/statusline"
MARKER_FILE="${CACHE_DIR}/active_skill"

mkdir -p "$CACHE_DIR" 2>/dev/null || exit 0

INPUT=$(cat)

SKILL=$(echo "$INPUT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    tool_input = data.get('tool_input', {})
    if isinstance(tool_input, str):
        tool_input = json.loads(tool_input)
    name = tool_input.get('skill', '') or ''
    # Skill names are trusted (they come from the model calling the Skill tool
    # with a name from the listed catalog), but cap length defensively so a
    # runaway value can never bloat the marker or the statusline row.
    print(name[:64])
except Exception:
    print('')
" 2>/dev/null)

[[ -z "$SKILL" ]] && exit 0

printf '%s|%s\n' "$SKILL" "$(date +%s)" > "$MARKER_FILE" 2>/dev/null

exit 0
