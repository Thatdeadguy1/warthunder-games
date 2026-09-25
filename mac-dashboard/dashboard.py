#!/usr/bin/env python3
"""
Dashboard - macOS launcher dashboard.

Runs a small local web server (127.0.0.1 only, standard library only) and
opens the dashboard page in your browser. The page launches apps and
websites from config.json, shows live system/network stats, and watches for
ESP32 USB-serial devices (opens the Ghost ESP panel).

Run with "Launch Dashboard.command", or:  python3 dashboard.py
"""

import glob
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONFIG = json.loads((HERE / "config.json").read_text())
TOKEN = secrets.token_urlsafe(24)  # the page must send this back; blocks other sites from calling the API

APP_DIRS = [
    Path("/Applications"),
    Path.home() / "Applications",
    Path("/Applications/Utilities"),
    Path("/System/Applications"),
    Path("/System/Applications/Utilities"),
]

# USB vendor IDs of the serial chips found on ESP32 dev boards.
ESP_VENDORS = {
    0x303A: "Espressif USB (S3/C3/C6)",
    0x10C4: "Silicon Labs CP210x",
    0x1A86: "WCH CH340/CH910x",
}
SERIAL_GLOBS = ["/dev/cu.usbmodem*", "/dev/cu.usbserial*", "/dev/cu.wchusbserial*", "/dev/cu.SLAB_USBtoUART*"]


def run(cmd, timeout=10):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


# ------------------------------------------------------------------ apps ---

def resolve_app(app):
    """Path of the .app bundle, or None if it isn't installed."""
    for p in app.get("paths", []):
        p = Path(os.path.expanduser(p))
        if p.exists():
            return str(p)
    for d in APP_DIRS:
        p = d / f"{app['app']}.app"
        if p.exists():
            return str(p)
    return None


def find_app(name):
    return next((a for a in CONFIG["apps"] if a["name"] == name), None)


def launch_app(app):
    path = resolve_app(app)
    if not path:
        return ("warn", f"{app['name']} not found in {', '.join(str(d) for d in APP_DIRS)}")
    res = subprocess.run(["open", "-a", path], capture_output=True, text=True)
    if res.returncode:
        return ("err", f"Failed to launch {app['name']}: {res.stderr.strip()}")
    return ("ok", f"Launched {app['name']}")


def open_url(url, label):
    browser = find_app(CONFIG.get("browser", ""))
    path = resolve_app(browser) if browser else None
    cmd = ["open", "-a", path, url] if path else ["open", url]
    res = subprocess.run(cmd, capture_output=True, text=True)
    if res.returncode:
        return ("err", f"Failed to open {label}: {res.stderr.strip()}")
    return ("ok", f"Opened {label}")


def open_ghost_esp():
    panel = Path(os.path.expanduser(CONFIG["ghostEspPanel"]))
    if not panel.exists():
        return ("warn", f"Ghost ESP panel not found at {panel} (edit ghostEspPanel in config.json)")
    return open_url(panel.as_uri(), "Ghost ESP panel")


# ----------------------------------------------------------------- stats ---

def get_stats():
    cpu = sum(float(x) for x in run(["ps", "-A", "-o", "%cpu="]).split() if x.replace(".", "", 1).isdigit())
    cpu = min(100.0, cpu / (os.cpu_count() or 1))

    total = int(run(["sysctl", "-n", "hw.memsize"]).strip() or 0)
    vm = run(["vm_stat"])
    page = int((re.search(r"page size of (\d+)", vm) or [0, 4096])[1])

    def pages(label):
        m = re.search(rf"{label}:\s+(\d+)", vm)
        return int(m.group(1)) if m else 0

    # roughly Activity Monitor's "Memory Used": app + wired + compressed
    used = (pages("Pages active") + pages("Pages wired down") + pages("Pages occupied by compressor")) * page

    boot = re.search(r"sec = (\d+)", run(["sysctl", "-n", "kern.boottime"]))
    uptime = int(time.time()) - int(boot.group(1)) if boot else 0

    return {
        "cpu": round(cpu),
        "ramUsedGb": round(used / 2**30, 1),
        "ramTotalGb": round(total / 2**30, 1),
        "uptime": f"{uptime // 86400}d {uptime % 86400 // 3600:02d}h {uptime % 3600 // 60:02d}m",
    }


def get_network():
    lines = []
    iface = None
    for line in run(["ifconfig"]).splitlines():
        m = re.match(r"^(\S+?):", line)
        if m:
            iface = m.group(1)
            continue
        m = re.search(r"inet (\d+\.\d+\.\d+\.\d+) netmask 0x([0-9a-f]+)", line)
        if m and iface != "lo0" and not m.group(1).startswith("169.254."):
            prefix = bin(int(m.group(2), 16)).count("1")
            lines.append(f"{iface:<14} {m.group(1)}/{prefix}")
    gw = re.search(r"gateway: (\S+)", run(["route", "-n", "get", "default"]))
    if gw:
        lines.append(f"{'gateway':<14} {gw.group(1)}")
    dns = list(dict.fromkeys(re.findall(r"nameserver\[\d+\] : (\S+)", run(["scutil", "--dns"]))))
    if dns:
        lines.append(f"{'dns':<14} {', '.join(dns[:3])}")
    return "\n".join(lines) or "No IPv4 connection"


