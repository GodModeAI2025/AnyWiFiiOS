import Foundation
import NetworkExtension
import UserNotifications
import CaptiveCore

/// Richtet den Hotspot-Provider ein (SPEC §5 Phase 9). Ohne das Entitlement scheitert `saveToPreferences`.
/// Dann bleibt die App im Manuellen Modus nutzbar (SPEC §3.5).
@Observable @MainActor
final class HotspotSetup {
    enum State: Equatable {
        case unknown
        case enabled
        case disabled
        case unavailable(String)
    }

    static let evaluationBundleID = "de.mobilebox.captiveai.evaluation"
    static let authenticationBundleID = "de.mobilebox.captiveai.authentication"

    private(set) var state: State = .unknown
    private(set) var notificationsAllowed: Bool?

    func refresh() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAllowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        do {
            let manager = NEHotspotManager.shared
            try await manager.loadFromPreferences()
            state = manager.isEnabled ? .enabled : .disabled
        } catch {
            state = .unavailable(Self.describe(error))
        }
    }

    /// Schaltet den Provider ein oder aus und übergibt die SSIDs aktiver Profile.
    func apply(enabled: Bool, profiles: [PortalProfile]) async {
        if enabled { notificationsAllowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false }
        let manager = NEHotspotManager.shared
        do {
            try? await manager.loadFromPreferences()
            manager.evaluationProviderBundleIdentifier = Self.evaluationBundleID
            manager.authenticationProviderBundleIdentifier = Self.authenticationBundleID
            manager.evaluatedSSIDs = Array(Set(profiles.filter(\.enabled).map(\.network.ssidExact))).sorted()
            manager.safariDomains = Array(Set(profiles.filter(\.enabled).flatMap(\.network.portalHostHints))).sorted()
            manager.isEnabled = enabled
            try await manager.saveToPreferences()
            state = enabled ? .enabled : .disabled
        } catch {
            state = .unavailable(Self.describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? NEHotspotManager.Error {
            switch e {
            case .configurationInvalid: return String(localized: "Die Konfiguration ist ungültig.")
            case .configurationNotLoaded: return String(localized: "Die Konfiguration konnte nicht geladen werden.")
            default: break
            }
        }
        return String(localized: "Das Hotspot-Helper-Entitlement fehlt oder ist noch nicht erteilt. Der Manuelle Modus funktioniert weiterhin.")
    }
}
