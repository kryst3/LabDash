#!/usr/bin/env bash
# installs labdash as a systemd service on a linux server
# run from the project folder: sudo bash setup-server.sh
# optional: DOMAIN=your.domain (https via caddy), APP_DIR, APP_USER, PORT
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/labdash}"
APP_USER="${APP_USER:-labdash}"
PORT="${PORT:-5000}"
DOMAIN="${DOMAIN-}"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="/etc/${APP_USER}.env"

die() { echo "error: $*" >&2; exit 1; }
ask() { local a; read -r -p "$1" a || true; echo "$a"; }

[ "$EUID" -eq 0 ] || die "run it with sudo"
command -v systemctl >/dev/null || die "needs systemd"
[ -f "$SRC_DIR/app.py" ] || die "app.py not found, run this from the labdash folder"

if [ -z "$DOMAIN" ] && [ -t 0 ]; then
    echo "domain for https (leave empty for plain http on port $PORT)"
    DOMAIN="$(ask 'domain: ')"
fi

echo "installing packages"
if command -v apt-get >/dev/null; then
    apt-get update
    apt-get install -y python3 python3-venv python3-pip rsync
    [ -z "$DOMAIN" ] || apt-get install -y caddy
elif command -v dnf >/dev/null; then
    dnf install -y python3 python3-pip rsync
    [ -z "$DOMAIN" ] || dnf install -y caddy
elif command -v pacman >/dev/null; then
    pacman -Sy --noconfirm --needed python python-pip rsync
    [ -z "$DOMAIN" ] || pacman -S --noconfirm --needed caddy
elif command -v zypper >/dev/null; then
    zypper --non-interactive install python3 python3-pip rsync
    [ -z "$DOMAIN" ] || zypper --non-interactive install caddy
else
    die "unknown package manager, install python3, pip, rsync (and caddy) yourself and run again"
fi

python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || die "need python 3.10 or newer"
if [ -n "$DOMAIN" ] && ! command -v caddy >/dev/null; then
    die "couldn't install caddy, see https://caddyserver.com/docs/install or run without a domain"
fi

echo "creating user and folders"
id "$APP_USER" >/dev/null 2>&1 || useradd --system --home "$APP_DIR" --shell "$(command -v nologin || echo /usr/sbin/nologin)" "$APP_USER"
install -d -o "$APP_USER" -g "$APP_USER" "$APP_DIR"
install -d -o "$APP_USER" -g "$APP_USER" -m 700 "$APP_DIR/instance"

echo "copying files"
if [ "$SRC_DIR" != "$APP_DIR" ]; then
    rsync -a --chown="$APP_USER:$APP_USER" \
        --exclude instance --exclude venv --exclude node_modules \
        --exclude __pycache__ --exclude .git --exclude '*.env' --exclude Plan.md \
        "$SRC_DIR"/ "$APP_DIR"/
fi

echo "setting up python"
cd "$APP_DIR"
[ -d venv ] || sudo -u "$APP_USER" python3 -m venv venv
if [ -s requirements.txt ]; then
    sudo -u "$APP_USER" ./venv/bin/pip install -r requirements.txt
else
    sudo -u "$APP_USER" ./venv/bin/pip install flask flask-sqlalchemy flask-login flask-wtf flask-limiter psutil
fi
sudo -u "$APP_USER" ./venv/bin/pip install gunicorn

if [ ! -f "$ENV_FILE" ]; then
    {
        echo "SECRET_KEY=$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
        [ -z "$DOMAIN" ] || echo "TRUST_PROXY=1"
    } > "$ENV_FILE"
    chown "root:$APP_USER" "$ENV_FILE"
    chmod 640 "$ENV_FILE"
fi

CREATE="set -a; source '$ENV_FILE'; set +a; cd '$APP_DIR'; ./venv/bin/flask --app app create-user"
if [ -t 0 ]; then
    echo "make your login"
    sudo -u "$APP_USER" bash -c "$CREATE" || echo "skipped, you can do it later"
else
    echo "no terminal, make a user later with: sudo -u $APP_USER bash -c \"$CREATE\""
fi

if [ -n "$DOMAIN" ]; then BIND="127.0.0.1:$PORT"; else BIND="0.0.0.0:$PORT"; fi
cat > "/etc/systemd/system/$APP_USER.service" <<EOF
[Unit]
Description=LabDash
After=network.target

[Service]
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$APP_DIR/venv/bin/gunicorn -w 1 --threads 4 -b $BIND app:app
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$APP_DIR/instance

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "$APP_USER"
systemctl restart "$APP_USER"

if [ -n "$DOMAIN" ]; then
    echo "setting up caddy"
    mkdir -p /etc/caddy
    [ ! -f /etc/caddy/Caddyfile ] || cp /etc/caddy/Caddyfile "/etc/caddy/Caddyfile.bak.$(date +%s)"
    cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
    reverse_proxy 127.0.0.1:$PORT
}
EOF
    systemctl enable caddy
    systemctl restart caddy
fi

PORTS="80/tcp 443/tcp"
[ -n "$DOMAIN" ] || PORTS="$PORT/tcp"
if command -v ufw >/dev/null; then
    if [ "$(ask 'set up ufw now? (allows ssh + web) [y/N] ')" = "y" ]; then
        SSH_PORT="$(ask 'ssh port [22]: ')"
        ufw allow "${SSH_PORT:-22}/tcp"
        for p in $PORTS; do ufw allow "$p"; done
        ufw --force enable
    fi
elif command -v firewall-cmd >/dev/null && systemctl is-active --quiet firewalld; then
    for p in $PORTS; do firewall-cmd --permanent --add-port="$p"; done
    firewall-cmd --reload
else
    echo "no firewall tool found, open these yourself if you use one: $PORTS"
fi

sleep 1
echo
curl -sI "http://127.0.0.1:$PORT/login" | head -1 || true
echo
if [ -n "$DOMAIN" ]; then
    echo "done, open https://$DOMAIN (the dns record has to point at this server)"
else
    echo "done, open http://SERVER-IP:$PORT"
    echo "this is plain http so your password isn't encrypted. use a domain or tailscale for anything public"
fi
echo "logs: journalctl -u $APP_USER -e and $APP_DIR/instance/security.log"