def get_esp():
    chips = []
    for vid in re.findall(r'"idVendor" = (\d+)', run(["ioreg", "-p", "IOUSB", "-l", "-w", "0"])):
        label = ESP_VENDORS.get(int(vid))
        if label and label not in chips:
            chips.append(label)
    ports = sorted({p for g in SERIAL_GLOBS for p in glob.glob(g)})
    return {"chips": chips, "ports": ports if chips else []}


def ping(host):
    if not re.fullmatch(r"[A-Za-z0-9.\-:]{1,253}", host):
        return ("warn", f"Invalid host: {host}")
    out = run(["ping", "-c", "4", "-t", "8", host], timeout=15)
    recv = re.search(r"(\d+) packets received", out)
    rtt = re.search(r"= ([\d.]+)/([\d.]+)/([\d.]+)/", out)
    if recv and int(recv.group(1)) and rtt:
        return ("ok", f"{host}: {recv.group(1)}/4 replies, min/avg/max "
                      f"{float(rtt.group(1)):.0f}/{float(rtt.group(2)):.0f}/{float(rtt.group(3)):.0f} ms")
    return ("warn", f"{host}: no reply")


def flush_dns():
    # Asks for your password with the normal macOS admin prompt.
    script = 'do shell script "dscacheutil -flushcache; killall -HUP mDNSResponder" with administrator privileges'
    res = subprocess.run(["osascript", "-e", script], capture_output=True, text=True)
    if res.returncode:
        return ("warn", "Flush DNS cancelled or failed")
    return ("ok", "DNS cache flushed")


def dev_start():
    log = [("info", "DEV TOOL START")]
    for name in CONFIG["devStartApps"]:
        app = find_app(name)
        log.append(launch_app(app) if app else ("warn", f"devStartApps: '{name}' is not in apps list"))
    esp = get_esp()
    if esp["chips"]:
        log.append(("ok", f"ESP32-style device: {', '.join(esp['chips'])}"))
        if CONFIG.get("autoOpenGhostEspOnDevStart"):
            log.append(open_ghost_esp())
    else:
        log.append(("info", "No ESP32 detected - skipping Ghost ESP panel"))
    return log


def page_config():
    user = os.environ.get("USER", "user")
    host = socket.gethostname().split(".")[0]
    ver = run(["sw_vers", "-productVersion"]).strip()
    apps = [{"name": a["name"], "group": a["group"], "installed": bool(p := resolve_app(a)),
             "sub": Path(p).name if p else "not installed"} for a in CONFIG["apps"]]
    return {"host": f"{user}@{host}  //  macOS {ver}".strip(), "apps": apps, "sites": CONFIG["sites"]}


# ---------------------------------------------------------------- server ---

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _allowed(self):
        port = self.server.server_address[1]
        if self.headers.get("Host") not in (f"127.0.0.1:{port}", f"localhost:{port}"):
            return False  # blocks DNS-rebinding
        return self.path == "/" or secrets.compare_digest(self.headers.get("X-Token", ""), TOKEN)

    def do_GET(self):
        if not self._allowed():
            return self._send(403, {"error": "forbidden"})
        if self.path == "/":
            html = (HERE / "index.html").read_text().replace("{{TOKEN}}", TOKEN)
            return self._send(200, html.encode(), "text/html; charset=utf-8")
        routes = {
            "/api/config": page_config,
            "/api/stats": get_stats,
            "/api/net": get_network,
            "/api/esp": get_esp,
        }
        if self.path in routes:
            return self._send(200, routes[self.path]())
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._allowed():
            return self._send(403, {"error": "forbidden"})
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/api/launch":
            app = find_app(body.get("name", ""))
            log = [launch_app(app) if app else ("warn", "Unknown app")]
        elif self.path == "/api/open":
            # only URLs from config.json can be opened
            site = next((s for s in CONFIG["sites"] if s["url"] == body.get("url")), None)
            log = [open_url(site["url"], site["name"]) if site else ("warn", "Unknown site")]
        elif self.path == "/api/devstart":
            log = dev_start()
        elif self.path == "/api/ghost":
            log = [open_ghost_esp()]
        elif self.path == "/api/ping":
            log = [ping(str(body.get("host", "")).strip())]
        elif self.path == "/api/flushdns":
            log = [flush_dns()]
        else:
            return self._send(404, {"error": "not found"})
        self._send(200, {"log": log})


def main():
    port = CONFIG.get("port", 8765)
    try:
        server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    except OSError:
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)  # port busy: pick a free one
    url = f"http://127.0.0.1:{server.server_address[1]}/"
    print(f"Dashboard running at {url}  (Ctrl+C to stop)")
    if "--no-browser" not in sys.argv:
        browser = find_app(CONFIG.get("browser", ""))
        path = resolve_app(browser) if browser else None
        subprocess.run(["open", "-a", path, url] if path else ["open", url])
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
