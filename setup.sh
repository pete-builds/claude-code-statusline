#!/bin/bash
# setup.sh — Install Claude Code statusline
#
# What it does:
#   1. Preflight: verifies jq, curl, bc are installed (prints install hints if not)
#   2. Copies statusline.sh to ~/.claude/statusline.sh (strips CRLF defensively)
#   3. Merges statusLine config into ~/.claude/settings.json (preserves other settings)
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

# ─── Preflight: required commands ──────────────────────────────────────────
detect_install_hint() {
  local pkg="$1"
  if command -v brew >/dev/null 2>&1; then
    echo "  brew install $pkg"
  elif command -v apt >/dev/null 2>&1; then
    echo "  sudo apt install -y $pkg"
  elif command -v dnf >/dev/null 2>&1; then
    echo "  sudo dnf install -y $pkg"
  elif command -v pacman >/dev/null 2>&1; then
    echo "  sudo pacman -S --noconfirm $pkg"
  elif command -v apk >/dev/null 2>&1; then
    echo "  sudo apk add $pkg"
  else
    echo "  (install '$pkg' via your package manager)"
  fi
}

MISSING=()
for cmd in jq curl bc; do
  command -v "$cmd" >/dev/null 2>&1 || MISSING+=("$cmd")
done
if (( ${#MISSING[@]} > 0 )); then
  echo "Missing required commands: ${MISSING[*]}"
  echo ""
  echo "Install with:"
  for pkg in "${MISSING[@]}"; do
    detect_install_hint "$pkg"
  done
  echo ""
  echo "Re-run ./setup.sh after installing."
  exit 1
fi

# ─── Source file sanity ────────────────────────────────────────────────────
if [[ ! -f "$SL_SOURCE" ]]; then
  echo "Error: statusline.sh not found at $SL_SOURCE"
  exit 1
fi

# ─── Install ───────────────────────────────────────────────────────────────
mkdir -p "$CLAUDE_DIR"

if [[ -f "$SL_DEST" ]]; then
  echo "Updating: $SL_DEST"
else
  echo "Installing: $SL_DEST"
fi

# Strip CRLF defensively in case the file was downloaded through a Windows
# path that injected them (zip download, git without .gitattributes, etc.)
tr -d '\r' < "$SL_SOURCE" > "$SL_DEST"
chmod +x "$SL_DEST"

# ─── Merge statusLine into settings.json ───────────────────────────────────
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

# ─── Clear stale caches ────────────────────────────────────────────────────
# statusline.sh caches location/weather/git under ~/.cache/claude/statusline.
# Clear them on (re)install so an update doesn't keep showing stale data until
# the TTLs expire. The rotating context_window_debug.log is left in place.
SL_CACHE_DIR="$HOME/.cache/claude/statusline"
rm -f "$SL_CACHE_DIR/git" "$SL_CACHE_DIR/location" \
      "$SL_CACHE_DIR/location_ip" "$SL_CACHE_DIR/weather"

echo ""
echo "Done. Start a new Claude Code session to see the statusline."
echo ""
echo "  ─── | CC STATUSLINE | ────────────────────────────────────"
echo "  LOC: City | time | date | weather"
echo "  ENV: CC version | auth | model"
echo "  ● CONTEXT: bar | % | context window size | tokens in/out"
echo "  ◆ GIT: project | branch | sync | modified"
echo "  + SESSION: lines | duration | session hash | battery | cost | rate limits"
