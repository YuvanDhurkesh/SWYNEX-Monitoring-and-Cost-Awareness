#!/usr/bin/env bash
# Summarise CloudFront access logs: who requested what, what failed, and how well the cache works.
# CloudFront delivers log files to the log bucket within about an hour of the requests.
#
# Usage:   ./scripts/log-report.sh [HOURS]      (default: the last 24 hours)
# Note:    client IP addresses are counted but never printed.
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

HOURS="${1:-24}"
[[ "$HOURS" =~ ^[0-9]+$ ]] || { echo "HOURS must be a whole number" >&2; exit 1; }
SINCE="$(date -u -d "$HOURS hours ago" '+%Y-%m-%d %H:%M:%S')"
LOG_DIR=".build/logs"
mkdir -p "$LOG_DIR"

echo "Downloading access logs from s3://$LOG_BUCKET/$LOG_PREFIX"
aws s3 sync "s3://$LOG_BUCKET/$LOG_PREFIX" "$LOG_DIR/" --only-show-errors

shopt -s nullglob
files=("$LOG_DIR"/*.gz)
if ((${#files[@]} == 0)); then
  echo "No log files yet. CloudFront delivers them within about an hour of the first requests."
  exit 0
fi

# Standard log fields used here (tab separated):
#  1 date  2 time  3 x-edge-location  4 sc-bytes  5 c-ip  6 cs-method  8 cs-uri-stem  9 sc-status
#  14 x-edge-result-type  19 time-taken (s)  24 cs-protocol-version
gzip -dc "${files[@]}" | awk -F'\t' -v since="$SINCE" '!/^#/ && ($1 " " $2) >= since' >.build/requests.tsv
total="$(wc -l <.build/requests.tsv | tr -d ' ')"

echo
echo "Access log report: last $HOURS hours (since $SINCE UTC), ${#files[@]} log files"
if ((total == 0)); then
  echo "  No requests in this period."
  exit 0
fi

top() {  # top FIELD_EXPRESSION LIMIT [FILTER]  ->  "count  value" lines, largest first
  awk -F'\t' "${3:-1} { print $1 }" .build/requests.tsv | sort | uniq -c | sort -rn | head -"$2" |
    awk '{ count = $1; $1 = ""; printf "    %6d  %s\n", count, substr($0, 2) }'
}

awk -F'\t' '
  { bytes += $4; time += $19; if ($19 > slowest) slowest = $19; ips[$5] = 1; pops[substr($3, 1, 3)] = 1
    if ($14 == "Hit" || $14 == "RefreshHit") hits++ }
  END {
    for (ip in ips) visitors++
    for (p in pops) locations++
    printf "  Requests                 %d\n", NR
    printf "  Distinct client IPs      %d\n", visitors
    printf "  Edge location cities     %d\n", locations
    printf "  Data sent                %.1f KB\n", bytes / 1024
    printf "  Cache hit ratio          %.0f%% (Hit + RefreshHit)\n", hits / NR * 100
    printf "  Average time taken       %.0f ms (slowest %.0f ms)\n", time / NR * 1000, slowest * 1000
  }' .build/requests.tsv

echo
echo "  Status codes"
top '$9' 10
echo
echo "  Edge result (cache)"
top '$14' 10
echo
echo "  Most requested paths"
top '$8' 6
echo
echo "  Paths that returned 4xx (broken links or scanners)"
top '$8 "  (" $9 ")"' 8 '$9 ~ /^4/'
echo
echo "  Edge locations (first 3 letters are the nearest airport code)"
top '$3' 6
echo
echo "  HTTP versions"
top '$24' 5
