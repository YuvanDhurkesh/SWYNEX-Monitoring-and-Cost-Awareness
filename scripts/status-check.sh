#!/usr/bin/env bash
# Health check for the live CloudNotes Lite site, as seen by a visitor.
# Needs only curl and openssl (no AWS credentials), so it also runs in GitHub Actions.
#
# Usage:   ./scripts/status-check.sh [--log FILE]
#            --log FILE   also append one CSV line with the result to FILE
# Exit:    0 when nothing FAILs (WARN and INFO lines are allowed), 1 otherwise.
set -uo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

LOG_FILE=""
[[ "${1:-}" == "--log" ]] && LOG_FILE="${2:?--log needs a file name}"

URL="https://$SITE_DOMAIN"
TIMEOUT_S=10          # FAIL if the site does not answer in this time
SLOW_MS=1500          # WARN if the home page takes longer than this
CERT_WARN_DAYS=30     # WARN if the TLS certificate expires sooner than this

ok=0 warn=0 fail=0
summary_rows=()

report() {  # report LEVEL NAME DETAIL
  local level="$1" name="$2" detail="$3" colour="" reset=""
  if [[ -t 1 ]]; then
    reset=$'\e[0m'
    case "$level" in OK) colour=$'\e[32m' ;; WARN) colour=$'\e[33m' ;; FAIL) colour=$'\e[31m' ;; INFO) colour=$'\e[36m' ;; esac
  fi
  printf '  %s%-4s%s  %-38s %s\n' "$colour" "$level" "$reset" "$name" "$detail"
  case "$level" in OK) ok=$((ok + 1)) ;; WARN) warn=$((warn + 1)) ;; FAIL) fail=$((fail + 1)) ;; esac
  summary_rows+=("| $level | $name | $detail |")
}

status() { curl -s -o /dev/null -m "$TIMEOUT_S" -w '%{http_code}' "$@"; }

echo "Status check for $URL at $(date -u '+%Y-%m-%d %H:%M UTC')"

# 1. Availability and response time of the home page
read -r code seconds < <(curl -s -o /dev/null -m "$TIMEOUT_S" -w '%{http_code} %{time_total}' "$URL/")
ms="$(awk -v t="$seconds" 'BEGIN { printf "%d", t * 1000 }')"
if [[ "$code" == "200" ]]; then
  report OK "Home page is up" "HTTP 200"
else
  report FAIL "Home page is up" "HTTP $code (000 means no answer within ${TIMEOUT_S}s)"
fi
if ((ms > SLOW_MS)); then
  report WARN "Response time" "$ms ms (limit $SLOW_MS ms)"
else
  report OK "Response time" "$ms ms"
fi

# 2. The page's assets load
for asset in styles.css app.js build.js; do
  asset_code="$(status "$URL/$asset")"
  [[ "$asset_code" == "200" ]] || { report FAIL "Asset /$asset" "HTTP $asset_code"; continue; }
  assets_ok="${assets_ok:-}${assets_ok:+, }$asset"
done
[[ -n "${assets_ok:-}" ]] && report OK "Static assets load" "$assets_ok"

# 3. Security and routing behaviour from Task 2 still holds
headers="$(curl -sI -m "$TIMEOUT_S" "$URL/" | tr -d '\r')"
header() { grep -i "^$1:" <<<"$headers" | head -1 | cut -d' ' -f2-; }

redirect="$(status "http://$SITE_DOMAIN/")"
[[ "$redirect" == "301" ]] && report OK "HTTP redirects to HTTPS" "301" || report FAIL "HTTP redirects to HTTPS" "got $redirect"

hsts="$(header strict-transport-security)"
[[ -n "$hsts" ]] && report OK "HSTS header" "$hsts" || report FAIL "HSTS header" "missing"

missing="$(status "$URL/status-check-missing-page")"
[[ "$missing" == "404" ]] && report OK "Missing page returns 404" "404" || report WARN "Missing page returns 404" "got $missing"

direct="$(status "https://$BUCKET.s3.$REGION.amazonaws.com/index.html")"
[[ "$direct" == "403" ]] && report OK "Direct S3 access is blocked" "403" || report FAIL "Direct S3 access is blocked" "got $direct: bucket may be public"

# 4. TLS certificate expiry (CloudFront renews *.cloudfront.net, but a custom domain would not be automatic)
cert_end="$(echo | timeout 10 openssl s_client -connect "$SITE_DOMAIN:443" -servername "$SITE_DOMAIN" 2>/dev/null |
  openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
if [[ -n "$cert_end" ]]; then
  days_left=$((($(date -d "$cert_end" +%s) - $(date +%s)) / 86400))
  if ((days_left < CERT_WARN_DAYS)); then
    report WARN "TLS certificate" "expires in $days_left days"
  else
    report OK "TLS certificate" "valid for $days_left more days"
  fi
else
  report WARN "TLS certificate" "could not read the certificate"
fi

# 5. Information that helps when something does go wrong
x_cache="$(header x-cache)"
pop="$(header x-amz-cf-pop)"
build="$(curl -s -m "$TIMEOUT_S" "$URL/build.js" | grep -o 'version: "[^"]*"' | cut -d'"' -f2)"
report INFO "Edge cache result" "${x_cache:-unknown} (edge location ${pop:-unknown})"
report INFO "Deployed build" "${build:-unknown}"

echo
echo "$ok OK, $warn WARN, $fail FAIL"

result="OK"
((warn > 0)) && result="WARN"
((fail > 0)) && result="FAIL"

if [[ -n "$LOG_FILE" ]]; then
  [[ -f "$LOG_FILE" ]] || echo "utc_time,result,http_code,response_ms,x_cache,edge_location,build" >"$LOG_FILE"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ),$result,$code,$ms,${x_cache:-},${pop:-},${build:-}" >>"$LOG_FILE"
fi

# In GitHub Actions, show the results as a table on the run's summary page.
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Status check: $result"
    echo
    echo "Checked \`$URL\` at $(date -u '+%Y-%m-%d %H:%M UTC')"
    echo
    echo "| Result | Check | Detail |"
    echo "|---|---|---|"
    printf '%s\n' "${summary_rows[@]}"
  } >>"$GITHUB_STEP_SUMMARY"
fi

((fail == 0))
