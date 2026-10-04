import AppIntents
import CaptiveCore

struct ProfileEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "WLAN-Profil")
    static let defaultQuery = ProfileQuery()

    var id: UUID
    var name: String
    var ssid: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(ssid)")
    }

    init(_ p: PortalProfile) { id = p.id; name = p.name; ssid = p.network.ssidExact }
}

struct ProfileQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [ProfileEntity] {
        AppEnvironment.profileStore().loadAll().filter { identifiers.contains($0.id) }.map(ProfileEntity.init)
    }

    func suggestedEntities() async throws -> [ProfileEntity] {
        AppEnvironment.profileStore().loadAll().filter(\.enabled).map(ProfileEntity.init)
    }
}

/// "Im WLAN anmelden" (SPEC §3.5): Kurzbefehle-Automation, Siri und Control Center.
struct LoginIntent: AppIntent {
    static let title: LocalizedStringResource = "Im WLAN anmelden"
    static let description = IntentDescription("Meldet dich mit einem CaptiveAI-Profil am Captive Portal des aktuellen WLANs an.")

    @Parameter(title: "Profil")
    var profile: ProfileEntity?

    init() {}
    init(profile: ProfileEntity?) { self.profile = profile }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = AppEnvironment.profileStore()
        let all = store.loadAll().filter(\.enabled)
        let chosen: PortalProfile? = {
            if let id = profile?.id { return all.first { $0.id == id } }
            // Ohne Auswahl: zuletzt verwendetes aktives Profil, sonst das erste.
            let lastUsed = AppEnvironment.runLogStore().all().first.flatMap { log in all.first { $0.id == log.profileId } }
            return lastUsed ?? all.first
        }()
        guard let chosen else { return .result(dialog: "Es gibt kein aktives Profil. Lege eines in CaptiveAI an.") }

        let report = await AppEnvironment.login(profile: chosen)
        switch report.result.outcome {
        case .success:
            return .result(dialog: "Angemeldet bei \(chosen.name).")
        case .missingUserValue:
            return .result(dialog: "\(chosen.name) braucht noch einen Wert. Öffne CaptiveAI und melde dich dort an.")
        default:
            return .result(dialog: "\(chosen.name): \(report.result.outcome.explanation)")
        }
    }
}

struct CaptiveShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LoginIntent(), phrases: ["Im WLAN anmelden mit \(.applicationName)",
                                                      "\(.applicationName) anmelden"],
                    shortTitle: "Im WLAN anmelden", systemImageName: "wifi")
    }
}
