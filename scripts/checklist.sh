#!/usr/bin/env bash
# Automated cost and access-control checklist for the deployment. Read-only: it changes nothing.
# Uses only free APIs (IAM, S3, CloudFront, CloudWatch, Budgets, Free Tier). It does not call
# the Cost Explorer API, which charges for each request.
#
# Usage:   ./scripts/checklist.sh
# Exit:    0 when nothing FAILs (WARN lines are recommendations), 1 otherwise.
set -uo pipefail
# shellcheck disable=SC1091
source "$(dirname "$0")/lib.sh"

KEY_MAX_AGE_DAYS=90
pass=0 warn=0 fail=0

line() {  # line LEVEL NAME DETAIL
  local colour="" reset=""
  if [[ -t 1 ]]; then
    reset=$'\e[0m'
    case "$1" in PASS) colour=$'\e[32m' ;; WARN) colour=$'\e[33m' ;; FAIL) colour=$'\e[31m' ;; esac
  fi
  printf '  %s%-4s%s  %-48s %s\n' "$colour" "$1" "$reset" "$2" "$3"
  case "$1" in PASS) pass=$((pass + 1)) ;; WARN) warn=$((warn + 1)) ;; FAIL) fail=$((fail + 1)) ;; esac
}
check() {  # check CONDITION_RESULT NAME PASS_DETAIL FAIL_LEVEL FAIL_DETAIL
  if [[ "$1" == "yes" ]]; then line PASS "$2" "$3"; else line "$4" "$2" "$5"; fi
}
is() { [[ "$1" == "$2" ]] && echo yes || echo no; }
days_since() { echo $((($(date +%s) - $(date -d "$1" +%s)) / 86400)); }

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
echo "Cost and access-control checklist for $SITE_DOMAIN ($(date -u '+%Y-%m-%d %H:%M UTC'))"

# ---------------------------------------------------------------- Access control
echo
echo "Access control: account"
read -r root_mfa root_keys < <(aws iam get-account-summary \
  --query 'SummaryMap.[AccountMFAEnabled,AccountAccessKeysPresent]' --output text)
check "$(is "$root_mfa" 1)" "Root user has MFA" "enabled" FAIL "not enabled"
check "$(is "$root_keys" 0)" "Root user has no access keys" "none" FAIL "root access keys exist: delete them"

for user in $(aws iam list-users --query 'Users[].UserName' --output text); do
  console=no
  aws iam get-login-profile --user-name "$user" >/dev/null 2>&1 && console=yes
  mfa="$(aws iam list-mfa-devices --user-name "$user" --query 'length(MFADevices)' --output text)"
  if [[ "$console" == "yes" ]]; then
    check "$( ((mfa > 0)) && echo yes || echo no)" "IAM user $user: console sign-in has MFA" "enabled" FAIL "console password without MFA"
  fi

  admin_policies="$(aws iam list-attached-user-policies --user-name "$user" \
    --query "AttachedPolicies[?PolicyName=='AdministratorAccess'].PolicyName" --output text)"
  for group in $(aws iam list-groups-for-user --user-name "$user" --query 'Groups[].GroupName' --output text); do
    admin_policies+="$(aws iam list-attached-group-policies --group-name "$group" \
      --query "AttachedPolicies[?PolicyName=='AdministratorAccess'].PolicyName" --output text)"
  done
  check "$(is "$admin_policies" "")" "IAM user $user: least privilege" "no AdministratorAccess" \
    WARN "has AdministratorAccess; use a scoped policy for day-to-day work"

  while read -r key_id created; do
    [[ -z "$key_id" ]] && continue
    age="$(days_since "$created")"
    last_used="$(aws iam get-access-key-last-used --access-key-id "$key_id" \
      --query 'AccessKeyLastUsed.LastUsedDate' --output text)"
    used="never used"
    [[ "$last_used" != "None" ]] && used="last used $(days_since "$last_used") days ago"
    check "$( ((age <= KEY_MAX_AGE_DAYS)) && echo yes || echo no)" \
      "IAM user $user: access key age" "$age days, $used" \
      WARN "$age days old (rotate after $KEY_MAX_AGE_DAYS), $used"
  done < <(aws iam list-access-keys --user-name "$user" \
    --query 'AccessKeyMetadata[?Status==`Active`].[AccessKeyId,CreateDate]' --output text)
