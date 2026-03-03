#!/bin/bash
# ~/.claude/statusline.sh — Labeled-row status bar for Claude Code TUI
# Caches: location 1hr, weather 10min, git 5s. Target: <50ms on cache hit.

# ─── ANSI Colors ─────────────────────────────────────────────────────────────
RESET='\033[0m'
DIM='\033[2m'
BCYAN='\033[1;36m'
CYAN='\033[36m'
WHITE='\033[37m'
BWHITE='\033[1;37m'
BGREEN='\033[1;32m'
YELLOW='\033[33m'
BYELLOW='\033[1;33m'
RED='\033[31m'
BRED='\033[1;31m'
BMAGENTA='\033[1;35m'
BBLUE='\033[1;34m'

PIPE="${DIM} | ${RESET}"

# ─── Read session JSON from stdin ────────────────────────────────────────────
INPUT=$(cat)

MODEL=$(echo "$INPUT" | jq -r '.model.display_name // "Unknown"')
USED_PCT=$(echo "$INPUT" | jq -r '.context_window.used_percentage // 0')
COST=$(echo "$INPUT" | jq -r '.cost.total_cost_usd // 0')
DURATION_MS=$(echo "$INPUT" | jq -r '.cost.total_duration_ms // 0')
PROJ_DIR=$(echo "$INPUT" | jq -r '.workspace.project_dir // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
LINES_ADD=$(echo "$INPUT" | jq -r '.cost.total_lines_added // 0')
LINES_DEL=$(echo "$INPUT" | jq -r '.cost.total_lines_removed // 0')
VERSION=$(echo "$INPUT" | jq -r '.version // "?"')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
SESSION_SHORT="${SESSION_ID:0:7}"
IN_TOKENS=$(echo "$INPUT" | jq -r '.context_window.total_input_tokens // 0')
OUT_TOKENS=$(echo "$INPUT" | jq -r '.context_window.total_output_tokens // 0')
EXCEEDS_200K=$(echo "$INPUT" | jq -r '.exceeds_200k_tokens // false')
CACHE_READ_TOKENS=$(echo "$INPUT" | jq -r '.context_window.cache_read_input_tokens // 0')
CTX_WIN_SIZE=$(echo "$INPUT" | jq -r '.context_window.context_window_size // 200000')
if (( CTX_WIN_SIZE >= 1000000 )); then CTX_WIN_LABEL="1M"; else CTX_WIN_LABEL="200K"; fi

WORK_DIR="${PROJ_DIR:-$CWD}"
PROJ_NAME=$(basename "${WORK_DIR:-unknown}")

# ─── Auth detection ──────────────────────────────────────────────────────────
if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
  GW_HOST=$(echo "$ANTHROPIC_BASE_URL" | sed -E 's|https?://||; s|/.*||' | awk -F. '{print $(NF-1)}')
  AUTH_TAG="GW:${GW_HOST}"
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  AUTH_TAG="Key:..${ANTHROPIC_API_KEY: -4}"
else
  AUTH_TAG="Max"
fi

# ─── Gateway model rate detection ─────────────────────────────────────────────
# GW_TIERED=true means rates double when input tokens/request exceed 200k
# Rates: $/1M tokens. T1=normal, T2=over 200k input threshold.
GW_TIERED=false
GW_RATE_IN=""; GW_RATE_OUT=""
GW_RATE2_IN=""; GW_RATE2_OUT=""
if [[ "$AUTH_TAG" == GW:* ]]; then
  case "$MODEL" in
    *claude-4.6-opus*)
      GW_TIERED=true; GW_RATE_IN=5; GW_RATE_OUT=25; GW_RATE2_IN=10; GW_RATE2_OUT=37.50 ;;
    *claude-4.5-opus*|*claude-4.1-opus*|*claude-4-opus*)
      GW_RATE_IN=5; GW_RATE_OUT=25 ;;
    *claude-4.6-sonnet*|*claude-4.5-sonnet*|*claude-4-sonnet*|*claude-3.7-sonnet*)
      GW_TIERED=true; GW_RATE_IN=3; GW_RATE_OUT=15; GW_RATE2_IN=6; GW_RATE2_OUT=22.50 ;;
    *claude-4.5-haiku*|*claude-3.5-haiku*|*claude-3-haiku*)
      GW_RATE_IN=1; GW_RATE_OUT=5 ;;
  esac
fi

# ─── Platform detection ───────────────────────────────────────────────────────
OS_TYPE="$(uname -s)"

# ─── Cache helper (cross-platform) ───────────────────────────────────────────
cache_fresh() {
  local file="$1" max_age="$2"
  [[ -f "$file" ]] || return 1
  local now; now=$(date +%s)
  local mtime
  if [[ "$OS_TYPE" == "Darwin" ]]; then
    mtime=$(stat -f %m "$file" 2>/dev/null || echo 0)
  else
    mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
  fi
  (( now - mtime < max_age ))
}

