#!/usr/bin/env bash
set -euo pipefail

# Validates the context window priority cascade in statusline.sh:
# P1 trusted, P2 exceeds_200k, P3 current_usage sum, P4 heuristic, fallback.
# Feeds synthetic session JSON and asserts the rendered label.

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/statusline.sh"
[[ -x "$SCRIPT" ]] || { echo "FAIL: $SCRIPT not executable"; exit 1; }

# Strip ANSI escapes from a pipe so matches stay readable.
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# Render the statusline against a JSON fixture and extract the CONTEXT row.
render_context() {
  local json="$1"
  printf '%s' "$json" | "$SCRIPT" 2>/dev/null | strip_ansi | grep 'CONTEXT:'
}

# Synthetic fixture builders. Fields we don't care about are set to safe defaults.
make_json() {
  local model="$1" ctx_win="$2" used_pct="$3" exceeds="$4" cur_in="$5" cur_create="$6" cur_read="$7" cur_null="$8" has_rl="$9"
  local current_usage="null"
  if [[ "$cur_null" == "false" ]]; then
    current_usage="{\"input_tokens\":$cur_in,\"cache_creation_input_tokens\":$cur_create,\"cache_read_input_tokens\":$cur_read}"
  fi
  local rate_limits='{}'
  if [[ "$has_rl" == "true" ]]; then
    rate_limits='{"five_hour":{"used_percentage":15,"resets_at":0},"seven_day":{"used_percentage":3,"resets_at":0}}'
  fi
  cat <<EOF
{"model":{"display_name":"$model"},"context_window":{"context_window_size":$ctx_win,"used_percentage":$used_pct,"total_input_tokens":100000,"total_output_tokens":5000,"current_usage":$current_usage},"exceeds_200k_tokens":$exceeds,"session_id":"test","version":"2.1","cost":{"total_cost_usd":0,"total_duration_ms":1000,"total_lines_added":0,"total_lines_removed":0},"rate_limits":$rate_limits,"workspace":{"project_dir":"/tmp"}}
EOF
}

# P1 trusted: JSON reports 1M -> label "1M ctx"
out=$(render_context "$(make_json "Opus 4.7" 1000000 10 false 0 0 0 true true)")
[[ "$out" == *"1M ctx"* ]] || { echo "FAIL P1: got $out"; exit 1; }
[[ "$out" != *"1M* ctx"* ]] || { echo "FAIL P1: should not have asterisk"; exit 1; }

# P2 exceeds_200k: ctx_win says 200K but flag says we crossed -> "1M ctx"
out=$(render_context "$(make_json "Opus 4.7" 200000 99 true 50000 5000 190000 false true)")
[[ "$out" == *"1M ctx"* ]] || { echo "FAIL P2: got $out"; exit 1; }

# P3 current_usage sum > 200K: ctx_win says 200K, no exceeds flag, sum is proof
out=$(render_context "$(make_json "Opus 4.7" 200000 99 false 30000 5000 210000 false true)")
[[ "$out" == *"1M ctx"* ]] || { echo "FAIL P3: got $out"; exit 1; }

# P4 heuristic: Max (rate_limits present) + 1M-capable model, no empirical signal yet
out=$(render_context "$(make_json "Opus 4.7" 200000 5 false 0 0 0 true true)")
[[ "$out" == *"1M* ctx"* ]] || { echo "FAIL P4: expected 1M* got $out"; exit 1; }

# P4 heuristic: Fable 5 and Opus 4.8 are 1M-capable
out=$(render_context "$(make_json "Fable 5" 200000 5 false 0 0 0 true true)")
[[ "$out" == *"1M* ctx"* ]] || { echo "FAIL P4(fable): expected 1M* got $out"; exit 1; }
out=$(render_context "$(make_json "Opus 4.8" 200000 5 false 0 0 0 true true)")
[[ "$out" == *"1M* ctx"* ]] || { echo "FAIL P4(opus48): expected 1M* got $out"; exit 1; }

# Fallback: 200K model, no rate_limits (API user)
out=$(render_context "$(make_json "Haiku 4.5" 200000 20 false 5000 0 35000 false false)")
[[ "$out" == *"200K ctx"* ]] || { echo "FAIL fallback: got $out"; exit 1; }

# Fallback: 1M-capable model but no rate_limits (no Max signal)
out=$(render_context "$(make_json "Opus 4.7" 200000 20 false 0 0 0 true false)")
[[ "$out" == *"200K ctx"* ]] || { echo "FAIL fallback(no-rl): got $out"; exit 1; }

echo "PASS: context window cascade (P1, P2, P3, P4, P4-fable/opus48, fallback)"
