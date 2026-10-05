import Foundation

/// Liefert Werte für Wertquellen. Die Apple-Implementierung liest den Keychain, Tests nutzen
/// `StaticValueProvider`. Rückgabe `nil` heißt: Wert fehlt (→ `missingUserValue`).
public protocol ValueProvider: Sendable {
    func value(for source: ValueSource) async -> String?
}

public struct StaticValueProvider: ValueProvider {
    public var keychain: [String: String]
    public var ask: [String: String]
    public var profile: [String: String]
    public var runtime: [String: String]

    public init(keychain: [String: String] = [:], ask: [String: String] = [:],
                profile: [String: String] = [:], runtime: [String: String] = [:]) {
        self.keychain = keychain
        self.ask = ask
        self.profile = profile
        self.runtime = runtime
    }

    public func value(for source: ValueSource) async -> String? {
        switch source {
        case .literal(let s): s
        case .keychain(let k): keychain[k]
        case .ask(let c): ask[c]
        case .profile(let k): profile[k]
        case .runtime(let c): runtime[c]
        }
    }
}

/// Ein im Lauf verwendeter sensibler Wert samt Platzhalter. Nur im Speicher: dient der
/// Redaktion von Debug-Paketen und wird nie serialisiert.
public struct SensitiveValue: Sendable, Equatable {
    public var value: String
    public var placeholder: String
}
