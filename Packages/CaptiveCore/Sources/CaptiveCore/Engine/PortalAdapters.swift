import Foundation

/// Fest eingebaute Login-Logik für bekannte Portalsysteme ohne verwertbares HTML-Formular (ADR 0001).
/// Ein Adapter ist reviewter Produktcode. Recipes können ihn nur per ID aufrufen, nie erweitern.
public protocol PortalAdapter: Sendable {
    var id: String { get }
    /// Erkennt das Portal an Host, Pfad oder Seiteninhalt.
    func detect(_ page: PortalPage) -> Bool
    func login(session: inout PortalHTTPSession, page: PortalPage, values: any ValueProvider,
               trace: inout RunTrace) async throws -> PortalAdapterResult
}

public enum PortalAdapterResult: Sendable, Equatable {
    /// Der Adapter hat eingeloggt. Die Engine prüft danach trotzdem per Probe.
    case loggedIn
    case failed(String)
}

public struct PortalAdapterRegistry: Sendable {
    public var adapters: [String: any PortalAdapter]

    public init(_ adapters: [any PortalAdapter]) {
        self.adapters = Dictionary(adapters.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public static let standard = PortalAdapterRegistry([IcomeraCNAAdapter()])

    /// IDs, die der `RecipeValidator` akzeptiert. Muss zu `Schemas/prl-v1.schema.json` passen.
    public static let knownIDs: Set<String> = ["icomeraCNA"]

    public func adapter(id: String) -> (any PortalAdapter)? { adapters[id] }
}

// MARK: - DB ICE (Icomera, neue Generation)

/// DB WIFIonICE mit JSON-Login (`POST /cna/logon`), siehe docs/research/portale-bahn-hotel.md.
/// Quelle: Open-Source-Bibliothek onboardapis. Auf echter Hardware noch nicht verifiziert.
public struct IcomeraCNAAdapter: PortalAdapter {
    public let id = "icomeraCNA"
    public var hosts: [String] = ["login.wifionice.de"]

    public init() {}

    public func detect(_ page: PortalPage) -> Bool {
        guard let host = page.url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }

    public func login(session: inout PortalHTTPSession, page: PortalPage, values: any ValueProvider,
                      trace: inout RunTrace) async throws -> PortalAdapterResult {
        guard let host = page.url.host, let base = URL(string: "https://\(host)") else {
            return .failed("Portal-Host fehlt")
        }
        let headers = [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "X-Csrf-Token": "csrf",
        ]
        let logon = try await session.perform(PortalRequest(
            method: "POST", url: base.appendingPathComponent("cna/logon"), headers: headers, body: Data("{}".utf8)))
        trace.record(.adapter, "POST \(host)/cna/logon → \(logon.final.status)")
        guard (200..<300).contains(logon.final.status) else {
            return .failed("cna/logon antwortet mit \(logon.final.status)")
        }

        let info = try await session.perform(PortalRequest(
            method: "GET", url: base.appendingPathComponent("cna/wifi/user_info"), headers: ["Accept": "application/json"]))
        trace.record(.adapter, "GET \(host)/cna/wifi/user_info → \(info.final.status)")
        return Self.isAuthenticated(info.final.body) ? .loggedIn : .failed("user_info meldet nicht angemeldet")
    }

    /// `{"result": {"authenticated": "1"}}`. Toleriert auch Zahl oder Bool.
    static func isAuthenticated(_ body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let result = json["result"] as? [String: Any] else { return false }
        switch result["authenticated"] {
        case let s as String: return s == "1" || s.lowercased() == "true"
        case let b as Bool: return b
        case let i as Int: return i == 1
        default: return false
        }
    }
}
