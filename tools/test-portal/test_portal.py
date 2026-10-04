#!/usr/bin/env python3
"""Lokales Fake-Captive-Portal für CaptiveAI (SPEC.md §4.1, 02 §5.3).

Nur Python-Standardbibliothek. Startet einen HTTP-Server, der

* die Fixtures aus Packages/CaptiveCore/Tests/Fixtures/portals ausliefert,
* den Apple-Probe /hotspot-detect.html simuliert (Success erst nach Login),
* Logins gegen manifest.json prüft (Pflichtfelder, verbotene Felder, CSRF, Cookies),
* jede Anfrage als JSON-Zeile in ein Server-Log schreibt (02 §5.3).

Der Online-Zustand gilt pro Client-IP. Alle Werte im Log sind Dummy-Testdaten (02 §18).

Aufruf:
    python3 tools/test-portal/test_portal.py --port 8080 --portal 05_hotel
"""
from __future__ import annotations

import argparse
import json
import secrets
import sys
import threading
import time
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

REPO_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_DIR = REPO_ROOT / "Packages" / "CaptiveCore" / "Tests" / "Fixtures" / "portals"

APPLE_SUCCESS = "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>"
SESSION_COOKIE = "portal_session"

# Benannte Routen aus 02 §5.3 → Fixture
ROUTES = {
    "/terms": "02_terms",
    "/login": "04_userpass",
    "/hotel": "05_hotel",
    "/multistage/1": "08_multistage_terms",
    "/multistage/2": "09_multistage_guest",
    "/dynamic": "11_hidden_csrf",
    "/changed-label": "10_changed_labels",
    "/js-required": "14_js_only",
}


class PortalState:
    """Gemeinsamer, threadsicherer Zustand des Fake-Portals."""

    def __init__(self, fixture_dir: Path, portal: str, log_path: Path | None):
        self.fixture_dir = fixture_dir
        self.manifest = json.loads((fixture_dir / "manifest.json").read_text(encoding="utf-8"))
        self.portal = portal
        self.log_path = log_path
        self.lock = threading.Lock()
        self.online: set[str] = set()
        # client -> {"session": str, "csrf": str, "stage_token": str}
        self.issued: dict[str, dict[str, str]] = {}
        self.events: list[dict] = []

    def fixture_names(self) -> list[str]:
        return sorted(self.manifest["fixtures"].keys())

    def log(self, event: dict) -> None:
        event = {"ts": round(time.time(), 3), **event}
        with self.lock:
            self.events.append(event)
            if self.log_path:
                with self.log_path.open("a", encoding="utf-8") as fh:
                    fh.write(json.dumps(event, ensure_ascii=False) + "\n")

    def reset(self) -> None:
        with self.lock:
            self.online.clear()
            self.issued.clear()
            self.events.clear()


