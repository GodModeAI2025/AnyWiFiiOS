import Foundation

/// Übergabe zwischen Authentication Provider und App bei `uiRequired` → `presentUI` (01 §4.5, 02 §12 Gate S6).
/// Enthält nie den Wert selbst. Der Wert geht über den gemeinsamen Keychain (`valueKeychainKey`).
public struct PendingAuthentication: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        /// Provider wartet auf einen Wert.
        case awaitingUser
        /// App hat den Wert in den Keychain geschrieben.
        case valueProvided
        /// Nutzer hat abgebrochen.
        case cancelled
        /// Provider hat den Lauf abgeschlossen.
        case completed
    }

    public var runId: UUID
    public var profileId: UUID
    public var requiredConcept: Concept?
    public var status: Status
    /// Keychain-Schlüssel, unter dem die App den Wert ablegt.
    public var valueKeychainKey: String?
    /// Nur diesmal verwenden (App löscht den Keychain-Eintrag danach) oder fürs Profil merken (01 §4.5).
    public var rememberValue: Bool
    public var updatedAt: Date

    public init(runId: UUID, profileId: UUID, requiredConcept: Concept?, status: Status,
                valueKeychainKey: String? = nil, rememberValue: Bool = false, updatedAt: Date) {
        self.runId = runId
        self.profileId = profileId
        self.requiredConcept = requiredConcept
        self.status = status
        self.valueKeychainKey = valueKeychainKey
        self.rememberValue = rememberValue
        self.updatedAt = updatedAt
    }

    /// Text für die lokale Notification. Nie mit Wert (01 §4.5).
    public func notificationText(profileName: String) -> String {
        let what = requiredConcept?.displayName ?? "eine Angabe"
        return "\(profileName) benötigt \(what) für die WLAN-Anmeldung."
    }
}

/// Kleine JSON-Dateien mit atomarem Schreiben (02 §12 Empfehlung). Keine Datenbank.
/// Konfliktstrategie: Last-writer-wins über `updatedAt`, ältere Stände überschreiben neuere nie.
public struct PendingAuthenticationStore: Sendable {
    public var directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public enum Failure: Error, Equatable, Sendable {
        case staleUpdate
    }

    func url(for runId: UUID) -> URL {
        directory.appendingPathComponent("pending-\(runId.uuidString).json")
    }

    public func save(_ pending: PendingAuthentication) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let existing = try load(runId: pending.runId), existing.updatedAt > pending.updatedAt {
            throw Failure.staleUpdate
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(pending).write(to: url(for: pending.runId), options: [.atomic])
    }

    public func load(runId: UUID) throws -> PendingAuthentication? {
        let file = url(for: runId)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PendingAuthentication.self, from: Data(contentsOf: file))
    }

    /// Alle offenen Anfragen (für die App beim Start bzw. bei `presentUI`).
    public func openRequests() throws -> [PendingAuthentication] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return files.filter { $0.lastPathComponent.hasPrefix("pending-") }
            .compactMap { try? decoder.decode(PendingAuthentication.self, from: Data(contentsOf: $0)) }
            .filter { $0.status == .awaitingUser }
            .sorted { $0.updatedAt < $1.updatedAt }
    }

    public func remove(runId: UUID) throws {
        let file = url(for: runId)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
