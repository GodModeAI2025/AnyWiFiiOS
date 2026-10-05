#if canImport(FoundationModels)
import Foundation
import FoundationModels
import CaptiveCore

// MARK: Typisierte Modellausgaben (@Generable). Das Modell erzeugt nie Code oder Werte,
// nur Auswahlen aus geschlossenen Mengen. Die Runtime baut daraus Targets und Wertquellen.

@available(iOS 27.0, macOS 27.0, *)
@Generable
enum GenValueSource: String {
    case askWhenMissing
    case keychain
}

@available(iOS 27.0, macOS 27.0, *)
@Generable
enum GenPersistence: String {
    case askEveryTime
    case rememberInKeychain
}

@available(iOS 27.0, macOS 27.0, *)
@Generable
struct GenField {
    @Guide(description: "Konzept des Felds, genau eins von: username, password, lastName, roomNumber, email, voucherCode, accessCode, phoneNumber")
    var concept: String
    var source: GenValueSource
    var persistence: GenPersistence
    @Guide(description: "Kurze deutsche Beschriftung für den Nutzer, zum Beispiel Zimmernummer")
    var prompt: String
}

@available(iOS 27.0, macOS 27.0, *)
@Generable
struct GenIntentTurn {
    @Guide(description: "Kurze Antwort an den Nutzer auf Deutsch")
    var reply: String
    @Guide(description: "Eine Rückfrage, solange etwas Wichtiges unklar ist, sonst leer lassen")
    var question: String?
    var acceptRequiredTerms: Bool
    var acceptRequiredPrivacy: Bool
    @Guide(.maximumCount(8))
    var fields: [GenField]
    @Guide(description: "Nur true, wenn der Nutzer ausdrücklich Newsletter, Werbung oder Tracking erlaubt")
    var allowOptionalMarketingConsent: Bool
    var submit: Bool
    @Guide(description: "true, wenn alle Fragen geklärt sind")
    var isComplete: Bool
}

@available(iOS 27.0, macOS 27.0, *)
@Generable
enum GenActionKind: String {
    case check, uncheck, fill, tap, stop
}

@available(iOS 27.0, macOS 27.0, *)
@Generable
struct GenAction {
    var kind: GenActionKind
    @Guide(description: "elementId aus der Elementliste, zum Beispiel e3. Für stop leer lassen.")
    var elementId: String?
}

@available(iOS 27.0, macOS 27.0, *)
@Generable
struct GenPlan {
    @Guide(.maximumCount(4))
    var actions: [GenAction]
    @Guide(description: "Konzept eines fehlenden Werts, sonst leer")
    var missingValue: String?
}

@available(iOS 27.0, macOS 27.0, *)
@Generable
struct GenPatch {
    @Guide(description: "elementId des Buttons auf der aktuellen Seite, der dem alten Button entspricht")
    var elementId: String
}

@available(iOS 27.0, macOS 27.0, *)
enum AssistantPrompts {
    static let chatInstructions = """
    Du hilfst beim Einrichten der automatischen Anmeldung an einem WLAN mit Anmeldeseite (Captive Portal). \
    Ziel ist ein vollständiger Entwurf: welche Pflicht-Einwilligungen gesetzt werden, welche Felder mit welchem Wert \
    gefüllt werden und ob das Formular abgesendet wird. Stelle Rückfragen, bis nichts Wichtiges offen ist, zum Beispiel \
    ob eine Zimmernummer gespeichert oder jedes Mal erfragt werden soll. Stelle immer nur eine Rückfrage. \
    Frage nie nach Passwörtern oder anderen Werten selbst. Der Nutzer gibt sie in einem separaten sicheren Feld ein. \
    Werte erscheinen im Gespräch nur als Platzhalter wie <secret:password>. \
    Setze Newsletter, Werbung, Tracking oder kostenpflichtige Optionen nie, außer der Nutzer erlaubt Marketing ausdrücklich. \
    Kostenpflichtige Optionen sind nie erlaubt. Antworte kurz und auf Deutsch.
    """

    static let planInstructions = """
    Du steuerst die Anmeldung an einem Captive Portal. Wähle für die aktuelle Seite die nächsten wenigen Aktionen \
    (höchstens vier) aus der Elementliste: Pflicht-Checkboxen setzen, Felder füllen, dann den passenden Button drücken. \
    Verwende nur elementIds aus der Liste. Setze nie optionale Checkboxen für Newsletter, Werbung oder Tracking und \
    nie kostenpflichtige Optionen. Wenn die Seite nicht bedienbar ist, wähle stop.
    """

