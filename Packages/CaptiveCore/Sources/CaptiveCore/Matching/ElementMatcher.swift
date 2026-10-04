import Foundation

public struct ElementMatch: Equatable, Sendable {
    public enum Reason: String, Sendable { case concept, label, name, placeholder, aria, nearby, selector, ordinal, roleOnly }
    public var control: NormalizedControl
    public var score: Int
    public var reasons: [Reason]
    public var usedSelectorFallback: Bool { reasons == [.selector] }
}

/// Semantisches Matching (01 §10). Reihenfolge: Konzept, Label/Name, HTML-Semantik,
/// Nähe, letzter Selector. Der Selector ist nur Fallback.
public enum ElementMatcher {
    public static func find(_ target: Target, in page: NormalizedPage) -> ElementMatch? {
        let candidates = page.allControls.filter { roleCompatible(target.role, $0) }
        var best: ElementMatch?
        for c in candidates {
            var score = 0
            var reasons: [ElementMatch.Reason] = []
            if let concept = target.concept, c.concept == concept { score += 100; reasons.append(.concept) }
            if anyHit(target.labelAny, in: [c.label, c.text, c.displayText]) { score += 60; reasons.append(.label) }
            if anyHit(target.nameAny, in: [c.name, c.htmlId]) { score += 50; reasons.append(.name) }
            if anyHit(target.placeholderAny, in: [c.placeholder]) { score += 50; reasons.append(.placeholder) }
            if anyHit(target.ariaAny, in: [c.ariaLabel]) { score += 50; reasons.append(.aria) }
            if anyHit(target.nearbyAny, in: [c.nearbyText]) { score += 30; reasons.append(.nearby) }
            if let sel = target.lastKnownSelector, sel == c.selector { score += 20; reasons.append(.selector) }
            if let o = target.ordinal, o == c.ordinal { score += 5; reasons.append(.ordinal) }
            let hasSpecifics = target.concept != nil || !target.labelAny.isEmpty || !target.nameAny.isEmpty
                || !target.placeholderAny.isEmpty || !target.ariaAny.isEmpty || !target.nearbyAny.isEmpty
                || target.lastKnownSelector != nil
            if !hasSpecifics { score = max(score, 10); if reasons.isEmpty { reasons.append(.roleOnly) } }
            guard score >= (hasSpecifics ? 20 : 5) else { continue }
            // Konzept-Konflikt: Ein Target mit Konzept trifft kein Feld mit anderem Konzept.
            if let tc = target.concept, let cc = c.concept, tc != cc { continue }
            let m = ElementMatch(control: c, score: score, reasons: reasons)
            if best == nil || m.score > best!.score { best = m }
        }
        return best
    }

    public static func roleCompatible(_ role: String?, _ c: NormalizedControl) -> Bool {
        guard let role else { return c.role != .hidden }
        switch role {
        case "button": return c.role == .button
        case "checkbox": return c.role == .checkbox
        case "radio": return c.role == .radio
        case "select": return c.role == .select
        case "password": return c.role == .password
        case "textField", "text": return [.textField, .password, .textArea].contains(c.role)
        default: return false
        }
    }

    static func anyHit(_ needles: [String], in hay: [String?]) -> Bool {
        guard !needles.isEmpty else { return false }
        let hs = hay.compactMap { $0 }.map(ConceptInference.fold).filter { !$0.isEmpty }
        for n in needles {
            let f = ConceptInference.fold(n)
            if f.isEmpty { continue }
            if hs.contains(where: { $0.contains(f) }) { return true }
        }
        return false
    }
}

public enum StageMatcher {
    public static func matches(_ stage: Stage, page: NormalizedPage) -> Bool {
        let m = stage.match
        if !m.anyText.isEmpty {
            let hay = ConceptInference.fold(page.text + " " + page.title + " " + page.allControls.map(\.displayText).joined(separator: " "))
            if !m.anyText.contains(where: { hay.contains(ConceptInference.fold($0)) }) { return false }
        }
        if !m.fields.isEmpty {
            let concepts = Set(page.visibleControls.compactMap(\.concept))
            if !m.fields.allSatisfy(concepts.contains) { return false }
        }
        if !m.urlContains.isEmpty, !m.urlContains.contains(where: { page.url.contains($0) }) { return false }
        return true
    }

    /// Erste passende, noch nicht ausgeführte Stage.
    public static func firstMatch(in recipe: Recipe, page: NormalizedPage, excluding done: Set<String>) -> Stage? {
        recipe.stages.first { !done.contains($0.id) && matches($0, page: page) }
    }
}
