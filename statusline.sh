#!/bin/bash
# ~/.claude/statusline.sh — Labeled-row status bar for Claude Code TUI
# Caches: location 1hr, weather 10min, git 5s. Target: <50ms on cache hit.
#
# Optional local config (untracked): set STATUSLINE_FALLBACK_CITY / _LAT / _LON
# to define a fallback location used before the first successful geolocation, or
# when the geolocation service is unavailable. No personal default is baked into
# this script. Override the path with STATUSLINE_CONFIG.
# shellcheck source=/dev/null
[[ -f "${STATUSLINE_CONFIG:-$HOME/.claude/statusline.env}" ]] && \
  source "${STATUSLINE_CONFIG:-$HOME/.claude/statusline.env}" 2>/dev/null
#
# ─── Background refresh mode ──────────────────────────────────────────────────
# Invoked as `"$0" --refresh-location-weather` in a detached background process
# by the main render path below. Does the blocking network calls (ipify, ipapi,
# open-meteo) and writes the cache files for the NEXT render to pick up. Never
# runs inline during a normal render — that's the whole point of this mode.
if [[ "${1:-}" == "--refresh-location-weather" ]]; then
  CACHE_DIR="${HOME}/.cache/claude/statusline"
  mkdir -p "$CACHE_DIR" 2>/dev/null
  LOCATION_CACHE="${CACHE_DIR}/location"
  IP_CACHE="${CACHE_DIR}/location_ip"
  WEATHER_CACHE="${CACHE_DIR}/weather"
  LOCK_FILE="${CACHE_DIR}/refresh.lock"
  FAIL_CACHE="${CACHE_DIR}/location_fail"   # backoff marker: touched when geolocation fails
  GEO_FAIL_COOLDOWN=3600                     # wait this many seconds before retrying after a failure

  # Best-effort lock: skip if a refresh is already running. Stale lock (older
  # than 30s — well beyond worst-case curl timeouts below) is treated as dead
  # and reclaimed rather than blocking forever.
  if [[ -f "$LOCK_FILE" ]]; then
    LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null)
    LOCK_AGE=999
    if [[ "$(uname -s)" == "Darwin" ]]; then
      LOCK_MTIME=$(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0)
    else
      LOCK_MTIME=$(stat -c %Y "$LOCK_FILE" 2>/dev/null || echo 0)
    fi
    LOCK_AGE=$(( $(date +%s) - LOCK_MTIME ))
    if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null && (( LOCK_AGE < 30 )); then
      exit 0
    fi
  fi
  echo $$ > "$LOCK_FILE"
  trap 'rm -f "$LOCK_FILE"' EXIT

  CURRENT_IP=$(curl -s "https://api.ipify.org" --max-time 2 2>/dev/null || echo "")
  CACHED_IP=""
  [[ -f "$IP_CACHE" ]] && CACHED_IP=$(cat "$IP_CACHE" 2>/dev/null || echo "")

  NEED_LOCATION=false
  if [[ -n "$CURRENT_IP" ]] && [[ "$CURRENT_IP" != "$CACHED_IP" ]]; then
    NEED_LOCATION=true                       # IP changed -> always look up (and clear any backoff)
    rm -f "$FAIL_CACHE"
  elif [[ ! -f "$LOCATION_CACHE" ]]; then
    NEED_LOCATION=true
    # Same IP, no cached location: honor the failure backoff so we don't hammer a
    # rate-limited geolocation API on every refresh while it's down.
    if [[ -f "$FAIL_CACHE" ]]; then
      if [[ "$(uname -s)" == "Darwin" ]]; then
        FAIL_MTIME=$(stat -f %m "$FAIL_CACHE" 2>/dev/null || echo 0)
      else
        FAIL_MTIME=$(stat -c %Y "$FAIL_CACHE" 2>/dev/null || echo 0)
      fi
      (( $(date +%s) - FAIL_MTIME < GEO_FAIL_COOLDOWN )) && NEED_LOCATION=false
    fi
  fi

  RLAT="" RLON="" RCITY=""
  if [[ "$NEED_LOCATION" == "true" ]]; then
    # Provider 1: ipapi.co (fields: .latitude .longitude .city)
    LOC_JSON=$(curl -s "https://ipapi.co/json/" --max-time 4 2>/dev/null)
    if [[ -n "$LOC_JSON" ]] && echo "$LOC_JSON" | jq -e '.latitude' >/dev/null 2>&1; then
      RLAT=$(echo "$LOC_JSON" | jq -r '.latitude')
      RLON=$(echo "$LOC_JSON" | jq -r '.longitude')
      RCITY=$(echo "$LOC_JSON" | jq -r '.city')
    else
      # Provider 2 (fallback): ip-api.com (fields: .lat .lon .city; free tier is HTTP-only, ~45 req/min)
      LOC_JSON=$(curl -s "http://ip-api.com/json/" --max-time 4 2>/dev/null)
      if [[ -n "$LOC_JSON" ]] && [[ "$(echo "$LOC_JSON" | jq -r '.status // ""' 2>/dev/null)" == "success" ]]; then
        RLAT=$(echo "$LOC_JSON" | jq -r '.lat')
        RLON=$(echo "$LOC_JSON" | jq -r '.lon')
        RCITY=$(echo "$LOC_JSON" | jq -r '.city')
      fi
    fi

    if [[ -n "$RLAT" ]] && [[ "$RLAT" != "null" ]]; then
      echo "${RLAT}|${RLON}|${RCITY}" > "$LOCATION_CACHE"
      [[ -n "$CURRENT_IP" ]] && echo "$CURRENT_IP" > "$IP_CACHE"
      rm -f "$FAIL_CACHE"                     # success clears the backoff
    else
      touch "$FAIL_CACHE"                     # both providers failed -> start/refresh backoff
    fi
  fi
  # Use freshly-fetched coords if we got them, else fall back to whatever's cached.
  if [[ -z "$RLAT" ]] && [[ -f "$LOCATION_CACHE" ]]; then
    IFS='|' read -r RLAT RLON _ < "$LOCATION_CACHE"
  fi
  [[ -z "$RLAT" ]] && RLAT="${STATUSLINE_FALLBACK_LAT:-}" && RLON="${STATUSLINE_FALLBACK_LON:-}"

  # Only fetch weather when we have coordinates (from geolocation, cache, or a
  # configured fallback). No coords → skip; the render shows a placeholder.
  if [[ -n "$RLAT" ]] && [[ -n "$RLON" ]]; then
    WX_JSON=$(curl -s "https://api.open-meteo.com/v1/forecast?latitude=${RLAT}&longitude=${RLON}&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m&temperature_unit=fahrenheit&wind_speed_unit=mph" --max-time 4 2>/dev/null)
    if [[ -n "$WX_JSON" ]] && echo "$WX_JSON" | jq -e '.current' >/dev/null 2>&1; then
      RTEMP=$(echo "$WX_JSON" | jq -r '.current.temperature_2m // ""' | xargs printf '%.0f' 2>/dev/null)
      RFEEL=$(echo "$WX_JSON" | jq -r '.current.apparent_temperature // ""' | xargs printf '%.0f' 2>/dev/null)
      RWIND=$(echo "$WX_JSON" | jq -r '.current.wind_speed_10m // ""' | xargs printf '%.0f' 2>/dev/null)
      RCODE=$(echo "$WX_JSON" | jq -r '.current.weather_code // 0')
      echo "${RCODE}|${RTEMP}|${RFEEL}|${RWIND}" > "$WEATHER_CACHE"
    fi
  fi

  exit 0
