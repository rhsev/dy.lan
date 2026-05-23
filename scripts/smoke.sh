#!/usr/bin/env bash
# Dylan Smoke Test — schnelle Sanity-Check-Suite für die häufigsten
# Regressionen: Routen erreichbar, Content-Type stimmt, erwarteter
# Inhalts-Marker im Response-Body.
#
# Läuft gegen eine laufende Dylan-Instanz. Nicht für CI — vor jedem Push
# manuell laufen lassen:
#
#   ./scripts/smoke.sh                          # gegen dy.lan
#   DYLAN_HOST=localhost DYLAN_PORT=8080 ./scripts/smoke.sh
#
# Exit 0 wenn alles grün, sonst Anzahl der Fehler.

set -u
HOST="${DYLAN_HOST:-dy.lan}"
PORT="${DYLAN_PORT:-80}"
BASE="http://${HOST}:${PORT}"

# Farben nur wenn das Terminal sie unterstützt
if [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; then
  GRN=$'\033[32m'; RED=$'\033[31m'; DIM=$'\033[2m'; OFF=$'\033[0m'
else
  GRN=''; RED=''; DIM=''; OFF=''
fi

passed=0
failed=0
fails=()

# check NAME URL  [expected-status]  [grep-pattern]
check() {
  local name="$1" url="$2" want_status="${3:-200}" want_grep="${4:-}"
  local body status

  body=$(curl -s -o /tmp/smoke-body.$$ -w "%{http_code}" -m 5 -L --max-redirs 0 "$BASE$url" 2>/dev/null) || true
  status="$body"

  if [ "$status" != "$want_status" ]; then
    failed=$((failed+1))
    fails+=("$name: expected HTTP $want_status, got $status — $url")
    printf "  ${RED}FAIL${OFF}  %-32s %s\n" "$name" "$DIM$status$OFF"
    rm -f /tmp/smoke-body.$$
    return
  fi

  if [ -n "$want_grep" ] && ! grep -q -- "$want_grep" /tmp/smoke-body.$$; then
    failed=$((failed+1))
    fails+=("$name: missing pattern '$want_grep' — $url")
    printf "  ${RED}FAIL${OFF}  %-32s %s\n" "$name" "$DIM(pattern missing)$OFF"
    rm -f /tmp/smoke-body.$$
    return
  fi

  passed=$((passed+1))
  printf "  ${GRN}ok${OFF}    %-32s %s\n" "$name" "$DIM$status$OFF"
  rm -f /tmp/smoke-body.$$
}

# check_ct NAME URL  expected-content-type-substring
check_ct() {
  local name="$1" url="$2" want_ct="$3"
  local ct
  ct=$(curl -s -I -m 5 "$BASE$url" 2>/dev/null | awk 'tolower($1) == "content-type:" { sub(/\r/,""); print tolower($2); exit }')
  if echo "$ct" | grep -q -- "$want_ct"; then
    passed=$((passed+1))
    printf "  ${GRN}ok${OFF}    %-32s %s\n" "$name" "$DIM$ct$OFF"
  else
    failed=$((failed+1))
    fails+=("$name: content-type expected to contain '$want_ct', got '$ct' — $url")
    printf "  ${RED}FAIL${OFF}  %-32s %s\n" "$name" "$DIM$ct$OFF"
  fi
}

printf "${DIM}Dylan smoke test → %s${OFF}\n\n" "$BASE"

echo "Server core"
check "stats html"        "/dylan/stats"                200 "## Server Statistics"
check "stats json"        "/dylan/stats?format=json"    200 '"uptime_seconds"'
check "routes html"       "/dylan/routes"               200 "## Registered Routes"
check "routes json"       "/dylan/routes?format=json"   200 '"plugins"'
check "test by query"     "/dylan/test?path=/g/test"    200 "## Route Tester"
check "test by suffix"    "/dylan/test/foo/bar"         200 "/foo/bar"
check "slow short"        "/dylan/slow/100"             200 "slept 100ms"
check "dashboard redir"   "/dylan"                      302
# /reload bleibt absichtlich ungetestet — der GET würde den Server runterfahren.
# Statt das Endpoint anzufassen prüfen wir nur dass das Plugin registriert ist:
check "reload registered" "/dylan/routes"               200 "ReloadPlugin"

echo
echo "Static assets + content types"
check_ct "stats text"     "/dylan/stats"                "text/plain"
check_ct "stats json ct"  "/dylan/stats?format=json"    "application/json"

echo
echo "ManageStage"
check    "manage page"    "/manage"                     200 "Dylan Maintenance"
check    "manage assets"  "/manage/assets/style.css"    200
check    "manage js"      "/manage/assets/app.js"       200
check    "manage agents"  "/manage/agents/status"       200 "{"
check_ct "manage css"     "/manage/assets/style.css"    "text/css"
check_ct "manage js ct"   "/manage/assets/app.js"       "javascript"

echo
echo "Monitor"
check    "monitor md"     "/monitor"                    200 "## Hosts"
check_ct "monitor ct"     "/monitor"                    "text/plain"

# Private endpoints — werden gemeldet wenn nicht 200, aber nicht als Fehler
echo
echo "${DIM}Optional (deine privaten Plugins; werden geskippt wenn nicht da)${OFF}"
for ep in /stage /whoami /widget; do
  st=$(curl -s -o /dev/null -w "%{http_code}" -m 3 "$BASE$ep" 2>/dev/null)
  [ -z "$st" ] && st=000
  if [ "$st" = "200" ] || [ "$st" = "400" ]; then
    printf "  ${GRN}ok${OFF}    %-32s %s\n" "$ep" "$DIM$st$OFF"
  else
    printf "  ${DIM}skip  %-32s %s${OFF}\n"   "$ep" "$st"
  fi
done

echo
total=$((passed + failed))
if [ "$failed" -eq 0 ]; then
  printf "${GRN}%d/%d passed${OFF}\n" "$passed" "$total"
  exit 0
else
  printf "${RED}%d/%d failed${OFF}\n\n" "$failed" "$total"
  for f in "${fails[@]}"; do echo "  · $f"; done
  exit "$failed"
fi
