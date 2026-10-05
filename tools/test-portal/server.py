#!/usr/bin/env python3
"""Lokales Testportal für CaptiveAI (SPEC §4.1, 02 §5.3). Nur Standardbibliothek.

Start:  python3 tools/test-portal/server.py [--port 8080]
Steuerung:
  GET /_control/reset?scenario=hotel   Szenario wählen, Zustand zurücksetzen
  GET /_log                            Request-Log als JSON (Clientaktion vs. echter Request)
Probe:
  GET /hotspot-detect.html             "Success" wenn angemeldet, sonst Redirect aufs Portal
Portal-Routen:
  /terms /login /hotel /multistage/1 /multistage/2 /dynamic /changed-label /js-required /success
"""
import argparse
import json
import secrets
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

FIXTURES = Path(__file__).resolve().parents[2] / "Packages/CaptiveCore/Tests/CaptiveCoreTests/Fixtures"

# Testwerte aus 02 §18
USER, PASSWORD, ROOM, SURNAME = "mark", "SuperSecret123", "417", "Example"

# Szenario = Liste von Schritten (Fixture, erwartete Formularwerte, Pflichtfelder)
SCENARIOS = {
    "clickthrough": [("01_clickthrough", {"action": "continue"})],
    "terms": [("02_terms", {"terms": "1"})],
    "terms-privacy": [("03_terms_privacy", {"terms": "1", "privacy": "1"})],
    "login": [("04_userpass", {"username": USER, "password": PASSWORD})],
    "hotel": [("05_hotel", {"room": ROOM, "lastname": SURNAME})],
    "dynamic": [("05_hotel", {"room": ROOM, "lastname": SURNAME})],
    "voucher": [("06_voucher", {"voucher": "VOUCH-7788"})],
    "email": [("07_email", {"email": "guest@portal.invalid", "terms": "1"})],
    "multistage": [("08_multistage_terms", {"terms": "1"}), ("09_multistage_guest", {"room": ROOM, "lastname": SURNAME})],
    "changed-label": [("10_changed_labels", {"room": ROOM, "lastname": SURNAME})],
    "csrf": [("11_hidden_csrf", {"username": USER, "password": PASSWORD})],
    "marketing": [("12_optional_marketing", {"terms": "1"})],
    "paid": [("13_paid_upgrade", {"terms": "1"})],
    "js-required": [("14_js_only", {})],
}
ROUTES = {
    "/terms": "terms", "/login": "login", "/hotel": "hotel", "/dynamic": "dynamic",
    "/changed-label": "changed-label", "/js-required": "js-required",
}


class State:
    lock = threading.Lock()
    scenario = "hotel"
    index = 0
    authenticated = False
    csrf = ""
    sessions = set()
    log = []


def reset(scenario):
    with State.lock:
        State.scenario = scenario if scenario in SCENARIOS else "hotel"
        State.index = 0
        State.authenticated = False
        State.csrf = ""
        State.sessions = set()
        State.log = []


class Handler(BaseHTTPRequestHandler):
    server_version = "CaptiveTestPortal/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.command, self.path))

    def send(self, status, body="", headers=None, ctype="text/html; charset=utf-8"):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, to):
        self.send(302, "", {"Location": to})

    def cookie(self):
        raw = self.headers.get("Cookie", "")
        for part in raw.split(";"):
            part = part.strip()
            if part.startswith("session="):
                return part[len("session="):]
        return None

    def record(self, form=None):
        with State.lock:
            State.log.append({"method": self.command, "path": urlparse(self.path).path,
                              "fields": sorted((form or {}).keys()), "hasCookie": self.cookie() is not None})

    def page(self):
        steps = SCENARIOS[State.scenario]
        fixture, _ = steps[min(State.index, len(steps) - 1)]
        html = (FIXTURES / f"{fixture}.html").read_text(encoding="utf-8")
        State.csrf = "tok" + secrets.token_hex(4)
        html = html.replace("{{csrf}}", State.csrf)
        sid = secrets.token_hex(4)
        State.sessions.add(sid)
        self.send(200, html, {"Set-Cookie": f"session={sid}; Path=/"})

    def do_GET(self):
        url = urlparse(self.path)
        path = url.path
        if path == "/_control/reset":
            reset(parse_qs(url.query).get("scenario", ["hotel"])[0])
            return self.send(200, "ok", ctype="text/plain")
        if path == "/_log":
            with State.lock:
                return self.send(200, json.dumps(State.log), ctype="application/json")
        self.record()
        if path in ("/hotspot-detect.html", "/generate_204"):
            if State.authenticated:
                return self.send(200, "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>")
            host = self.headers.get("Host", "127.0.0.1:8080")
            return self.redirect(f"http://{host}/portal")
        if path == "/portal" or path in ROUTES or path.startswith("/multistage/"):
            if path in ROUTES and ROUTES[path] != State.scenario:
                reset(ROUTES[path])
            with State.lock:
                return self.page()
        if path == "/success":
            return self.send(200, "<html><body>You are connected</body></html>")
        self.send(404, "not found", ctype="text/plain")

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        form = {k: v[0] for k, v in parse_qs(self.rfile.read(length).decode("utf-8"), keep_blank_values=True).items()}
        self.record(form)
        if urlparse(self.path).path != "/auth":
            return self.send(404, "not found", ctype="text/plain")
        with State.lock:
            steps = SCENARIOS[State.scenario]
            fixture, expect = steps[min(State.index, len(steps) - 1)]
            ok = self.cookie() in State.sessions
            ok = ok and all(form.get(k) == v for k, v in expect.items())
            if "{{csrf}}" in (FIXTURES / f"{fixture}.html").read_text(encoding="utf-8"):
                ok = ok and form.get("csrf") == State.csrf
            if not ok:
                return self.page()
            State.index += 1
            if State.index >= len(steps):
                State.authenticated = True
                return self.redirect("/success")
            return self.redirect("/portal")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--scenario", default="hotel")
    args = ap.parse_args()
    reset(args.scenario)
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"Testportal auf http://127.0.0.1:{args.port} (Szenario {State.scenario})", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
