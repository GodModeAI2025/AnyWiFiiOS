import Foundation
@testable import CaptiveCore

/// Lädt Dateien aus Tests/Fixtures per #filePath. Kein Bundle nötig, funktioniert auf Linux und macOS.
enum Fixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // CaptiveCoreTests
        .deletingLastPathComponent() // Tests
        .appendingPathComponent("Fixtures")

    static func recipeFiles(_ group: String) throws -> [URL] {
        let dir = root.appendingPathComponent("recipes").appendingPathComponent(group)
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "yaml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func recipeText(_ group: String, _ name: String) throws -> String {
        let url = root.appendingPathComponent("recipes").appendingPathComponent(group)
            .appendingPathComponent("\(name).yaml")
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func recipe(_ group: String, _ name: String) throws -> Recipe {
        try PRLCodec.decode(yaml: recipeText(group, name))
    }

    /// Keychain-Bindings aus recipes/bindings.json.
    static func bindings() throws -> [String: Concept] {
        struct File: Decodable { let bindings: [String: String] }
        let data = try Data(contentsOf: root.appendingPathComponent("recipes/bindings.json"))
        let raw = try JSONDecoder().decode(File.self, from: data).bindings
        return try raw.mapValues { value in
            guard let concept = Concept(rawValue: value) else {
                throw CocoaError(.coderInvalidValue)
            }
            return concept
        }
    }
}

extension URL {
    var baseName: String { deletingPathExtension().lastPathComponent }
}
