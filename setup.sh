#!/bin/bash
# setup.sh — Install Claude Code statusline
#
# What it does:
#   1. Copies statusline.sh to ~/.claude/statusline.sh
#   2. Merges statusLine config into ~/.claude/settings.json (preserves existing settings)
#
# Usage: ./setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
SL_SOURCE="$SCRIPT_DIR/statusline.sh"
SL_DEST="$CLAUDE_DIR/statusline.sh"
SETTINGS="$CLAUDE_DIR/settings.json"

echo "=== Claude Code Statusline Setup ==="
echo ""

# Ensure ~/.claude exists
mkdir -p "$CLAUDE_DIR"

# 1. Install statusline script
if [[ -f "$SL_DEST" ]]; then
  echo "Updating: $SL_DEST"
else
  echo "Installing: $SL_DEST"
fi
cp "$SL_SOURCE" "$SL_DEST"
chmod +x "$SL_DEST"

# 2. Merge statusLine config into settings.json
SL_CONFIG='{"type":"command","command":"~/.claude/statusline.sh"}'

if [[ -f "$SETTINGS" ]]; then
  if jq -e '.statusLine' "$SETTINGS" >/dev/null 2>&1; then
    echo "Updating statusLine in: $SETTINGS"
  else
    echo "Adding statusLine to: $SETTINGS"
  fi
  jq --argjson sl "$SL_CONFIG" '.statusLine = $sl' "$SETTINGS" > "${SETTINGS}.tmp" && mv "${SETTINGS}.tmp" "$SETTINGS"
else
  echo "Creating: $SETTINGS"
  echo "{\"statusLine\":$SL_CONFIG}" | jq . > "$SETTINGS"
fi

# 3. Clear stale caches
rm -f /tmp/claude-sl-location /tmp/claude-sl-weather /tmp/claude-sl-git /tmp/claude-sl-counts

echo ""
echo "Done. Start a new Claude Code session to see the statusline."
echo ""
echo "  ─── | CC STATUSLINE | ────────────────────────────────────"
echo "  LOC: City | time | date | weather"
echo "  ENV: CC version | auth | model"
echo "  ● CONTEXT: bar | % | tokens in/out  [ T1/T2 on API gateway ]"
echo "  ◆ GIT: project | branch | sync | modified"
echo "  + SESSION: lines | duration | API time | session hash | battery | cost"
