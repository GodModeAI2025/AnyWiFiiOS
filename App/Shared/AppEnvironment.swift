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

    static func debugDirectory() -> URL { base.appendingPathComponent("Debug", isDirectory: true) }

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

    /// Lokales Modell, falls verfügbar (SPEC §3.2). Ohne Modell bleibt Replay deterministisch und
    /// Lernen läuft regelbasiert.
    static func localAssistant() -> (any AssistantModel)? {
        // UI-Tests laufen deterministisch ohne Modell, außer `-useModel` ist gesetzt.
        if isUITest, !ProcessInfo.processInfo.arguments.contains("-useModel") { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 27.0, macOS 27.0, *) { return OnDeviceAssistant.make() }
        #endif
        return nil
    }

    /// Führt einen Anmeldeversuch aus und speichert Profil und Protokoll.
    static func login(profile: PortalProfile, askValues: [String: String] = [:]) async -> LoginReport {
        var planner: any PortalPlanner = HeuristicPlanner()
        var repairer: any RecipeRepairer = HeuristicRepairer()
        if let model = localAssistant(), await model.availability.isAvailable {
            planner = FallbackPlanner(primary: model)
            repairer = FallbackRepairer(primary: model)
        }
        let report = await LoginCoordinator(transport: URLSessionWiFiTransport(), secrets: secrets(), planner: planner,
                                            repairer: repairer, config: engineConfig())
            .login(profile: profile, askValues: askValues)
        if report.profile != profile { try? profileStore().save(report.profile) }
        var log = report.log
        if report.result.outcome != .success {
            log.debugBundle = await writeDebugBundle(profile: report.profile, report: report)
        }
        try? runLogStore().append(log)
        return report
    }

    /// Erzeugt nach jedem Lauf mit Ausgang ≠ success automatisch ein Debug-Paket (SPEC §3.3).
    @discardableResult
    static func writeDebugBundle(profile: PortalProfile, report: LoginReport, chat: [ChatLogMessage] = []) async -> String? {
        let availability = await localAssistant()?.availability
        let model: String = switch availability {
        case .some(.available): "available"
        case .some(.unavailable(let r)): "unavailable:\(r.rawValue)"
        case .none: "none"
        }
        var sys = utsname(); uname(&sys)
        let device = withUnsafePointer(to: &sys.machine) { $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) } }
        let env = DebugEnvironment(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString, device: device,
            modelAvailability: model, mode: "manual")
        do {
            let (name, data) = try DebugBundleBuilder.build(DebugBundleInput(
                profileName: profile.name, recipeRevision: profile.recipeRevision, startedAt: report.log.startedAt,
                intent: profile.intent, recipe: profile.recipe, run: report.result, environment: env, chat: chat))
            let dir = debugDirectory()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
            pruneDebugBundles(keep: 10)
            return name
        } catch { return nil }
    }

    static func pruneDebugBundles(keep: Int) {
        let dir = debugDirectory()
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "zip" }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for f in files.dropFirst(keep) { try? FileManager.default.removeItem(at: f) }
    }
}
