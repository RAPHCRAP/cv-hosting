#!/usr/bin/env bash
# EC2 user data for Amazon Linux 2023 — self-contained.
# Installs nginx, lays down path-routing config, installs the sync script on a
# 5-minute systemd timer (embedded below), and runs the first sync.
set -euxo pipefail

BUCKET="cv-23l-3063"
WEBROOT="/srv/www"

dnf -y install nginx

# config consumed by sync-cv.sh (bucket name not baked into the script)
cat > /etc/cv-sync.env <<EOF
BUCKET=${BUCKET}
EOF

mkdir -p "${WEBROOT}/tenants"
touch /var/log/cv-sync.log

# nginx: /u/<roll>/<rest>  ->  /srv/www/tenants/<roll>/site/<rest>
cat > /etc/nginx/conf.d/cv.conf <<'NGINX'
server {
    listen 80 default_server;
    server_name _;
    root /srv/www;
    index index.html;

    location ~ ^/u/(?<roll>[^/]+)(?<rest>/.*)?$ {
        rewrite ^ /tenants/$roll/site$rest break;
    }

    location = / {
        return 200 "CV hosting is up. Open /u/<roll-number>/ to view a CV.\n";
        default_type text/plain;
    }
}
NGINX
rm -f /etc/nginx/conf.d/default.conf || true
systemctl enable --now nginx

# sync script (mirror all tenants from S3, stamp the EC2 footer)
cat > /usr/local/bin/sync-cv.sh <<'SYNC'
#!/usr/bin/env bash
set -uo pipefail
ENV_FILE="/etc/cv-sync.env"
WEBROOT="/srv/www"
LOG="/var/log/cv-sync.log"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && . "$ENV_FILE"
: "${BUCKET:?BUCKET not set in $ENV_FILE}"
ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
IID="${IID:-unknown-instance}"

mkdir -p "$WEBROOT/tenants"
if aws s3 sync "s3://${BUCKET}/tenants/" "${WEBROOT}/tenants/" --delete >/dev/null 2>&1; then
  SYNC="ok"
else
  SYNC="FAILED"
fi

while IFS= read -r -d '' f; do
  sed -i "s|{{HOSTED_ON}}|EC2 ${IID}|g" "$f"
done < <(find "${WEBROOT}/tenants" -type f -name index.html -print0 2>/dev/null)

echo "$(ts) sync=${SYNC} instance=${IID}" >> "$LOG"
SYNC
chmod +x /usr/local/bin/sync-cv.sh

# systemd service + timer, every 5 minutes
cat > /etc/systemd/system/cv-sync.service <<'SVC'
[Unit]
Description=Sync CV tenants from S3 and stamp EC2 footer
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-cv.sh
SVC

cat > /etc/systemd/system/cv-sync.timer <<'TMR'
[Unit]
Description=Run cv-sync every 5 minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
AccuracySec=15s

[Install]
WantedBy=timers.target
TMR

systemctl daemon-reload
systemctl enable --now cv-sync.timer

# first run immediately
/usr/local/bin/sync-cv.sh || true
