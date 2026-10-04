import Foundation
import Yams

/// Lesen und Schreiben von `recipe.yaml` (01 §8.2).
///
/// Das Lesen ist absichtlich streng: unbekannte Felder, unbekannte Opcodes und falsche
/// Versionen führen zu `PRLError` (02 §22). Ein gelesenes Recipe ist nur **strukturell** gültig.
/// Vor jeder Ausführung muss es zusätzlich durch den `RecipeValidator` (01 §24, §29).
public enum PRLCodec {
    /// Obergrenze für Recipe-Dateien. Schützt vor absurd großen Importen.
    public static let maxDocumentBytes = 256 * 1024

    public static func decode(yaml: String) throws -> Recipe {
        guard yaml.utf8.count <= maxDocumentBytes else {
            throw PRLCodecError.documentTooLarge(bytes: yaml.utf8.count)
        }
        return try YAMLDecoder().decode(Recipe.self, from: yaml)
    }

    public static func decode(data: Data) throws -> Recipe {
        guard let text = String(data: data, encoding: .utf8) else { throw PRLCodecError.notUTF8 }
        return try decode(yaml: text)
    }

    public static func encode(_ recipe: Recipe) throws -> String {
        try YAMLEncoder().encode(recipe)
    }
}

public enum PRLCodecError: Error, Equatable, Sendable {
    case documentTooLarge(bytes: Int)
    case notUTF8
}