# ─── Setup cache directory ───────────────────────────────────────────────────
CACHE_DIR="${HOME}/.cache/claude/statusline"
mkdir -p "$CACHE_DIR" 2>/dev/null

# ─── Git info (cached 5s) ────────────────────────────────────────────────────
GIT_CACHE="${CACHE_DIR}/git"
if cache_fresh "$GIT_CACHE" 5; then
  IFS='|' read -r BRANCH AHEAD BEHIND MODIFIED < "$GIT_CACHE"
else
  BRANCH=$(git -C "$WORK_DIR" --no-optional-locks rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [[ -n "$BRANCH" ]]; then
    AHEAD=$(git -C "$WORK_DIR" --no-optional-locks rev-list @{upstream}..HEAD 2>/dev/null | wc -l | tr -d ' ')
    BEHIND=$(git -C "$WORK_DIR" --no-optional-locks rev-list HEAD..@{upstream} 2>/dev/null | wc -l | tr -d ' ')
    MODIFIED=$(git -C "$WORK_DIR" --no-optional-locks status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  else
    AHEAD=0; BEHIND=0; MODIFIED=0
  fi
  echo "${BRANCH}|${AHEAD}|${BEHIND}|${MODIFIED}" > "$GIT_CACHE"
fi

# ─── Location via ipapi.co (HTTPS, cached 1hr) ───────────────────────────────
LOCATION_CACHE="${CACHE_DIR}/location"
if cache_fresh "$LOCATION_CACHE" 3600; then
  IFS='|' read -r WX_LAT WX_LON WX_CITY < "$LOCATION_CACHE"
else
  LOC_JSON=$(curl -s "https://ipapi.co/json/" --max-time 4 2>/dev/null)
  if [[ -n "$LOC_JSON" ]] && echo "$LOC_JSON" | jq -e '.latitude' >/dev/null 2>&1; then
    WX_LAT=$(echo "$LOC_JSON" | jq -r '.latitude')
    WX_LON=$(echo "$LOC_JSON" | jq -r '.longitude')
    WX_CITY=$(echo "$LOC_JSON" | jq -r '.city')
    echo "${WX_LAT}|${WX_LON}|${WX_CITY}" > "$LOCATION_CACHE"
  else
    WX_LAT="42.44"; WX_LON="-76.50"; WX_CITY="Ithaca"
  fi
fi

# ─── Weather via Open-Meteo (cached 10min) ───────────────────────────────────
# Cache stores raw components: CODE|TEMP|FEEL|WIND (icon derived at render time for day/night)
WEATHER_CACHE="${CACHE_DIR}/weather"
if cache_fresh "$WEATHER_CACHE" 600; then
  IFS='|' read -r WX_CODE WX_TEMP WX_FEEL WX_WIND < "$WEATHER_CACHE"
else
  WX_JSON=$(curl -s "https://api.open-meteo.com/v1/forecast?latitude=${WX_LAT}&longitude=${WX_LON}&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m&temperature_unit=fahrenheit&wind_speed_unit=mph" --max-time 4 2>/dev/null)
  if [[ -n "$WX_JSON" ]] && echo "$WX_JSON" | jq -e '.current' >/dev/null 2>&1; then
    WX_TEMP=$(echo "$WX_JSON" | jq -r '.current.temperature_2m // ""' | xargs printf '%.0f' 2>/dev/null)
    WX_FEEL=$(echo "$WX_JSON" | jq -r '.current.apparent_temperature // ""' | xargs printf '%.0f' 2>/dev/null)
    WX_WIND=$(echo "$WX_JSON" | jq -r '.current.wind_speed_10m // ""' | xargs printf '%.0f' 2>/dev/null)
    WX_CODE=$(echo "$WX_JSON" | jq -r '.current.weather_code // 0')
    echo "${WX_CODE}|${WX_TEMP}|${WX_FEEL}|${WX_WIND}" > "$WEATHER_CACHE"
  else
    WX_CODE="-1"; WX_TEMP="N/A"; WX_FEEL=""; WX_WIND=""
  fi
fi

# ─── Weather icon (day/night aware) ──────────────────────────────────────────
HOUR_NOW=$(date '+%H')
if (( HOUR_NOW < 7 || HOUR_NOW >= 20 )); then IS_NIGHT=true; else IS_NIGHT=false; fi
case "$WX_CODE" in
  0)        $IS_NIGHT && WX_ICON="🌙"  || WX_ICON="☀️";;
  1)        $IS_NIGHT && WX_ICON="🌙"  || WX_ICON="🌤";;
  2)        $IS_NIGHT && WX_ICON="☁️🌙" || WX_ICON="⛅";;
  3)        WX_ICON="☁️";;
  45|48)    WX_ICON="🌫";;
  51|53|55) WX_ICON="🌦";;
  56|57)    WX_ICON="🌧❄";;
  61|63|65) WX_ICON="🌧";;
  66|67)    WX_ICON="🌧❄";;
  71|73|75) WX_ICON="❄️";;
  77)       WX_ICON="❄️";;
  80|81|82) WX_ICON="🌧";;
  85|86)    WX_ICON="🌨";;
  95|96|99) WX_ICON="⛈";;
  *)        WX_ICON="🌡";;
