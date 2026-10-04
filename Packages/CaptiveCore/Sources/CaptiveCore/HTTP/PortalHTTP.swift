import Foundation

// HTTP-Schicht der Engine (01 §17.1). Der eigentliche Transport ist austauschbar:
// - Provider-Modus: HotspotCommandTransport (an das Hotspot-Interface gebunden, CaptiveCoreApple)
// - Manueller Modus: URLSessionWiFiTransport (allowsCellularAccess = false, CaptiveCoreApple)
// - Tests: FakePortal
// Der Transport folgt KEINEN Redirects und verwaltet KEINE Cookies, das erledigt `PortalHTTPSession`.

public struct PortalRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct PortalResponse: Sendable, Equatable {
    public var status: Int
    /// URL der Anfrage, die diese Antwort erzeugt hat.
    public var url: URL
    /// Header mit kleingeschriebenen Namen. `Set-Cookie` steht separat in `setCookies`.
    public var headers: [String: String]
    public var setCookies: [String]
    public var body: Data

    public init(status: Int, url: URL, headers: [String: String] = [:], setCookies: [String] = [], body: Data = Data()) {
        self.status = status
        self.url = url
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
        self.setCookies = setCookies
        self.body = body
    }

    public var text: String { String(decoding: body, as: UTF8.self) }
    public var isRedirect: Bool { [301, 302, 303, 307, 308].contains(status) && headers["location"] != nil }
}

public protocol PortalTransport: Sendable {
    /// Sendet genau eine Anfrage. Keine Redirects, keine Cookie-Verwaltung.
    func send(_ request: PortalRequest) async throws -> PortalResponse
}

public enum PortalHTTPError: Error, Equatable, Sendable {
    case tooManyRedirects
    case responseTooLarge(bytes: Int)
    case invalidRedirect(String)
}

// MARK: - Cookies

/// Minimaler Cookie-Speicher für einen Login-Lauf. Wird nie persistiert (Cookies sind Session-Daten, 01 §21.2).
public struct CookieJar: Sendable, Equatable {
    struct Cookie: Sendable, Equatable {
        var domain: String
        var hostOnly: Bool
        var name: String
        var value: String
    }

    private(set) var cookies: [Cookie] = []

    public init() {}

    public mutating func store(setCookieHeaders: [String], from url: URL) {
        guard let host = url.host?.lowercased() else { return }
        for header in setCookieHeaders {
            let parts = header.split(separator: ";", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let first = parts.first, let eq = first.firstIndex(of: "=") else { continue }
            let name = String(first[..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(first[first.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }

            var domain = host
            var hostOnly = true
            var expired = false
            for attribute in parts.dropFirst() {
                let pair = attribute.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                let key = pair[0].lowercased()
                if key == "domain", pair.count == 2 {
                    var d = pair[1].lowercased()
                    if d.hasPrefix(".") { d.removeFirst() }
                    // Nur gleiche Domain oder Elterndomain zulassen.
                    if host == d || host.hasSuffix("." + d) {
                        domain = d
                        hostOnly = false
                    }
                } else if key == "max-age", pair.count == 2, let seconds = Int(pair[1]), seconds <= 0 {
                    expired = true
                }
            }
            cookies.removeAll { $0.domain == domain && $0.name == name }
            if !expired {
                cookies.append(Cookie(domain: domain, hostOnly: hostOnly, name: name, value: value))
            }
        }
    }

    public func value(named name: String, for url: URL) -> String? {
        matching(url).last { $0.name == name }?.value
    }

    public func headerValue(for url: URL) -> String? {
        let list = matching(url)
        guard !list.isEmpty else { return nil }
        return list.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func matching(_ url: URL) -> [Cookie] {
        guard let host = url.host?.lowercased() else { return [] }
        return cookies.filter { cookie in
            cookie.hostOnly ? host == cookie.domain : (host == cookie.domain || host.hasSuffix("." + cookie.domain))
        }
    }
}

// MARK: - Session (Redirects + Cookies)

public struct PortalExchange: Sendable, Equatable {
    /// Alle Antworten in Reihenfolge, inklusive Redirects. Die letzte ist die finale Antwort.
    public var responses: [PortalResponse]
    public var final: PortalResponse { responses[responses.count - 1] }
    /// Hosts aller beteiligten Antworten (für die vertrauenswürdige Host-Menge, 01 §25).
    public var hosts: [String] { responses.compactMap { $0.url.host?.lowercased() } }
}

public struct PortalHTTPSession: Sendable {
    public var transport: any PortalTransport
    public var cookies = CookieJar()
    public var maxRedirects = 10
    public var maxBodyBytes = 1_048_576
    public var userAgent = "CaptiveAI/1.0"

    public init(transport: any PortalTransport) {
        self.transport = transport
    }

    /// Sendet eine Anfrage und folgt Redirects (301/302/303 → GET, 307/308 behalten Methode und Body).
    public mutating func perform(_ initial: PortalRequest) async throws -> PortalExchange {
        var request = initial
        var responses: [PortalResponse] = []
        for _ in 0...maxRedirects {
            var outgoing = request
            if outgoing.headers["User-Agent"] == nil { outgoing.headers["User-Agent"] = userAgent }
            if let cookie = cookies.headerValue(for: outgoing.url) { outgoing.headers["Cookie"] = cookie }

            let response = try await transport.send(outgoing)
            if response.body.count > maxBodyBytes {
                throw PortalHTTPError.responseTooLarge(bytes: response.body.count)
            }
            cookies.store(setCookieHeaders: response.setCookies, from: response.url)
            responses.append(response)

            guard response.isRedirect, let location = response.headers["location"] else {
                return PortalExchange(responses: responses)
            }
            guard let next = URL(string: location, relativeTo: request.url)?.absoluteURL,
                  let scheme = next.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                throw PortalHTTPError.invalidRedirect(location)
            }
            if response.status == 307 || response.status == 308 {
                request = PortalRequest(method: request.method, url: next, headers: request.headers, body: request.body)
            } else {
                var headers = request.headers
                headers["Content-Type"] = nil
                request = PortalRequest(method: "GET", url: next, headers: headers, body: nil)
            }
        }
        throw PortalHTTPError.tooManyRedirects
    }

    public mutating func get(_ url: URL) async throws -> PortalExchange {
        try await perform(PortalRequest(method: "GET", url: url))
    }
}

// MARK: - Formular-Kodierung

public enum FormEncoding {
    /// application/x-www-form-urlencoded nach WHATWG URL-Standard (Leerzeichen → "+").
    public static func encode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(escape($0.0))=\(escape($0.1))" }.joined(separator: "&")
    }

    public static func decode(_ body: String) -> [(String, String)] {
        body.split(separator: "&", omittingEmptySubsequences: true).map { part in
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = unescape(String(kv[0]))
            let value = kv.count > 1 ? unescape(String(kv[1])) : ""
            return (key, value)
        }
    }

    private static let hexDigits = Array("0123456789ABCDEF")

    static func escape(_ string: String) -> String {
        var out = ""
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "*"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"):
                out.append(Character(Unicode.Scalar(byte)))
            case UInt8(ascii: " "):
                out.append("+")
            default:
                out.append("%")
                out.append(hexDigits[Int(byte >> 4)])
                out.append(hexDigits[Int(byte & 0x0F)])
            }
        }
        return out
    }

    static func unescape(_ string: String) -> String {
        let spaced = string.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}
