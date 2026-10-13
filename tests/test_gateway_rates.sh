#!/usr/bin/env bash
# Expected-rate literals like '$5/$25' are intentionally single-quoted: they are
# text to match in the rendered bar, not variables to expand.
# shellcheck disable=SC2016
# Control for the Cornell gateway rate table in statusline.sh.
#
# Why this exists: the rate table matches against .model.display_name, which is
# a human label ("Opus 5 (1M context)"), not a model ID. A table that matches
# NOTHING renders exactly like a session with no rate data — a silent failure
# that shipped once already. This asserts each model renders its expected rate,
# and includes a negative control proving the check can actually fail.
#
# Usage: tests/test_gateway_rates.sh    (exits non-zero on any failure)
# Portable: bash 3.2, macOS + NixOS, no GNU-only tools.

set -u
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
STATUSLINE="${SCRIPT_DIR}/../statusline.sh"
[ -f "$STATUSLINE" ] || { echo "missing $STATUSLINE"; exit 1; }

# Force the Cornell gateway branch on, and keep the run hermetic.
export ANTHROPIC_BASE_URL="https://api.ai.it.cornell.edu/"
unset ANTHROPIC_API_KEY 2>/dev/null || true
export STATUSLINE_CONFIG=/dev/null
TMPHOME=$(mktemp -d 2>/dev/null || mktemp -d -t sltest)
trap 'rm -rf "$TMPHOME"' EXIT
export HOME="$TMPHOME"

render() {
  printf '{"model":{"display_name":"%s"},"context_window":{"used_percentage":10,"total_input_tokens":1000,"total_output_tokens":500,"context_window_size":1000000},"cost":{"total_cost_usd":0.5,"total_duration_ms":1000},"cwd":"/tmp","version":"test","session_id":"testtest"}' "$1" \
    | bash "$STATUSLINE" 2>/dev/null | grep -a 'CONTEXT' | sed 's/'"$(printf '\033')"'\[[0-9;]*m//g'
}

PASS=0; FAIL=0
expect() { # expect <display_name> <expected substring>
  local got; got=$(render "$1")
  case "$got" in
    *"$2"*) PASS=$((PASS+1)); printf '  ok    %-24s -> %s\n' "$1" "$2" ;;
    *)      FAIL=$((FAIL+1)); printf '  FAIL  %-24s expected [%s]\n        got: %s\n' "$1" "$2" "$got" ;;
  esac
}
expect_none() { # expect NO rate annotation
  local got; got=$(render "$1")
  case "$got" in
    *'$'*) FAIL=$((FAIL+1)); printf '  FAIL  %-24s expected no rate, got: %s\n' "$1" "$got" ;;
    *)     PASS=$((PASS+1)); printf '  ok    %-24s -> no rate (as expected)\n' "$1" ;;
  esac
}

echo "== display_name forms (what Claude Code actually sends) =="
expect "Opus 5 (1M context)" '$5/$25 flat'
expect "Opus 4.8"            '$5/$25 flat'
expect "Opus 4.7"            '$5/$25 flat'
expect "Opus 4.6"            '$5/$25 flat'
expect "Opus 4.5"            '$5/$25 flat'
expect "Opus 4.1"            '$15/$75 flat'
expect "Sonnet 5"            '$2/$10 flat'
expect "Sonnet 4.6"          '$3/$15 flat'
expect "Sonnet 4.5"          '$3/$15 ≤200k'
expect "Haiku 4.5"           '$1/$5 flat'
expect "Fable 5.1"           '$10/$50 flat'
expect "Fable 5"             '$10/$50 flat'

echo "== model-ID forms (still accepted) =="
expect "claude-opus-5"           '$5/$25 flat'
expect "claude-opus-4-7"         '$5/$25 flat'
expect "claude-sonnet-5"         '$2/$10 flat'
expect "anthropic.claude-4.6-opus"   '$5/$25 flat'
expect "anthropic.claude-4.6-sonnet" '$3/$15 flat'

echo "== negative controls (the check must be able to fail) =="
expect_none "Gemini 3.1 Pro"
expect_none "Unknown Model"

echo "== gateway guard: non-Cornell base URL must suppress rates =="
( export ANTHROPIC_BASE_URL="https://api.openai.example.com/"
  out=$(render "Opus 5 (1M context)")
  case "$out" in
    *'$'*) echo "  FAIL  non-Cornell gateway leaked a rate: $out"; exit 1 ;;
    *)     echo "  ok    non-Cornell gateway shows no rate" ;;
  esac ) || FAIL=$((FAIL+1))
PASS=$((PASS+1))

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
