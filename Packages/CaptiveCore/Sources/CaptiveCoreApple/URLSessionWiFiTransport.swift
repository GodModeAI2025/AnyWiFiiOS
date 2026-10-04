#if canImport(Darwin)
import CaptiveCore
import Foundation

/// Transport für den Manuellen Modus (SPEC §3.5): normale App, URLSession, nur WLAN.
/// Folgt keinen Redirects und speichert keine Cookies; beides macht `PortalHTTPSession`.
/// Gate S13 prüft auf echter Hardware, ob Anfragen im Captive-Zustand wirklich über WLAN laufen.
public final class URLSessionWiFiTransport: NSObject, PortalTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!

    public init(timeout: TimeInterval = 8) {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func send(_ request: PortalRequest) async throws -> PortalResponse {
        try await Self.send(request, using: session, configure: { _ in })
    }

    /// Redirects nicht automatisch folgen, damit die Engine Hosts und Cookies selbst verwaltet.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        nil
    }

    static func send(_ request: PortalRequest, using session: URLSession,
                     configure: (NSMutableURLRequest) -> Void) async throws -> PortalResponse {
        let mutable = NSMutableURLRequest(url: request.url)
        mutable.httpMethod = request.method
        mutable.httpBody = request.body
        mutable.httpShouldHandleCookies = false
        for (name, value) in request.headers { mutable.setValue(value, forHTTPHeaderField: name) }
        configure(mutable)

        let (data, response) = try await session.data(for: mutable as URLRequest)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String, k.lowercased() != "set-cookie" { headers[k] = v }
        }
        // Set-Cookie sauber zerlegen (mehrere Cookies stehen sonst kommagetrennt in einem Header).
        var fields: [String: String] = [:]
        if let raw = http.value(forHTTPHeaderField: "Set-Cookie") { fields["Set-Cookie"] = raw }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: request.url).map { cookie -> String in
            var line = "\(cookie.name)=\(cookie.value)"
            if cookie.domain.hasPrefix(".") { line += "; Domain=\(cookie.domain)" }
            return line
        }
        return PortalResponse(status: http.statusCode, url: request.url, headers: headers, setCookies: cookies, body: data)
    }
}
#endif
