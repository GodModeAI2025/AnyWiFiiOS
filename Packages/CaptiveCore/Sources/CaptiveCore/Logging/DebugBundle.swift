import Foundation
import Yams

public struct DebugEnvironment: Codable, Equatable, Sendable {
    public var appVersion: String
    public var osVersion: String
    public var device: String
    public var modelAvailability: String
    /// "provider" oder "manual" (SPEC §3.5)
    public var mode: String

    public init(appVersion: String, osVersion: String, device: String, modelAvailability: String, mode: String) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.device = device
        self.modelAvailability = modelAvailability
        self.mode = mode
    }
}

public struct ChatLogMessage: Codable, Equatable, Sendable {
    public var role: String
    public var text: String
    public init(role: String, text: String) { self.role = role; self.text = text }
}

public struct DebugBundleInput: Sendable {
    public var profileName: String
    public var recipeRevision: Int
    public var startedAt: Date
    public var intent: PortalIntent?
    public var recipe: Recipe?
    public var run: RunResult
    public var environment: DebugEnvironment
    public var chat: [ChatLogMessage]
    /// Zusätzliche Werte, die nie im Paket auftauchen dürfen (z. B. Cookies aus dem Transport).
    public var extraSensitive: [SensitiveValue]

    public init(profileName: String, recipeRevision: Int, startedAt: Date, intent: PortalIntent?, recipe: Recipe?,
                run: RunResult, environment: DebugEnvironment, chat: [ChatLogMessage] = [],
                extraSensitive: [SensitiveValue] = []) {
        self.profileName = profileName
        self.recipeRevision = recipeRevision
        self.startedAt = startedAt
        self.intent = intent
        self.recipe = recipe
        self.run = run
        self.environment = environment
        self.chat = chat
        self.extraSensitive = extraSensitive
    }
}

/// Baut das Debug-Paket nach SPEC §3.3. Jede Textdatei läuft durch den `Redactor`.
public enum DebugBundleBuilder {
    public static func filename(profile: String, at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmm"
        let safe = profile.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let cleaned = String(safe).split(separator: "-").joined(separator: "-")
        return "CaptiveAI-Debug-\(cleaned.isEmpty ? "profil" : cleaned)-\(f.string(from: date)).zip"
    }

    public static func build(_ input: DebugBundleInput, now: Date = Date()) throws -> (filename: String, data: Data) {
        let redactor = Redactor(values: input.run.secretsUsed + input.extraSensitive)
        var entries: [ZipArchive.Entry] = []
        func add(_ path: String, _ text: String) {
            entries.append(.init(path: path, data: Data(redactor.redact(text).utf8)))
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        func json<T: Encodable>(_ v: T) throws -> String { String(decoding: try enc.encode(v), as: UTF8.self) }

        let run = input.run
        let iso = ISO8601DateFormatter()

        struct Summary: Encodable {
            var outcome: Outcome
            var reason: String?
            var requiredConcept: String?
            var failedStage: String?
            var failedActionIndex: Int?
            var recipeRevision: Int
            var startedAt: String
            var durationMs: Int
            var modelCalls: Int
        }
        let summary = Summary(outcome: run.outcome, reason: run.reason, requiredConcept: run.requiredConcept,
                              failedStage: run.failedStageId, failedActionIndex: run.failedActionIndex,
                              recipeRevision: input.recipeRevision, startedAt: iso.string(from: input.startedAt),
                              durationMs: run.durationMs, modelCalls: run.modelCalls)

        add("README.md", readme(input))
        add("summary.json", try json(summary))
        if let intent = input.intent { add("intent.json", try json(intent)) }
        if let recipe = input.recipe { add("recipe.yaml", try PRLCodec.serialize(recipe)) }

        let trace = run.trace.map { TraceRecord($0) }
        let line = JSONEncoder()
        line.outputFormatting = [.sortedKeys]
        add("trace.jsonl", try trace.map { String(decoding: try line.encode($0), as: UTF8.self) }.joined(separator: "\n"))

        for (i, p) in run.pages.enumerated() {
            let nn = String(format: "%02d", i + 1)
            add("pages/\(nn).yaml", try YAMLEncoder().encode(p.normalized.redactedForModel()))
            entries.append(.init(path: "pages/\(nn).html", data: Data(redactor.redactHTML(p.html).utf8)))
        }

        struct Network: Encodable { var hosts: [String]; var entries: [NetworkEntry] }
        add("network.json", try json(Network(hosts: Array(Set(run.network.map(\.host))).sorted(), entries: run.network)))
        add("environment.json", try json(input.environment))
        if !input.chat.isEmpty { add("chat.json", try json(input.chat)) }
        add("schema/prl-v1.json", PRLSchema.json)

        return (filename(profile: input.profileName, at: now), ZipArchive.write(entries))
    }

    static func readme(_ i: DebugBundleInput) -> String {
        """
        # CaptiveAI Debug-Paket

        Profil: \(i.profileName)
        Ergebnis: \(i.run.outcome.rawValue)
        Grund: \(i.run.reason ?? "unbekannt")
        Fehlgeschlagene Stage: \(i.run.failedStageId ?? "keine")
        Recipe-Revision: \(i.recipeRevision)

        \(template)
        """
    }

    /// Vorlage aus SPEC §3.3 (Anleitung für Mensch und KI-Agent).
    public static let template = """
        Dieses Paket beschreibt einen fehlgeschlagenen Captive-Portal-Login. Lies `summary.json`, dann `trace.jsonl` und die Seiten in `pages/`. Erzeuge eine korrigierte `recipe.yaml` nach `schema/prl-v1.json`. Ändere nur die Stages/Targets, die den Fehler verursachen. Verwende keine Literal-Werte für Konzepte, die als `<secret:…>`/`<personal:…>` markiert sind. Gib die Datei als `recipe.yaml` zurück. Sie wird in CaptiveAI über „Recipe importieren“ geladen.
        """
}
