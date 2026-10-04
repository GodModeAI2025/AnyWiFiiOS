"""Selbsttests für das Fake-Portal: python3 -m unittest discover -s tools/test-portal"""
from __future__ import annotations

import http.cookiejar
import json
import threading
import unittest
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser

import test_portal

MANIFEST = json.loads((test_portal.FIXTURE_DIR / "manifest.json").read_text(encoding="utf-8"))
VALUES = MANIFEST["testValues"]


class HiddenInputs(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.hidden: dict[str, str] = {}
        self.action: str | None = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "form" and self.action is None:
            self.action = a.get("action")
        if tag == "input" and a.get("type") == "hidden" and a.get("name"):
            self.hidden[a["name"]] = a.get("value", "")


class Client:
    def __init__(self, base: str) -> None:
        self.base = base
        self.opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),  # localhost nie über Proxy
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
        )

    def get(self, path: str) -> tuple[int, str, str]:
        try:
            with self.opener.open(self.base + path, timeout=5) as r:
                return r.status, r.geturl(), r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.geturl(), e.read().decode()

    def post(self, path: str, form: dict[str, str]) -> tuple[int, str, str]:
        data = urllib.parse.urlencode(form).encode()
        try:
            with self.opener.open(self.base + path, data=data, timeout=5) as r:
                return r.status, r.geturl(), r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.geturl(), e.read().decode()


def resolve(value: str, hidden: dict[str, str], field: str) -> str:
    if value == "$issued":
        return hidden[field]
    if value.startswith("$"):
        return VALUES[value[1:]]
    return value


class PortalTests(unittest.TestCase):
    def setUp(self) -> None:
        self.server = test_portal.make_server("127.0.0.1", 0, "05_hotel")
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.client = Client(self.base)

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def login_like_oracle(self, fixture: str) -> tuple[int, str, str]:
        """Sendet genau die im Manifest geforderten Felder (Referenz für die Engine)."""
        _, _, html = self.client.get(f"/fixtures/{fixture}")
        parser = HiddenInputs()
        parser.feed(html)
        spec = MANIFEST["fixtures"][fixture]
        form = {"fixture": parser.hidden.get("fixture", fixture)}
        for k, v in parser.hidden.items():
            form[k] = v
        for field, value in spec.get("required", {}).items():
            form[field] = resolve(value, parser.hidden, field)
        return self.client.post(parser.action or "/auth", form)

    def test_probe_redirects_until_login(self):
        status, url, body = self.client.get("/hotspot-detect.html")
        self.assertEqual(status, 200)
        self.assertIn("/portal?fixture=05_hotel", url)
        self.assertNotIn("Success</BODY>", body)
        status, url, _ = self.login_like_oracle("05_hotel")
        self.assertEqual((status, urllib.parse.urlsplit(url).path), (200, "/success"))
        status, _, body = self.client.get("/hotspot-detect.html")
        self.assertIn("<BODY>Success</BODY>", body)

    def test_every_success_fixture_accepts_correct_form(self):
        for name, spec in MANIFEST["fixtures"].items():
            if spec["expectedOutcome"] != "success" or name == "09_multistage_guest" or spec.get("swiftOnly"):
                continue
            with self.subTest(fixture=name):
                self.client = Client(self.base)
                status, url, body = self.login_like_oracle(name)
                self.assertEqual(status, 200, body)
                self.assertTrue(url.endswith("/success"))

    def test_multistage_flow(self):
        status, url, html = self.login_like_oracle("08_multistage_terms")
        self.assertEqual(status, 200)
        self.assertTrue(url.endswith("/multistage/2"))
        parser = HiddenInputs()
        parser.feed(html)
        form = dict(parser.hidden)
        form.update(room_no=VALUES["roomNumber"], surname=VALUES["lastName"])
        status, url, _ = self.client.post("/auth", form)
        self.assertEqual(status, 200)
        self.assertTrue(url.endswith("/success"))

    def test_missing_cookie_is_rejected(self):
        _, _, html = self.client.get("/fixtures/11_hidden_csrf")
        parser = HiddenInputs()
        parser.feed(html)
        fresh = Client(self.base)  # andere Cookie-Jar, gleicher Client-Host
        form = dict(parser.hidden, username=VALUES["username"], password=VALUES["password"], action="login")
        status, _, body = fresh.post("/auth", form)
        self.assertEqual(status, 400)
        self.assertIn("session cookie", body)

    def test_wrong_csrf_is_rejected(self):
        self.client.get("/fixtures/11_hidden_csrf")
        form = {"fixture": "11_hidden_csrf", "csrf": "nope", "username": VALUES["username"],
                "password": VALUES["password"], "action": "login"}
        status, _, body = self.client.post("/auth", form)
        self.assertEqual(status, 400)
        self.assertIn("csrf", body)

    def test_preselected_newsletter_must_be_unchecked(self):
        self.client.get("/fixtures/12_optional_marketing")
        status, _, body = self.client.post("/auth", {"fixture": "12_optional_marketing", "terms": "1", "newsletter": "1"})
        self.assertEqual(status, 400)
        self.assertIn("newsletter", body)

    def test_premium_is_rejected(self):
        self.client.get("/fixtures/13_paid_upgrade")
        status, _, body = self.client.post("/auth", {"fixture": "13_paid_upgrade", "terms": "1", "tier": "premium"})
        self.assertEqual(status, 400)
        self.assertIn("paid upgrade", body)

    def test_js_only_has_no_server_side_form(self):
        _, _, html = self.client.get("/js-required")
        self.assertNotIn("<form", html.split("<script>")[0])

    def test_named_routes_exist(self):
        for route in test_portal.ROUTES:
            with self.subTest(route=route):
                status, _, _ = self.client.get(route)
                self.assertEqual(status, 200)

    def test_server_log_records_requests(self):
        self.login_like_oracle("02_terms")
        _, _, raw = self.client.get("/__log")
        events = json.loads(raw)
        self.assertTrue(any(e.get("result") == "online" and e.get("fixture") == "02_terms" for e in events))


if __name__ == "__main__":
    unittest.main()