done

trails="$(aws cloudtrail describe-trails --query 'length(trailList)' --output text)"
check "$( ((trails > 0)) && echo yes || echo no)" "CloudTrail trail records API activity" "$trails trail(s)" \
  WARN "no trail; only the free 90-day Event history is kept"

echo
echo "Access control: deployment"
block="$(aws s3api get-public-access-block --bucket "$BUCKET" \
  --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
  --output text | tr -s '\t' ' ')"
check "$(is "$block" "True True True True")" "Site bucket blocks all public access" "all 4 settings on" FAIL "$block"

policy="$(aws s3api get-bucket-policy --bucket "$BUCKET" --query Policy --output text 2>/dev/null)"
scoped=no
[[ "$policy" == *'"Service":"cloudfront.amazonaws.com"'* && "$policy" == *"distribution/$DIST_ID"* &&
  "$policy" == *'"Action":"s3:GetObject"'* && "$policy" != *'"Principal":"*"'* ]] && scoped=yes
check "$scoped" "Bucket policy: only this distribution can read" "s3:GetObject for $DIST_ID only" \
  FAIL "policy is broader than one distribution"

direct="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "https://$BUCKET.s3.$REGION.amazonaws.com/index.html")"
check "$(is "$direct" 403)" "Direct S3 request is denied" "403" FAIL "got $direct"

read -r viewer_policy methods < <(aws cloudfront get-distribution-config --id "$DIST_ID" \
  --query 'DistributionConfig.DefaultCacheBehavior.[ViewerProtocolPolicy,join(`,`,AllowedMethods.Items)]' --output text)
check "$( [[ "$viewer_policy" == "redirect-to-https" || "$viewer_policy" == "https-only" ]] && echo yes || echo no)" \
  "Viewers must use HTTPS" "$viewer_policy" FAIL "$viewer_policy"
check "$(is "$methods" "HEAD,GET")" "Only read methods allowed" "GET, HEAD" WARN "$methods"

sse="$(aws s3api get-bucket-encryption --bucket "$BUCKET" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text)"
check "$( [[ "$sse" == "AES256" || "$sse" == aws:kms* ]] && echo yes || echo no)" "Site files encrypted at rest" "$sse" FAIL "none"

if aws s3api head-bucket --bucket "$LOG_BUCKET" >/dev/null 2>&1; then
  log_block="$(aws s3api get-public-access-block --bucket "$LOG_BUCKET" \
    --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
    --output text | tr -s '\t' ' ')"
  check "$(is "$log_block" "True True True True")" "Log bucket blocks all public access" "all 4 settings on" FAIL "$log_block"
fi

# ---------------------------------------------------------------- Cost
echo
echo "Cost"
budget="$(aws budgets describe-budgets --account-id "$ACCOUNT_ID" \
  --query "Budgets[?BudgetName=='$BUDGET_NAME'] | [0].[BudgetLimit.Amount,CalculatedSpend.ActualSpend.Amount,CalculatedSpend.ForecastedSpend.Amount]" \
  --output text 2>/dev/null)"
if [[ -n "$budget" && "$budget" != "None" ]]; then
  read -r limit actual forecast <<<"$budget"
  detail="$(printf 'limit $%.2f, spent $%.2f, forecast $%.2f' "$limit" "${actual/None/0}" "${forecast/None/0}")"
  alerts="$(aws budgets describe-notifications-for-budget --account-id "$ACCOUNT_ID" --budget-name "$BUDGET_NAME" \
    --query 'length(Notifications)' --output text)"
  line PASS "Monthly budget with $alerts email alerts" "$detail"
  over="$(awk -v a="${actual/None/0}" -v l="$limit" 'BEGIN { print (a > l) ? "yes" : "no" }')"
  check "$(is "$over" no)" "Spend this month is within the budget" "yes" WARN "over budget: check the Billing console"
  over="$(awk -v f="${forecast/None/0}" -v l="$limit" 'BEGIN { print (f > l) ? "yes" : "no" }')"
  check "$(is "$over" no)" "Forecast for the month is within the budget" "yes" \
    WARN "forecast is above the limit: check Billing > Bills for the services involved"
