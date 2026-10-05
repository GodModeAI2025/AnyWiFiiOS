import Foundation

/// Fehlerkontext eines Laufs für das Repair Center (01 §15, §29). Enthält nur redigierte Daten:
/// die normalisierte Seite ohne Hidden-Werte und Eingaben, keine Cookies, keine Werte.
public struct RepairContext: Codable, Equatable, Sendable {
    public var runId: UUID
    public var profileId: UUID
    public var failedStageId: String?
    public var failedActionIndex: Int?
    public var reason: String?
    public var page: NormalizedPage
    public var createdAt: Date

    public init(runId: UUID, profileId: UUID, failedStageId: String?, failedActionIndex: Int?, reason: String?,
                page: NormalizedPage, createdAt: Date = Date()) {
        self.runId = runId
        self.profileId = profileId
        self.failedStageId = failedStageId
        self.failedActionIndex = failedActionIndex
        self.reason = reason
        self.page = page.redactedForModel()
        self.createdAt = createdAt
    }

    public static func make(from result: RunResult, runId: UUID, profileId: UUID) -> RepairContext? {
        guard result.outcome == .recipeMismatch, let page = result.pages.last?.normalized else { return nil }
        return RepairContext(runId: runId, profileId: profileId, failedStageId: result.failedStageId,
                             failedActionIndex: result.failedActionIndex, reason: result.reason, page: page)
    }
}

public struct RepairProposal: Sendable {
    public var patch: RecipePatch
    public var recipe: Recipe
    public var diff: [DiffLine]
}

public enum RepairError: Error, Equatable, Sendable {
    case noRecipe
    case modelUnavailable
    case noProposal
    case rejected(String)
}

/// Repair Center: Modell (lokal oder PCC) schlägt einen Patch vor, die Runtime prüft ihn.
/// Gespeichert wird erst nach Bestätigung durch den Nutzer.
public enum RepairService {
    public static func propose(profile: PortalProfile, context: RepairContext, model: any AssistantModel,
                               chat: [ChatLogMessage] = []) async throws -> RepairProposal {
        guard let recipe = profile.recipe else { throw RepairError.noRecipe }
        guard await model.availability.isAvailable else { throw RepairError.modelUnavailable }
        let input = RepairInput(intent: profile.intent, recipe: recipe, failedStageId: context.failedStageId,
                                failedActionIndex: context.failedActionIndex, reason: context.reason,
                                page: context.page, chat: chat)
        guard let patch = try await model.proposePatch(input) else { throw RepairError.noProposal }
        do {
            let patched = try patch.apply(to: recipe, bindings: profile.credentialBindings)
            let diff = RecipeDiff.lines(old: (try? PRLCodec.serialize(recipe)) ?? "", new: (try? PRLCodec.serialize(patched)) ?? "")
            return RepairProposal(patch: patch, recipe: patched, diff: diff)
        } catch let e as RecipePatch.PatchError {
            throw RepairError.rejected(String(describing: e))
        }
    }

    public static func apply(_ proposal: RepairProposal, to profile: PortalProfile, note: String = "Repair Center") -> PortalProfile {
        var p = profile
        p.commit(proposal.recipe, note: note)
        return p
    }
}

/// Ablage der Reparaturkontexte (eine kleine JSON-Datei pro Lauf, atomar).
public struct RepairContextStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func save(_ c: RepairContext) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try e.encode(c).write(to: directory.appendingPathComponent("\(c.runId.uuidString).json"), options: .atomic)
        prune()
    }

    public func load(runId: UUID) -> RepairContext? {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: directory.appendingPathComponent("\(runId.uuidString).json"))).flatMap { try? d.decode(RepairContext.self, from: $0) }
    }

    private func prune(keep: Int = 20) {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let items = files.compactMap { f in (try? d.decode(RepairContext.self, from: Data(contentsOf: f))).map { ($0.createdAt, f) } }
            .sorted { $0.0 > $1.0 }
        for (_, f) in items.dropFirst(keep) { try? FileManager.default.removeItem(at: f) }
    }
}
