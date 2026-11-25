# LabDash

A self-hosted homelab dashboard with a Windows 7-inspired look. View system
stats, processes, drives, and services in one place.

If you want a live demo dont hesitate to DM me on the hack club slack @RobinOSS

## Features

- Windows 7 look built with[7.css](https://khang-nd.github.io/7.css/)
- Login with hashed passwords
- Performance tab
- Processes tab
- Drives tab: mounted partitions with filesystems
- Services tab
- Host info: hostname, OS, kernel, uptime and load average
- Auto-refreshes every 1 second

## Setup

Requires Python 3.10+

```bash
git clone https://github.com/kryst3/labdash.git
cd labdash
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```
Before running you need a SECRET_KEY

```bash
python -c "import secrets; print(secrets.token_hex(32))"
export SECRET_KEY=paste-it-here
```

### Create a user

There is no registration page. Create accounts from the command line:

```bash
flask --app app create-user
```

You'll be prompted for a username and password. The database is created
automatically at `instance/db.sqlite`.

### Run

```bash
python app.py
```


Then open http://localhost:5000 and sign in. The server binds to `0.0.0.0:5000`
by default.

For anything public, run it behind a real server and HTTPS instead of Flask's
dev server, for example:

```bash
gunicorn -w 1 -b 127.0.0.1:5000 app:app
```

### Run with Docker Compose

Create a persistent application secret, then build and start LabDash:

```bash
printf 'SECRET_KEY=%s\n' "$(openssl rand -hex 32)" > .env
docker compose up --build -d
```

Create the first login account inside the running container:

```bash
docker compose exec app flask --app app create-user
```

Open http://localhost:5000 and sign in. Compose persists the SQLite database
and security log in the `labdash-data` volume. Set `PORT` in `.env` to change
the host port. Keep `.env` private; it contains the session-signing key.

### Deploy with the interactive script

From the project directory, run:

```bash
sudo bash deploy.sh
```

Choose either a systemd service (with optional Caddy-managed HTTPS for a domain)
or Docker Compose from the menu. The Docker option asks which host HTTP port to
publish and can create the first login account. It requires Docker Engine and
the Docker Compose plugin to be installed; it does not install Docker for you.