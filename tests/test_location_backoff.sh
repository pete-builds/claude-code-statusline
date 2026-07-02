#!/usr/bin/env bash
set -euo pipefail

# Validates the geolocation backoff gating in the refresher: when the same IP has
# no cached location AND a recent lookup failed, skip the call so a rate-limited
# geolocation API is not hit on every refresh. Mirrors the NEED_LOCATION block in
# statusline.sh; keep the two in sync.

need_location() {
  local ip_changed="$1" has_location_cache="$2" fail_age="$3" cooldown="$4"
  if [[ "$ip_changed" == "true" ]]; then
    echo "true"; return                    # IP changed -> always look up
  fi
  if [[ "$has_location_cache" == "true" ]]; then
    echo "false"; return                   # already have a location, same IP
  fi
  # No cache, same IP: look up unless a failure is still within the cooldown.
  if [[ "$fail_age" -ge 0 ]] && (( fail_age < cooldown )); then
    echo "false"; return
  fi
  echo "true"
}

COOLDOWN=3600
NO_FAIL=-1   # sentinel: no failure marker present

# IP changed => look up, even if a failure is recent
[[ "$(need_location true  false 10       "$COOLDOWN")" == "true" ]]
[[ "$(need_location true  true  10       "$COOLDOWN")" == "true" ]]

# Same IP, no cache, no prior failure => look up
[[ "$(need_location false false "$NO_FAIL" "$COOLDOWN")" == "true" ]]

# Same IP, no cache, recent failure (within cooldown) => back off, skip
[[ "$(need_location false false 60       "$COOLDOWN")" == "false" ]]

# Same IP, no cache, stale failure (past cooldown) => retry
[[ "$(need_location false false 4000     "$COOLDOWN")" == "true" ]]

# Same IP, has cache => no lookup regardless of failure state
[[ "$(need_location false true  "$NO_FAIL" "$COOLDOWN")" == "false" ]]

echo "PASS: geolocation backoff gating"