else
  line FAIL "Monthly budget with email alerts" "none: run setup-monitoring.sh"
fi

anomaly="$(aws ce get-anomaly-subscriptions --query 'length(AnomalySubscriptions)' --output text 2>/dev/null)"
check "$( ((${anomaly:-0} > 0)) && echo yes || echo no)" "Cost Anomaly Detection alerts" "$anomaly subscription(s)" \
  WARN "none: turn on Cost Anomaly Detection (free)"

alarm_count=0
for r in "$METRICS_REGION" "$REGION"; do
  alarm_count=$((alarm_count + $(aws cloudwatch describe-alarms --region "$r" --query 'length(MetricAlarms)' --output text)))
done
check "$( ((alarm_count <= 10)) && echo yes || echo no)" "CloudWatch alarms within the free 10" "$alarm_count in use" \
  WARN "$alarm_count alarms; each one over 10 costs USD 0.10 a month"

if [[ -f "$STATE_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  pending="$(aws sns list-subscriptions-by-topic --region "$METRICS_REGION" --topic-arn "$TOPIC_ARN" \
    --query "length(Subscriptions[?SubscriptionArn=='PendingConfirmation'])" --output text)"
  check "$(is "$pending" 0)" "Alert email subscription confirmed" "confirmed" WARN "pending: click the link in the AWS email"
fi

log_expiry="$(aws s3api get-bucket-lifecycle-configuration --bucket "$LOG_BUCKET" \
  --query 'Rules[?Status==`Enabled`] | [0].Expiration.Days' --output text 2>/dev/null)"
check "$( [[ "$log_expiry" =~ ^[0-9]+$ ]] && echo yes || echo no)" "Access logs expire automatically" "after $log_expiry days" \
  WARN "no expiry rule: logs grow forever"

version_expiry="$(aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --query 'Rules[?Status==`Enabled`] | [0].NoncurrentVersionExpiration.NoncurrentDays' --output text 2>/dev/null)"
check "$( [[ "$version_expiry" =~ ^[0-9]+$ ]] && echo yes || echo no)" "Old file versions expire automatically" \
  "after $version_expiry days (3 newest kept)" WARN "versioning keeps every old copy forever"

price_class="$(aws cloudfront get-distribution-config --id "$DIST_ID" --query 'DistributionConfig.PriceClass' --output text)"
check "$( [[ "$price_class" != "PriceClass_All" ]] && echo yes || echo no)" "CloudFront price class limited" "$price_class" \
  WARN "PriceClass_All uses the most expensive edge locations"

tagged="$(aws cloudfront list-tags-for-resource --resource "arn:aws:cloudfront::$ACCOUNT_ID:distribution/$DIST_ID" \
  --query "Tags.Items[?Key=='Project'].Value" --output text)"
check "$(is "$tagged" "$PROJECT_TAG")" "Resources tagged for cost tracking" "Project=$tagged" WARN "no Project tag"

# Free Tier usage for the services this site uses, month to date
while IFS=$'\t' read -r service usage_type used limit unit; do
  [[ -z "$service" ]] && continue
  pct="$(awk -v u="$used" -v l="$limit" 'BEGIN { printf "%.3f", (l > 0) ? u / l * 100 : 0 }')"
  ok="$(awk -v p="$pct" 'BEGIN { print (p < 80) ? "yes" : "no" }')"
  check "$ok" "Free tier: ${service#Amazon } $usage_type" "$(printf '%s%% used (%g of %g %s)' "$pct" "$used" "$limit" "$unit")" \
    WARN "$pct% of the free allowance used this month"
done < <(aws freetier get-free-tier-usage --region us-east-1 \
  --query 'freeTierUsages[?service==`Amazon CloudFront` && (usageType==`DataTransfer-Out-Bytes` || usageType==`Requests-Tier1`)].[service,usageType,actualUsageAmount,limit,unit]' \
  --output text 2>/dev/null)

echo
echo "$pass passed, $warn warnings, $fail failed"
((fail == 0))
