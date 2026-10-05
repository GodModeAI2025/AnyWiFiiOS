import Foundation

/// Statische Sicherheitsprüfung für Recipes und Pläne (01 §24). Das Modell ist Planer, nicht
/// Security Authority. Die Runtime hat immer die letzte Entscheidung.
public enum SecurityValidator {
    private static let forbiddenConcepts: Set<String> = [
        "cardNumber", "cvv", "cvc", "iban", "creditCard", "cardHolder", "paymentToken", "expiry",
    ]

    public static func validate(_ recipe: Recipe, bindings: [CredentialBinding] = [],
                                context: ValidationContext = .init()) -> [ValidationIssue] {
        var ctx = context
        if ctx.knownKeychainKeys == nil, !bindings.isEmpty {
            ctx.knownKeychainKeys = Set(bindings.map(\.keychainKey))
        }
        var issues = RecipeValidator.validate(recipe, context: ctx)
        for (si, stage) in recipe.stages.enumerated() {
            for (ai, action) in stage.actions.enumerated() {
                let p = "stages[\(si)].actions[\(ai)]"
                issues += check(action, path: p, bindings: bindings)
                for s in strings(of: action) where containsCode(s) {
                    issues.append(.init(.error, path: p, "enthält Script-/Code-Fragment"))
                }
            }
            for s in stage.match.anyText + stage.match.urlContains where containsCode(s) {
                issues.append(.init(.error, path: "stages[\(si)].match", "enthält Script-/Code-Fragment"))
            }
        }
        return issues
    }

    public static func errors(_ recipe: Recipe, bindings: [CredentialBinding] = [],
                              context: ValidationContext = .init()) -> [ValidationIssue] {
        validate(recipe, bindings: bindings, context: context).filter { $0.severity == .error }
    }

    /// Validiert eine einzelne, vom Planer vorgeschlagene Aktionsgruppe (Limit pro Runde, S/§20).
    public static func validate(plan actions: [Action], bindings: [CredentialBinding] = [],
                                maxActions: Int = 4) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if actions.count > maxActions {
            issues.append(.init(.error, path: "plan", "mehr als \(maxActions) Aktionen pro Runde"))
        }
        for (i, a) in actions.enumerated() {
            let p = "plan[\(i)]"
            issues += check(a, path: p, bindings: bindings)
            for s in strings(of: a) where containsCode(s) {
                issues.append(.init(.error, path: p, "enthält Script-/Code-Fragment"))
            }
        }
        return issues
    }

    private static func check(_ action: Action, path p: String, bindings: [CredentialBinding]) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        switch action {
        case .fill(let target, let value):
            if let c = target.concept, forbiddenConcepts.contains(c) {
                issues.append(.init(.error, path: p, "Zahlungsdaten sind nicht erlaubt (\(c))"))
            }
            switch value {
            case .literal:
                if let c = target.concept, ConceptCatalog.sensitivity(of: c) != .public {
                    issues.append(.init(.error, path: p, "Literal für sensibles Konzept '\(c)' nicht erlaubt"))
                }
                if target.concept == nil {
                    issues.append(.init(.error, path: p, "Literal ohne Konzept nicht erlaubt"))
                }
            case .keychain(let key):
                if let b = bindings.first(where: { $0.keychainKey == key }), let c = target.concept, b.concept != c {
                    issues.append(.init(.error, path: p, "Keychain-Wert '\(key)' gehört zu '\(b.concept)', nicht '\(c)'"))
                }
            case .ask(let c), .runtime(let c):
                if let tc = target.concept, tc != c {
                    issues.append(.init(.error, path: p, "Wert '\(c)' darf nicht in Feld '\(tc)'"))
                }
            case .profile:
                break
            }
        case .check(let t), .tap(let t), .select(let t, _):
            if paidTarget(t) { issues.append(.init(.error, path: p, "Kostenpflichtige Aktion ist in V1 nicht automatisierbar")) }
        default:
            break
        }
        return issues
    }

    private static func paidTarget(_ t: Target) -> Bool {
        (t.labelAny + t.nearbyAny + t.ariaAny + t.placeholderAny).contains(where: ConsentPolicy.isPaid)
    }

    private static func strings(of action: Action) -> [String] {
        func t(_ x: Target) -> [String] {
            x.labelAny + x.nameAny + x.placeholderAny + x.ariaAny + x.nearbyAny
                + [x.role, x.concept, x.lastKnownSelector].compactMap { $0 }
        }
        switch action {
        case .fill(let target, let v):
            let s: String = switch v {
            case .literal(let s), .profile(let s), .keychain(let s), .ask(let s), .runtime(let s): s
            }
            return t(target) + [s]
        case .check(let x), .uncheck(let x), .tap(let x): return t(x)
        case .select(let x, let o): return t(x) + [o]
        case .requestValue(let c, let p): return [c] + (p.map { [$0] } ?? [])
        case .waitFor(let c):
            switch c {
            case .urlContains(let s), .elementConcept(let s): return [s]
            case .textAny(let l): return l
            }
        case .verify(let c):
            if case .pageContainsAny(let l) = c { return l }
            return []
        case .submit, .stop: return []
        }
    }

    static func containsCode(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.contains("javascript:") || l.contains("<script") || l.contains("onerror=") || l.contains("onclick=")
            || l.contains("eval(") || l.contains("document.") || l.contains("window.")
    }
}

/// Host-Regeln für Credential-Weitergabe (01 §25). Erlaubt sind Hosts der Redirect-Kette,
/// die Host des aktuellen Portals und Profil-Hints. Form-Action-Hosts erweitern die Menge
/// bewusst NICHT, sonst könnte eine Portalseite beliebige Ziele freischalten (ADR 0001).
public struct HostPolicy: Sendable, Equatable {
    public private(set) var credentialHosts: Set<String>

    public init(hints: [String] = []) {
        credentialHosts = Set(hints.map { $0.lowercased() })
    }

    public mutating func allow(_ host: String?) {
        if let h = host?.lowercased(), !h.isEmpty { credentialHosts.insert(h) }
    }

    public func permitsCredentials(to host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return credentialHosts.contains(h)
    }
}
