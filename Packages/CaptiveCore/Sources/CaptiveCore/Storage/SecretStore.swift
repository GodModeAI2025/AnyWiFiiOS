import Foundation

/// Ablage für Secrets und persönliche Werte (01 §20). Die Apple-Implementierung nutzt den
/// Keychain, Tests nutzen `InMemorySecretStore`. Werte landen nie in JSON, Logs oder Exporten.
public protocol SecretStore: Sendable {
    func read(_ key: String) throws -> String?
    func write(_ value: String, for key: String) throws
    func delete(_ key: String) throws
    func contains(_ key: String) -> Bool
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init(_ initial: [String: String] = [:]) { values = initial }

    public func read(_ key: String) throws -> String? { lock.withLock { values[key] } }
    public func write(_ value: String, for key: String) throws { lock.withLock { values[key] = value } }
    public func delete(_ key: String) throws { lock.withLock { _ = values.removeValue(forKey: key) } }
    public func contains(_ key: String) -> Bool { lock.withLock { values[key] != nil } }
}

/// Wertquellen aus Secret-Store, Profilwerten und einmalig eingegebenen Werten.
/// `ask`-Werte stammen aus der UI (Pending-Input), `keychain`/`profile` aus dem Store.
public struct StoreValueProvider: ValueProvider {
    public var secrets: any SecretStore
    public var askValues: [String: String]
    public var runtimeValues: [String: String]
    /// Mit Bindings fällt `keychain(key)` auf einen einmalig eingegebenen Wert desselben Konzepts
    /// zurück, solange er noch nicht im Schlüsselbund liegt (erster Lauf).
    public var bindings: [CredentialBinding]

    public init(secrets: any SecretStore, askValues: [String: String] = [:], runtimeValues: [String: String] = [:],
                bindings: [CredentialBinding] = []) {
        self.secrets = secrets
        self.askValues = askValues
        self.runtimeValues = runtimeValues
        self.bindings = bindings
    }

    public func value(for source: ValueSource) async -> String? {
        switch source {
        case .literal(let s): return s
        case .keychain(let k), .profile(let k):
            if let v = (try? secrets.read(k)) ?? nil { return v }
            if let b = bindings.first(where: { $0.keychainKey == k }) { return askValues[b.concept] }
            return nil
        case .ask(let c): return askValues[c]
        case .runtime(let c): return runtimeValues[c]
        }
    }
}
