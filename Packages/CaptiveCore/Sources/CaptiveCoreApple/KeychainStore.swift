#if canImport(Security)
import CaptiveCore
import Foundation
import Security

/// Gemeinsamer Keychain von App und Authentication Provider (01 §20.2).
/// Schutzklasse `AfterFirstUnlockThisDeviceOnly`: Hintergrundzugriff nach erstem Entsperren, kein Geräte-Transfer.
public struct KeychainStore: Sendable {
    public var service: String
    public var accessGroup: String?

    public init(service: String = "com.captiveai.credentials", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public enum Failure: Error, Equatable, Sendable {
        case unexpectedStatus(Int32)
    }

    private func query(_ key: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func set(_ value: String, for key: String) throws {
        let data = Data(value.utf8)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(key) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(key)
            add.merge(update) { _, new in new }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure.unexpectedStatus(status) }
    }

    /// Schreibt nur, wenn noch kein Wert existiert (Import-Regel 01 §31: nie überschreiben ohne Rückfrage).
    @discardableResult
    public func setIfAbsent(_ value: String, for key: String) throws -> Bool {
        if try get(key) != nil { return false }
        try set(value, for: key)
        return true
    }

    public func get(_ key: String) throws -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure.unexpectedStatus(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.unexpectedStatus(status) }
    }
}

/// `ValueProvider` auf Basis des Keychains. `ask`-Werte kommen aus der Pending-Übergabe (01 §4.5).
public struct KeychainValueProvider: ValueProvider {
    public var keychain: KeychainStore
    /// Keychain-Schlüssel für abgefragte Werte dieses Laufs, z. B. aus `PendingAuthentication.valueKeychainKey`.
    public var askedKeys: [Concept: String]
    public var profileValues: [String: String]

    public init(keychain: KeychainStore, askedKeys: [Concept: String] = [:], profileValues: [String: String] = [:]) {
        self.keychain = keychain
        self.askedKeys = askedKeys
        self.profileValues = profileValues
    }

    public func value(for source: ValueSource) async -> String? {
        switch source {
        case .literal(let v): return v
        case .keychain(let key): return try? keychain.get(key)
        case .ask(let concept): return askedKeys[concept].flatMap { try? keychain.get($0) }
        case .profile(let key): return profileValues[key]
        case .runtime: return nil
        }
    }
}
#endif
