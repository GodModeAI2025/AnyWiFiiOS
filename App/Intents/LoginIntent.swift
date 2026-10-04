import AppIntents
import CaptiveCore
import Foundation
import SwiftData

/// Kurzbefehl „Im WLAN anmelden“ (SPEC §3.5). Für Automationen wie „Wenn mit WLAN X verbunden“.
struct LoginIntent: AppIntent {
    static let title: LocalizedStringResource = "Im WLAN anmelden"
    static var description: IntentDescription {
        IntentDescription("Meldet dich mit dem gespeicherten Ablauf im Portal des WLANs an.")
    }
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Profilname", description: "Leer lassen, um das einzige aktive Profil zu verwenden.")
    var profileName: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let container = try ModelContainer(for: ProfileRecord.self, RunRecord.self)
        let context = container.mainContext
        let profiles = try context.fetch(FetchDescriptor<ProfileRecord>()).filter(\.enabled)
        let profile: ProfileRecord?
        if let name = profileName, !name.isEmpty {
            profile = profiles.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
        } else {
            profile = profiles.count == 1 ? profiles.first : nil
        }
        guard let profile else {
            return .result(dialog: "Kein passendes Profil gefunden. Gib den Profilnamen an.")
        }

        let service = LoginService()
        await service.login(profile, context: context)
        switch service.state {
        case .finished(let outcome, let reason):
            return .result(dialog: "\(profile.name): \(outcome.title). \(reason)")
        case .needsValue(let concept):
            return .result(dialog: "\(profile.name) benötigt \(concept.displayName). Öffne CaptiveAI, um den Wert einzugeben.")
        case .idle, .running:
            return .result(dialog: "\(profile.name): Anmeldung läuft.")
        }
    }
}

struct CaptiveAIShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LoginIntent(), phrases: ["Mit \(.applicationName) im WLAN anmelden"],
                    shortTitle: "WLAN-Anmeldung", systemImageName: "wifi")
    }
}