    static let repairInstructions = """
    Ein gespeicherter Anmeldeablauf findet seinen Button nicht mehr, weil das Portal die Beschriftung geändert hat. \
    Wähle aus der Elementliste den Button, der dem alten Button entspricht. Wähle nie einen Button, der etwas kauft, \
    abbricht oder ablehnt.
    """

}

/// Assistent auf Basis von Foundation Models. Generisch über das Sprachmodell:
/// `OnDeviceAssistant` (SystemLanguageModel, Standard) und `PCCAssistant` (Private Cloud Compute).
@available(iOS 27.0, macOS 27.0, *)
public struct FoundationModelsAssistant<Model: LanguageModel>: AssistantModel {
    private let model: Model
    private let availabilityProvider: @Sendable () -> AssistantAvailability
    private let label: String

    init(model: Model, label: String, availability: @escaping @Sendable () -> AssistantAvailability) {
        self.model = model
        self.label = label
        self.availabilityProvider = availability
    }

    public var availability: AssistantAvailability {
        get async { availabilityProvider() }
    }

    // MARK: Chat

    public func chatTurn(_ input: IntentChatInput) async throws -> IntentChatTurn {
        let session = LanguageModelSession(model: model, instructions: AssistantPrompts.chatInstructions)
        var prompt = ""
        if let page = input.portalContext {
            prompt += "Elemente der Portalseite:\n\(Self.elementList(page))\n\n"
        }
        prompt += "Bisheriger Entwurf: \(Self.describe(input.currentDraft))\n\nGespräch:\n"
        prompt += input.transcript.map { "\($0.role == "user" ? "Nutzer" : "Assistent"): \($0.text)" }.joined(separator: "\n")
        let r = try await session.respond(to: prompt, generating: GenIntentTurn.self, options: GenerationOptions(temperature: 0.2))
        let t = r.content
        let draft = PortalIntentDraft(
            acceptRequiredTerms: t.acceptRequiredTerms, acceptRequiredPrivacy: t.acceptRequiredPrivacy,
            fields: t.fields.map { f in
                PortalIntentDraft.Field(
                    concept: f.concept,
                    source: f.source == .keychain ? .keychain : .askWhenMissing,
                    persistence: f.persistence == .rememberInKeychain ? .rememberInKeychain : .askEveryTime,
                    prompt: f.prompt)
            },
            allowOptionalMarketingConsent: t.allowOptionalMarketingConsent, submit: t.submit)
        let q = t.question.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return IntentChatTurn(reply: t.reply, question: q, draft: draft, isComplete: t.isComplete && q == nil)
    }


    // MARK: Planung

    public func plan(_ input: PlanningInput) async throws -> PortalPlan {
        let session = LanguageModelSession(model: model, instructions: AssistantPrompts.planInstructions)
        var prompt = "Absicht: \(Self.describe(input.intent))\n\nElemente der Seite:\n\(Self.elementList(input.page))\n"
        if !input.completed.isEmpty { prompt += "\nBereits ausgeführt: \(input.completed.map(\.opcode).joined(separator: ", "))\n" }
        let r = try await session.respond(to: prompt, generating: GenPlan.self, options: GenerationOptions(temperature: 0))
        var actions: [Action] = []
        for a in r.content.actions {
            switch a.kind {
            case .stop:
                actions.append(.stop(.requiresManualInteraction))
            case .check, .uncheck, .tap, .fill:
                guard let id = a.elementId, let c = input.page.control(id) else { continue }
                let target = HeuristicPlanner.target(for: c)
                switch a.kind {
                case .check: actions.append(.check(target: target))
                case .uncheck: actions.append(.uncheck(target: target))
                case .tap: actions.append(.tap(target: target))
                default:
                    // Wertquelle bestimmt die Runtime aus Intent und Bindings, nie das Modell.
                    guard let concept = c.concept,
                          let source = HeuristicPlanner.source(for: concept, intent: input.intent, bindings: input.bindings) else { continue }
                    actions.append(.fill(target: target, value: source))
                }
            }
        }
        return PortalPlan(actions: actions, missingValue: r.content.missingValue)
    }