class Handler(BaseHTTPRequestHandler):
    server_version = "CaptiveAITestPortal/1.0"
    state: PortalState  # wird in make_server gesetzt

    # ---- Hilfsfunktionen -------------------------------------------------
    def log_message(self, fmt: str, *args) -> None:  # Standard-Stderr-Log unterdrücken
        pass

    @property
    def client(self) -> str:
        return self.client_address[0]

    def _cookies(self) -> dict[str, str]:
        jar = cookies.SimpleCookie(self.headers.get("Cookie", ""))
        return {k: v.value for k, v in jar.items()}

    def _send(self, status: int, body: str = "", headers: dict[str, str] | None = None,
              content_type: str = "text/html; charset=utf-8") -> None:
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _redirect(self, location: str, extra: dict[str, str] | None = None) -> None:
        self._send(303 if self.command == "POST" else 302, "", {"Location": location, **(extra or {})})

    def _issue(self) -> dict[str, str]:
        with self.state.lock:
            tokens = self.state.issued.get(self.client)
            if tokens is None or tokens.get("session") != self._cookies().get(SESSION_COOKIE):
                tokens = {"session": secrets.token_hex(8), "csrf": secrets.token_hex(8),
                          "stage_token": secrets.token_hex(8)}
                self.state.issued[self.client] = tokens
            return tokens

    def _serve_fixture(self, name: str) -> None:
        path = self.state.fixture_dir / f"{name}.html"
        if name not in self.state.manifest["fixtures"] or not path.exists():
            self._send(404, "<h1>Unknown fixture</h1>")
            return
        tokens = self._issue()
        html = path.read_text(encoding="utf-8")
        html = html.replace("{{csrf}}", tokens["csrf"]).replace("{{stage_token}}", tokens["stage_token"])
        self._send(200, html, {"Set-Cookie": f"{SESSION_COOKIE}={tokens['session']}; Path=/; HttpOnly"})

    def _form(self) -> dict[str, str]:
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8") if length else ""
        # Bei mehrfach vorkommenden Namen gewinnt der letzte Wert (wie viele Portal-Backends)
        return {k: v[-1] for k, v in parse_qs(raw, keep_blank_values=True).items()}

    # ---- Login-Prüfung ---------------------------------------------------
    def _check(self, fixture: str, form: dict[str, str]) -> list[str]:
        spec = self.state.manifest["fixtures"].get(fixture)
        if spec is None:
            return [f"unknown fixture '{fixture}'"]
        values = self.state.manifest["testValues"]
        tokens = self.state.issued.get(self.client, {})
        errors: list[str] = []
        if tokens.get("session") is None or self._cookies().get(SESSION_COOKIE) != tokens.get("session"):
            errors.append("missing or wrong session cookie")
        for field, expected in spec.get("required", {}).items():
            if expected == "$issued":
                # CSRF-artige Felder → csrf-Token, Challenge/Stage-Felder → stage_token
                key = "csrf" if "csrf" in field.lower() else "stage_token"
                expected = tokens.get(key)
            elif isinstance(expected, str) and expected.startswith("$"):
                expected = values[expected[1:]]
            if form.get(field) != expected:
                errors.append(f"field '{field}' missing or wrong")
        for field in spec.get("forbidden", []):
            if field in form:
                errors.append(f"forbidden field '{field}' was submitted")
        if fixture == "13_paid_upgrade" and form.get("tier") == "premium":
            errors.append("paid upgrade was triggered")
        return errors

    # ---- HTTP-Methoden ---------------------------------------------------
    def do_HEAD(self) -> None:
        self.do_GET()

    def do_GET(self) -> None:
        url = urlsplit(self.path)
        path = url.path
        self.state.log({"client": self.client, "method": "GET", "path": path,
                        "cookie": self._cookies().get(SESSION_COOKIE)})

        if path == "/hotspot-detect.html":
            if self.client in self.state.online:
                self._send(200, APPLE_SUCCESS)
            else:
                self._redirect(f"/portal?fixture={self.state.portal}")
            return
        if path == "/portal":
            name = parse_qs(url.query).get("fixture", [self.state.portal])[0]
            self._serve_fixture(name)
            return
        if path.startswith("/fixtures/"):
            self._serve_fixture(path.removeprefix("/fixtures/").removesuffix(".html"))
            return
        if path in ROUTES:
            self._serve_fixture(ROUTES[path])
            return
        if path == "/success":
            self._send(200, "<h1>Connected</h1><p>You are now online. Success.</p>")
            return
        if path == "/terms-of-use":
            self._send(200, "<h1>Terms of Use</h1><p>Lorem ipsum.</p>")
            return
        if path == "/__log":
            self._send(200, json.dumps(self.state.events, ensure_ascii=False), content_type="application/json")
            return
        if path == "/":
            links = "".join(f'<li><a href="/fixtures/{n}">{n}</a></li>' for n in self.state.fixture_names())
            self._send(200, f"<h1>CaptiveAI Test Portal</h1><ul>{links}</ul>")
            return
        self._send(404, "<h1>Not found</h1>")

    def do_POST(self) -> None:
        path = urlsplit(self.path).path
        form = self._form()
        fixture = form.get("fixture", "")
        self.state.log({"client": self.client, "method": "POST", "path": path, "form": form,
                        "cookie": self._cookies().get(SESSION_COOKIE)})

        if path == "/__reset":
            self.state.reset()
            self._send(204)
            return
        if path == "/__config":
            portal = form.get("portal", "")
            if portal not in self.state.manifest["fixtures"]:
                self._send(400, "unknown portal")
                return
            self.state.portal = portal
            self._send(204)
            return
        if path == "/multistage/1":
            errors = self._check("08_multistage_terms", form)
            if errors:
                self.state.log({"client": self.client, "result": "rejected", "fixture": fixture, "errors": errors})
                self._send(400, "<h1>Please accept the terms</h1>")
                return
            self._redirect("/multistage/2")
            return
        if path == "/auth":
            errors = self._check(fixture, form)
            if errors:
                self.state.log({"client": self.client, "result": "rejected", "fixture": fixture, "errors": errors})
                self._send(400, "<h1>Login failed</h1><ul>" + "".join(f"<li>{e}</li>" for e in errors) + "</ul>")
                return
            with self.state.lock:
                self.state.online.add(self.client)
            self.state.log({"client": self.client, "result": "online", "fixture": fixture})
            self._redirect("/success")
            return
        self._send(404, "<h1>Not found</h1>")


def make_server(host: str, port: int, portal: str, log_path: Path | None = None,
                fixture_dir: Path = FIXTURE_DIR) -> ThreadingHTTPServer:
    state = PortalState(fixture_dir, portal, log_path)
    if portal not in state.manifest["fixtures"]:
        raise SystemExit(f"Unbekanntes Portal '{portal}'. Verfügbar: {', '.join(state.fixture_names())}")
    handler = type("BoundHandler", (Handler,), {"state": state})
    return ThreadingHTTPServer((host, port), handler)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--portal", default="05_hotel", help="Fixture hinter /hotspot-detect.html")
    parser.add_argument("--log", type=Path, default=None, help="JSONL-Server-Log")
    args = parser.parse_args(argv)
    server = make_server(args.host, args.port, args.portal, args.log)
    print(f"Test-Portal läuft auf http://{args.host}:{args.port}/ (Portal: {args.portal})", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
