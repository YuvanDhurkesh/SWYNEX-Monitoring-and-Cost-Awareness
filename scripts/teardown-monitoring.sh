#!/usr/bin/env bash
# Remove everything setup-monitoring.sh created. The Task 2 site itself is not touched.
#
# Usage:   ./scripts/teardown-monitoring.sh
set -uo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

[[ -f "$STATE_FILE" ]] || { echo "Nothing to remove ($STATE_FILE not found)."; exit 0; }
# shellcheck disable=SC1090
source "$STATE_FILE"

read -r -p "Remove the alarms, alert topic, budget and access logs? Type 'yes': " answer
[[ "$answer" == "yes" ]] || { echo "Cancelled."; exit 1; }

if [[ -n "${ALARMS:-}" ]]; then
  echo "[1/5] Deleting CloudWatch alarms"
  # shellcheck disable=SC2086
  aws cloudwatch delete-alarms --region "$METRICS_REGION" --alarm-names ${ALARMS//,/ }
fi

if [[ -n "${TOPIC_ARN:-}" ]]; then
  echo "[2/5] Deleting SNS topic and its subscriptions"
  aws sns delete-topic --region "$METRICS_REGION" --topic-arn "$TOPIC_ARN"
fi

if [[ "${BUDGET_CREATED:-}" == "yes" ]]; then
  echo "[3/5] Deleting budget $BUDGET_NAME"
  aws budgets delete-budget --budget-name "$BUDGET_NAME" \
    --account-id "$(aws sts get-caller-identity --query Account --output text)"
fi

if [[ "${LOGGING_ENABLED:-}" == "yes" ]]; then
  echo "[4/5] Turning off CloudFront access logs (waits for the distribution to deploy)"
  set_cloudfront_logging false
fi
if [[ "${LOG_BUCKET_CREATED:-}" == "yes" ]]; then
  echo "      Emptying and deleting $LOG_BUCKET"
  aws s3 rm "s3://$LOG_BUCKET" --recursive --only-show-errors
  aws s3api delete-bucket --bucket "$LOG_BUCKET" --region "$REGION"
fi

if [[ "${SITE_LIFECYCLE_SET:-}" == "yes" ]]; then
  echo "[5/5] Removing the old-version lifecycle rule from $BUCKET"
  aws s3api delete-bucket-lifecycle --bucket "$BUCKET" 2>/dev/null || echo "      (site bucket already gone)"
fi

rm -f "$STATE_FILE"
echo "Monitoring removed."
