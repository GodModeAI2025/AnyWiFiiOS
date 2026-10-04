#if os(iOS) && canImport(NetworkExtension)
import Foundation
import NetworkExtension
import CaptiveCore

/// Transport im Provider-Modus (SPEC §3.5): Anfragen werden per `bindToHotspotHelperCommand` an das
/// Hotspot-Interface gebunden. Spike S2 klärt Cookies, Hidden Fields und Redirects auf Gerät.
public final class HotspotCommandTransport: PortalTransport, @unchecked Sendable {
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private let command: NEHotspotHelperCommand
    private let session: URLSession
    private let delegate = NoRedirect()
    private let maxBytes: Int

    public init(command: NEHotspotHelperCommand, timeout: TimeInterval = 4, maxBytes: Int = 1_048_576) {
        self.command = command
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout * 2
        cfg.httpCookieAcceptPolicy = .always
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        self.maxBytes = maxBytes
    }

    public func send(_ request: PortalRequest) async throws -> PortalResponse {
        let req = NSMutableURLRequest(url: request.url)
        req.httpMethod = request.method.rawValue
        req.httpBody = request.body
        for (k, v) in request.headers { req.setValue(v, forHTTPHeaderField: k) }
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
        }
        req.bind(to: command)
        do {
            let (data, response) = try await session.data(for: req as URLRequest)
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
