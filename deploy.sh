#!/usr/bin/env bash
# installs labdash as a systemd service or with Docker Compose
# run from the project folder: sudo bash deploy.sh
# optional: DEPLOY_MODE=systemd|docker, DOMAIN=your.domain (Caddy HTTPS),
#           APP_DIR, APP_USER, PORT
set -euo pipefail

APP_DIR="${APP_DIR:-/opt/labdash}"
APP_USER="${APP_USER:-labdash}"
PORT="${PORT:-5000}"
DOMAIN="${DOMAIN-}"
DEPLOY_MODE="${DEPLOY_MODE-}"
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="/etc/${APP_USER}.env"

die() { echo "error: $*" >&2; exit 1; }
ask() { local a=""; read -r -p "$1" a || true; echo "$a"; }

if [ -z "$DEPLOY_MODE" ] && [ -t 0 ]; then
    echo "Choose a deployment method:"
    echo "  1) systemd service (optionally with Caddy HTTPS)"
    echo "  2) Docker Compose"
    case "$(ask 'Select [1-2]: ')" in
        1) DEPLOY_MODE="systemd" ;;
        2) DEPLOY_MODE="docker" ;;
        *) die "choose 1 or 2" ;;
    esac
else
    DEPLOY_MODE="${DEPLOY_MODE:-systemd}"
fi

case "$DEPLOY_MODE" in
    systemd|docker) ;;
    *) die "DEPLOY_MODE must be 'systemd' or 'docker'" ;;
esac

[ "$EUID" -eq 0 ] || die "run it with sudo"
[ -f "$SRC_DIR/app.py" ] || die "app.py not found, run this from the labdash folder"

if [ "$DEPLOY_MODE" = "docker" ]; then
    [ -f "$SRC_DIR/compose.yaml" ] || die "compose.yaml not found"
    command -v docker >/dev/null || die "install Docker and the Compose plugin first"
    docker compose version >/dev/null || die "Docker Compose plugin is required"
    docker info >/dev/null || die "Docker daemon is unavailable"

    if [ -t 0 ]; then
        PORT="$(ask "Host port for HTTP [${PORT}]: ")"
        PORT="${PORT:-5000}"
    fi
    [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] \
        || die "PORT must be a number from 1 to 65535"

    if [ "$SRC_DIR" != "$APP_DIR" ]; then
        command -v rsync >/dev/null || die "rsync is required to copy the app to $APP_DIR"
        install -d "$APP_DIR"
        rsync -a \
            --exclude instance --exclude venv --exclude .venv --exclude node_modules \
            --exclude __pycache__ --exclude .git --exclude .env --exclude Plan.md \
            "$SRC_DIR"/ "$APP_DIR"/
    fi

    cd "$APP_DIR"
    if ! grep -Eq '^SECRET_KEY=.+$' .env 2>/dev/null; then
        umask 077
        printf 'SECRET_KEY=%s\n' "$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')" >> .env
    fi
    chmod 600 .env

    echo "building and starting LabDash with Docker Compose"
    PORT="$PORT" docker compose config --quiet
    PORT="$PORT" docker compose up --build -d

    if [ -t 0 ]; then
        case "$(ask 'Create a login account now? [y/N]: ')" in
            y|Y) docker compose exec app flask --app app create-user ;;
            *) echo "Create an account later with: cd '$APP_DIR' && docker compose exec app flask --app app create-user" ;;
        esac
    else
        echo "Create an account later with: cd '$APP_DIR' && docker compose exec app flask --app app create-user"
    fi

    echo "done, open http://SERVER-IP:$PORT"
    echo "database and logs persist in the Docker volume 'labdash-data'"
    exit 0
fi

command -v systemctl >/dev/null || die "systemd is required for this deployment method"

if [ -z "$DOMAIN" ] && [ -t 0 ]; then
    case "$(ask 'Configure Caddy HTTPS for a domain? [y/N]: ')" in
        y|Y)
            DOMAIN="$(ask 'Domain name: ')"
            [ -n "$DOMAIN" ] || die "a domain is required to configure Caddy"
            ;;
    esac
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