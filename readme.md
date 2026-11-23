# LabDash

A self-hosted homelab dashboard styled like windows 7.

If you want a live demo dont hesitate to DM me on the hack club slack @RobinOSS

## Features

- Windows 7 look built with[7.css](https://khang-nd.github.io/7.css/)
- Login with hashed passwords
- Performance tab
- Processes tab
- Drives tab: mounted partitions with filesystems
- Services tab
- Host info: hostname, OS, kernel, uptime and load average
- Auto-refreshes every 2 seconds

## Setup

Requires Python 3.10+

```bash
git clone https://github.com/YOU/labdash.git
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