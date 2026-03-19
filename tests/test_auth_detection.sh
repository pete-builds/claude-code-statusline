#!/usr/bin/env bash
set -euo pipefail

# Reproducer test for issue #4: env vars may be absent even for API-key sessions.
# We expect auth detection to infer API when non-zero cost is present.

detect_auth_tag() {
  local anthropic_base_url="${1:-}"
  local anthropic_api_key="${2:-}"
  local cost="${3:-0}"

  if [[ -n "$anthropic_base_url" ]]; then
    echo "GW"
  elif [[ -n "$anthropic_api_key" ]]; then
    echo "API_KEY"
  elif awk "BEGIN {exit !($cost > 0)}"; then
    echo "API_INFERRED"
  else
    echo "OAUTH"
  fi
}

[[ "$(detect_auth_tag "https://api.ai.it.cornell.edu" "" 0)" == "GW" ]]
[[ "$(detect_auth_tag "" "sk-ant-1234" 0)" == "API_KEY" ]]
[[ "$(detect_auth_tag "" "" 0.0034)" == "API_INFERRED" ]]
[[ "$(detect_auth_tag "" "" 0)" == "OAUTH" ]]

echo "PASS: auth detection fallback logic"
