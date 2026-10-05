import Foundation

public enum ProfileStoreError: Error, Equatable, Sendable {
    case notFound
    case corrupt(String)
}

/// Profilablage als kleine JSON-Dateien mit atomarem Schreiben (02 §12, keine Datenbank).
/// Enthält nie Secrets. Ein Profil pro Datei, damit App und Provider sich nicht blockieren.
public struct ProfileStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func url(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    public func save(_ profile: PortalProfile) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(profile).write(to: url(for: profile.id), options: .atomic)
    }

    public func load(_ id: UUID) throws -> PortalProfile {
        guard let data = try? Data(contentsOf: url(for: id)) else { throw ProfileStoreError.notFound }
        do { return try decoder.decode(PortalProfile.self, from: data) }
        catch { throw ProfileStoreError.corrupt(String(describing: error)) }
    }

    /// Alle lesbaren Profile, nach Name sortiert. Beschädigte Dateien werden übersprungen.
    public func loadAll() -> [PortalProfile] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(PortalProfile.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func delete(_ id: UUID) throws {
        let u = url(for: id)
        guard FileManager.default.fileExists(atPath: u.path) else { throw ProfileStoreError.notFound }
        try FileManager.default.removeItem(at: u)
    }

    /// Evaluation Provider: nur exakte SSID-Treffer aktivierter Profile (01 §26).
    public func enabledProfile(ssid: String, bssid: String? = nil) -> PortalProfile? {
        loadAll().first { $0.enabled && $0.network.matches(ssid: ssid, bssid: bssid) }
    }
}