esac

# ─── Battery (cross-platform) ─────────────────────────────────────────────────
if [[ "$OS_TYPE" == "Darwin" ]]; then
  BATT_RAW=$(pmset -g batt 2>/dev/null | grep -o '[0-9]*%' | head -1)
  BATT_NUM="${BATT_RAW//%/}"
elif [[ -f /sys/class/power_supply/BAT0/capacity ]]; then
  BATT_NUM=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null)
else
  BATT_NUM=""
fi
if [[ -n "$BATT_NUM" ]]; then
  if (( BATT_NUM <= 20 )); then
    BATT_CLR="$BRED"; BATT_ICON="🪫"
  elif (( BATT_NUM <= 50 )); then
    BATT_CLR="$YELLOW"; BATT_ICON="🔋"
  else
    BATT_CLR="$BGREEN"; BATT_ICON="🔋"
  fi
  BATT="${BATT_CLR}${BATT_ICON} ${BATT_NUM}%${RESET}"
else
  BATT=""
fi

# ─── Time & Date ──────────────────────────────────────────────────────────────
TIME_RAW=$(date '+%-I:%M%p')
TIME_NOW=$(echo "${TIME_RAW%?}" | tr '[:upper:]' '[:lower:]')  # 2:45p / 10:30a
DATE_NOW=$(date '+%a %b %d')

# ─── Duration format ─────────────────────────────────────────────────────────
fmt_duration() {
  local s=$(( $1 / 1000 ))
  if (( s >= 3600 )); then
    printf '%dh%dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
  elif (( s >= 60 )); then
    printf '%dm%ds' $(( s / 60 )) $(( s % 60 ))
  else
    printf '%ds' "$s"
  fi
}
DUR_FMT=$(fmt_duration "$DURATION_MS")

# ─── Token format ─────────────────────────────────────────────────────────────
fmt_tokens() {
  local n=$1
  if (( n >= 1000000 )); then
    printf '%.1fM' "$(echo "scale=1; $n / 1000000" | bc)"
  elif (( n >= 1000 )); then
    printf '%.1fk' "$(echo "scale=1; $n / 1000" | bc)"
  else
    printf '%d' "$n"
  fi
}
IN_FMT=$(fmt_tokens "$IN_TOKENS")
OUT_FMT=$(fmt_tokens "$OUT_TOKENS")

# ─── Context bar (wide) ───────────────────────────────────────────────────────
# Scale raw % by auto-compact threshold (~85%) so bar fills to 100% when truly full
RAW_PCT=$(printf '%.0f' "$USED_PCT" 2>/dev/null || echo 0)
[[ -z "$RAW_PCT" ]] && RAW_PCT=0
PCT=$(( RAW_PCT * 100 / 85 ))
(( PCT > 100 )) && PCT=100
BAR_LEN=24
FILLED=$(( PCT * BAR_LEN / 100 ))
EMPTY=$(( BAR_LEN - FILLED ))

if (( PCT >= 90 )); then
  BAR_COLOR="$BRED"
elif (( PCT >= 70 )); then
  BAR_COLOR="$BYELLOW"
else
  BAR_COLOR="$BGREEN"
fi

BAR_FILL="" BAR_EMPTY=""
for ((i=0; i<FILLED; i++)); do BAR_FILL+="●"; done
for ((i=0; i<EMPTY; i++)); do BAR_EMPTY+="○"; done
CTX_BAR="${BAR_COLOR}${BAR_FILL}${DIM}${BAR_EMPTY}${RESET}"

# ─── Gateway tier annotation ──────────────────────────────────────────────────
# Shows T1/T2 tier label + input/output rates on the CONTEXT row for gateway sessions.
# T2 triggers on exceeds_200k_tokens boolean from session JSON (per-request signal).
CTX_TIER=""
if [[ "$AUTH_TAG" == GW:* ]] && [[ -n "$GW_RATE_IN" ]]; then
  if [[ "$GW_TIERED" == true ]] && [[ "$EXCEEDS_200K" == "true" ]]; then
    CTX_TIER="${PIPE}${BRED}⚠ T2 \$${GW_RATE2_IN}/\$${GW_RATE2_OUT}${RESET}"
  elif [[ "$GW_TIERED" == true ]]; then
    CTX_TIER="${PIPE}${BGREEN}T1 \$${GW_RATE_IN}/\$${GW_RATE_OUT}${RESET}"
  else
    CTX_TIER="${PIPE}${DIM}\$${GW_RATE_IN}/\$${GW_RATE_OUT} flat${RESET}"
  fi
