import Foundation

/// Hält sensible Werte aus Prompts heraus (SPEC §3.2). Bekannte Werte werden ersetzt, typische
/// Formulierungen ("mein Passwort ist …") erkannt. Die UI fragt sensible Werte stattdessen über
/// ein separates, sicheres Eingabefeld ab.
public enum PromptSanitizer {
    public struct Result: Equatable, Sendable {
        public var text: String
        /// Konzepte, bei denen ein Klartextwert im Text vermutet wurde.
        public var detectedConcepts: [String]
    }

    private static let patterns: [(concept: String, regex: NSRegularExpression)] = {
        func re(_ s: String) -> NSRegularExpression { try! NSRegularExpression(pattern: s, options: [.caseInsensitive]) }
        return [
            ("password", re(#"\b(passwort|password|kennwort|pw|pin)\b\s*(?:ist|is|lautet|=|:)\s*(\S+)"#)),
            ("voucherCode", re(#"\b(gutschein(?:code)?|voucher(?: code)?|zugangscode|access code)\b\s*(?:ist|is|lautet|=|:)\s*(\S+)"#)),
            ("roomNumber", re(#"\b(zimmer(?:nummer)?|room(?: number)?)\b\s*(?:ist|is|=|:)?\s*(\d{1,5}[a-z]?)\b"#)),
            ("lastName", re(#"\b(nachname|last name|surname)\b\s*(?:ist|is|lautet|=|:)\s*([\p{L}'-]+)"#)),
            ("email", re(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#)),
        ]
    }()

    public static func sanitize(_ input: String, known: [SensitiveValue] = []) -> Result {
        var text = Redactor(values: known).redact(input)
        var found: [String] = []
        for (concept, regex) in patterns {
            let range = NSRange(text.startIndex..., in: text)
            guard regex.firstMatch(in: text, range: range) != nil else { continue }
            found.append(concept)
            let placeholder = ConceptCatalog.placeholder(for: concept)
            let matches = regex.matches(in: text, range: range).reversed()
            for m in matches {
                // Wertgruppe (letzte Gruppe) ersetzen, Schlüsselwort stehen lassen. Gruppenlose Muster (E-Mail) komplett.
                let target = m.numberOfRanges > 1 ? m.range(at: m.numberOfRanges - 1) : m.range
                if let r = Range(target, in: text) { text.replaceSubrange(r, with: placeholder) }
            }
        }
        return Result(text: text, detectedConcepts: found)
    }
}
