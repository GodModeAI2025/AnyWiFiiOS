import Foundation
@testable import CaptiveCore

enum Fixtures {
    static func html(_ name: String) -> String {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name).html")
        return try! String(contentsOf: url, encoding: .utf8)
    }
}

/// Testwerte aus 02 §18.
enum TestValues {
    static let username = "mark"
    static let password = "SuperSecret123"
    static let room = "417"
    static let surname = "Example"
    static let cookie = "SESSION=abcdef"
}

struct SiteStep: Sendable {
    var fixture: String
    var expect: [String: String] = [:]
    var requireFields: [String] = []
}

struct LoggedRequest: Sendable {
    var method: String
    var host: String
    var path: String
    var form: [String: String]
    var cookie: String?
}

/// Simuliert ein Captive Portal samt Probe-URL, Cookies, CSRF und mehrstufigem Ablauf.
actor MockPortalSite: PortalTransport {
    let steps: [SiteStep]
    private var index = 0
    private var authenticated = false
    private var cookieJar: [String: String] = [:]
    private var csrf = ""
    private(set) var log: [LoggedRequest] = []
    private(set) var rejectedPosts = 0
    var evilHits = 0

    init(steps: [SiteStep]) { self.steps = steps }

    func send(_ request: PortalRequest) async throws -> PortalResponse {
        let url = request.url
        let host = url.host ?? ""
        var form: [String: String] = [:]
        if let body = request.body, let s = String(data: body, encoding: .utf8) {
            for pair in s.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let k = String(kv[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
                let v = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "") : ""
                form[k] = v
            }
        }
        let cookie = cookieJar[host]
        log.append(LoggedRequest(method: request.method.rawValue, host: host, path: url.path, form: form, cookie: cookie))

        if host == "evil.example" { evilHits += 1; return PortalResponse(url: url, status: 200, body: "<html>thanks</html>") }
        if url.absoluteString == CaptiveProbe.url.absoluteString || host == "captive.apple.com" {
            if authenticated {
                return PortalResponse(url: url, status: 200, body: "<HTML><HEAD><TITLE>Success</TITLE></HEAD><BODY>Success</BODY></HTML>")
            }
            return redirect("http://portal.test/page/\(index)")
        }
        if host == "portal.test", url.path.hasPrefix("/page/") {
            return page(url)
        }
        if host == "portal.test", url.path == "/auth", request.method == .post {
            guard let step = steps[safe: index], cookie != nil else { rejectedPosts += 1; return page(URL(string: "http://portal.test/page/\(index)")!) }
            var ok = true
            for (k, v) in step.expect where form[k] != v { ok = false }
            for k in step.requireFields where (form[k] ?? "").isEmpty { ok = false }
            if Fixtures.html(step.fixture).contains("{{csrf}}"), form["csrf"] != csrf { ok = false }
            guard ok else { rejectedPosts += 1; return page(URL(string: "http://portal.test/page/\(index)")!) }
            index += 1
            if index >= steps.count { authenticated = true; return redirect("http://portal.test/success") }
            return redirect("http://portal.test/page/\(index)")
        }
        if host == "portal.test", url.path == "/success" {
            return PortalResponse(url: url, status: 200, body: "<html><body>You are connected</body></html>")
        }
        return PortalResponse(url: url, status: 404, body: "")
    }

    private func page(_ url: URL) -> PortalResponse {
        let n = Int(url.lastPathComponent) ?? index
        guard let step = steps[safe: n] else { return PortalResponse(url: url, status: 404, body: "") }
        csrf = "tok\(Int.random(in: 100000...999999))"
        cookieJar["portal.test"] = cookieJar["portal.test"] ?? "session=\(UUID().uuidString.prefix(8))"
        let html = Fixtures.html(step.fixture).replacingOccurrences(of: "{{csrf}}", with: csrf)
        return PortalResponse(url: url, status: 200, headers: ["Set-Cookie": cookieJar["portal.test"]!], body: html)
    }

    private func redirect(_ to: String) -> PortalResponse {
        PortalResponse(url: URL(string: to)!, status: 302, headers: ["Location": to], body: "")
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

enum Scenarios {
    static let clickthrough = [SiteStep(fixture: "01_clickthrough", expect: ["action": "continue"])]
    static let terms = [SiteStep(fixture: "02_terms", expect: ["terms": "1"])]
    static let termsPrivacy = [SiteStep(fixture: "03_terms_privacy", expect: ["terms": "1", "privacy": "1"])]
    static let userpass = [SiteStep(fixture: "04_userpass", expect: ["username": TestValues.username, "password": TestValues.password])]
    static let hotel = [SiteStep(fixture: "05_hotel", expect: ["room": TestValues.room, "lastname": TestValues.surname])]
    static let voucher = [SiteStep(fixture: "06_voucher", expect: ["voucher": "VOUCH-7788"])]
    static let email = [SiteStep(fixture: "07_email", expect: ["email": "guest@portal.invalid", "terms": "1"])]
    static let multistage = [
        SiteStep(fixture: "08_multistage_terms", expect: ["terms": "1"]),
        SiteStep(fixture: "09_multistage_guest", expect: ["room": TestValues.room, "lastname": TestValues.surname]),
    ]
    static let changed = [SiteStep(fixture: "10_changed_labels", expect: ["room": TestValues.room, "lastname": TestValues.surname])]
    static let csrf = [SiteStep(fixture: "11_hidden_csrf", expect: ["username": TestValues.username, "password": TestValues.password])]
    static let marketing = [SiteStep(fixture: "12_optional_marketing", expect: ["terms": "1"])]
    static let paid = [SiteStep(fixture: "13_paid_upgrade", expect: ["terms": "1"])]
    static let js = [SiteStep(fixture: "14_js_only")]
    static let malformed = [SiteStep(fixture: "15_malformed_html", expect: ["username": TestValues.username, "password": TestValues.password])]
    static let external = [SiteStep(fixture: "16_external_action", expect: ["username": TestValues.username])]
}

enum Kit {
    static let lastNameBinding = CredentialBinding(concept: "lastName", keychainKey: "hotel.lastName", prompt: "Nachname", persistence: .rememberInKeychain)
    static let usernameBinding = CredentialBinding(concept: "username", keychainKey: "portal.username", prompt: "Benutzer", persistence: .rememberInKeychain)
    static let passwordBinding = CredentialBinding(concept: "password", keychainKey: "portal.password", prompt: "Passwort", persistence: .rememberInKeychain)
    static let voucherBinding = CredentialBinding(concept: "voucherCode", keychainKey: "portal.voucher", prompt: "Gutschein", persistence: .rememberInKeychain)
    static let emailBinding = CredentialBinding(concept: "email", keychainKey: "portal.email", prompt: "E-Mail", persistence: .rememberInKeychain)

    static let values = StaticValueProvider(
        keychain: ["hotel.lastName": TestValues.surname, "portal.username": TestValues.username,
                   "portal.password": TestValues.password, "portal.voucher": "VOUCH-7788",
                   "portal.email": "guest@portal.invalid"],
        ask: ["roomNumber": TestValues.room])

    static func intent(_ ins: [IntentInstruction], policy: IntentPolicy = .init()) -> PortalIntent {
        PortalIntent(instructions: ins + [.submit], policy: policy)
    }

    static let terms: [IntentInstruction] = [.acceptRequiredTerms, .acceptRequiredPrivacy]
    static let hotelIntent = intent(terms + [.fill(concept: "roomNumber", source: .askWhenMissing), .fill(concept: "lastName", source: .keychain)])
    static let userpassIntent = intent([.fill(concept: "username", source: .keychain), .fill(concept: "password", source: .keychain)])
    static let allBindings = [lastNameBinding, usernameBinding, passwordBinding, voucherBinding, emailBinding]

    static func engine(_ site: MockPortalSite, values: StaticValueProvider = Kit.values,
                       policy: IntentPolicy = .init(), model: Bool = false) -> RunEngine {
        RunEngine(transport: site, values: values, intentPolicy: policy, bindings: allBindings, plannedByModel: model)
    }
}