fi

# ─── Cache read tokens (Anthropic prompt cache) ─────────────────────────────
# Shows when > 0. Currently 0 because DISABLE_PROMPT_CACHING=1 is set in most
# gateway configs. Will activate automatically when prompt caching is enabled.
CTX_CACHE=""
if (( CACHE_READ_TOKENS > 0 )); then
  CACHE_FMT=$(fmt_tokens "$CACHE_READ_TOKENS")
  CTX_CACHE="${PIPE}${BGREEN}⚡${CACHE_FMT} cached${RESET}"
fi

# ─── Cost display ─────────────────────────────────────────────────────────────
# Direct API key: show cost in magenta (Claude Code calculates from Anthropic rates)
# Gateway (GW:*): don't show a dollar amount — Claude Code calculates cost using
#   Anthropic retail rates, but gateway billing uses different vendor pass-through
#   rates + per-request surcharges, and gateway response caching means some
#   requests cost $0 upstream. Show billing pointer instead.
# No ANTHROPIC_API_KEY (Max/OAuth): no cost field available, show nothing.
COST_PART=""
if [[ "$AUTH_TAG" == GW:* ]]; then
  COST_PART="${PIPE}${DIM}💰 billing: gateway UI${RESET}"
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  COST_PART="${PIPE}${BMAGENTA}$(printf '$%.4f' "$COST")${RESET}"
fi

# ─── Git display ──────────────────────────────────────────────────────────────
if [[ -n "$BRANCH" ]]; then
  if (( AHEAD > 0 || BEHIND > 0 )); then
    BRANCH_DISPLAY="${BYELLOW}${BRANCH}${RESET}"
    SYNC_DISPLAY="${YELLOW}↑${AHEAD} ↓${BEHIND}${RESET}"
  else
    BRANCH_DISPLAY="${BGREEN}${BRANCH}${RESET}"
    SYNC_DISPLAY="${DIM}↑${AHEAD} ↓${BEHIND}${RESET}"
  fi
  if (( MODIFIED > 0 )); then
    MOD_DISPLAY="${RED}~${MODIFIED} modified${RESET}"
  else
    MOD_DISPLAY="${DIM}clean${RESET}"
  fi
  GIT_ROW="${BMAGENTA}◆ GIT:${RESET} ${WHITE}${PROJ_NAME}${RESET}${PIPE}Branch: ${BRANCH_DISPLAY}${PIPE}${SYNC_DISPLAY}${PIPE}${MOD_DISPLAY}"
else
  GIT_ROW="${BMAGENTA}◆ GIT:${RESET} ${DIM}no git${RESET}"
fi

# ─── Session row ──────────────────────────────────────────────────────────────
SESSION_ROW="${BGREEN}+ SESSION:${RESET} ${BGREEN}+${LINES_ADD}${RESET} ${RED}-${LINES_DEL}${RESET} lines${PIPE}${WHITE}Dur ${DUR_FMT}${RESET}${PIPE}${DIM}#${SESSION_SHORT}${RESET}"
[[ -n "$BATT" ]] && SESSION_ROW+="${PIPE}${BATT}"
[[ -n "$COST_PART" ]] && SESSION_ROW+="$COST_PART"

# ─── Output ───────────────────────────────────────────────────────────────────
echo -e "${DIM}─── ${RESET}${BCYAN}| CC STATUSLINE |${RESET}${DIM} ────────────────────────────────────────────────────${RESET}"
echo -e "${BCYAN}◉ LOC:${RESET} ${BWHITE}${WX_CITY}${RESET}${PIPE}${BYELLOW}${TIME_NOW}${RESET}${PIPE}${WHITE}${DATE_NOW}${RESET}${PIPE}${WHITE}${WX_ICON}  ${WX_TEMP}°F · ${WX_WIND}mph${RESET}"
echo -e "${BCYAN}▲ ENV:${RESET} CC: ${WHITE}v${VERSION}${RESET}${PIPE}${BGREEN}${AUTH_TAG}${RESET}${PIPE}${BCYAN}${MODEL}${RESET}"
echo -e "${BBLUE}● CONTEXT:${RESET} ${CTX_BAR} ${BYELLOW}${PCT}% used${RESET}${PIPE}${DIM}${CTX_WIN_LABEL} ctx${RESET}${PIPE}${CYAN}In:${IN_FMT}  Out:${OUT_FMT}${RESET}${CTX_CACHE}${CTX_TIER}"
echo -e "$GIT_ROW"
echo -e "$SESSION_ROW"
