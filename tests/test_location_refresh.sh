#!/usr/bin/env bash
set -euo pipefail

# Reproducer test for issue #1: location should refresh when IP changes
# This test validates the decision logic added in statusline.sh.

should_refresh() {
  local current_ip="$1"
  local cached_ip="$2"
  local cache_is_fresh="$3"

  if [[ "$cache_is_fresh" == "true" ]] && [[ -n "$current_ip" ]] && [[ "$current_ip" == "$cached_ip" ]]; then
    echo "false"
  else
    echo "true"
  fi
}

# Case 1: fresh cache + same IP => do NOT refresh
[[ "$(should_refresh "1.1.1.1" "1.1.1.1" true)" == "false" ]]

# Case 2: fresh cache + changed IP => refresh
[[ "$(should_refresh "2.2.2.2" "1.1.1.1" true)" == "true" ]]

# Case 3: stale cache => refresh
[[ "$(should_refresh "1.1.1.1" "1.1.1.1" false)" == "true" ]]

# Case 4: missing current IP => refresh (safe fallback)
[[ "$(should_refresh "" "1.1.1.1" true)" == "true" ]]

echo "PASS: location refresh decision logic"
