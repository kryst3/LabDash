#!/usr/bin/env bash
set -Eeu
trap 'echo "failed at line $LINENO" >&2' ERR

APP=/opt/labdash
BAK=/var/backups/labdash-prev.tgz
ENV=/etc/labdash.env
SERVICE=/etc/systemd/system/labdash.service
CADDY=/etc/caddy/Caddyfile

die() { echo "error: $*" >&2; exit 1; }

need() {
  for c in "$@"; do
    command -v "$c" >/dev/null || die "$c is not installed"
  done
}

[ "$EUID" -eq 0 ] || die "run as root"
need apt-get rsync curl python3

SRC=${SRC:-$PWD}
[ -f "$SRC/app.py" ] || die "no app.py in $SRC"
[ -f "$SRC/requirements.txt" ] || die "no requirements.txt in $SRC"
grep -qi '^gunicorn' "$SRC/requirements.txt" || die "gunicorn missing from requirements.txt"
grep -qE '^app *= *Flask' "$SRC/app.py" || die "app.py needs app = Flask(...)"

apt-get update
apt-get install -y python3 python3-venv python3-pip rsync caddy ufw curl gunicorn

id labdash >/dev/null 2>&1 || useradd --system --home "$APP" --shell /usr/sbin/nologin labdash
install -d -o labdash -g labdash "$APP"
install -d -o labdash -g labdash -m 700 "$APP/instance"

if [ -d "$APP" ]; then
  mkdir -p /var/backups
  tar -czf "$BAK" -C "$APP" --exclude=./instance --exclude=./venv .
fi

rsync -a --delete \
  --exclude instance --exclude venv --exclude .venv \
  --exclude __pycache__ --exclude .git \
  --exclude '*.env' --exclude '*.sqlite' --exclude '*.log' \
  "$SRC"/ "$APP"/

chown -R labdash:labdash "$APP"

if [ ! -d "$APP/venv" ]; then
  sudo -u labdash python3 -m venv "$APP/venv"
fi

sudo -u labdash "$APP/venv/bin/pip" install -r "$APP/requirements.txt"

if [ ! -f "$ENV" ]; then
  key=$(python3 -c "import secrets; print(secrets.token_hex(32))")
  printf 'SECRET_KEY=%s\nTRUST_PROXY=1\n' "$key" > "$ENV"
  chown root:labdash "$ENV"
  chmod 640 "$ENV"
fi

cat > "$SERVICE" <<'UNIT'
[Unit]
Description=LabDash
After=network.target

[Service]
User=labdash
Group=labdash
WorkingDirectory=/opt/labdash
EnvironmentFile=/etc/labdash.env
ExecStart=/opt/labdash/venv/bin/gunicorn -w 1 --threads 4 -b 127.0.0.1:5000 app:app
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=/opt/labdash/instance

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable labdash

read -rp "domain: " DOMAIN
[[ "$DOMAIN" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]] || die "bad domain"

cat > "$CADDY" <<EOF
$DOMAIN {
    reverse_proxy 127.0.0.1:5000
}
EOF

systemctl restart caddy
systemctl restart labdash

ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

for i in $(seq 1 10); do
  curl -sf -o /dev/null http://127.0.0.1:5000/login && break
  sleep 1
done

systemctl --no-pager status labdash || true
echo "done"
