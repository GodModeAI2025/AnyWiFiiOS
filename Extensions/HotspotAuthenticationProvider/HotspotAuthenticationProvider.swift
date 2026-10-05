import ExtensionFoundation
import Foundation
import NetworkExtension
import UserNotifications
import os.log
import CaptiveCore
import CaptiveCoreApple

/// Lokale Benachrichtigung, wenn ein Wert fehlt. Enthält nur Profilname und Frage (01 §4.5).
struct LocalNotifier: UserNotifier {
    func notifyValueNeeded(profileName: String, prompt: String, runId: UUID) async {
        let content = UNMutableNotificationContent()
        content.title = profileName
        content.body = String(localized: "\(prompt) wird für die WLAN-Anmeldung gebraucht.")
        content.userInfo = ["runId": runId.uuidString]
        let request = UNNotificationRequest(identifier: runId.uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// Authentication Provider (01 §27): authenticate, presentUI, maintain, logoff.
/// Die Logik liegt in `AuthenticationCore` (CaptiveCore), hier nur die Abbildung auf das System.
@main
class HotspotAuthenticationProvider: NEHotspotAuthenticationProvider {
    private let logger = os.Logger(subsystem: "de.mobilebox.captiveai.authentication", category: "Provider")
    /// Merkt sich pro SSID den offenen Lauf, damit `presentUI` ihn fortsetzt.
    private let runs = RunTable()

    required init() {}

    func start() async -> Bool {
        logger.log("start")
        return true
    }

    func stop(reason: NEProviderStopReason) async {
        logger.log("stop")
    }

    private func core() -> AuthenticationCore {
        var planner: any PortalPlanner = HeuristicPlanner()
        var repairer: any RecipeRepairer = HeuristicRepairer()
        if let model = AppEnvironment.localAssistant() {
            planner = FallbackPlanner(primary: model)
            repairer = FallbackRepairer(primary: model)
        }
        return AuthenticationCore(
            profiles: AppEnvironment.profileStore(), runLogs: AppEnvironment.runLogStore(),
            pending: AppEnvironment.pendingStore(), secrets: AppEnvironment.secrets(), notifier: LocalNotifier(),
            planner: planner, repairer: repairer, config: AppEnvironment.engineConfig())
    }

    func handleCommand(_ command: NEHotspotHelperCommand) async -> NEHotspotHelperResponse {
        let transport = HotspotCommandTransport(command: command)
        let core = core()
        let ssid = command.network?.ssid ?? ""
        switch command.commandType {
        case .authenticate:
            let r = await core.authenticate(ssid: ssid, bssid: command.network?.bssid, transport: transport)
            if let id = r.runId, r.hotspot == .uiRequired { await runs.set(id, for: ssid) }
            logger.log("authenticate: \(String(describing: r.hotspot), privacy: .public)")
            return command.createResponse(Self.map(r.hotspot))
        case .presentUI:
            guard let id = await runs.take(ssid) else { return command.createResponse(.failure) }
            let r = await core.presentUI(runId: id, ssid: ssid, transport: transport)
            logger.log("presentUI: \(String(describing: r.hotspot), privacy: .public)")
            return command.createResponse(Self.map(r.hotspot))
        case .maintain:
            return command.createResponse(Self.map(await core.maintain(transport: transport)))
        case .logoff:
            return command.createResponse(Self.map(core.logoff()))
        default:
            return command.createResponse(.commandNotRecognized)
        }
    }

    static func map(_ r: HotspotResult) -> NEHotspotHelperResult {
        switch r {
        case .success: .success
        case .failure: .failure
        case .uiRequired: .uiRequired
        case .authenticationRequired: .authenticationRequired
        case .unsupportedNetwork: .unsupportedNetwork
        case .temporaryFailure: .temporaryFailure
        case .commandNotRecognized: .commandNotRecognized
        }
    }
}

actor RunTable {
    private var bySSID: [String: UUID] = [:]
    func set(_ id: UUID, for ssid: String) { bySSID[ssid] = id }
    func take(_ ssid: String) -> UUID? { bySSID.removeValue(forKey: ssid) }
}
