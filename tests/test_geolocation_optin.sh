#!/usr/bin/env bash
set -euo pipefail

# Runs the REAL statusline.sh refresher with a stub curl on PATH and asserts
# which hosts it contacts. The other location tests mirror the decision logic
# in a copy, so they keep passing if statusline.sh drifts; this one does not.
#
# The rule under test: nothing that reveals the user's IP-derived location is
# called unless STATUSLINE_GEOLOCATE=1, and the plain-HTTP provider is never
# called without STATUSLINE_GEO_ALLOW_HTTP=1 on top of that.

HERE="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$HERE/statusline.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
echo "$url" >> "$CURL_LOG"
case "$url" in
  *ipify*)      echo "203.0.113.7" ;;
  *ipapi.co*)   [[ "${STUB_IPAPI_FAIL:-0}" == "1" ]] || echo '{"latitude":42.4,"longitude":-76.5,"city":"Stubville"}' ;;
  *ip-api.com*) echo '{"status":"success","lat":42.4,"lon":-76.5,"city":"Httpville"}' ;;
  *open-meteo*) echo '{"current":{"temperature_2m":50,"apparent_temperature":48,"weather_code":1,"wind_speed_10m":5}}' ;;
esac
STUB
chmod +x "$WORK/bin/curl"

fail=0
# run_case NAME EXPECTED_HOSTS(space separated, "none" for no calls) [VAR=VAL ...]
run_case() {
  local name="$1" want="$2"; shift 2
  local home="$WORK/home-$name"
  mkdir -p "$home"
  : > "$WORK/log-$name"
  env -i PATH="$WORK/bin:$PATH" HOME="$home" STATUSLINE_CONFIG=/nonexistent \
    CURL_LOG="$WORK/log-$name" "$@" \
    bash "$SCRIPT" --refresh-location-weather
  local got
  got=$(sed -E 's|https?://([^/]+).*|\1|' "$WORK/log-$name" | tr '\n' ' ' | sed 's/ $//')
  [[ -z "$got" ]] && got="none"
  if [[ "$got" == "$want" ]]; then
    echo "ok   $name: $got"
  else
    echo "FAIL $name: wanted [$want] got [$got]"
    fail=1
  fi
}

run_case default            "none"
run_case fallback-only      "api.open-meteo.com" \
  STATUSLINE_FALLBACK_LAT=42.4 STATUSLINE_FALLBACK_LON=-76.5
run_case geolocate          "api.ipify.org ipapi.co api.open-meteo.com" \
  STATUSLINE_GEOLOCATE=1
run_case https-fail-no-http "api.ipify.org ipapi.co" \
  STATUSLINE_GEOLOCATE=1 STUB_IPAPI_FAIL=1
run_case https-fail-http-ok "api.ipify.org ipapi.co ip-api.com api.open-meteo.com" \
  STATUSLINE_GEOLOCATE=1 STUB_IPAPI_FAIL=1 STATUSLINE_GEO_ALLOW_HTTP=1

# A city cached while geolocation was on must not keep rendering after it is
# switched off: the configured fallback city wins.
home="$WORK/home-render"
mkdir -p "$home/.cache/claude/statusline"
echo "1|2|CachedCity" > "$home/.cache/claude/statusline/location"
out=$(printf '%s' '{"model":{"display_name":"Opus 5"}}' \
  | env -i PATH="$WORK/bin:$PATH" HOME="$home" STATUSLINE_CONFIG=/nonexistent \
      CURL_LOG="$WORK/log-render" STATUSLINE_FALLBACK_CITY=FallbackTown \
      bash "$SCRIPT" 2>&1)
# Here-strings, not `printf | grep -q`: under pipefail grep -q exiting early can
# SIGPIPE the printf and fail the check precisely when the needle was found.
if grep -q FallbackTown <<<"$out" && ! grep -q CachedCity <<<"$out"; then
  echo "ok   render-ignores-stale-cache"
else
  echo "FAIL render-ignores-stale-cache"; fail=1
fi

[[ "$fail" == "0" ]] && echo "PASS: geolocation is opt-in, HTTP provider needs its own opt-in"
exit "$fail"
