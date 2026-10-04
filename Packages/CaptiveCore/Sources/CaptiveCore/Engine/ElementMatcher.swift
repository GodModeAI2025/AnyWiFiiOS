import Foundation

/// Findet zu einem semantischen `Target` das passende Element einer Seite (01 §10).
///
/// Reihenfolge der Merkmale (absteigendes Gewicht): concept → id/name → Label → Placeholder →
/// HTML-Semantik (type/autocomplete) → umgebender Text → letzter bekannter Selector (nur Fallback).
/// Gibt es mehrere gleich gute Kandidaten, ist das ein Fehler (`ambiguous`), kein Raten.
public enum ElementMatcher {
    public enum Failure: Error, Equatable, Sendable {
        case notFound
        case ambiguous([String])
    }

    public struct Match: Equatable, Sendable {
        public var control: PortalControl
        public var score: Int
    }

    static let minimumScore = 20

    public static func resolve(_ target: Target, in page: PortalPage) -> Result<Match, Failure> {
        let scored = page.interactiveControls.compactMap { control -> Match? in
            guard let score = score(target, control) else { return nil }
            return Match(control: control, score: score)
        }
        .filter { $0.score >= minimumScore }
        .sorted { $0.score > $1.score }

        guard let best = scored.first else { return .failure(.notFound) }
        let ties = scored.filter { $0.score == best.score }
        if ties.count == 1 { return .success(best) }
        if let ordinal = target.ordinal, ordinal < ties.count { return .success(ties[ordinal]) }
        return .failure(.ambiguous(ties.map(\.control.elementId)))
    }

    /// `nil` = Kandidat ausgeschlossen (falsche Rolle, widersprechendes Konzept).
    static func score(_ target: Target, _ control: PortalControl) -> Int? {
        guard let role = control.role else { return nil }
        if let wanted = target.role, !rolesCompatible(wanted, role) { return nil }
        if let wanted = target.concept, let actual = control.concept, wanted != actual { return nil }

        var score = 0
        if let wanted = target.concept, control.concept == wanted { score += 100 }

        if let id = target.id, equalsIgnoringCase(id, control.htmlId) { score += 80 }
        if let name = target.name, equalsIgnoringCase(name, control.name) { score += 60 }
        if let names = target.nameAny, names.contains(where: { equalsIgnoringCase($0, control.name) }) { score += 60 }

        if let labels = target.labelAny {
            score += bestTextScore(labels, control.captions, exact: 60, partial: 50)
        }
        if let placeholders = target.placeholderAny {
            score += bestTextScore(placeholders, [control.placeholder].compactMap { $0 }, exact: 40, partial: 35)
        }
        if let type = target.type, equalsIgnoringCase(type, control.inputType) { score += 10 }
        if let autocomplete = target.autocomplete, equalsIgnoringCase(autocomplete, control.autocomplete) { score += 10 }
        if let nearby = target.nearbyText {
            score += bestTextScore(nearby, [control.nearbyText, control.label].compactMap { $0 }, exact: 20, partial: 20)
        }
        if let selector = target.lastKnownSelector, selectorMatches(selector, control) { score += 25 }
        return score
    }

    static func rolesCompatible(_ wanted: ElementRole, _ actual: ElementRole) -> Bool {
        switch (wanted, actual) {
        case (.textField, .passwordField), (.passwordField, .textField): return true
        case (.checkbox, .radio), (.radio, .checkbox): return false
        default: return wanted == actual
        }
    }

    /// Bester Treffer aus Suchbegriffen gegen Beschriftungen: exakt (normalisiert) oder enthalten.
    static func bestTextScore(_ needles: [String], _ haystacks: [String], exact: Int, partial: Int) -> Int {
        var best = 0
        for needle in needles.map(normalized) where !needle.isEmpty {
            for hay in haystacks.map(normalized) where !hay.isEmpty {
                if hay == needle {
                    best = max(best, exact)
                } else if hay.contains(needle) {
                    best = max(best, partial)
                }
            }
        }
        return best
    }

    /// Unterstützt die einfachen Selector-Formen, die der Trace-Compiler schreibt: `#id`, `[name=x]`, `tag[name=x]`.
    static func selectorMatches(_ selector: String, _ control: PortalControl) -> Bool {
        let s = selector.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { return String(s.dropFirst()) == control.htmlId }
        if let open = s.firstIndex(of: "["), s.hasSuffix("]") {
            let tag = String(s[..<open]).lowercased()
            if !tag.isEmpty && tag != control.tag { return false }
            let inner = s[s.index(after: open)..<s.index(before: s.endIndex)]
            let parts = inner.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
            }
            if parts.count == 2, parts[0] == "name" { return parts[1] == control.name }
        }
        return false
    }

    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    static func equalsIgnoringCase(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        return a.lowercased() == b.lowercased()
    }
}