fi

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

# ─── Read session JSON from stdin (single jq call for performance) ───────────
INPUT=$(cat)

eval "$(echo "$INPUT" | jq -r '
  @sh "MODEL=\(.model.display_name // "Unknown")",
  @sh "USED_PCT=\(.context_window.used_percentage // 0)",
  @sh "COST=\(.cost.total_cost_usd // 0)",
  @sh "DURATION_MS=\(.cost.total_duration_ms // 0)",
  @sh "PROJ_DIR=\(.workspace.project_dir // "")",
  @sh "CWD=\(.cwd // "")",
  @sh "LINES_ADD=\(.cost.total_lines_added // 0)",
  @sh "LINES_DEL=\(.cost.total_lines_removed // 0)",
  @sh "VERSION=\(.version // "?")",
  @sh "SESSION_ID=\(.session_id // "")",
  @sh "IN_TOKENS=\(.context_window.total_input_tokens // 0)",
  @sh "OUT_TOKENS=\(.context_window.total_output_tokens // 0)",
  @sh "CUR_IN_TOKENS=\(.context_window.current_usage.input_tokens // 0)",
  @sh "CUR_CACHE_CREATE=\(.context_window.current_usage.cache_creation_input_tokens // 0)",
  @sh "CUR_CACHE_READ=\(.context_window.current_usage.cache_read_input_tokens // 0)",
  @sh "CUR_USAGE_PRESENT=\(if .context_window.current_usage == null then "false" else "true" end)",
  @sh "EXCEEDS_200K=\(.exceeds_200k_tokens // false)",
  @sh "CTX_WIN_SIZE=\(.context_window.context_window_size // 0)",
  @sh "RL_5H_PCT=\(.rate_limits.five_hour.used_percentage // "")",
  @sh "RL_5H_RESETS=\(.rate_limits.five_hour.resets_at // "")",
  @sh "RL_7D_PCT=\(.rate_limits.seven_day.used_percentage // "")",
  @sh "RL_7D_RESETS=\(.rate_limits.seven_day.resets_at // "")",
  @sh "VIM_MODE=\(.vim.mode // "")",
  @sh "AGENT_NAME=\(.agent.name // "")",
  @sh "WORKTREE_NAME=\(.worktree.name // "")",
  @sh "WORKTREE_BRANCH=\(.worktree.branch // "")"
