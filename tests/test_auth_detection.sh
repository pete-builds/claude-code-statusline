#!/usr/bin/env bash
# Runs the REAL statusline.sh against fixture session JSON (tests/fixtures) and
# asserts two things per case: the auth label on the ENV row, and whether a cost
# shows on the SESSION row. Covers subscriber, API key (env present and env
# absent), gateway (env and JSON-only), a session with no cost yet, and a Team
# seat. No network: curl on PATH is a stub that records any call, the location
# and weather caches are pre-seeded so no refresh fires, and the run fails if
# the stub was ever called.
#
# Override STATUSLINE_UNDER_TEST to point at a different script (used to prove
# these cases fail against the old detection logic).
# Portable: bash 3.2, no associative arrays, no mapfile.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${STATUSLINE_UNDER_TEST:-$HERE/../statusline.sh}"
FIX="$HERE/fixtures"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing"; exit 1; }

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t sltest)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CURL_LOG"
exit 1
STUB
chmod +x "$WORK/bin/curl"
CURL_LOG="$WORK/curl.log"; : > "$CURL_LOG"

ESC="$(printf '\033')"
fail=0; n=0

# run_case NAME FIXTURE SEAT_TIER WANT_LABEL WANT_COST [VAR=VAL ...]
#   SEAT_TIER: value for ~/.claude.json oauthAccount.seatTier, or "noseat" for no file
#   WANT_COST: "none" or the exact cost text expected on the SESSION row
run_case() {
  local name="$1" fixture="$2" seat="$3" want_label="$4" want_cost="$5"; shift 5
  local home="$WORK/home-$name"
  mkdir -p "$home/.cache/claude/statusline"
  # Fresh caches so the background refresher never fires.
  echo "0|0|Testville" > "$home/.cache/claude/statusline/location"
  echo "1|50|48|5" > "$home/.cache/claude/statusline/weather"
  case "$seat" in
    noseat) ;;
    cfg:*|cfgempty)
      # Seat lives in CLAUDE_CONFIG_DIR; ~/.claude.json holds a decoy "max" that
      # must be ignored when the variable is set.
      printf '{"oauthAccount":{"seatTier":"max"}}' > "$home/.claude.json"
      mkdir -p "$home/cfg"
      [ "$seat" = cfgempty ] || printf '{"oauthAccount":{"seatTier":"%s"}}' "${seat#cfg:}" > "$home/cfg/.claude.json"
      set -- "$@" "CLAUDE_CONFIG_DIR=$home/cfg" ;;
    *) printf '{"oauthAccount":{"seatTier":"%s"}}' "$seat" > "$home/.claude.json" ;;
  esac
  local out env_row session_row got_label got_cost
  out=$(env -i PATH="$WORK/bin:$PATH" HOME="$home" STATUSLINE_CONFIG=/dev/null \
          CURL_LOG="$CURL_LOG" "$@" bash "$SCRIPT" < "$FIX/$fixture.json" 2>&1 \
        | sed "s/$ESC\[[0-9;]*m//g")
  env_row=$(printf '%s\n' "$out" | grep -a 'ENV:')
  session_row=$(printf '%s\n' "$out" | grep -a 'SESSION:')
  # ENV row is: ENV: CC: v2.1.0 | <label> | <model>
  got_label=$(printf '%s' "$env_row" | awk -F' [|] ' '{print $2}')
  got_cost=$(printf '%s' "$session_row" | grep -a -o '~\{0,1\}\$[0-9][0-9.]*\( est\)\{0,1\}' | head -1)
  [ -z "$got_cost" ] && got_cost="none"
  n=$((n+1))
  if [ "$got_label" = "$want_label" ] && [ "$got_cost" = "$want_cost" ]; then
    printf '  ok    %-26s label=[%s] cost=[%s]\n' "$name" "$got_label" "$got_cost"
  else
    printf '  FAIL  %-26s want label=[%s] cost=[%s]\n        got  label=[%s] cost=[%s]\n' \
      "$name" "$want_label" "$want_cost" "$got_label" "$got_cost"
    fail=1
  fi
}

echo "== subscriber: rate_limits present, any env =="
run_case subscriber-max             subscriber noseat "OAuth"       none
run_case subscriber-seat-max        subscriber max "OAuth·Max" none
run_case subscriber-with-key-env    subscriber noseat "OAuth"       none ANTHROPIC_API_KEY=sk-ant-test-abcd1234

echo "== API key =="
run_case apikey-env-not-passed      api_key    noseat "API"            '$0.4321'
run_case apikey-env-passed          api_key    noseat "API:..1234"     '$0.4321' ANTHROPIC_API_KEY=sk-ant-test-abcd1234

echo "== gateway =="
run_case gateway-env                api_key    noseat "GW:example"     '~$0.4321 est' ANTHROPIC_BASE_URL=https://llm.example.com/v1
run_case gateway-env-with-label     api_key    noseat "GW:example·work" '~$0.4321 est' ANTHROPIC_BASE_URL=https://llm.example.com/v1 ANTHROPIC_KEY_LABEL=work
run_case gateway-spend-limit-json   gateway_spend_limit noseat "GW"    '~$0.4321 est'

echo "== no cost yet / team seat =="
run_case no-cost-yet                no_cost    noseat "OAuth"          none
run_case no-cost-with-key-env       no_cost    noseat "API:..1234"     '$0.0000' ANTHROPIC_API_KEY=sk-ant-test-abcd1234
run_case team-seat-no-rate-limits   api_key    team_standard "OAuth·Team" none

echo "== Bedrock, Vertex, Foundry: never labelled API =="
run_case bedrock                    api_key noseat "Bedrock" '~$0.4321 est' CLAUDE_CODE_USE_BEDROCK=1
run_case vertex                     api_key noseat "Vertex"  '~$0.4321 est' CLAUDE_CODE_USE_VERTEX=1
run_case foundry                    api_key noseat "Foundry" '~$0.4321 est' CLAUDE_CODE_USE_FOUNDRY=1
run_case bedrock-with-key-env       api_key noseat "Bedrock" '~$0.4321 est' CLAUDE_CODE_USE_BEDROCK=1 ANTHROPIC_API_KEY=sk-ant-test-abcd1234
run_case bedrock-flag-off           api_key noseat "API"     '$0.4321' CLAUDE_CODE_USE_BEDROCK=0

echo "== CLAUDE_CONFIG_DIR decides where the seat is read =="
run_case configdir-team-seat        api_key cfg:team_standard "OAuth·Team" none
run_case configdir-no-seat          api_key cfgempty "API" '$0.4321'

if [ -s "$CURL_LOG" ]; then
  echo "FAIL: network was called:"; sed 's/^/    /' "$CURL_LOG"; fail=1
fi

if [ "$fail" = "0" ]; then echo "PASS: auth label and cost visibility ($n cases, no network)"; fi
exit "$fail"
