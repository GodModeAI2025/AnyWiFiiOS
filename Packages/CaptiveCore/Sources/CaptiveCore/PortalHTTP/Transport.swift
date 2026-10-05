import Foundation

public struct PortalRequest: Sendable, Equatable {
    public enum Method: String, Sendable { case get = "GET", post = "POST" }

    public var method: Method
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: Method = .get, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct PortalResponse: Sendable, Equatable {
    public var url: URL
    public var status: Int
    public var headers: [String: String]
    public var body: String

    public init(url: URL, status: Int, headers: [String: String] = [:], body: String = "") {
        self.url = url
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Transport-Adapter (SPEC §3.5). Redirects verfolgt der Transport nicht selbst, das macht
/// `PortalHTTPClient`. Cookies verwaltet der Transport (URLSession bzw. Hotspot-Session).
public protocol PortalTransport: Sendable {
    func send(_ request: PortalRequest) async throws -> PortalResponse
}

public enum PortalError: Error, Equatable, Sendable {
    case tooManyRedirects
    case invalidRedirect
    case network(String)
    case timeout
}

/// Ein Eintrag der Redirect-Kette bzw. des Netzwerkprotokolls (ohne Cookies/Authorization).
public struct NetworkEntry: Codable, Equatable, Sendable {
    public var method: String
    public var url: String
    public var status: Int
    public var host: String
    public var location: String?
}

public struct FetchResult: Sendable {
    public var response: PortalResponse
    public var entries: [NetworkEntry]
}

/// Folgt Redirects (max. 10), begrenzt Antwortgrößen (1 MB) und zeichnet die Kette auf (01 §17, §28).
public struct PortalHTTPClient: Sendable {
    public var transport: any PortalTransport
    public var maxRedirects: Int
    public var maxBodyBytes: Int

    public init(transport: any PortalTransport, maxRedirects: Int = 10, maxBodyBytes: Int = 1_048_576) {
        self.transport = transport
        self.maxRedirects = maxRedirects
        self.maxBodyBytes = maxBodyBytes
    }

    public func fetch(_ request: PortalRequest) async throws -> FetchResult {
        var current = request
        var entries: [NetworkEntry] = []
        var hops = 0
        while true {
            var response = try await transport.send(current)
            if response.body.utf8.count > maxBodyBytes {
                response.body = String(decoding: Array(response.body.utf8.prefix(maxBodyBytes)), as: UTF8.self)
            }
            let location = response.header("Location")
            entries.append(NetworkEntry(
                method: current.method.rawValue,
                url: Self.stripQuery(current.url),
                status: response.status,
                host: current.url.host ?? "",
                location: location.flatMap { URL(string: $0, relativeTo: current.url)?.absoluteURL }.map(Self.stripQuery)))
            guard (300..<400).contains(response.status), let location else {
                return FetchResult(response: response, entries: entries)
            }
            hops += 1
            guard hops <= maxRedirects else { throw PortalError.tooManyRedirects }
            guard let next = URL(string: location, relativeTo: current.url)?.absoluteURL,
                  let scheme = next.scheme, scheme == "http" || scheme == "https", next.host != nil else {
                throw PortalError.invalidRedirect
            }
            switch response.status {
            case 307, 308:
                current = PortalRequest(method: current.method, url: next, headers: current.headers, body: current.body)
            default:
                current = PortalRequest(method: .get, url: next, headers: current.headers.filter { $0.key.lowercased() != "content-type" })
            }
        }
    }

    /// Query-Werte können Tokens enthalten und gehören nie in Protokolle.
    static func stripQuery(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        if c.query != nil { c.query = "<redacted>" }
        c.fragment = nil
        c.user = nil
        c.password = nil
        return (c.string ?? url.absoluteString).replacingOccurrences(of: "%3Credacted%3E", with: "<redacted>")
    }
}

/// Captive-Erkennung (SPEC §3.5). Die Antwort enthält "Success", wenn das Gerät online ist.
public enum CaptiveProbe {
    public static let url = URL(string: "http://captive.apple.com/hotspot-detect.html")!

    public static func isSuccess(_ response: PortalResponse) -> Bool {
        response.status == 200 && response.body.contains("Success")
    }
}
