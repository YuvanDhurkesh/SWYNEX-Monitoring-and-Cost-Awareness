#!/usr/bin/env bash
# Add monitoring, alerts and cost guardrails to the Task 2 CloudNotes Lite deployment.
#
#   1. SNS topic + email subscription for alerts                         (us-east-1)
#   2. CloudWatch alarms on CloudFront error rates and request volume    (us-east-1)
#   3. AWS Budget: monthly cost limit with email alerts at 50% / 100% / forecast 100%
#   4. CloudFront access logs to a private S3 bucket that deletes logs after 30 days
#   5. Lifecycle rule that expires old object versions in the site bucket
#
# Usage:   ./scripts/setup-monitoring.sh <alert-email>
# Needs:   AWS CLI v2 with permission for SNS, CloudWatch, Budgets, S3 and CloudFront.
# Writes:  .monitoring-state (read by the other scripts; not committed).
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

ALERT_EMAIL="${1:-}"
if [[ ! "$ALERT_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
  echo "Usage: $0 <alert-email>" >&2
  exit 1
fi
if [[ -f "$STATE_FILE" ]]; then
  echo "Monitoring is already set up ($STATE_FILE). Run ./scripts/teardown-monitoring.sh first." >&2
  exit 1
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
RUNBOOK="https://github.com/YuvanDhurkesh/SWYNEX-Monitoring-and-Cost-Awareness/blob/main/docs/alerts.md"

# Record each resource as soon as it exists, so teardown can clean up after a partial run.
save() { echo "$1=$2" >>"$STATE_FILE"; }
save ALERT_EMAIL "$ALERT_EMAIL"

echo "[1/5] Creating SNS topic for alerts in $METRICS_REGION"
TOPIC_ARN="$(aws sns create-topic --region "$METRICS_REGION" --name "${ALARM_PREFIX}-alerts" \
  --tags "${TAG_ARGS[@]}" --query TopicArn --output text)"
save TOPIC_ARN "$TOPIC_ARN"
aws sns subscribe --region "$METRICS_REGION" --topic-arn "$TOPIC_ARN" \
  --protocol email --notification-endpoint "$ALERT_EMAIL" >/dev/null
echo "      $TOPIC_ARN"
echo "      Subscription email sent to $ALERT_EMAIL (click the link in it to start receiving alerts)"

echo "[2/5] Creating CloudWatch alarms on CloudFront metrics"
put_alarm() {  # put_alarm NAME METRIC STATISTIC THRESHOLD PERIODS DESCRIPTION
  aws cloudwatch put-metric-alarm --region "$METRICS_REGION" \
    --alarm-name "$1" \
    --alarm-description "$6 Runbook: $RUNBOOK" \
    --namespace AWS/CloudFront --metric-name "$2" \
    --dimensions "Name=DistributionId,Value=$DIST_ID" "Name=Region,Value=Global" \
    --statistic "$3" --period 300 \
    --evaluation-periods "$5" --datapoints-to-alarm "$5" \
    --threshold "$4" --comparison-operator GreaterThanThreshold \
    --treat-missing-data notBreaching \
    --alarm-actions "$TOPIC_ARN" --ok-actions "$TOPIC_ARN" \
    --tags "${TAG_ARGS[@]}"
  echo "      $1: $2 ($3) > $4 for $5 x 5 min"
}
put_alarm "${ALARM_PREFIX}-5xx-error-rate" 5xxErrorRate Average 5 2 \
  "CloudNotes Lite: more than 5% of requests are failing with 5xx errors (CloudFront or S3 cannot serve the site)."
put_alarm "${ALARM_PREFIX}-4xx-error-rate" 4xxErrorRate Average 30 3 \
  "CloudNotes Lite: more than 30% of requests return 4xx (broken links after a deploy, or a bot scanning for files)."
put_alarm "${ALARM_PREFIX}-request-spike" Requests Sum 1000 3 \
  "CloudNotes Lite: over 1,000 requests per 5 minutes for 15 minutes. Sustained, this passes the CloudFront free tier of 10 million requests a month."
save ALARMS "${ALARM_PREFIX}-5xx-error-rate,${ALARM_PREFIX}-4xx-error-rate,${ALARM_PREFIX}-request-spike"

echo "[3/5] Creating AWS Budget ($BUDGET_NAME, USD $MONTHLY_BUDGET_USD per month)"
cat >.build/budget.json <<JSON
{
  "BudgetName": "$BUDGET_NAME",
  "BudgetLimit": { "Amount": "$MONTHLY_BUDGET_USD", "Unit": "USD" },
  "TimeUnit": "MONTHLY",
  "BudgetType": "COST"
}
JSON
notification() {  # notification TYPE PERCENT
  printf '{"Notification":{"NotificationType":"%s","ComparisonOperator":"GREATER_THAN","Threshold":%s,"ThresholdType":"PERCENTAGE"},"Subscribers":[{"SubscriptionType":"EMAIL","Address":"%s"}]}' \
    "$1" "$2" "$ALERT_EMAIL"
}
echo "[$(notification ACTUAL 50),$(notification ACTUAL 100),$(notification FORECASTED 100)]" \
  >.build/budget-notifications.json
aws budgets create-budget --account-id "$ACCOUNT_ID" \
  --budget file://.build/budget.json \
  --notifications-with-subscribers file://.build/budget-notifications.json
save BUDGET_CREATED yes
echo "      Emails at 50% and 100% of actual spend, and when the month's forecast passes 100%"

echo "[4/5] Turning on CloudFront access logs (bucket $LOG_BUCKET, kept $LOG_RETENTION_DAYS days)"
aws s3api create-bucket --bucket "$LOG_BUCKET" --region "$REGION" \
  --create-bucket-configuration "LocationConstraint=$REGION" \
  --object-ownership BucketOwnerPreferred >/dev/null
save LOG_BUCKET_CREATED yes
# CloudFront standard logging writes through a bucket ACL, so ACLs stay enabled (BucketOwnerPreferred),
# but every form of public access is still blocked.
aws s3api put-public-access-block --bucket "$LOG_BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
aws s3api put-bucket-encryption --bucket "$LOG_BUCKET" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
aws s3api put-bucket-lifecycle-configuration --bucket "$LOG_BUCKET" --lifecycle-configuration \
  "{\"Rules\":[{\"ID\":\"expire-access-logs\",\"Status\":\"Enabled\",\"Filter\":{\"Prefix\":\"\"},\"Expiration\":{\"Days\":$LOG_RETENTION_DAYS},\"AbortIncompleteMultipartUpload\":{\"DaysAfterInitiation\":1}}]}" >/dev/null
aws s3api put-bucket-tagging --bucket "$LOG_BUCKET" \
  --tagging "TagSet=[{Key=Project,Value=$PROJECT_TAG},{Key=Owner,Value=$OWNER_TAG}]"
echo "      Updating the distribution and waiting for it to deploy (a few minutes)"
set_cloudfront_logging true "$LOG_BUCKET" "$LOG_PREFIX"
save LOGGING_ENABLED yes

echo "[5/5] Expiring old object versions in the site bucket after $OLD_VERSION_RETENTION_DAYS days"
# Versioning keeps a copy of every file on every deploy. Keep the 3 newest old copies for
# rollback, and delete anything older than the retention period.
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration \
  "{\"Rules\":[{\"ID\":\"expire-old-versions\",\"Status\":\"Enabled\",\"Filter\":{\"Prefix\":\"\"},\"NoncurrentVersionExpiration\":{\"NoncurrentDays\":$OLD_VERSION_RETENTION_DAYS,\"NewerNoncurrentVersions\":3},\"AbortIncompleteMultipartUpload\":{\"DaysAfterInitiation\":1}}]}" >/dev/null
save SITE_LIFECYCLE_SET yes

echo
echo "Monitoring is set up. Next:"
echo "  1. Confirm the SNS subscription from the email sent to $ALERT_EMAIL"
echo "  2. ./scripts/checklist.sh   to review cost and access control"
echo "  3. ./scripts/metrics.sh     to see CloudFront traffic and errors"
echo "  4. ./scripts/log-report.sh  once access logs arrive (within about an hour)"
