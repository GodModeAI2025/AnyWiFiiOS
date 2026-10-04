#if canImport(FoundationModels)
import CaptiveCore
import Foundation
import FoundationModels

// On-device-Planner mit Apple Foundation Models (01 §16, SPEC §3.2).
// Das Modell sieht nur die normalisierte Seite und Konzepte, nie Werte. Ausgaben sind typisiert
// (`@Generable`) und laufen danach durch `PlanValidator`.

@available(iOS 26.0, macOS 26.0, *)
@Generable
enum GeneratedActionKind {
    case fill, check, uncheck, select, tap, submit
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
enum GeneratedConcept {
    case username, password, lastName, roomNumber, email, voucherCode, accessCode, phoneNumber, otp
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
enum GeneratedTransition {
    case newPage, samePage, online
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedAction {
    @Guide(description: "Art der Aktion")
    var kind: GeneratedActionKind
    @Guide(description: "Element-ID aus der Seitenliste, z. B. e3. Nie erfinden.")
    var elementId: String
    @Guide(description: "Nur bei fill: welches Konzept in das Feld gehört")
    var concept: GeneratedConcept?
    @Guide(description: "Nur bei select: value der gewählten Option")
    var optionValue: String?
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedPlan {
    @Guide(description: "Ein kurzer Satz, warum diese Aktionen")
    var reasoningSummary: String
    @Guide(description: "Höchstens vier Aktionen nur für die aktuelle Seite", .maximumCount(4))
    var actions: [GeneratedAction]
    var expectedTransition: GeneratedTransition
    @Guide(description: "Nur setzen, wenn ein benötigter Wert im Intent fehlt")
    var missingValue: GeneratedConcept?
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedRepair {
    @Guide(description: "Element-ID des Ersatz-Elements oder leer, wenn keins passt")
    var elementId: String
    var reasoningSummary: String
}

@available(iOS 26.0, macOS 26.0, *)
public struct FoundationModelsPlanner: PortalPlanner {
    public init() {}

    public static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static let instructions = """
    Du steuerst die Anmeldung in einem WLAN-Portal (Hotel, Bahn, Café). Du siehst eine Liste der \
    bedienbaren Elemente mit IDs wie [e3]. Plane nur die Aktionen für die aktuelle Seite, höchstens vier.
    Regeln:
    - Verwende nur Element-IDs aus der Liste.
    - Bei fill gibst du nur das Konzept an, nie einen Wert.
    - Setze nur Haken, die für die Verbindung nötig sind (Nutzungsbedingungen, Datenschutz).
    - Nie Newsletter, Werbung, Partnerangebote, Premium, Kauf, Upgrade oder Abo.
    - Wenn ein Feld ein Konzept braucht, das im Intent fehlt, setze missingValue und keine Aktionen.
    - Zum Abschluss den Button drücken, der kostenlos verbindet.
    """

    public func nextPlan(_ input: PlanningInput) async throws -> PortalPlan {
        guard Self.isAvailable else { throw PlannerError.modelUnavailable }
        let session = LanguageModelSession(instructions: Self.instructions)
        do {
            let response = try await session.respond(to: Self.prompt(input), generating: GeneratedPlan.self)
            return Self.convert(response.content)
        } catch {
            throw PlannerError.generationFailed(String(describing: type(of: error)))
        }
    }

    public func repairTarget(old: Target, opcode: PortalAction.Opcode, intent: PortalIntent,
                             page: PortalPage) async throws -> RepairSuggestion? {
        guard Self.isAvailable else { throw PlannerError.modelUnavailable }
        let session = LanguageModelSession(instructions: Self.instructions)
        let prompt = """
        Ein gespeicherter Schritt (\(opcode.rawValue)) findet sein Element nicht mehr.
        Früher beschriftet: \((old.labelAny ?? []).joined(separator: ", ")).
        Welches Element der aktuellen Seite erfüllt dieselbe Aufgabe?

        \(PageRenderer.render(page))
        """
        let response = try await session.respond(to: prompt, generating: GeneratedRepair.self)
        let id = response.content.elementId.trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? nil : RepairSuggestion(elementId: id, reasoningSummary: response.content.reasoningSummary)
    }

    static func prompt(_ input: PlanningInput) -> String {
        let available = input.intent.bindings.keys.map(\.rawValue).sorted().joined(separator: ", ")
        let done = input.completedActions.map { "\($0.kind.rawValue) \($0.elementId)" }.joined(separator: "; ")
        return """
        Nutzerwunsch: \(input.intent.summaryLines.joined(separator: " | "))
        Verfügbare Konzepte: \(available.isEmpty ? "keine" : available)
        Bereits erledigt: \(done.isEmpty ? "nichts" : done)

        Aktuelle Seite:
        \(PageRenderer.render(input.page))
        """
    }

    static func convert(_ generated: GeneratedPlan) -> PortalPlan {
        PortalPlan(
            reasoningSummary: generated.reasoningSummary,
            actions: generated.actions.map { action in
                PlannedAction(kind: kind(action.kind), elementId: action.elementId,
                              concept: action.concept.map(concept), optionValue: action.optionValue)
            },
            expectedTransition: transition(generated.expectedTransition),
            missingValue: generated.missingValue.map(concept))
    }

    static func kind(_ k: GeneratedActionKind) -> PlannedAction.Kind {
        switch k {
        case .fill: .fill
        case .check: .check
        case .uncheck: .uncheck
        case .select: .select
        case .tap: .tap
        case .submit: .submit
        }
    }

    static func concept(_ c: GeneratedConcept) -> Concept {
        switch c {
        case .username: .username
        case .password: .password
        case .lastName: .lastName
        case .roomNumber: .roomNumber
        case .email: .email
        case .voucherCode: .voucherCode
        case .accessCode: .accessCode
        case .phoneNumber: .phoneNumber
        case .otp: .otp
        }
    }

    static func transition(_ t: GeneratedTransition) -> PortalPlan.Transition {
        switch t {
        case .newPage: .newPage
        case .samePage: .samePage
        case .online: .online
        }
    }
}
#endif