' | tr ',' '\n')"
SESSION_SHORT="${SESSION_ID:0:7}"

# ─── Context window detection ────────────────────────────────────────────────
# Priority cascade. Claude Code bug anthropics/claude-code#34143 (still open)
# makes context_window_size report 200000 on Max plans for 1M-capable models,
# even when the backend actually uses 1M. Prefer empirical JSON signals; fall
# back to a model+plan heuristic only when no API call has yet proven the size.
# Retire P4 when #34143 closes and the debug log shows CTX_WIN_SIZE reliably
# reporting 1000000 on Max sessions (~/.cache/claude/statusline/context_window_debug.log).
#
# P1: JSON reports 1M (trusted)
# P2: exceeds_200k_tokens true (empirical — last response crossed 200K)
# P3: current-call token sum > 200K (empirical — same idea, different source)
# P4: Max plan + 1M-capable model (heuristic — label suffixed with "*")
# Fallback: reported size
CUR_USAGE_SUM=$(( CUR_IN_TOKENS + CUR_CACHE_CREATE + CUR_CACHE_READ ))

# TODO: remove MODEL_SUPPORTS_1M and P4 branch when anthropics/claude-code#34143 is fixed.
MODEL_SUPPORTS_1M=false
case "$MODEL" in
  *[Oo]pus*4.[678]*|*[Oo]pus*4-[678]*|*[Ss]onnet*4.6*|*[Ss]onnet*4-6*|*[Ff]able*) MODEL_SUPPORTS_1M=true ;;
esac

if (( CTX_WIN_SIZE >= 1000000 )); then
  CTX_WIN_LABEL="1M";  DECISION="P1_trusted";   EFFECTIVE_WIN=1000000
elif [[ "$EXCEEDS_200K" == "true" ]]; then
  CTX_WIN_LABEL="1M";  DECISION="P2_exceeds";   EFFECTIVE_WIN=1000000
elif [[ "$CUR_USAGE_PRESENT" == "true" ]] && (( CUR_USAGE_SUM > 200000 )); then
  CTX_WIN_LABEL="1M";  DECISION="P3_sum";       EFFECTIVE_WIN=1000000
elif [[ "$MODEL_SUPPORTS_1M" == "true" ]] && [[ -n "$RL_5H_PCT" ]] && [[ "$RL_5H_PCT" != "null" ]]; then
  CTX_WIN_LABEL="1M*"; DECISION="P4_heuristic"; EFFECTIVE_WIN=1000000
else
  CTX_WIN_LABEL="200K"; DECISION="fallback_200k"; EFFECTIVE_WIN=200000
fi

# ─── Debug log (for retiring P4 when #34143 closes) ──────────────────────────
DEBUG_LOG="${HOME}/.cache/claude/statusline/context_window_debug.log"
if [[ -d "$(dirname "$DEBUG_LOG")" ]]; then
  MODEL_SAFE="${MODEL//|/_}"
  RL_5H_PRESENT="false"
  [[ -n "$RL_5H_PCT" ]] && [[ "$RL_5H_PCT" != "null" ]] && RL_5H_PRESENT="true"
  echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ')|${SESSION_SHORT}|${MODEL_SAFE}|${CTX_WIN_SIZE}|${USED_PCT}|${IN_TOKENS}|${OUT_TOKENS}|${EXCEEDS_200K}|${CUR_USAGE_SUM}|${RL_5H_PRESENT}|${CTX_WIN_LABEL}|${DECISION}" >> "$DEBUG_LOG" 2>/dev/null
  { tail -n 200 "$DEBUG_LOG" > "${DEBUG_LOG}.tmp" 2>/dev/null && mv "${DEBUG_LOG}.tmp" "$DEBUG_LOG" 2>/dev/null; } &
