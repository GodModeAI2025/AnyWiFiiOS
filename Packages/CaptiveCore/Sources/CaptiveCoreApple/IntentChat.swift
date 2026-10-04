#if canImport(FoundationModels)
import CaptiveCore
import Foundation
import FoundationModels

// Chat zum Einrichten eines Profils (SPEC §3.2): mehrstufiges Gespräch, Ergebnis ist ein `IntentDraft`.
// Werte (Passwörter, Zimmernummern …) gehören nie in den Chat. Die App fragt sie in einem separaten,
// sicheren Feld ab und legt sie direkt im Keychain ab.

@available(iOS 26.0, macOS 26.0, *)
@Generable
enum GeneratedStorage {
    case remember, askEachTime
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedField {
    var concept: GeneratedConcept
    @Guide(description: "remember: einmal fragen und sicher speichern. askEachTime: bei jeder Anmeldung fragen.")
    var storage: GeneratedStorage
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
struct GeneratedIntentDraft {
    @Guide(description: "Nutzungsbedingungen/AGB akzeptieren?")
    var acceptTerms: Bool
    @Guide(description: "Datenschutzhinweis akzeptieren?")
    var acceptPrivacy: Bool
    @Guide(description: "Felder, die ausgefüllt werden sollen", .maximumCount(6))
    var fields: [GeneratedField]
    @Guide(description: "Nur true, wenn der Nutzer Newsletter/Werbung ausdrücklich erlaubt")
    var allowMarketing: Bool
    @Guide(description: "Eine kurze Rückfrage auf Deutsch, falls etwas unklar ist, sonst leer")
    var followUpQuestion: String
}

/// Führt das Gespräch über mehrere Runden. Eine Instanz pro Profil-Chat.
@available(iOS 26.0, macOS 26.0, *)
public final class IntentChat: @unchecked Sendable {
    private let session: LanguageModelSession
    public private(set) var draft = IntentDraft()

    static let instructions = """
    Du hilfst beim Einrichten der automatischen Anmeldung in einem WLAN-Portal. Der Nutzer beschreibt, \
    was im Portal zu tun ist. Erfasse daraus: ob Nutzungsbedingungen bzw. Datenschutz akzeptiert werden, \
    welche Felder ausgefüllt werden (Zimmernummer, Nachname, Benutzername, Passwort, Voucher, E-Mail …) \
    und ob ein Wert gespeichert oder jedes Mal abgefragt werden soll.
    Regeln:
    - Frage nie nach den Werten selbst. Werte gibt der Nutzer später in ein sicheres Feld ein.
    - Newsletter, Werbung oder Kauf nie annehmen, außer der Nutzer erlaubt es ausdrücklich.
    - Stelle höchstens eine kurze Rückfrage, wenn etwas unklar ist.
    """

    public init() {
        session = LanguageModelSession(instructions: Self.instructions)
    }

    public static var isAvailable: Bool { FoundationModelsPlanner.isAvailable }

    /// Verarbeitet eine Nutzernachricht und liefert den aktualisierten Entwurf.
    public func send(_ message: String) async throws -> IntentDraft {
        let prompt = """
        Bisheriger Stand: \(Self.describe(draft))
        Neue Nachricht des Nutzers: \(message)
        """
        let response = try await session.respond(to: prompt, generating: GeneratedIntentDraft.self)
        draft = Self.convert(response.content)
        return draft
    }

    static func describe(_ draft: IntentDraft) -> String {
        let fields = draft.fields.map { "\($0.concept.rawValue)=\($0.storage.rawValue)" }.joined(separator: ", ")
        return "terms=\(draft.acceptTerms), privacy=\(draft.acceptPrivacy), fields=[\(fields)], marketing=\(draft.allowMarketing)"
    }

    static func storage(_ s: GeneratedStorage) -> IntentDraft.Storage {
        switch s {
        case .remember: .remember
        case .askEachTime: .askEachTime
        }
    }

    static func convert(_ generated: GeneratedIntentDraft) -> IntentDraft {
        let question = generated.followUpQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        return IntentDraft(
            acceptTerms: generated.acceptTerms,
            acceptPrivacy: generated.acceptPrivacy,
            fields: generated.fields.map {
                IntentDraft.Field(concept: FoundationModelsPlanner.concept($0.concept), storage: storage($0.storage))
            },
            allowMarketing: generated.allowMarketing,
            followUpQuestion: question.isEmpty ? nil : question)
    }
}
#endif
