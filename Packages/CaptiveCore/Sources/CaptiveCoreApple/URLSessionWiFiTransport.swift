#if canImport(Darwin)
import Foundation
import CaptiveCore

/// Transport für den Manuellen Modus (SPEC §3.5): Anfragen laufen nur über WLAN
/// (`allowsCellularAccess = false`), Redirects verfolgt `PortalHTTPClient`, Cookies verwaltet die Session.
public final class URLSessionWiFiTransport: PortalTransport, @unchecked Sendable {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private let session: URLSession
    private let delegate = NoRedirect()
    private let maxBytes: Int

    public init(timeout: TimeInterval = 5, maxBytes: Int = 1_048_576) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.allowsCellularAccess = false
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 3
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        self.maxBytes = maxBytes
    }

    public func send(_ request: PortalRequest) async throws -> PortalResponse {
        var req = URLRequest(url: request.url)
        req.httpMethod = request.method.rawValue
        req.httpBody = request.body
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            // Wie ein Systembrowser, damit Portale die Seite ausliefern.
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
        }
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw PortalError.network("Keine HTTP-Antwort") }
            var headers: [String: String] = [:]
            for (k, v) in http.allHeaderFields { if let k = k as? String, let v = v as? String { headers[k] = v } }
            let clipped = data.prefix(maxBytes)
            let body = String(data: clipped, encoding: .utf8) ?? String(data: clipped, encoding: .isoLatin1) ?? ""
            return PortalResponse(url: http.url ?? request.url, status: http.statusCode, headers: headers, body: body)
        } catch let e as URLError where e.code == .timedOut {
            throw PortalError.timeout
        } catch let e as PortalError {
            throw e
        } catch {
            throw PortalError.network((error as NSError).localizedDescription)
        }
    }
}
#endif