    // MARK: Reparatur

    public func proposePatch(_ input: RepairInput) async throws -> RecipePatch? {
        guard let sid = input.failedStageId, let ai = input.failedActionIndex,
              let stage = input.recipe.stages.first(where: { $0.id == sid }), stage.actions.indices.contains(ai),
              case .tap(let old) = stage.actions[ai], old.role == "button" else { return nil }
        let session = LanguageModelSession(model: model, instructions: AssistantPrompts.repairInstructions)
        let prompt = "Alter Button: \(old.labelAny.joined(separator: ", "))\nFehler: \(input.reason ?? "unbekannt")\n\nElemente der Seite:\n\(Self.elementList(input.page))"
        let r = try await session.respond(to: prompt, generating: GenPatch.self, options: GenerationOptions(temperature: 0))
        guard let c = input.page.control(r.content.elementId), c.role == .button, !c.displayText.isEmpty else { return nil }
        var new = old
        new.labelAny = old.labelAny + [String(c.displayText.prefix(80))]
        new.lastKnownSelector = c.selector
        return RecipePatch(stageId: sid, actionIndex: ai, replace: old, with: new)
    }


    // MARK: Hilfen

    static func elementList(_ page: NormalizedPage) -> String {
        var lines: [String] = []
        for c in page.visibleControls {
            var parts = ["\(c.elementId)", c.role.rawValue]
            if c.required { parts.append("pflicht") }
            if c.checked { parts.append("gesetzt") }
            if let k = c.concept { parts.append("konzept=\(k)") }
            let text = String(c.displayText.prefix(80))
            if !text.isEmpty { parts.append("\"\(text)\"") }
            lines.append(parts.joined(separator: " | "))
        }
        for l in page.links { lines.append("\(l.elementId) | link | \"\(String(l.text.prefix(60)))\"") }
        return lines.isEmpty ? "(keine)" : lines.joined(separator: "\n")
    }

    static func describe(_ d: PortalIntentDraft) -> String {
        let f = d.fields.map { "\($0.concept)(\($0.source.rawValue))" }.joined(separator: ", ")
        return "Einwilligungen: \(d.acceptRequiredTerms ? "AGB " : "")\(d.acceptRequiredPrivacy ? "Datenschutz" : ""); Felder: \(f.isEmpty ? "keine" : f); absenden: \(d.submit)"
    }

    static func describe(_ i: PortalIntent) -> String {
        i.instructions.map { ins -> String in
            switch ins {
            case .acceptRequiredTerms: "AGB akzeptieren"
            case .acceptRequiredPrivacy: "Datenschutz akzeptieren"
            case .fill(let c, _): "\(c) eintragen"
            case .submit: "absenden"
            }
        }.joined(separator: ", ")
    }
}

/// Lokales Modell (Standard). Verfügbar auf Apple-Intelligence-Geräten.
@available(iOS 27.0, macOS 27.0, *)
public enum OnDeviceAssistant {
    public static func make() -> FoundationModelsAssistant<SystemLanguageModel> {
        FoundationModelsAssistant(model: .default, label: "on-device") {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.deviceNotEligible): return .unavailable(.deviceNotEligible)
            case .unavailable(.appleIntelligenceNotEnabled): return .unavailable(.appleIntelligenceDisabled)
            case .unavailable(.modelNotReady): return .unavailable(.modelNotReady)
            case .unavailable: return .unavailable(.other)
            }
        }
    }
}

/// Private Cloud Compute (SPEC §3.2): nur mit Entitlement `com.apple.developer.private-cloud-compute`
/// und Internet, nie im Live-Login (01 §15). Die Ausgabe durchläuft denselben Validator.
@available(iOS 27.0, macOS 27.0, *)
public enum PCCAssistant {
    public static func make() -> FoundationModelsAssistant<PrivateCloudComputeLanguageModel> {
        let pcc = PrivateCloudComputeLanguageModel()
        return FoundationModelsAssistant(model: pcc, label: "pcc") {
            switch pcc.availability {
            case .available: return .available
            case .unavailable(.deviceNotEligible): return .unavailable(.deviceNotEligible)
            case .unavailable(.systemNotReady): return .unavailable(.modelNotReady)
            case .unavailable: return .unavailable(.other)
            }
        }
    }
}
#endif
