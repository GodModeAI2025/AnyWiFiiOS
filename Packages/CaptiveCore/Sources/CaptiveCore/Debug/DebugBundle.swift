import Foundation
import Yams

/// Laufzeitumgebung für `environment.json` im Debug-Paket.
public struct DebugEnvironment: Codable, Sendable, Equatable {
    public var appVersion: String
    public var osVersion: String
    public var device: String
    /// `provider` (Hotspot-Extension) oder `manual` (Manueller Modus, SPEC §3.5).
    public var mode: String
    public var modelAvailability: String

    public init(appVersion: String, osVersion: String, device: String, mode: String, modelAvailability: String) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.device = device
        self.mode = mode
        self.modelAvailability = modelAvailability
    }
}

/// Erzeugt das Debug-Paket nach SPEC §3.3. Lesbar für Menschen und KI-Agenten, ohne Secrets.
///
/// Drei Redaction-Ebenen:
/// 1. Der Trace enthält nur Platzhalter (RunTrace).
/// 2. Seiten werden bereinigt: Hidden-Werte, vorbelegte Feldwerte und Query-Werte entfernt.
/// 3. Abschließend werden alle Dateien gegen die bekannten Klartextwerte des Profils geprüft und bereinigt.
public struct DebugBundleBuilder: Sendable {
    public var profileName: String
    public var recipe: Recipe
    public var recipeRevision: Int
    public var result: RunResult
    public var environment: DebugEnvironment
    public var createdAt: Date
    public var intentJSON: Data?
    public var chatJSON: Data?
    /// Klartextwerte aus dem Keychain des Profils, die keinesfalls im Paket landen dürfen.
    public var knownSecrets: [String]

    public init(profileName: String, recipe: Recipe, recipeRevision: Int, result: RunResult,
                environment: DebugEnvironment, createdAt: Date, knownSecrets: [String],
                intentJSON: Data? = nil, chatJSON: Data? = nil) {
        self.profileName = profileName
        self.recipe = recipe
        self.recipeRevision = recipeRevision
        self.result = result
        self.environment = environment
        self.createdAt = createdAt
        self.knownSecrets = knownSecrets
        self.intentJSON = intentJSON
        self.chatJSON = chatJSON
    }

