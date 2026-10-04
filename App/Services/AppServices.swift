import CaptiveCore
import CaptiveCoreApple
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum AppConfig {
    /// Platzhalter bis zur echten Bundle-ID (SPEC §3.6).
    static let appGroup = "group.com.example.captiveai"
    static let keychain = KeychainStore(service: "com.captiveai.credentials", accessGroup: nil)
    static let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    static var debugBundleDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("DebugBundles", isDirectory: true)
    }

    static var pendingStore: PendingAuthenticationStore {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.temporaryDirectory
        return PendingAuthenticationStore(directory: base.appendingPathComponent("Pending", isDirectory: true))
    }
}

/// Spiegelt Profile ohne Secrets in die App Group, damit die Hotspot-Provider sie lesen können (Phase 9).
enum SharedProfileMirror {
    struct Entry: Codable {
        var id: UUID
        var ssid: String
        var enabled: Bool
        var portalHostHints: [String]
        var recipeYAML: String?
    }

    @MainActor
    static func write(_ profiles: [ProfileRecord]) {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroup)?
            .appendingPathComponent("profiles.json") else { return }
        let entries = profiles.map {
            Entry(id: $0.id, ssid: $0.ssid, enabled: $0.enabled, portalHostHints: $0.portalHostHints, recipeYAML: $0.recipeYAML)
        }
        try? JSONEncoder().encode(entries).write(to: url, options: [.atomic])
    }
}

extension UTType {
    static let captiveProfile = UTType(exportedAs: "com.captiveai.profile")
    static let recipeYAML = UTType(filenameExtension: "yaml") ?? .plainText
}

/// Werte aus dem Keychain plus Werte, die der Nutzer gerade eingegeben hat (nur im Speicher, nur für diesen Lauf).
struct SessionValueProvider: ValueProvider {
    var keychain: KeychainStore
    var asked: [Concept: String]

    func value(for source: ValueSource) async -> String? {
        switch source {
        case .literal(let v): return v
        case .keychain(let key): return try? keychain.get(key)
        case .ask(let concept): return asked[concept]
        case .profile, .runtime: return nil
        }
    }
}

enum PlannerFactory {
    /// Apple Intelligence, falls verfügbar. Sonst regelbasiert (SPEC §3.2).
    static func make() -> any PortalPlanner {
        if #available(iOS 26.0, *), FoundationModelsPlanner.isAvailable {
            return FoundationModelsPlanner()
        }
        return HeuristicPlanner()
    }

    static var modelDescription: String {
        if #available(iOS 26.0, *), FoundationModelsPlanner.isAvailable { return "Apple Intelligence (auf dem Gerät)" }
        return "Regelbasiert (Apple Intelligence nicht verfügbar)"
    }
}

extension RunOutcome {
    var title: String {
        switch self {
        case .success: "Verbunden"
        case .temporaryFailure: "Vorübergehend fehlgeschlagen"
        case .unsupportedPortal: "Portal wird nicht unterstützt"
        case .missingUserValue: "Angabe fehlt"
        case .recipeMismatch: "Portal hat sich geändert"
        case .networkError: "Netzwerkfehler"
        case .timeout: "Zeitüberschreitung"
        case .aiUnavailable: "KI nicht verfügbar"
        case .aiRejectedPlan: "KI-Vorschlag abgelehnt"
        case .manualInteractionRequired: "Manuelle Anmeldung nötig"
        }
    }

    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .missingUserValue: "questionmark.circle.fill"
        case .manualInteractionRequired, .unsupportedPortal: "hand.raised.fill"
        default: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success: .green
        case .missingUserValue: .blue
        default: .orange
        }
    }
}

extension RunReason {
    /// Verständlicher Grund für die Aktivitätsansicht (01 §23).
    var explanation: String {
        switch self {
        case .alreadyOnline: "Das Gerät war bereits online."
        case .loggedIn: "Anmeldung erfolgreich."
        case .stageNotFound: "Die Portalseite passt zu keinem gespeicherten Schritt."
        case .loginNotAccepted: "Das Portal hat die Anmeldung nicht angenommen."
        case .targetNotFound: "Ein Element (z. B. ein Button) wurde nicht gefunden."
        case .targetAmbiguous: "Mehrere Elemente passen. Der Schritt ist nicht eindeutig."
        case .wrongElementKind: "Ein Schritt passt nicht zum gefundenen Element."
        case .missingValue(let concept): "\(concept?.displayName ?? "Ein Wert") war nicht verfügbar."
        case .commercialElement(let label): "Abgebrochen: „\(label)“ wäre kostenpflichtig."
        case .optionalConsent(let label): "Abgebrochen: „\(label)“ ist eine optionale Werbe-Einwilligung."
        case .credentialHostNotTrusted(let host): "Zugangsdaten wurden nicht an \(host) gesendet."
        case .javaScriptRequired: "Das Portal funktioniert nur mit JavaScript im Browser."
        case .httpStatus(let code): "Das Portal antwortete mit Fehler \(code)."
        case .tooManyRedirects: "Zu viele Weiterleitungen."
        case .responseTooLarge: "Die Portalseite ist zu groß."
        case .transport: "Keine Verbindung zum Portal."
        case .stillCaptive: "Nach dem Absenden ist das WLAN immer noch gesperrt."
        case .unknownAdapter(let id): "Unbekannter Portal-Adapter \(id)."
        case .adapterFailed(let message): "Portal-Adapter: \(message)"
        case .conditionNotMet: "Eine erwartete Seite ist nicht erschienen."
        case .stopRequested: "Das Recipe hat den Lauf beendet."
        case .roundLimitReached: "Zu viele Schritte ohne Erfolg."
        case .modelUnavailable: "Apple Intelligence ist nicht verfügbar."
        case .planRejected: "Der KI-Vorschlag verletzte eine Sicherheitsregel."
        }
    }
}
