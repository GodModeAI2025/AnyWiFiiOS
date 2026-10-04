import Foundation

/// Regelbasierter Planner ohne Sprachmodell.
///
/// Setzt einen `PortalIntent` auf typischen Portalseiten um: Pflicht-Einwilligungen anhaken,
/// vorausgewähltes Marketing abwählen, Felder mit bekannten Konzepten füllen, nicht-kommerziellen
/// Submit-Button drücken. Dient als Rückfallebene ohne Apple Intelligence (SPEC §3.2) und als
/// deterministischer Planner in Tests. Seine Pläne laufen durch denselben `PlanValidator`.
public struct HeuristicPlanner: PortalPlanner {
    static let consentWords = ["terms", "agb", "nutzungsbedingungen", "bedingungen", "datenschutz", "privacy",
                               "accept", "akzept", "agree", "conditions", "einverstanden", "richtlinie", "policy"]
    static let submitWords = ["connect", "continue", "login", "log in", "verbinden", "weiter", "einloggen",
                              "anmelden", "accept", "akzeptieren", "start", "surf", "free", "kostenlos", "go"]

    public init() {}

    public func nextPlan(_ input: PlanningInput) async throws -> PortalPlan {
        let page = input.page
        let intent = input.intent
        var actions: [PlannedAction] = []

        // 1. Felder mit erkannten Konzepten.
        for control in page.interactiveControls where control.role == .textField || control.role == .passwordField {
            guard let concept = control.concept else { continue }
            guard intent.bindings[concept] != nil else {
                if control.required {
                    return PortalPlan(reasoningSummary: "\(concept.displayName) wird verlangt", actions: [],
                                      expectedTransition: .samePage, missingValue: concept)
                }
                continue
            }
            actions.append(PlannedAction(kind: .fill, elementId: control.elementId, concept: concept))
        }

        // 2. Einwilligungen.
        let wantsConsent = intent.instructions.contains(.acceptRequiredTerms)
            || intent.instructions.contains(.acceptRequiredPrivacy)
        for control in page.interactiveControls where control.role == .checkbox {
            let commercial = ConsentClassifier.isCommercial(control.descriptors)
            let marketing = ConsentClassifier.isMarketing(control.descriptors)
            if control.checked {
                if (marketing && !intent.policy.allowOptionalMarketingConsent) || commercial {
                    actions.append(PlannedAction(kind: .uncheck, elementId: control.elementId))
                }
                continue
            }
            guard wantsConsent, !commercial, !marketing else { continue }
            let text = control.descriptors.joined(separator: " ").lowercased()
            if control.required || Self.consentWords.contains(where: { text.contains($0) }) {
                actions.append(PlannedAction(kind: .check, elementId: control.elementId))
            }
        }

        // 3. Absenden.
        if let button = Self.submitButton(on: page) {
            actions.append(PlannedAction(kind: .tap, elementId: button.elementId))
        }

        return PortalPlan(reasoningSummary: "Regelbasiert: \(actions.count) Aktionen",
                          actions: Array(actions.prefix(PlanValidator.maxActions)),
                          expectedTransition: .newPage)
    }

    public func repairTarget(old: Target, opcode: PortalAction.Opcode, intent: PortalIntent,
                             page: PortalPage) async throws -> RepairSuggestion? {
        switch opcode {
        case .tap, .submit:
            guard let button = Self.submitButton(on: page) else { return nil }
            return RepairSuggestion(elementId: button.elementId, reasoningSummary: "Einziger passender Absende-Button")
        case .fill:
            guard let concept = old.concept,
                  let field = page.interactiveControls.first(where: { $0.concept == concept }) else { return nil }
            return RepairSuggestion(elementId: field.elementId, reasoningSummary: "Feld mit Konzept \(concept.rawValue)")
        default:
            return nil
        }
    }

    /// Nicht-kommerzieller Submit-Button, bevorzugt mit typischer Beschriftung; sonst ein „Weiter“-Link.
    static func submitButton(on page: PortalPage) -> PortalControl? {
        let buttons = page.interactiveControls.filter {
            $0.role == .button && $0.isSubmit && !ConsentClassifier.isCommercial($0.descriptors)
        }
        func preferred(_ c: PortalControl) -> Bool {
            let text = c.captions.joined(separator: " ").lowercased()
            return submitWords.contains(where: { text.contains($0) })
        }
        if let best = buttons.first(where: preferred) ?? buttons.first { return best }
        return page.links.first { preferred($0) && !ConsentClassifier.isCommercial($0.descriptors) }
    }
}
