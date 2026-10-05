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
    /// Von außen geöffnete Recipe-Datei (onOpenURL, Drag & Drop) wartet auf Zuordnung und Bestätigung.
    var pendingImport: PendingImport?

    struct PendingImport: Identifiable { let id = UUID(); var yaml: String; var profileID: UUID? }

    /// Geöffnetes `.captiveprofile` wartet auf Vorschau und Bestätigung.
    var pendingProfileImport: PendingProfileImport?

    struct PendingProfileImport: Identifiable { let id = UUID(); var data: Data }

    /// Zentraler Einstieg für geöffnete Dateien (onOpenURL, Dateiauswahl, Drag and Drop).
    func open(_ url: URL, recipeTarget: UUID? = nil) {
        if url.pathExtension.lowercased() == ProfileExporter.fileExtension {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url), data.count <= ProfileImporter.maxContainerBytes {
                pendingProfileImport = PendingProfileImport(data: data)
            }
        } else {
            openRecipeFile(url, profileID: recipeTarget)
        }
    }

    /// Erzeugt die Exportdatei im temporären Verzeichnis. Zugangsdaten nur mit Opt-in (SPEC §3.4).
    func exportFile(profileID: UUID, includeCredentials: Bool, passphrase: String?, unencryptedConfirmed: Bool) throws -> URL {
        guard let p = profile(profileID) else { throw SharingError.noCredentialsToShare }
        var credentials: SharedCredentials?
        if includeCredentials {
            var values: [String: String] = [:]
            for b in p.credentialBindings where b.persistence == .rememberInKeychain {
                if let v = (try? secrets.read(b.keychainKey)) ?? nil, !v.isEmpty { values[b.concept] = v }
            }
            let wifi = p.wifi?.passphraseKeychainKey.flatMap { (try? secrets.read($0)) ?? nil }
            credentials = SharedCredentials(values: values, wifiPassphrase: wifi)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        let data = try ProfileExporter.export(
            profile: p, credentials: credentials,
            options: ExportOptions(includeCredentials: includeCredentials, passphrase: passphrase,
                                   confirmedUnencrypted: unencryptedConfirmed, appVersion: version),
            cipher: CryptoKitCredentialCipher())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(ProfileExporter.filename(for: p))
        try data.write(to: url, options: .atomic)
        return url
    }

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

    /// Liest eine Recipe-Datei und ordnet sie über profileId oder SSID einem Profil zu.
    func openRecipeFile(_ url: URL, profileID: UUID? = nil) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count < 1_000_000,
              let yaml = String(data: data, encoding: .utf8) else { return }
        var target = profileID
        if target == nil, let recipe = try? PRLCodec.parse(yaml: yaml) {
            target = profiles.first { $0.id.uuidString == recipe.profileId }?.id
                ?? profiles.first { $0.network.ssidExact == recipe.ssid }?.id
        }
        pendingImport = PendingImport(yaml: yaml, profileID: target)
    }

    func debugBundleURL(for log: RunLog) -> URL? {
        guard let name = log.debugBundle else { return nil }
        let u = AppEnvironment.debugDirectory().appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
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