fi

WORK_DIR="${PROJ_DIR:-$CWD}"
PROJ_NAME=$(basename "${WORK_DIR:-unknown}")

# ─── Auth detection ──────────────────────────────────────────────────────────
if [[ -n "${ANTHROPIC_BASE_URL:-}" ]]; then
  GW_HOST=$(echo "$ANTHROPIC_BASE_URL" | sed -E 's|https?://||; s|/.*||' | awk -F. '{print $(NF-1)}')
  AUTH_TAG="GW:${GW_HOST}"
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  AUTH_TAG="API:..${ANTHROPIC_API_KEY: -4}"
else
  AUTH_TAG="OAuth"
fi

# ─── Plan/seat tier (subscription sessions) ──────────────────────────────────
# Reads oauthAccount.seatTier from ~/.claude.json so the bar shows Pro/Max/Team,
# not just "OAuth". Local file read only, no network. Unknown tiers fall through
# to the raw value with underscores spaced out.
if [[ "$AUTH_TAG" == "OAuth" ]] && [[ -f "$HOME/.claude.json" ]]; then
  SEAT_TIER=$(jq -r '.oauthAccount.seatTier // empty' "$HOME/.claude.json" 2>/dev/null)
  case "$SEAT_TIER" in
    team_standard) PLAN_TAG="Team" ;;
    team_premium)  PLAN_TAG="Team+" ;;
    max_20x)       PLAN_TAG="Max20x" ;;
    max_5x)        PLAN_TAG="Max5x" ;;
    max)           PLAN_TAG="Max" ;;
    pro)           PLAN_TAG="Pro" ;;
    free)          PLAN_TAG="Free" ;;
    "")            PLAN_TAG="" ;;
    *)             PLAN_TAG="${SEAT_TIER//_/ }" ;;
  esac
  [[ -n "$PLAN_TAG" ]] && AUTH_TAG="OAuth·${PLAN_TAG}"
fi

# ─── Cornell model rate detection ────────────────────────────────────────────
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

# ─── Location + Weather: render from cache only, NEVER block on network ─────
# Prior design ran ipify+ipapi+open-meteo curls inline (worst case ~10s). Claude
# Code kills the statusline command at ~5s, before the cache file was written —
# so a slow/offline network produced a PERMANENT blank statusline (no cache ever
# landed, every render re-tried the same blocking calls and got killed again).
# Fix: render always reads whatever is on disk right now (or shows a placeholder
# if nothing's there yet) and a detached background process refreshes the cache
# for the *next* render whenever it's due. Render itself never touches the network.
LOCATION_CACHE="${CACHE_DIR}/location"
IP_CACHE="${CACHE_DIR}/location_ip"
WEATHER_CACHE="${CACHE_DIR}/weather"

if [[ -f "$LOCATION_CACHE" ]]; then
  IFS='|' read -r WX_LAT WX_LON WX_CITY < "$LOCATION_CACHE"
else
  # No cache yet. Fall back to a configured location if set, else a neutral
  # placeholder — no personal default is hardcoded here.
  WX_LAT="${STATUSLINE_FALLBACK_LAT:-}"
  WX_LON="${STATUSLINE_FALLBACK_LON:-}"
  WX_CITY="${STATUSLINE_FALLBACK_CITY:-…}"
fi

# Cache stores raw components: CODE|TEMP|FEEL|WIND (icon derived at render time for day/night)
if [[ -f "$WEATHER_CACHE" ]]; then
  IFS='|' read -r WX_CODE WX_TEMP WX_FEEL WX_WIND < "$WEATHER_CACHE"
else
  WX_CODE="-1"; WX_TEMP="…"; WX_FEEL=""; WX_WIND="…"
fi

# Kick a background refresh if either cache is stale/missing. The refresher
# guards itself with a lock file (see --refresh-location-weather mode above),
# so it's safe to fire this on every render without piling up processes.
if ! cache_fresh "$LOCATION_CACHE" 3600 || ! cache_fresh "$WEATHER_CACHE" 600; then
  ( "$0" --refresh-location-weather >/dev/null 2>&1 & disown ) 2>/dev/null
fi

