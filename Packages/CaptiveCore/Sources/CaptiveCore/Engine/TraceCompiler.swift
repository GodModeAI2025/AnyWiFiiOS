import Foundation

/// Kompiliert einen erfolgreichen Lerntrace in ein Recipe (01 §12.4).
/// Verworfen werden Hidden-/CSRF-Werte, Cookies und flüchtige Daten. Es bleiben semantische Targets.
public enum TraceCompiler {
    public static func compile(trace: [TraceStep], name: String, ssid: String, profileId: String? = nil) -> Recipe {
        let grouped = Dictionary(grouping: trace, by: \.pageIndex)
        var stages: [Stage] = []
        for pageIndex in grouped.keys.sorted() {
            let steps = (grouped[pageIndex] ?? []).sorted { $0.index < $1.index }
            let actions = steps.compactMap(stableAction)
            guard !actions.isEmpty else { continue }
            stages.append(Stage(id: stageId(stages.count + 1, steps: steps), match: stageMatch(steps), actions: actions))
        }
        return Recipe(profileId: profileId, name: name, ssid: ssid, stages: stages, success: .init(internetAccess: true))
    }

    /// Nur wiederholbare, semantisch beschriebene Aktionen. Rohe Werte gelangen nie ins Recipe,
    /// Werte bleiben Referenzen (`ask`, `keychain`, `profile`).
    private static func stableAction(_ s: TraceStep) -> Action? {
        switch s.action {
        case .fill(let target, let value):
            switch value {
            case .literal, .runtime: return nil // flüchtig oder nicht reproduzierbar
            default: return .fill(target: target, value: value)
            }
        case .check, .uncheck, .tap, .select, .submit, .verify, .waitFor, .requestValue:
            return s.action
        case .stop:
            return nil
        }
    }

    private static func stageId(_ n: Int, steps: [TraceStep]) -> String {
        let hasFill = steps.contains { if case .fill = $0.action { true } else { false } }
        let hasCheck = steps.contains { if case .check = $0.action { true } else { false } }
        return "s\(n)_\(hasFill ? "form" : hasCheck ? "terms" : "step")"
    }

    private static func stageMatch(_ steps: [TraceStep]) -> StageMatch {
        var fields: [String] = []
        var texts: [String] = []
        for s in steps {
            switch s.action {
            case .fill(let t, _):
                if let c = t.concept, !fields.contains(c) { fields.append(c) }
            case .check:
                if let c = s.control { texts.append(String(c.displayText.prefix(60))) }
            case .tap:
                break
            default: break
            }
        }
        if fields.isEmpty, texts.isEmpty {
            for s in steps { if case .tap = s.action, let c = s.control { texts.append(String(c.displayText.prefix(60))) } }
        }
        return StageMatch(anyText: Array(texts.prefix(3)), fields: fields)
    }
}