    public var fileName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let safeName = profileName.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "CaptiveAI-Debug-\(String(safeName))-\(formatter.string(from: createdAt)).zip"
    }

    public func entries() throws -> [ZipArchive.Entry] {
        let json = JSONEncoder()
        json.outputFormatting = [.prettyPrinted, .sortedKeys]
        json.dateEncodingStrategy = .iso8601

        var entries: [ZipArchive.Entry] = []
        entries.append(.init(path: "README.md", text: readme()))
        entries.append(.init(path: "summary.json", data: try json.encode(summary())))
        entries.append(.init(path: "recipe.yaml", text: try PRLCodec.encode(recipe)))

        let line = JSONEncoder()
        line.outputFormatting = [.sortedKeys]
        let trace = try result.trace.events.map { String(decoding: try line.encode($0), as: UTF8.self) }
        entries.append(.init(path: "trace.jsonl", text: trace.joined(separator: "\n") + "\n"))

        for (index, page) in result.visitedPages.enumerated() {
            let yaml = try YAMLEncoder().encode(Self.redacted(page))
            let number = index + 1 < 10 ? "0\(index + 1)" : "\(index + 1)"
            entries.append(.init(path: "pages/\(number).yaml", text: yaml))
        }
        entries.append(.init(path: "environment.json", data: try json.encode(environment)))
        if let intentJSON { entries.append(.init(path: "intent.json", data: intentJSON)) }
        if let chatJSON { entries.append(.init(path: "chat.json", data: chatJSON)) }
        entries.append(.init(path: "schema/prl-v1.json", data: try PRLSchema.data()))

        return entries.map { scrub($0) }
    }

    public func archive() throws -> Data {
        try ZipArchive.write(entries())
    }

    // MARK: - Inhalte

    struct Summary: Codable, Equatable {
        var profileName: String
        var outcome: String
        var reason: String
        var failedStageId: String?
        var failedActionIndex: Int?
        var recipeRevision: Int
        var pagesVisited: Int
        var createdAt: Date
    }

    func summary() -> Summary {
        Summary(profileName: profileName, outcome: result.outcome.rawValue, reason: "\(result.reason)",
                failedStageId: result.failedStageId, failedActionIndex: result.failedActionIndex,
                recipeRevision: recipeRevision, pagesVisited: result.visitedPages.count, createdAt: createdAt)
    }

    func readme() -> String {
        let failedAt: String
        if let stage = result.failedStageId {
            failedAt = "Stage `\(stage)`" + (result.failedActionIndex.map { ", Aktion \($0)" } ?? "")
        } else {
            failedAt = "keine einzelne Aktion"
        }
        return """
        # CaptiveAI Debug-Paket: \(profileName)

        Dieses Paket beschreibt einen fehlgeschlagenen Captive-Portal-Login.

        - **Ergebnis:** `\(result.outcome.rawValue)` (\(result.reason))
        - **Fehlerstelle:** \(failedAt)
        - **Recipe-Revision:** \(recipeRevision)

        ## Dateien
        | Datei | Inhalt |
        |---|---|
        | `summary.json` | Ergebnis, Fehlerstelle, Zeitpunkt |
        | `recipe.yaml` | Das verwendete Recipe (PRL v1) |
        | `trace.jsonl` | Schritt-Protokoll, eine JSON-Zeile pro Ereignis |
        | `pages/NN.yaml` | Normalisierte Portalseiten in Besuchsreihenfolge |
        | `environment.json` | App-/OS-Version, Gerät, Modus, Modellverfügbarkeit |
        | `schema/prl-v1.json` | JSON-Schema der Recipe-Sprache |

        Alle Werte von Passwörtern, Vouchern, Namen, Zimmernummern, Cookies und Hidden Fields sind entfernt
        oder durch Platzhalter wie `<secret:…>`, `<runtime:…>`, `<hidden>` ersetzt.

        ## Anleitung für einen KI-Agenten
        Lies `summary.json`, dann `trace.jsonl` und die Seiten in `pages/`.
        Erzeuge eine korrigierte `recipe.yaml` nach `schema/prl-v1.json`.
        Ändere nur die Stages/Targets, die den Fehler verursachen.
        Bevorzuge semantische Merkmale (`concept`, `labelAny`, `nameAny`) vor `lastKnownSelector`.
        Verwende keine Literal-Werte für Konzepte, die als `<secret:…>`/`<runtime:…>` markiert sind.
        Kein JavaScript, keine neuen Opcodes.
        Gib die Datei als `recipe.yaml` zurück. Sie wird in CaptiveAI über „Recipe importieren“ geladen.
        """
    }

    // MARK: - Redaction

    /// Entfernt Werte, die aus dem Portal stammen, aber sensibel sein können (CSRF, Session, Vorbelegungen).
    static func redacted(_ page: PortalPage) -> PortalPage {
        var copy = page
        copy.url = redactQuery(page.url)
        copy.metaRefresh = page.metaRefresh.map(redactQuery)
        for f in copy.forms.indices {
            copy.forms[f].action = redactQuery(copy.forms[f].action)
            for c in copy.forms[f].controls.indices {
                let control = copy.forms[f].controls[c]
                switch control.role {
                case nil:
                    if control.value != nil { copy.forms[f].controls[c].value = "<hidden>" }
                case .textField?, .passwordField?:
                    if let value = control.value, !value.isEmpty { copy.forms[f].controls[c].value = "<value>" }
                default:
                    break
                }
            }
        }
        for l in copy.links.indices {
            copy.links[l].href = copy.links[l].href.map(redactQuery)
        }
        return copy
    }

    /// Behält Parameternamen, ersetzt Werte (z. B. MAC-Adressen, Tokens).
    static func redactQuery(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, !items.isEmpty else { return url }
        components.queryItems = items.map { URLQueryItem(name: $0.name, value: ($0.value ?? "").isEmpty ? $0.value : "x") }
        return components.url ?? url
    }

    func scrub(_ entry: ZipArchive.Entry) -> ZipArchive.Entry {
        let terms = knownSecrets.filter { $0.count >= 2 }.sorted { $0.count > $1.count }
        // Das Schema ist eine statische Datei aus der App und wird nicht verändert.
        guard !terms.isEmpty, !entry.path.hasPrefix("schema/") else { return entry }
        var text = String(decoding: entry.data, as: UTF8.self)
        for term in terms {
            text = text.replacingOccurrences(of: term, with: "<redacted>")
        }
        return ZipArchive.Entry(path: entry.path, text: text)
    }
}

/// Zugriff auf das mitgelieferte PRL-Schema (Kopie von Schemas/prl-v1.schema.json, CI prüft Gleichheit).
public enum PRLSchema {
    public static func data() throws -> Data {
        guard let url = Bundle.module.url(forResource: "prl-v1.schema", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }
}