# ─── Weather icon (day/night aware) ──────────────────────────────────────────
HOUR_NOW=$(date '+%-H')
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
# When EFFECTIVE_WIN was inferred 1M but JSON reports 200K (bug #34143), the
# precomputed used_percentage is calculated against 200K and is therefore
# inflated. Recompute locally from current_usage token sum against 1M.
# Otherwise trust used_percentage. On 200K sessions, scale by the ~85%
# auto-compact threshold so the bar fills visually at true full. The 1M
# auto-compact threshold is undocumented, so skip scaling there.
if (( EFFECTIVE_WIN == 1000000 )) && (( CTX_WIN_SIZE < 1000000 )); then
  if [[ "$CUR_USAGE_PRESENT" == "true" ]]; then
    RAW_PCT=$(( CUR_USAGE_SUM * 100 / 1000000 ))
  else
    RAW_PCT=0
  fi
else
  RAW_PCT=$(printf '%.0f' "$USED_PCT" 2>/dev/null || echo 0)
  [[ -z "$RAW_PCT" ]] && RAW_PCT=0
fi
if (( EFFECTIVE_WIN == 1000000 )); then
  PCT=$RAW_PCT
else
  PCT=$(( RAW_PCT * 100 / 85 ))
fi
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

# ─── Cornell tier annotation ─────────────────────────────────────────────────
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

# ─── Cost display ─────────────────────────────────────────────────────────────
# Direct API key: show exact cost in magenta (Claude Code calculates from Anthropic rates)
# Cornell gateway (GW:*): show as estimate (~$) in yellow — Claude Code still calculates
#   cost client-side using Anthropic rates, but actual Cornell charge is cloud vendor
#   pass-through + $0.002/request surcharge. Value is directionally useful, not exact.
# No ANTHROPIC_API_KEY (Max/OAuth): no cost field available, show nothing.
COST_PART=""
if [[ "$AUTH_TAG" == GW:* ]]; then
  COST_PART="${PIPE}${BYELLOW}~$(printf '$%.4f' "$COST") est${RESET}"
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

# ─── Rate limits (Claude.ai Pro/Max only) ────────────────────────────────────
# Format a reset epoch (UTC) into a short local-time string: "1pm" if within
# 24h, "Apr 23 7pm" otherwise. Returns empty if epoch is empty/null/0.
# Honors CLAUDE_STATUSLINE_TZ env var (e.g. "America/New_York"); otherwise
# uses the system's local timezone.
fmt_reset_time() {
  local epoch="$1"
  [[ -z "$epoch" ]] && return
  [[ "$epoch" == "null" ]] && return
  (( epoch == 0 )) && return
  local now_epoch delta fmt
  now_epoch=$(date +%s)
  delta=$(( epoch - now_epoch ))
  if (( delta < 86400 )); then
    fmt='+%-I%p'
  else
    fmt='+%b %-d %-I%p'
  fi
  local tz="${CLAUDE_STATUSLINE_TZ:-}"
  if [[ "$OS_TYPE" == "Darwin" ]]; then
    if [[ -n "$tz" ]]; then
      TZ="$tz" date -r "$epoch" "$fmt" 2>/dev/null | tr '[:upper:]' '[:lower:]'
    else
      date -r "$epoch" "$fmt" 2>/dev/null | tr '[:upper:]' '[:lower:]'
    fi
  else
    if [[ -n "$tz" ]]; then
      TZ="$tz" date -d "@$epoch" "$fmt" 2>/dev/null | tr '[:upper:]' '[:lower:]'
    else
      date -d "@$epoch" "$fmt" 2>/dev/null | tr '[:upper:]' '[:lower:]'
    fi
  fi
}

RL_PART=""
if [[ -n "$RL_5H_PCT" ]] && [[ "$RL_5H_PCT" != "null" ]]; then
  RL_5H_NUM=$(printf '%.0f' "$RL_5H_PCT" 2>/dev/null || echo 0)
  if (( RL_5H_NUM >= 80 )); then RL_5H_CLR="$BRED"
  elif (( RL_5H_NUM >= 50 )); then RL_5H_CLR="$BYELLOW"
  else RL_5H_CLR="$BGREEN"; fi
  RL_5H_RESET_FMT=$(fmt_reset_time "$RL_5H_RESETS")
  RL_PART="${RL_5H_CLR}5h:${RL_5H_NUM}%${RESET}"
  [[ -n "$RL_5H_RESET_FMT" ]] && RL_PART+="${DIM}→${RL_5H_RESET_FMT}${RESET}"
