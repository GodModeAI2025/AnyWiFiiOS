import Foundation
@testable import CaptiveCore

/// manifest.json der Testportale (gemeinsame Quelle mit tools/test-portal).
struct PortalManifest: Decodable, Sendable {
    struct Fixture: Decodable, Sendable {
        let expectedOutcome: String
        let required: [String: String]?
        let forbidden: [String]?
        let swiftOnly: Bool?
        let adapter: String?
    }

    let testValues: [String: String]
    let fixtures: [String: Fixture]

    static func load() throws -> PortalManifest {
        let url = Fixtures.root.appendingPathComponent("portals/manifest.json")
        return try JSONDecoder().decode(PortalManifest.self, from: Data(contentsOf: url))
    }
}

/// Zustand des Fake-Portals (ein Client).
actor FakePortalState {
    var online = false
    let session = "s" + UUID().uuidString.prefix(8)
    let csrf = "c" + UUID().uuidString.prefix(8)
    let stageToken = "t" + UUID().uuidString.prefix(8)
    private(set) var requests: [PortalRequest] = []
    private(set) var rejections: [[String]] = []

    func setOnline(_ value: Bool) { online = value }
    func record(_ request: PortalRequest) { requests.append(request) }
    func reject(_ errors: [String]) { rejections.append(errors) }
}

/// In-Memory-Captive-Portal als `PortalTransport`. Spiegelt tools/test-portal/test_portal.py und
/// ergänzt Hosts für Adapter (login.wifionice.de) und Meraki (n123.network-auth.com, example.com).
struct FakePortal: PortalTransport {
    static let portalHost = "portal.test"
    static let merakiEntry = "http://portal.test/splash?base_grant_url=https%3A%2F%2Fn123.network-auth.com%2Fsplash%2Fgrant&user_continue_url=http%3A%2F%2Fexample.com%2F&node_mac=02%3A00%3A00%3A00%3A00%3A01"

    let portal: String
    let manifest: PortalManifest
    let state = FakePortalState()
    /// Zusätzliche Seiten auf portal.test (Pfad → HTML), z. B. für Sicherheitstests.
    var extraPages: [String: String] = [:]
    /// Überschreibt das Redirect-Ziel des Apple-Probes.
    var entryURL: String?

    init(portal: String, manifest: PortalManifest) {
        self.portal = portal
        self.manifest = manifest
    }

    var defaultEntry: String {
        switch portal {
        case "17_icomera_cna": "http://login.wifionice.de/"
        case "19_meraki_clickthrough": Self.merakiEntry
        default: "http://\(Self.portalHost)/portal?fixture=\(portal)"
        }
    }

    func send(_ request: PortalRequest) async throws -> PortalResponse {
        await state.record(request)
        let host = request.url.host ?? ""
        let path = request.url.path.isEmpty ? "/" : request.url.path
        let query = Self.query(request.url)

        switch host {
        case "captive.apple.com":
            if await state.online {
                return Self.html(200, "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>", request.url)
            }
            return Self.redirect(302, to: entryURL ?? defaultEntry, from: request.url)

        case Self.portalHost:
            return try await portalTest(request, path: path, query: query)

        case "login.wifionice.de":
            return try await icomeraCNA(request, path: path)

        case "n123.network-auth.com":
            guard path == "/splash/grant", let next = query["continue_url"], query["duration"] == "3600" else {
                return Self.html(400, "bad grant", request.url)
            }
            await state.setOnline(true)
            return Self.redirect(302, to: next, from: request.url)

        case "example.com":
            return Self.html(200, "<h1>Example Domain</h1>", request.url)

        default:
            return Self.html(502, "unknown host \(host)", request.url)
        }
    }

    // MARK: portal.test

