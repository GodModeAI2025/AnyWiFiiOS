import Foundation

/// Offene Anmeldung, die auf einen Wert vom Nutzer wartet (02 §12, S6). Liegt im App Group
/// Container. Enthält nie den Wert selbst, nur eine Keychain-Referenz.
public struct PendingAuthentication: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { runId }

    /// Reihenfolge ist verbindlich: Zustände gehen nur vorwärts (Konfliktstrategie).
    public enum Status: String, Codable, Sendable, Comparable {
        case awaitingUser, valueProvided, completed, failed, expired

        var rank: Int {
            switch self {
            case .awaitingUser: 0
            case .valueProvided: 1
            case .completed, .failed, .expired: 2
            }
        }

        public static func < (a: Status, b: Status) -> Bool { a.rank < b.rank }
    }

    public var runId: UUID
    public var profileId: UUID
    public var profileName: String
    public var requiredConcept: String?
    public var prompt: String?
    public var status: Status
    public var createdAt: Date
    /// Schlüssel im gemeinsamen Keychain, unter dem die App den Wert abgelegt hat.
    public var valueKey: String?

    public init(runId: UUID = UUID(), profileId: UUID, profileName: String, requiredConcept: String?, prompt: String?,
                status: Status = .awaitingUser, createdAt: Date = Date(), valueKey: String? = nil) {
        self.runId = runId
        self.profileId = profileId
        self.profileName = profileName
        self.requiredConcept = requiredConcept
        self.prompt = prompt
        self.status = status
        self.createdAt = createdAt
        self.valueKey = valueKey
    }

    public static func valueKey(runId: UUID, concept: String) -> String { "pending.\(runId.uuidString).\(concept)" }
}

/// Kleine JSON-Dateien mit atomarem Schreiben, eine pro Lauf.
public struct PendingStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

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

    private func url(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    public func write(_ p: PendingAuthentication) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(p).write(to: url(p.runId), options: .atomic)
    }

    public func read(_ id: UUID) -> PendingAuthentication? {
        (try? Data(contentsOf: url(id))).flatMap { try? decoder.decode(PendingAuthentication.self, from: $0) }
    }

    /// Offene Einträge (wartend), neueste zuerst. Beschädigte Dateien werden ignoriert.
    public func awaiting(now: Date = Date(), maxAge: TimeInterval = 600) -> [PendingAuthentication] {
        all().filter { $0.status == .awaitingUser && now.timeIntervalSince($0.createdAt) <= maxAge }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func all() -> [PendingAuthentication] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { try? decoder.decode(PendingAuthentication.self, from: Data(contentsOf: $0)) }
    }

    /// Zustandswechsel nur vorwärts. Verhindert, dass ein spätes Update von Provider oder App
    /// einen bereits weiter fortgeschrittenen Lauf zurücksetzt.
    @discardableResult
    public func transition(_ id: UUID, to status: PendingAuthentication.Status, valueKey: String? = nil) -> Bool {
        guard var p = read(id), p.status.rank < 2, status.rank >= p.status.rank else { return false }
        p.status = status
        if let valueKey { p.valueKey = valueKey }
        return (try? write(p)) != nil
    }

    public func delete(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }

    /// Räumt alte Einträge auf.
    public func purge(olderThan age: TimeInterval = 3600, now: Date = Date()) {
        for p in all() where now.timeIntervalSince(p.createdAt) > age { delete(p.runId) }
    }
}
