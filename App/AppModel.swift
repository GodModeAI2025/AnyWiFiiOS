import SwiftUI
import CaptiveCore
import CaptiveCoreApple

/// Zentraler App-Zustand. Profile liegen als JSON im App-Group-Container (ohne Secrets),
/// Secrets im Keychain.
@Observable @MainActor
final class AppModel {
    static let appGroup = "group.com.example.captiveai"
    static let keychainService = "com.example.captiveai"

    private(set) var profiles: [PortalProfile] = []
    let store: ProfileStore
    let secrets: any SecretStore

    init(store: ProfileStore, secrets: any SecretStore) {
        self.store = store
        self.secrets = secrets
        reload()
    }

    /// UI-Tests (`-uitest`) laufen isoliert: temporäres Verzeichnis, Secrets im Speicher.
    static func make() -> AppModel {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-uitest") {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("captive-uitest-\(UUID().uuidString)")
            return AppModel(store: ProfileStore(directory: dir), secrets: InMemorySecretStore())
        }
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let store = ProfileStore(directory: base.appendingPathComponent("Profiles", isDirectory: true))
        #if targetEnvironment(simulator)
        let group: String? = nil
        #else
        let group = Bundle.main.object(forInfoDictionaryKey: "CaptiveKeychainGroup") as? String
        #endif
        return AppModel(store: store, secrets: KeychainSecretStore(service: keychainService, accessGroup: group))
    }

    func reload() { profiles = store.loadAll() }

    func profile(_ id: UUID) -> PortalProfile? { profiles.first { $0.id == id } }

    @discardableResult
    func create(name: String, ssid: String) -> PortalProfile {
        let p = PortalProfile(
            name: name.trimmingCharacters(in: .whitespaces),
            network: NetworkMatcher(ssidExact: ssid.trimmingCharacters(in: .whitespaces)),
            intent: PortalIntent(instructions: [.submit]))
        try? store.save(p)
        reload()
        return p
    }

    func save(_ profile: PortalProfile) {
        var p = profile
        p.updatedAt = Date()
        try? store.save(p)
        reload()
    }

    func delete(_ id: UUID) {
        if let p = profile(id) {
            for b in p.credentialBindings { try? secrets.delete(b.keychainKey) }
            if let k = p.wifi?.passphraseKeychainKey { try? secrets.delete(k) }
        }
        try? store.delete(id)
        reload()
    }

    static func secretKey(profile: UUID, concept: String) -> String { "profile.\(profile.uuidString).\(concept)" }
    static func wifiKey(profile: UUID) -> String { "profile.\(profile.uuidString).wifi" }
}
