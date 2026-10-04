import Foundation

public struct PlanningInput: Sendable {
    public var intent: PortalIntent
    public var page: NormalizedPage
    public var completed: [Action]
    public var bindings: [CredentialBinding]
}

public struct PortalPlan: Sendable, Equatable {
    public var actions: [Action]
    public var missingValue: String?

    public init(actions: [Action], missingValue: String? = nil) {
        self.actions = actions
        self.missingValue = missingValue
    }
}

/// Planer-Schnittstelle. Implementierungen: `HeuristicPlanner` (regelbasiert, ohne AI) und ab
/// Phase 5 der Foundation-Models-Adapter. Die Ausgabe läuft immer durch den `SecurityValidator`.
public protocol PortalPlanner: Sendable {
    func plan(_ input: PlanningInput) async throws -> PortalPlan
}

/// Regelbasierter Planer aus Intent und normalisierter Seite. Dient als Fake-Modell in Tests
/// und als AI-freie Rückfallebene.
public struct HeuristicPlanner: PortalPlanner {
    public init() {}

    public func plan(_ input: PlanningInput) async throws -> PortalPlan {
        let page = input.page
        var actions: [Action] = []

        for c in ConsentPolicy.acceptable(in: page, intent: input.intent) {
            actions.append(.check(target: Self.target(for: c)))
        }

        var unmapped: String?
        for c in page.visibleControls where [.textField, .password, .textArea].contains(c.role) {
            guard let concept = c.concept else {
                if c.required { unmapped = c.displayText }
                continue
            }
            guard let src = Self.source(for: concept, intent: input.intent, bindings: input.bindings) else {
                if c.required { unmapped = concept }
                continue
            }
            actions.append(.fill(target: Self.target(for: c), value: src))
        }
        if unmapped != nil { return PortalPlan(actions: [.stop(.requiresManualInteraction)], missingValue: unmapped) }

        let submitButtons = page.visibleControls.filter { $0.role == .button && $0.submit }
        let chosen = submitButtons.first { ConsentPolicy.evaluate($0, action: "tap", policy: input.intent.policy) == .allow
            && !Self.isNegative($0.displayText) }
        if let b = chosen {
            actions.append(.tap(target: Self.target(for: b)))
        } else if let link = page.links.first(where: { ConsentPolicy.evaluate(Self.linkControl($0), action: "tap", policy: input.intent.policy) == .allow && !Self.isNegative($0.text) }),
                  actions.isEmpty {
            actions.append(.tap(target: Target(role: "link", labelAny: [link.text])))
        }
        guard !actions.isEmpty else { return PortalPlan(actions: [.stop(.requiresManualInteraction)]) }
        let remaining = actions.filter { !input.completed.contains($0) }
        return PortalPlan(actions: Array(remaining.prefix(4)))
    }

    public static func source(for concept: String, intent: PortalIntent, bindings: [CredentialBinding]) -> ValueSource? {
        for ins in intent.instructions {
            guard case .fill(let c, let src) = ins, c == concept else { continue }
            switch src {
            case .askWhenMissing:
                if let b = bindings.first(where: { $0.concept == concept }), b.persistence == .rememberInKeychain {
                    return .keychain(b.keychainKey)
                }
                return .ask(concept)
            case .keychain:
                if let b = bindings.first(where: { $0.concept == concept }) { return .keychain(b.keychainKey) }
                return .ask(concept)
            case .profile:
                return .profile(concept)
            }
        }
        return nil
    }

    public static func isNegative(_ text: String) -> Bool {
        let t = text.lowercased()
        return ["cancel", "abbrechen", "back", "zurück", "decline", "ablehnen"].contains { t.contains($0) }
    }

    static func linkControl(_ l: NormalizedLink) -> NormalizedControl {
        NormalizedControl(elementId: l.elementId, role: .button, tag: "a", inputType: nil, name: nil, htmlId: nil,
                          label: nil, text: l.text, placeholder: nil, ariaLabel: nil, autocomplete: nil,
                          nearbyText: nil, value: nil, required: false, checked: false, submit: false,
                          options: [], concept: nil, selector: "a", ordinal: 0)
    }

    /// Semantischer Descriptor eines Controls (01 §10, §12.4). Keine Werte, keine Hidden-Felder.
    public static func target(for c: NormalizedControl) -> Target {
        var t = Target()
        switch c.role {
        case .password: t.role = "password"
        case .textField, .textArea: t.role = "textField"
        case .checkbox: t.role = "checkbox"
        case .radio: t.role = "radio"
        case .select: t.role = "select"
        case .button: t.role = "button"
        case .hidden: break
        }
        t.concept = c.concept
        let text = String(c.displayText.prefix(80))
        if c.role == .button {
            if !text.isEmpty { t.labelAny = [text] }
        } else {
            if let l = c.label ?? c.ariaLabel { t.labelAny = [String(l.prefix(80))] }
            else if c.concept == nil, !text.isEmpty { t.labelAny = [text] }
            if let n = c.name { t.nameAny = [n] }
            if let p = c.placeholder { t.placeholderAny = [String(p.prefix(80))] }
        }
        t.lastKnownSelector = c.selector
        return t
    }
}
