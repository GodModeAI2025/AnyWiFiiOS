import Foundation
import CaptiveCore
import CaptiveCoreApple

/// Gemeinsame Ablageorte für App, App Intents und Control-Extension.
enum AppEnvironment {
    static let appGroup = "group.com.example.captiveai"
    static let keychainService = "com.example.captiveai"

    static var isUITest: Bool { ProcessInfo.processInfo.arguments.contains("-uitest") }

    private static let uitestRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("captive-uitest-\(UUID().uuidString)", isDirectory: true)
    private static let uitestSecrets = InMemorySecretStore()

    private static var base: URL {
        if isUITest { return uitestRoot }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    static func profileStore() -> ProfileStore { ProfileStore(directory: base.appendingPathComponent("Profiles", isDirectory: true)) }
    static func runLogStore() -> RunLogStore { RunLogStore(directory: base.appendingPathComponent("RunLogs", isDirectory: true)) }

    static func secrets() -> any SecretStore {
        if isUITest { return uitestSecrets }
        #if targetEnvironment(simulator)
        let group: String? = nil
        #else
        let group = Bundle.main.object(forInfoDictionaryKey: "CaptiveKeychainGroup") as? String
        #endif
        return KeychainSecretStore(service: keychainService, accessGroup: group)
    }

    /// Probe-URL. Standard ist Apples Captive-Erkennung, Tests übergeben `-probeURL`.
    static func engineConfig() -> EngineConfig {
        if let s = UserDefaults.standard.string(forKey: "probeURL"), let u = URL(string: s) {
            return EngineConfig(probeURL: u)
        }
        return EngineConfig()
    }

    /// Führt einen Anmeldeversuch aus und speichert Profil und Protokoll.
    static func login(profile: PortalProfile, askValues: [String: String] = [:]) async -> LoginReport {
        let report = await LoginCoordinator(transport: URLSessionWiFiTransport(), secrets: secrets(), config: engineConfig())
            .login(profile: profile, askValues: askValues)
        if report.profile != profile { try? profileStore().save(report.profile) }
        try? runLogStore().append(report.log)
        return report
    }
}
