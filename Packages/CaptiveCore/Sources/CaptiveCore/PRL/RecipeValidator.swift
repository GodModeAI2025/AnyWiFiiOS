import Foundation

public struct ValidationIssue: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }
    public var severity: Severity
    public var path: String
    public var message: String

    public init(_ severity: Severity, path: String, _ message: String) {
        self.severity = severity
        self.path = path
        self.message = message
    }

    public var description: String { "[\(severity.rawValue)] \(path): \(message)" }
}

public struct ValidationContext: Sendable {
    /// Bekannte Keychain-Schlüssel des Profils. `nil` = nicht prüfen.
    public var knownKeychainKeys: Set<String>?
    public var maxStages: Int
    public var maxActionsPerStage: Int

    public init(knownKeychainKeys: Set<String>? = nil, maxStages: Int = 12, maxActionsPerStage: Int = 20) {
        self.knownKeychainKeys = knownKeychainKeys
        self.maxStages = maxStages
        self.maxActionsPerStage = maxActionsPerStage
    }
}

/// Schema-Validierung auf Modellebene (Struktur, Limits, Referenzen). Sicherheitsregeln
/// (Payment, Hosts, Literale) liegen im `SecurityValidator`.
public enum RecipeValidator {
    public static func validate(_ recipe: Recipe, context: ValidationContext = .init()) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if recipe.recipeVersion != Recipe.currentVersion {
            issues.append(.init(.error, path: "recipeVersion", "nicht unterstützt: \(recipe.recipeVersion)"))
        }
        if recipe.name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(.error, path: "name", "darf nicht leer sein"))
        }
        if recipe.ssid.isEmpty {
            issues.append(.init(.error, path: "network.ssid", "darf nicht leer sein"))
        }
        if recipe.stages.isEmpty {
            issues.append(.init(.error, path: "stages", "mindestens eine Stage nötig"))
        }
        if recipe.stages.count > context.maxStages {
            issues.append(.init(.error, path: "stages", "mehr als \(context.maxStages) Stages"))
        }
        var ids = Set<String>()
        for (si, stage) in recipe.stages.enumerated() {
            let sp = "stages[\(si)]"
            if stage.id.isEmpty { issues.append(.init(.error, path: "\(sp).id", "darf nicht leer sein")) }
            if !ids.insert(stage.id).inserted { issues.append(.init(.error, path: "\(sp).id", "doppelte Stage-ID '\(stage.id)'")) }
            if stage.actions.isEmpty { issues.append(.init(.error, path: "\(sp).actions", "mindestens eine Aktion nötig")) }
            if stage.actions.count > context.maxActionsPerStage {
                issues.append(.init(.error, path: "\(sp).actions", "mehr als \(context.maxActionsPerStage) Aktionen"))
            }
            for (ai, action) in stage.actions.enumerated() {
                let ap = "\(sp).actions[\(ai)]"
                switch action {
                case .fill(_, let value):
                    switch value {
                    case .keychain(let key), .profile(let key):
                        if let known = context.knownKeychainKeys, !known.contains(key) {
                            issues.append(.init(.error, path: ap, "unbekannte Referenz '\(key)'"))
                        }
                    case .ask(let c), .runtime(let c):
                        if c.isEmpty { issues.append(.init(.error, path: ap, "Konzept darf nicht leer sein")) }
                    case .literal:
                        break
                    }
                case .requestValue(let c, _):
                    if c.isEmpty { issues.append(.init(.error, path: ap, "Konzept darf nicht leer sein")) }
                case .verify(.pageContainsAny(let l)), .waitFor(.textAny(let l)):
                    if l.isEmpty { issues.append(.init(.error, path: ap, "Liste darf nicht leer sein")) }
                default:
                    break
                }
            }
        }
        return issues
    }

    public static func errors(_ recipe: Recipe, context: ValidationContext = .init()) -> [ValidationIssue] {
        validate(recipe, context: context).filter { $0.severity == .error }
    }
}