fi
if [[ -n "$RL_7D_PCT" ]] && [[ "$RL_7D_PCT" != "null" ]]; then
  RL_7D_NUM=$(printf '%.0f' "$RL_7D_PCT" 2>/dev/null || echo 0)
  if (( RL_7D_NUM >= 80 )); then RL_7D_CLR="$BRED"
  elif (( RL_7D_NUM >= 50 )); then RL_7D_CLR="$BYELLOW"
  else RL_7D_CLR="$BGREEN"; fi
  RL_7D_RESET_FMT=$(fmt_reset_time "$RL_7D_RESETS")
  [[ -n "$RL_PART" ]] && RL_PART+=" "
  RL_PART+="${RL_7D_CLR}7d:${RL_7D_NUM}%${RESET}"
  [[ -n "$RL_7D_RESET_FMT" ]] && RL_PART+="${DIM}→${RL_7D_RESET_FMT}${RESET}"
fi

# ─── Vim mode indicator ──────────────────────────────────────────────────────
VIM_PART=""
if [[ -n "$VIM_MODE" ]] && [[ "$VIM_MODE" != "null" ]]; then
  if [[ "$VIM_MODE" == "INSERT" ]]; then
    VIM_PART="${BGREEN}[INS]${RESET}"
  else
    VIM_PART="${BCYAN}[NOR]${RESET}"
  fi
fi

# ─── Agent/worktree indicators ───────────────────────────────────────────────
AGENT_PART=""
[[ -n "$AGENT_NAME" ]] && [[ "$AGENT_NAME" != "null" ]] && AGENT_PART="${BMAGENTA}⚙ ${AGENT_NAME}${RESET}"
WORKTREE_PART=""
[[ -n "$WORKTREE_NAME" ]] && [[ "$WORKTREE_NAME" != "null" ]] && WORKTREE_PART="${WORKTREE_NAME}${DIM}(${WORKTREE_BRANCH})${RESET}"

# ─── Session row ──────────────────────────────────────────────────────────────
SESSION_ROW="${BGREEN}+ SESSION:${RESET} ${BGREEN}+${LINES_ADD}${RESET} ${RED}-${LINES_DEL}${RESET} lines${PIPE}${WHITE}Dur ${DUR_FMT}${RESET}${PIPE}${DIM}#${SESSION_SHORT}${RESET}"
[[ -n "$BATT" ]] && SESSION_ROW+="${PIPE}${BATT}"
[[ -n "$COST_PART" ]] && SESSION_ROW+="$COST_PART"
[[ -n "$RL_PART" ]] && SESSION_ROW+="${PIPE}${RL_PART}"

# ─── ENV row extras ──────────────────────────────────────────────────────────
ENV_EXTRAS=""
[[ -n "$VIM_PART" ]] && ENV_EXTRAS+="${PIPE}${VIM_PART}"
[[ -n "$AGENT_PART" ]] && ENV_EXTRAS+="${PIPE}${AGENT_PART}"

# ─── Output ───────────────────────────────────────────────────────────────────
echo -e "${DIM}─── ${RESET}${BCYAN}| CC STATUSLINE |${RESET}${DIM} ────────────────────────────────────────────────────${RESET}"
echo -e "${BCYAN}◉ LOC:${RESET} ${BWHITE}${WX_CITY}${RESET}${PIPE}${BYELLOW}${TIME_NOW}${RESET}${PIPE}${WHITE}${DATE_NOW}${RESET}${PIPE}${WHITE}${WX_ICON}  ${WX_TEMP}°F · ${WX_WIND}mph${RESET}"
echo -e "${BCYAN}▲ ENV:${RESET} CC: ${WHITE}v${VERSION}${RESET}${PIPE}${BGREEN}${AUTH_TAG}${RESET}${PIPE}${BCYAN}${MODEL}${RESET}${ENV_EXTRAS}"
[[ -n "$WORKTREE_PART" ]] && echo -e "${BYELLOW}🌿 WORKTREE:${RESET} ${WORKTREE_PART}"
echo -e "${BBLUE}● CONTEXT:${RESET} ${CTX_BAR} ${BYELLOW}${PCT}% used${RESET}${PIPE}${DIM}${CTX_WIN_LABEL} ctx${RESET}${PIPE}${CYAN}In:${IN_FMT}  Out:${OUT_FMT}${RESET}${CTX_TIER}"
echo -e "$GIT_ROW"
echo -e "$SESSION_ROW"
