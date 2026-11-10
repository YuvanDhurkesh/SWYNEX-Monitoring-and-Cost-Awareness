#!/usr/bin/env bash
# Traffic and error metrics for the distribution from CloudWatch, plus the state of each alarm.
# CloudFront publishes these metrics for free; they appear a few minutes after the requests.
#
# Usage:   ./scripts/metrics.sh [HOURS]      (default: the last 24 hours, in 1-hour buckets)
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

HOURS="${1:-24}"
[[ "$HOURS" =~ ^[0-9]+$ ]] && ((HOURS >= 1 && HOURS <= 360)) || { echo "HOURS must be 1-360" >&2; exit 1; }
START="$(date -u -d "$HOURS hours ago" +%Y-%m-%dT%H:00:00Z)"
END="$(date -u +%Y-%m-%dT%H:%M:00Z)"

metric() {  # metric NAME STATISTIC  ->  "YYYY-MM-DDTHH value" lines in UTC, one per hour
  aws cloudwatch get-metric-statistics --region "$METRICS_REGION" \
    --namespace AWS/CloudFront --metric-name "$1" \
    --dimensions "Name=DistributionId,Value=$DIST_ID" "Name=Region,Value=Global" \
    --start-time "$START" --end-time "$END" --period 3600 --statistics "$2" \
    --query "Datapoints[].[Timestamp,$2]" --output text |
    # The CLI prints timestamps in the local time zone; convert them to UTC.
    while read -r timestamp value; do
      echo "$(date -u -d "$timestamp" +%Y-%m-%dT%H) $value"
    done
}

metric Requests Sum >.build/m-requests.txt
metric BytesDownloaded Sum >.build/m-bytes.txt
metric 4xxErrorRate Average >.build/m-4xx.txt
metric 5xxErrorRate Average >.build/m-5xx.txt

echo "CloudFront metrics for $DIST_ID ($SITE_DOMAIN)"
echo "From $START to $END"
echo

# Join the four series by hour. Error counts are estimated as requests x error rate.
awk '
  FNR == 1 { file++ }
  { hour = substr($1, 1, 13); value[file, hour] = $2; hours[hour] = 1 }
  END {
    n = 0
    for (h in hours) order[++n] = h
    for (i = 2; i <= n; i++) { k = order[i]; for (j = i - 1; j > 0 && order[j] > k; j--) order[j + 1] = order[j]; order[j + 1] = k }
    max = 0
    for (i = 1; i <= n; i++) if (value[1, order[i]] > max) max = value[1, order[i]]
    printf "  %-16s %8s %6s %6s  %s\n", "Hour (UTC)", "Requests", "4xx", "5xx", ""
    for (i = 1; i <= n; i++) {
      h = order[i]; r = value[1, h] + 0
      e4 = r * value[3, h] / 100; e5 = r * value[4, h] / 100
      bar = ""; width = (max > 0) ? int(r / max * 30 + 0.5) : 0
      for (b = 0; b < width; b++) bar = bar "#"
      printf "  %-16s %8d %6d %6d  %s\n", substr(h, 1, 10) " " substr(h, 12, 2) ":00", r, e4 + 0.5, e5 + 0.5, bar
      total += r; bytes += value[2, h]; t4 += e4; t5 += e5
    }
    if (n == 0) { print "  No requests in this period."; exit }
    print ""
    printf "  Total requests          %d\n", total
    printf "  Data sent to viewers    %.1f KB\n", bytes / 1024
    printf "  4xx error rate          %.1f%%\n", (total ? t4 / total * 100 : 0)
    printf "  5xx error rate          %.1f%%\n", (total ? t5 / total * 100 : 0)
  }
' .build/m-requests.txt .build/m-bytes.txt .build/m-4xx.txt .build/m-5xx.txt

echo
echo "Alarms ($METRICS_REGION)"
aws cloudwatch describe-alarms --region "$METRICS_REGION" --alarm-name-prefix "${ALARM_PREFIX}-" \
  --query 'MetricAlarms[].[AlarmName,StateValue,MetricName,ComparisonOperator,Threshold]' --output text |
  awk -F'\t' '{ op = ($4 ~ /Greater/) ? ">" : "<"; printf "  %-28s %-17s %s %s %s\n", $1, $2, $3, op, $5 + 0 }'
