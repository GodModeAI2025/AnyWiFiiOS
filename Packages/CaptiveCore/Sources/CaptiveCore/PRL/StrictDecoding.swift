import Foundation

/// Fehler beim Lesen eines PRL-Dokuments (docs/spec/01 §8, 02 §22 „Recipe Parser“).
public enum PRLError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedVersion(Int)
    case unknownFields([String], path: String)
    case unknownOpcode(String, path: String)
    /// Eine Aktion bzw. Wertquelle muss genau einen Schlüssel haben.
    case expectedSingleKey(found: [String], path: String)

    public var description: String {
        switch self {
        case .unsupportedVersion(let v):
            "recipeVersion \(v) wird nicht unterstützt (erwartet: \(Recipe.currentVersion))"
        case .unknownFields(let fields, let path):
            "Unbekannte Felder \(fields.joined(separator: ", ")) bei \(path.isEmpty ? "<root>" : path)"
        case .unknownOpcode(let op, let path):
            "Unbekannte Aktion '\(op)' bei \(path)"
        case .expectedSingleKey(let found, let path):
            "Genau ein Schlüssel erwartet bei \(path), gefunden: \(found.isEmpty ? "keiner" : found.joined(separator: ", "))"
        }
    }
}

/// Dynamischer CodingKey für Schlüsselprüfung und Ein-Schlüssel-Objekte.
struct AnyKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?
    init(_ string: String) { stringValue = string; intValue = nil }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { stringValue = String(intValue); self.intValue = intValue }
}

extension Decoder {
    /// Lesbarer Pfad wie `stages[0].actions[1].fill.target`.
    var pathString: String {
        var path = ""
        for key in codingPath {
            if let index = key.intValue {
                path += "[\(index)]"
            } else {
                path += path.isEmpty ? key.stringValue : ".\(key.stringValue)"
            }
        }
        return path
    }

    /// Wirft `PRLError.unknownFields`, wenn das aktuelle Objekt Schlüssel außerhalb von `allowed` enthält.
    /// Codable ignoriert unbekannte Schlüssel sonst stillschweigend. Für PRL ist das nicht erlaubt (02 §22).
    func rejectUnknownKeys<K: CodingKey & CaseIterable>(_: K.Type) throws {
        let allowed = Set(K.allCases.map(\.stringValue))
        let present = try container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        let unknown = present.filter { !allowed.contains($0) }.sorted()
        if !unknown.isEmpty {
            throw PRLError.unknownFields(unknown, path: pathString)
        }
    }

    /// Liest ein Objekt, das genau einen Schlüssel hat (Aktionen, Wertquellen).
    func singleKey() throws -> (KeyedDecodingContainer<AnyKey>, AnyKey) {
        let c = try container(keyedBy: AnyKey.self)
        let keys = c.allKeys
        guard keys.count == 1, let key = keys.first else {
            throw PRLError.expectedSingleKey(found: keys.map(\.stringValue).sorted(), path: pathString)
        }
        return (c, key)
    }
}