    private func portalTest(_ request: PortalRequest, path: String, query: [String: String]) async throws -> PortalResponse {
        if request.method == "GET" {
            if let extra = extraPages[path] {
                return Self.html(200, extra, request.url, cookies: [await sessionCookie()])
            }
            switch path {
            case "/portal": return try await fixture(query["fixture"] ?? portal, request.url)
            case "/multistage/2": return try await fixture("09_multistage_guest", request.url)
            case "/splash":
                var html = try Self.fixtureHTML("19_meraki_clickthrough")
                html = html.replacingOccurrences(of: "{{base_grant_url}}", with: query["base_grant_url"] ?? "")
                html = html.replacingOccurrences(of: "{{user_continue_url}}", with: query["user_continue_url"] ?? "")
                return Self.html(200, html, request.url, cookies: [await sessionCookie()])
            case "/success": return Self.html(200, "<h1>Connected</h1><p>You are now online.</p>", request.url)
            default:
                if path.hasPrefix("/fixtures/") {
                    return try await fixture(String(path.dropFirst("/fixtures/".count)), request.url)
                }
                return Self.html(404, "not found", request.url)
            }
        }

        let form = Dictionary(FormEncoding.decode(String(decoding: request.body ?? Data(), as: UTF8.self)),
                              uniquingKeysWith: { _, last in last })
        let cookieOK = await hasSessionCookie(request)
        switch path {
        case "/multistage/1":
            let errors = await check("08_multistage_terms", form, cookieOK: cookieOK)
            guard errors.isEmpty else { await state.reject(errors); return Self.html(400, "terms", request.url) }
            return Self.redirect(303, to: "/multistage/2", from: request.url)
        case "/auth":
            let errors = await check(form["fixture"] ?? "", form, cookieOK: cookieOK)
            guard errors.isEmpty else {
                await state.reject(errors)
                return Self.html(400, "<h1>Login failed</h1>", request.url)
            }
            await state.setOnline(true)
            return Self.redirect(303, to: "/success", from: request.url)
        default:
            return Self.html(404, "not found", request.url)
        }
    }

    private func check(_ fixture: String, _ form: [String: String], cookieOK: Bool) async -> [String] {
        guard let spec = manifest.fixtures[fixture] else { return ["unknown fixture \(fixture)"] }
        var errors: [String] = cookieOK ? [] : ["session cookie"]
        for (field, expected) in spec.required ?? [:] {
            let wanted: String?
            if expected == "$issued" {
                wanted = field.lowercased().contains("csrf") ? state.csrf : state.stageToken
            } else if expected.hasPrefix("$") {
                wanted = manifest.testValues[String(expected.dropFirst())]
            } else {
                wanted = expected
            }
            if form[field] != wanted { errors.append("field \(field)") }
        }
        for field in spec.forbidden ?? [] where form[field] != nil {
            errors.append("forbidden \(field)")
        }
        if fixture == "13_paid_upgrade", form["tier"] == "premium" { errors.append("paid upgrade") }
        return errors
    }

    // MARK: login.wifionice.de (Icomera CNA)

    private func icomeraCNA(_ request: PortalRequest, path: String) async throws -> PortalResponse {
        switch (request.method, path) {
        case ("GET", "/"):
            return Self.html(200, try Self.fixtureHTML("17_icomera_cna"), request.url, cookies: [await sessionCookie()])
        case ("POST", "/cna/logon"):
            guard request.headers["X-Csrf-Token"] == "csrf",
                  request.headers["Content-Type"] == "application/json" else {
                return Self.json(403, #"{"error":"csrf"}"#, request.url)
            }
            await state.setOnline(true)
            return Self.json(200, #"{"result":{"status":"ok"}}"#, request.url)
        case ("GET", "/cna/wifi/user_info"):
            let authenticated = await state.online ? "1" : "0"
            return Self.json(200, #"{"result":{"authenticated":"\#(authenticated)"}}"#, request.url)
        default:
            return Self.json(404, #"{"error":"not found"}"#, request.url)
        }
    }

    // MARK: Hilfen

    private func fixture(_ name: String, _ url: URL) async throws -> PortalResponse {
        var html = try Self.fixtureHTML(name)
        html = html.replacingOccurrences(of: "{{csrf}}", with: state.csrf)
        html = html.replacingOccurrences(of: "{{stage_token}}", with: state.stageToken)
        return Self.html(200, html, url, cookies: [await sessionCookie()])
    }

    private func sessionCookie() async -> String { "portal_session=\(state.session); Path=/; HttpOnly" }

    private func hasSessionCookie(_ request: PortalRequest) async -> Bool {
        (request.headers["Cookie"] ?? "").contains("portal_session=\(state.session)")
    }

    static func fixtureHTML(_ name: String) throws -> String {
        try String(contentsOf: Fixtures.root.appendingPathComponent("portals/\(name).html"), encoding: .utf8)
    }

    static func html(_ status: Int, _ body: String, _ url: URL, cookies: [String] = []) -> PortalResponse {
        PortalResponse(status: status, url: url, headers: ["Content-Type": "text/html; charset=utf-8"],
                       setCookies: cookies, body: Data(body.utf8))
    }

    static func json(_ status: Int, _ body: String, _ url: URL) -> PortalResponse {
        PortalResponse(status: status, url: url, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
    }

    static func redirect(_ status: Int, to location: String, from url: URL) -> PortalResponse {
        PortalResponse(status: status, url: url, headers: ["Location": location])
    }

    static func query(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }
}
