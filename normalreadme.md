# LabDash
A homelab dashboard styled like Win7

Demo is in defaultt.html

## Features

- Windows 7 Style built using [7.css](https://khang-nd.github.io/7.css/)
- Login with hashed passwords
- Performance tab featuring CPU-Core speeds, RAM Amount-Usage Stats (With swap, but nobody cares about that)
- Processes tab with PID and Process Name
- Drives tab: Mounted partitions with filesystems and total-free storage
- Services tab: currently shows only HTTP and SSH and the port
- Host info: hostname, OS, kernel, uptime and load average 
- Automatically refreshes every 1 second

## Setup

Requires Python 3.10+

```bash
git clone https://github.com/kryst3/labdash.git
cd labdash
python -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```
##### Before running you need a SECRET_KEY

```bash
python -c "import secrets; print(secrets.token_hex(64))"
export SECRET_KEY=PASTETHEKEYHERE!!!!!!!!!!!!!!!!!
```
### Create a user

You cannot register. There is no registration page.
To create users use the command line:

```bash
flask --app app create-user
```

You'll be prompted for a username and a password. The database is created automatically at `instance/db.sqlite`

### Run
To run it for testing use the command
```bash
python app.py
```

Then open http://localhost:5000 and sign in. The server binds to `0.0.0.0:5000` by default.

For anything public, run it behind a real server and HTTPS instead of Flask's dev server.
```bash
gunicorn -w 1 -b 127.0.0.1:5000 app:app
```
