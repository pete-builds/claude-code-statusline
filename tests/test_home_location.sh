#!/usr/bin/env bash
# Runs the REAL statusline.sh with a stub curl and a real settings file
# (STATUSLINE_CONFIG) to assert the STATUSLINE_HOME_* setting wins over every
# lookup: with it set, no IP lookup host is ever contacted, the configured city
# renders even when a different city is cached, and bad coordinates are ignored.
# No real network: curl is a stub that logs the host it was asked for.
# Portable: bash 3.2, no associative arrays, no mapfile.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${STATUSLINE_UNDER_TEST:-$HERE/../statusline.sh}"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT missing"; exit 1; }
WORK="$(mktemp -d 2>/dev/null || mktemp -d -t sltest)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
echo "$url" >> "$CURL_LOG"
case "$url" in
  *ipify*)      echo "203.0.113.7" ;;
  *ipapi.co*)   echo '{"latitude":1.5,"longitude":2.5,"city":"WrongCity"}' ;;
  *ip-api.com*) echo '{"status":"success","lat":1.5,"lon":2.5,"city":"WrongCity"}' ;;
  *open-meteo*) echo '{"current":{"temperature_2m":50,"apparent_temperature":48,"weather_code":1,"wind_speed_10m":5}}' ;;
esac
STUB
chmod +x "$WORK/bin/curl"
ESC="$(printf '\033')"
fail=0

# Seed a WRONG cached city (what an earlier IP lookup would have left behind).
mk_home() { # mk_home NAME CONFIG_BODY -> sets H and CFG
  H="$WORK/home-$1"; CFG="$WORK/cfg-$1.env"
  mkdir -p "$H/.cache/claude/statusline"
  echo "1.5|2.5|WrongCity" > "$H/.cache/claude/statusline/location"
  printf '%s\n' "$2" > "$CFG"
  : > "$WORK/log-$1"
}
hosts() { sed -E 's|https?://([^/?]+).*|\1|' "$WORK/log-$1" | tr '\n' ' ' | sed 's/ $//'; }
check() { # check NAME WHAT GOT WANT
  if [ "$3" = "$4" ]; then echo "  ok    $1: $2 = [$3]"
  else echo "  FAIL  $1: $2 wanted [$4] got [$3]"; fail=1; fi
}

# 1. Home set, stale location cache: refresher contacts only open-meteo, and
#    the render shows the home city, not the cached one.
mk_home full 'STATUSLINE_HOME_CITY=Homeburg
STATUSLINE_HOME_LAT=42.44
STATUSLINE_HOME_LON=-76.50'
env -i PATH="$WORK/bin:$PATH" HOME="$H" STATUSLINE_CONFIG="$CFG" CURL_LOG="$WORK/log-full" \
  bash "$SCRIPT" --refresh-location-weather
check full "hosts contacted" "$(hosts full)" "api.open-meteo.com"
grep -q 'latitude=42.44&longitude=-76.50' "$WORK/log-full"; check full "weather asked for home coords" "$?" "0"
: > "$WORK/log-full"
out=$(printf '%s' '{"model":{"display_name":"Opus 5"}}' \
  | env -i PATH="$WORK/bin:$PATH" HOME="$H" STATUSLINE_CONFIG="$CFG" CURL_LOG="$WORK/log-full" \
    bash "$SCRIPT" 2>&1 | sed "s/$ESC\[[0-9;]*m//g" | grep -a 'LOC:')
case "$out" in *Homeburg*) ok=yes ;; *) ok=no ;; esac; check full "LOC row shows home city" "$ok" "yes"
case "$out" in *WrongCity*) ok=yes ;; *) ok=no ;; esac; check full "LOC row hides cached city" "$ok" "no"

# 2. Home set to a different value than the cache AND a fresh weather cache:
#    a render alone makes no network call at all.
echo "1|50|48|5" > "$H/.cache/claude/statusline/weather"
: > "$WORK/log-full"
printf '%s' '{"model":{"display_name":"Opus 5"}}' \
  | env -i PATH="$WORK/bin:$PATH" HOME="$H" STATUSLINE_CONFIG="$CFG" CURL_LOG="$WORK/log-full" \
    bash "$SCRIPT" >/dev/null 2>&1
sleep 1
check full "render with fresh weather: hosts" "$(hosts full)" ""

# 3. City only: shown, and no lookup of any kind (no coordinates, no weather).
mk_home cityonly 'STATUSLINE_HOME_CITY=Cityonly'
env -i PATH="$WORK/bin:$PATH" HOME="$H" STATUSLINE_CONFIG="$CFG" CURL_LOG="$WORK/log-cityonly" \
  bash "$SCRIPT" --refresh-location-weather
check cityonly "hosts contacted" "$(hosts cityonly)" ""

# 3b. City only must show NO weather, even with a cached reading on disk.
echo "1|50|48|5" > "$H/.cache/claude/statusline/weather"
touch "$H/.cache/claude/statusline/weather"
out=$(printf '%s' '{"model":{"display_name":"Opus 5"}}' \
  | env -i PATH="$WORK/bin:$PATH" HOME="$H" STATUSLINE_CONFIG="$CFG" CURL_LOG="$WORK/log-cityonly" \
    bash "$SCRIPT" 2>&1 | sed "s/$ESC\[[0-9;]*m//g" | grep -a 'LOC:')
case "$out" in *"50°F"*|*"5mph"*) ok=yes ;; *) ok=no ;; esac; check cityonly "stale weather hidden" "$ok" "no"
case "$out" in *Cityonly*) ok=yes ;; *) ok=no ;; esac; check cityonly "city still shown" "$ok" "yes"

# 4. Invalid coordinates (out of range, or carrying URL characters) are ignored
#    and never reach a URL, city still honoured.
mk_home bad 'STATUSLINE_HOME_CITY=Badcoords
STATUSLINE_HOME_LAT=999
STATUSLINE_HOME_LON="1&x=2"'
env -i PATH="$WORK/bin:$PATH" HOME="$H" STATUSLINE_CONFIG="$CFG" CURL_LOG="$WORK/log-bad" \
  bash "$SCRIPT" --refresh-location-weather
check bad "hosts contacted" "$(hosts bad)" ""

# 5. Control: nothing configured behaves as before (IP lookup is attempted).
mk_home none '# empty'
rm -f "$H/.cache/claude/statusline/location"
env -i PATH="$WORK/bin:$PATH" HOME="$H" STATUSLINE_CONFIG="$CFG" CURL_LOG="$WORK/log-none" \
  bash "$SCRIPT" --refresh-location-weather
check none "default still looks up by IP" "$(hosts none)" "api.ipify.org ipapi.co api.open-meteo.com"

[ "$fail" = "0" ] && echo "PASS: home location is used before any lookup"
exit "$fail"
