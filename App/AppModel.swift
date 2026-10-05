import SwiftUI
import CaptiveCore
import CaptiveCoreApple

/// Zentraler App-Zustand. Profile liegen als JSON im App-Group-Container (ohne Secrets),
/// Secrets im Keychain.
@Observable @MainActor
final class AppModel {
    private(set) var profiles: [PortalProfile] = []
    let store: ProfileStore
    let secrets: any SecretStore
    let logs: RunLogStore
    private(set) var runLogs: [RunLog] = []
    private(set) var running: Set<UUID> = []

    init(store: ProfileStore, secrets: any SecretStore, logs: RunLogStore) {
        self.store = store
        self.secrets = secrets
        self.logs = logs
        reload()
    }

    static func make() -> AppModel {
        let model = AppModel(store: AppEnvironment.profileStore(), secrets: AppEnvironment.secrets(),
                             logs: AppEnvironment.runLogStore())
        if ProcessInfo.processInfo.arguments.contains("-seedHotel") { model.seedHotelProfile() }
        return model
    }

    func reload() {
        profiles = store.loadAll()
        runLogs = logs.all()
    }

    /// Meldet an. Das Ergebnis enthält fehlende Werte als `missingUserValue` samt Konzept.
    func login(_ id: UUID, askValues: [String: String] = [:]) async -> LoginReport? {
        guard let p = profile(id), !running.contains(id) else { return nil }
        running.insert(id)
        defer { running.remove(id) }
        let report = await AppEnvironment.login(profile: p, askValues: askValues)
        reload()
        return report
    }

    /// Testprofil für UI-Tests (`-seedHotel`): Nachname im Schlüsselbund, Zimmernummer wird erfragt.
    func seedHotelProfile() {
        let last = CredentialBinding(concept: "lastName", keychainKey: "seed.lastName", prompt: "Nachname", persistence: .rememberInKeychain)
        let room = CredentialBinding(concept: "roomNumber", keychainKey: "seed.room", prompt: "Zimmernummer", persistence: .askEveryTime)
        let intent = PortalIntent(instructions: [.acceptRequiredTerms, .acceptRequiredPrivacy,
                                                 .fill(concept: "roomNumber", source: .askWhenMissing),
                                                 .fill(concept: "lastName", source: .keychain), .submit])
        let p = PortalProfile(name: "Testhotel", network: .init(ssidExact: "Test_Guest"), intent: intent,
                              credentialBindings: [last, room])
        try? secrets.write("Example", for: "seed.lastName")
        try? store.save(p)
        reload()
    }

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
