#!/usr/bin/env bash
# EC2 user data for Amazon Linux 2023.
# Installs nginx, lays down the path-routing config, installs the sync script
# on a 5-minute systemd timer, and runs the first sync.
#
# EDIT THIS before launch: set BUCKET to your real bucket name.
set -euxo pipefail

BUCKET="cv-22l-6543"      # <-- change to your bucket
WEBROOT="/srv/www"

dnf -y update
dnf -y install nginx awscli

# --- config consumed by sync-cv.sh (bucket name is not baked into the script) ---
cat > /etc/cv-sync.env <<EOF
BUCKET=${BUCKET}
EOF

mkdir -p "${WEBROOT}/tenants"
touch /var/log/cv-sync.log

# --- nginx: /u/<roll>/<rest>  ->  /srv/www/tenants/<roll>/site/<rest> ---
cat > /etc/nginx/conf.d/cv.conf <<'EOF'
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
EOF

# strip the stock default server block so ours is the only one
rm -f /etc/nginx/conf.d/default.conf || true

systemctl enable --now nginx

# --- install the sync script ---
install -m 0755 /dev/stdin /usr/local/bin/sync-cv.sh < /opt/cv/sync-cv.sh 2>/dev/null || true
# (when provisioning by hand, copy ec2/sync-cv.sh to /usr/local/bin/sync-cv.sh)

# --- systemd service + timer, every 5 minutes ---
cat > /etc/systemd/system/cv-sync.service <<'EOF'
[Unit]
Description=Sync CV tenants from S3 and stamp EC2 footer
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-cv.sh
EOF

cat > /etc/systemd/system/cv-sync.timer <<'EOF'
[Unit]
Description=Run cv-sync every 5 minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
AccuracySec=15s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now cv-sync.timer

# first run immediately
/usr/local/bin/sync-cv.sh || true
