import Foundation

/// Redigiertes Laufprotokoll (01 §22.1). Enthält nie Secrets, Cookies oder Query-Werte.
public struct RunLog: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var profileId: UUID
    public var profileName: String
    public var startedAt: Date
    public var durationMs: Int
    public var outcome: Outcome
    public var reason: String?
    public var requiredConcept: String?
    public var failedStage: String?
    public var usedRecipe: Bool
    public var recipeRevision: Int
    public var events: [TraceRecord]
    public var learned: Bool
    public var repaired: Bool
    /// Dateiname des automatisch erzeugten Debug-Pakets (Ausgang ≠ success).
    public var debugBundle: String?

    public init(id: UUID = UUID(), profileId: UUID, profileName: String, startedAt: Date, durationMs: Int,
                outcome: Outcome, reason: String?, requiredConcept: String?, failedStage: String?,
                usedRecipe: Bool, recipeRevision: Int, events: [TraceRecord],
                learned: Bool = false, repaired: Bool = false, debugBundle: String? = nil) {
        self.id = id
        self.profileId = profileId
        self.profileName = profileName
        self.startedAt = startedAt
        self.durationMs = durationMs
        self.outcome = outcome
        self.reason = reason
        self.requiredConcept = requiredConcept
        self.failedStage = failedStage
        self.usedRecipe = usedRecipe
        self.recipeRevision = recipeRevision
        self.events = events
        self.learned = learned
        self.repaired = repaired
        self.debugBundle = debugBundle
    }

    private enum CodingKeys: String, CodingKey {
        case id, profileId, profileName, startedAt, durationMs, outcome, reason, requiredConcept, failedStage
        case usedRecipe, recipeRevision, events, learned, repaired, debugBundle
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        profileId = try c.decode(UUID.self, forKey: .profileId)
        profileName = try c.decode(String.self, forKey: .profileName)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        durationMs = try c.decode(Int.self, forKey: .durationMs)
        outcome = try c.decode(Outcome.self, forKey: .outcome)
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        requiredConcept = try c.decodeIfPresent(String.self, forKey: .requiredConcept)
        failedStage = try c.decodeIfPresent(String.self, forKey: .failedStage)
        usedRecipe = try c.decode(Bool.self, forKey: .usedRecipe)
        recipeRevision = try c.decode(Int.self, forKey: .recipeRevision)
        events = try c.decode([TraceRecord].self, forKey: .events)
        learned = try c.decodeIfPresent(Bool.self, forKey: .learned) ?? false
        repaired = try c.decodeIfPresent(Bool.self, forKey: .repaired) ?? false
        debugBundle = try c.decodeIfPresent(String.self, forKey: .debugBundle)
    }
}

public struct RunLogStore: Sendable {
    public let directory: URL
    public var maxEntries: Int

    public init(directory: URL, maxEntries: Int = 200) {
        self.directory = directory
        self.maxEntries = maxEntries
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func append(_ log: RunLog) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(log).write(to: directory.appendingPathComponent("\(log.id.uuidString).json"), options: .atomic)
        prune()
    }

    /// Neueste zuerst.
    public func all(profile: UUID? = nil) -> [RunLog] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(RunLog.self, from: Data(contentsOf: $0)) }
            .filter { profile == nil || $0.profileId == profile }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func clear(profile: UUID) {
        for l in all(profile: profile) { try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(l.id.uuidString).json")) }
    }

    private func prune() {
        let logs = all()
        guard logs.count > maxEntries else { return }
        for l in logs.dropFirst(maxEntries) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(l.id.uuidString).json"))
        }
    }
}

public extension Outcome {
    /// Verständlicher Grund statt "Es ging nicht" (01 §23).
    var explanation: String {
        switch self {
        case .success: "Verbunden."
        case .temporaryFailure: "Vorübergehender Fehler. Der nächste Versuch kann klappen."
        case .unsupportedPortal: "Dieses Portal wird nicht unterstützt."
        case .missingUserValue: "Ein benötigter Wert war nicht verfügbar."
        case .recipeMismatch: "Das Portal sieht anders aus als beim Lernen."
        case .networkError: "Keine Verbindung zum Portal."
        case .timeout: "Das Portal hat nicht rechtzeitig geantwortet."
        case .aiUnavailable: "Das lokale Modell ist nicht verfügbar."
        case .aiRejectedPlan: "Ein vorgeschlagener Schritt wurde aus Sicherheitsgründen abgelehnt."
        case .manualInteractionRequired: "Für dieses Portal ist eine manuelle Anmeldung nötig."
        }
    }
}
