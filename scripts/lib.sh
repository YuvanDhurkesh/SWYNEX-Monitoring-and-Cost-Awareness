# Helpers shared by the scripts in this folder. Source it; do not run it.

# Git Bash on Windows rewrites arguments that start with "/" into Windows paths.
export MSYS_NO_PATHCONV=1

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
# shellcheck disable=SC1091
source monitoring.conf
STATE_FILE=".monitoring-state"
mkdir -p .build

# On Windows the AWS CLI ends lines with CRLF, which breaks string comparisons in Bash.
# This wrapper strips the carriage returns and keeps the CLI's exit status.
set -o pipefail
aws() { command aws "$@" | tr -d '\r'; }

# Arguments for "aws ... --tags" on services that take Key=,Value= pairs.
TAG_ARGS=("Key=Project,Value=$PROJECT_TAG" "Key=Owner,Value=$OWNER_TAG")

# A working Python 3, used only to edit the CloudFront distribution JSON.
# (On Windows, "python3" can be a Microsoft Store stub that does nothing.)
find_python() {
  local candidate
  for candidate in python3 python py; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import json' >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  echo "Python 3 is required to edit the distribution config." >&2
  return 1
}

# Turn CloudFront standard (access) logging on or off.
#   set_cloudfront_logging true  <bucket> <prefix>
#   set_cloudfront_logging false
set_cloudfront_logging() {
  local enabled="$1" bucket_domain="" prefix="${3:-}" py etag
  [[ "$enabled" == "true" ]] && bucket_domain="$2.s3.amazonaws.com"
  py="$(find_python)" || return 1

  etag="$(aws cloudfront get-distribution-config --id "$DIST_ID" --query ETag --output text)"
  aws cloudfront get-distribution-config --id "$DIST_ID" --query DistributionConfig --output json \
    >.build/distribution-config.json

  "$py" - .build/distribution-config.json "$enabled" "$bucket_domain" "$prefix" <<'PY'
import json, sys
path, enabled, bucket, prefix = sys.argv[1:5]
with open(path) as f:
    config = json.load(f)
config["Logging"] = {
    "Enabled": enabled == "true",
    "IncludeCookies": False,
    "Bucket": bucket,
    "Prefix": prefix,
}
with open(path, "w") as f:
    json.dump(config, f, indent=2)
PY

  aws cloudfront update-distribution --id "$DIST_ID" --if-match "$etag" \
    --distribution-config file://.build/distribution-config.json >/dev/null
  aws cloudfront wait distribution-deployed --id "$DIST_ID"
}
