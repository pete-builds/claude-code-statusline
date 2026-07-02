#!/usr/bin/env bash
set -euo pipefail

# Validates the plan/seat-tier mapping added to statusline.sh: oauthAccount.seatTier
# (from ~/.claude.json) -> the label appended to the OAuth auth tag.
# Mirrors the `case` block in statusline.sh; keep the two in sync.

plan_tag() {
  local seat_tier="$1"
  case "$seat_tier" in
    team_standard) echo "Team" ;;
    team_premium)  echo "Team+" ;;
    max_20x)       echo "Max20x" ;;
    max_5x)        echo "Max5x" ;;
    max)           echo "Max" ;;
    pro)           echo "Pro" ;;
    free)          echo "Free" ;;
    "")            echo "" ;;
    *)             echo "${seat_tier//_/ }" ;;
  esac
}

# Known tiers map to friendly labels
[[ "$(plan_tag team_standard)" == "Team" ]]
[[ "$(plan_tag team_premium)"  == "Team+" ]]
[[ "$(plan_tag max_20x)"       == "Max20x" ]]
[[ "$(plan_tag max_5x)"        == "Max5x" ]]
[[ "$(plan_tag max)"           == "Max" ]]
[[ "$(plan_tag pro)"           == "Pro" ]]
[[ "$(plan_tag free)"          == "Free" ]]

# Empty tier (field absent) yields no tag => AUTH_TAG stays plain "OAuth"
[[ "$(plan_tag "")" == "" ]]

# Unknown tier falls back to the raw value with underscores spaced out
[[ "$(plan_tag enterprise_annual)" == "enterprise annual" ]]

echo "PASS: plan/seat tier mapping"
