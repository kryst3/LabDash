import os
import time
import platform
import psutil
import socket
import getpass
import logging
from logging.handlers import RotatingFileHandler
from datetime import datetime, timezone
from urllib.parse import urlparse
from flask import Flask, render_template, request, url_for, redirect, jsonify, session
from flask_sqlalchemy import SQLAlchemy
from flask_login import LoginManager, UserMixin, login_user, logout_user, login_required, current_user
from flask_wtf.csrf import CSRFProtect
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from werkzeug.security import generate_password_hash, check_password_hash
# flask init
app = Flask(__name__)
limiter = Limiter(
    get_remote_address,
    app=app,
    storage_uri="memory://",
)
app.config["SQLALCHEMY_DATABASE_URI"] = "sqlite:///db.sqlite"
app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
app.config["SECRET_KEY"] = os.environ["SECRET_KEY"]
db = SQLAlchemy(app)
login_manager = LoginManager()
login_manager.init_app(app)
login_manager.login_view = "login"

if os.environ.get("TRUST_PROXY") == "1":
    from werkzeug.middleware.proxy_fix import ProxyFix
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1)

os.makedirs(app.instance_path, exist_ok=True)
sec = logging.getLogger("labdash.security")
sec.setLevel(logging.INFO)
_sec_handler = RotatingFileHandler(
    os.path.join(app.instance_path, "security.log"),
    maxBytes=1_000_000, backupCount=5,
)
_sec_handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
sec.addHandler(_sec_handler)

def who():
    ua = request.headers.get("User-Agent", "-")[:200]
    return f"ip={get_remote_address()} ua={ua!r}"

class Users(UserMixin, db.Model):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(250), unique=True, nullable=False)
    password = db.Column(db.String(250), nullable=False)

with app.app_context():
    db.create_all()

@login_manager.user_loader
def load_user(user_id):
    return db.session.get(Users, int(user_id))

# no register cus opsec or something
@app.route("/login", methods=["GET", "POST"])
@limiter.limit("5 per minute; 30 per hour", methods=["POST"])
def login():
    if request.method == "POST":
        username = request.form.get("username")
        password = request.form.get("password")

        if not username or not password:
            return render_template("login.html", error="Enter a username and password"), 400

        user = Users.query.filter_by(username=username).first()

        if user and check_password_hash(user.password, password):
            sec.info(f"LOGIN_OK user={username!r} {who()}")
            login_user(user)
            session["login_sound"] = True
            return redirect(url_for("dashboard"))
        else:
            # never log the password itself
            sec.warning(f"LOGIN_FAIL user={(username or '')[:100]!r} {who()}")
            return render_template("login.html", error="Invalid username or password")
    return render_template("login.html")

@app.errorhandler(429)
def too_many_requests(e):
    sec.warning(f"RATE_LIMITED {who()} limit={e.description!r}")
    return render_template("login.html", error="Too many attempts. Try again later."), 429

@app.route("/logout")
@login_required
def logout():
    logout_user()
    return redirect(url_for("login"))
psutil.cpu_percent(interval=None, percpu=True)
GB = 1024 ** 3

def port_open(port, host="127.0.0.1"):
    with socket.socket() as s:
        s.settimeout(0.4)
        return s.connect_ex((host, port)) == 0
def snapshot():
    mem = psutil.virtual_memory()
    swap = psutil.swap_memory()
    cores = psutil.cpu_percent(interval=None, percpu=True)

    procs = []
    for p in psutil.process_iter(["pid", "name", "username", "cpu_percent", "memory_info"]):
        i = p.info 
        if i["memory_info"] is None:
            continue
        procs.append({
           "pid": i["pid"], "name": i["name"] or "?", "user": i["username"] or "?",
           "cpu": i["cpu_percent"] or 0.0,
           "mem": round(i["memory_info"].rss / 1024**2, 1),
        })
    procs.sort(key=lambda x: x["mem"], reverse=True)

    drives = []
    for part in psutil.disk_partitions(all=False):
        try:
            u = psutil.disk_usage(part.mountpoint)
        except (PermissionError, OSError):
            continue
        drives.append({
            "dev": part.device, "mount": part.mountpoint, "fs": part.fstype,
            "used": round(u.used / GB, 1), "total": round(u.total / GB, 1), "percent": u.percent,
        })
    return {
        "cpu": round(sum(cores) / len(cores), 1),
        "cores": cores,
        "ram": mem.percent, "ram_used": round(mem.used / GB, 2), "ram_total": round(mem.total / GB, 2),
        "swap": swap.percent, "swap_used": round(swap.used / GB, 2), "swap_total": round(swap.total / GB, 2),
        "uptime": int(time.time() - psutil.boot_time()),
        "load": [round(x, 2) for x in psutil.getloadavg()],
        "proc_count": len(procs),
        "procs": procs[:30],
        "drives": drives,
        "services": {"ssh": port_open(22), "http": port_open(80)},
    }
@app.route("/dashboard")
@login_required
def dashboard():
    if request.headers.get("X-Requested-With") == "fetch":
        return jsonify(snapshot())
    uname = platform.uname()
    return render_template(
        "dashboard.html",
        username=current_user.username,
        os_name=platform.system(),
        node_name=uname.node,
        release=uname.release,
        machine=uname.machine,
    )
 # NEEDS A FUCKING TEMPLATE FOLDER :`)
# folder has to be named templates NOT template
@app.cli.command("create-user")
def create_user():
    username = input("Username: ").strip()

    if not username:
        raise RuntimeError("Username cannot be empty.")
    if Users.query.filter_by(username=username).first():
        raise RuntimeError("That username already exists.")

    password = getpass.getpass("Password: ")
    if not password:
        raise RuntimeError("Password cannot be empty.")

    user = Users(
        username=username,
        password=generate_password_hash(password)
    )
    db.session.add(user)
    db.session.commit()
    print(f"Created user {username!r}.")

if __name__ == "__main__":
   app.run(host="0.0.0.0", port=5000, debug=False)