#!/usr/bin/env bash
# Mirror every tenant's CV from S3 into the web root, then stamp the EC2 footer.
# Reads BUCKET from /etc/cv-sync.env so no bucket name is hard-coded in the script.
set -uo pipefail

ENV_FILE="/etc/cv-sync.env"
WEBROOT="/srv/www"
LOG="/var/log/cv-sync.log"

# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
: "${BUCKET:?BUCKET not set in $ENV_FILE}"

ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# --- instance id via IMDSv2 (token required) ---
TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
IID="${IID:-unknown-instance}"

# --- pull all tenants: s3://BUCKET/tenants/<roll>/site/... -> /srv/www/tenants/<roll>/site/... ---
mkdir -p "$WEBROOT/tenants"
if aws s3 sync "s3://${BUCKET}/tenants/" "${WEBROOT}/tenants/" --delete >/dev/null 2>&1; then
  SYNC="ok"
else
  SYNC="FAILED"
fi

# --- stamp the EC2 footer into every tenant's index.html ---
# The placeholder is re-pulled fresh on each sync, so this stays idempotent.
while IFS= read -r -d '' f; do
  sed -i "s|{{HOSTED_ON}}|EC2 ${IID}|g" "$f"
done < <(find "${WEBROOT}/tenants" -type f -name index.html -print0 2>/dev/null)

echo "$(ts) sync=${SYNC} instance=${IID}" >> "$LOG"
