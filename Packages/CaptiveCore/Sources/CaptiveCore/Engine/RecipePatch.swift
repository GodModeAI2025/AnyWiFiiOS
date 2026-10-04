import Foundation

/// Kleiner Reparaturvorschlag (01 §14, §15.3): ersetzt genau ein Target einer Aktion durch ein
/// breiteres. Keine neuen Opcodes, keine neuen Werte.
public struct RecipePatch: Equatable, Sendable {
    public var stageId: String
    public var actionIndex: Int
    public var replace: Target
    public var with: Target

    public init(stageId: String, actionIndex: Int, replace: Target, with: Target) {
        self.stageId = stageId
        self.actionIndex = actionIndex
        self.replace = replace
        self.with = with
    }

    public enum PatchError: Error, Equatable, Sendable {
        case stageNotFound, actionNotFound, targetMismatch, actionHasNoTarget, rejected(String)
    }

    /// Wendet den Patch an. Der Alt-Target muss exakt dem gespeicherten entsprechen und das Ergebnis
    /// muss den Security-Validator passieren.
    public func apply(to recipe: Recipe, bindings: [CredentialBinding] = []) throws -> Recipe {
        guard let si = recipe.stages.firstIndex(where: { $0.id == stageId }) else { throw PatchError.stageNotFound }
        guard recipe.stages[si].actions.indices.contains(actionIndex) else { throw PatchError.actionNotFound }
        var out = recipe
        let action = recipe.stages[si].actions[actionIndex]
        let replaced: Action
        switch action {
        case .tap(let t): guard t == replace else { throw PatchError.targetMismatch }; replaced = .tap(target: with)
        case .check(let t): guard t == replace else { throw PatchError.targetMismatch }; replaced = .check(target: with)
        case .uncheck(let t): guard t == replace else { throw PatchError.targetMismatch }; replaced = .uncheck(target: with)
        case .select(let t, let o): guard t == replace else { throw PatchError.targetMismatch }; replaced = .select(target: with, option: o)
        case .fill(let t, let v): guard t == replace else { throw PatchError.targetMismatch }; replaced = .fill(target: with, value: v)
        default: throw PatchError.actionHasNoTarget
        }
        // Rolle und Konzept dürfen sich nicht ändern: ein Patch repariert Beschriftungen, er baut nichts um.
        guard with.role == replace.role, with.concept == replace.concept else {
            throw PatchError.rejected("Rolle oder Konzept ändern sich")
        }
        out.stages[si].actions[actionIndex] = replaced
        if let issue = SecurityValidator.errors(out, bindings: bindings).first {
            throw PatchError.rejected(issue.description)
        }
        return out
    }
}

public protocol RecipeRepairer: Sendable {
    func proposePatch(_ input: RepairInput) async throws -> RecipePatch?
}

/// Regelbasierte lokale Reparatur ohne Modell: Wenn ein Button nicht mehr gefunden wird und die
/// Seite genau einen erlaubten Submit-Button hat, wird dessen Beschriftung ergänzt.
public struct HeuristicRepairer: RecipeRepairer {
    public init() {}

    public func proposePatch(_ input: RepairInput) async throws -> RecipePatch? {
        guard let sid = input.failedStageId, let ai = input.failedActionIndex,
              let stage = input.recipe.stages.first(where: { $0.id == sid }),
              stage.actions.indices.contains(ai), case .tap(let old) = stage.actions[ai], old.role == "button" else { return nil }
        let candidates = input.page.visibleControls.filter {
            $0.role == .button && $0.submit && ConsentPolicy.evaluate($0, action: "tap", policy: input.intent.policy) == .allow
                && !HeuristicPlanner.isNegative($0.displayText)
        }
        guard candidates.count == 1, let button = candidates.first, !button.displayText.isEmpty else { return nil }
        var new = old
        new.labelAny = old.labelAny + [String(button.displayText.prefix(80))]
        new.lastKnownSelector = button.selector
        return RecipePatch(stageId: sid, actionIndex: ai, replace: old, with: new)
    }
}
