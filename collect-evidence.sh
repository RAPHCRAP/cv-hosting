#!/usr/bin/env bash
# Collect grading evidence into evidence.txt.
# Usage: ./collect-evidence.sh <bucket> <ec2-address> <lambda-address>
#   e.g. ./collect-evidence.sh cv-23l-3063 http://1.2.3.4 https://abc.lambda-url.us-east-1.on.aws
#
# Each section fails soft: if a command errors, the section says so and the script continues.

set -u

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <bucket> <ec2-address> <lambda-address>" >&2
  exit 1
fi

BUCKET="$1"
EC2="${2%/}"
LAMBDA="${3%/}"
OUT="evidence.txt"

# --- names (edit to match your deployment) ---
EC2_ROLE="cv-ec2-role-23l-3063"
EC2_POLICY="cv-ec2-read"
LAMBDA_ROLE="cv-lambda-role-23l-3063"
LAMBDA_POLICY="cv-lambda-read-write"
FUNCTION="cv-func-23l-3063"
LOG_GROUP="/aws/lambda/${FUNCTION}"

sec() { echo "== $1 =="; }
run() { "$@" 2>&1 || echo "(command failed: $*)"; }

{
  sec caller
  run aws sts get-caller-identity

  echo
  sec public-access
  run aws s3api get-public-access-block --bucket "$BUCKET"

  echo
  sec versioning
  run aws s3api get-bucket-versioning --bucket "$BUCKET"

  echo
  sec objects
  run aws s3 ls "s3://${BUCKET}/tenants/" --recursive --human-readable

  echo
  sec ec2-policy
  run aws iam get-role-policy --role-name "$EC2_ROLE" --policy-name "$EC2_POLICY"

  echo
  sec lambda-policy
  run aws iam list-attached-role-policies --role-name "$LAMBDA_ROLE"
  run aws iam get-role-policy --role-name "$LAMBDA_ROLE" --policy-name "$LAMBDA_POLICY"

  echo
  sec security-group
  run aws ec2 describe-security-groups \
    --filters "Name=tag:Course,Values=cloud" \
    --query "SecurityGroups[].IpPermissions"

  echo
  sec instance
  run aws ec2 describe-instances \
    --filters "Name=tag:Course,Values=cloud" "Name=instance-state-name,Values=running" \
    --query "Reservations[].Instances[].{type:InstanceType,imds:MetadataOptions.HttpTokens,profile:IamInstanceProfile.Arn}"

  echo
  sec endpoints
  for url in "${EC2}/" "${LAMBDA}/" "https://${BUCKET}.s3.amazonaws.com/tenants/"; do
    echo "--- $url"
    run curl -s -o /dev/null -w "http=%{http_code} type=%{content_type}\n" "$url"
  done

  echo
  sec lambda-logs
  run aws logs tail "$LOG_GROUP" --since 1h

  echo
  sec log-retention
  run aws logs describe-log-groups \
    --log-group-name-prefix "$LOG_GROUP" \
    --query "logGroups[].{name:logGroupName,days:retentionInDays}"
} > "$OUT" 2>&1

echo "DONE"
