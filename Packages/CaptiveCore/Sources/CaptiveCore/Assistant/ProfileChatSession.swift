import Foundation

public struct ChatTurnResult: Equatable, Sendable {
    public var reply: String
    public var question: String?
    public var draft: PortalIntentDraft
    public var isComplete: Bool
    /// Konzepte, bei denen der Nutzer Klartext getippt hat. Die UI bietet das sichere Feld an.
    public var detectedSensitiveConcepts: [String]
}

public enum ChatError: Error, Equatable, Sendable {
    case modelUnavailable
    case invalidDraft(String)
}

/// Mehrstufiges Profil-Gespräch (SPEC §3.2). Hält nur redigierten Text und den Entwurf.
public struct ProfileChatSession: Sendable {
    public private(set) var transcript: [ChatLogMessage] = []
    public private(set) var draft = PortalIntentDraft()
    public private(set) var isComplete = false
    public var portalContext: NormalizedPage?
    public private(set) var originalText: String = ""

    public init(portalContext: NormalizedPage? = nil) {
        self.portalContext = portalContext?.redactedForModel()
    }

    public mutating func send(_ userText: String, model: any AssistantModel,
                              knownSensitive: [SensitiveValue] = []) async throws -> ChatTurnResult {
        guard await model.availability.isAvailable else { throw ChatError.modelUnavailable }
        let clean = PromptSanitizer.sanitize(userText, known: knownSensitive)
        transcript.append(ChatLogMessage(role: "user", text: clean.text))
        originalText += (originalText.isEmpty ? "" : "\n") + clean.text

        let turn = try await model.chatTurn(IntentChatInput(transcript: transcript, currentDraft: draft, portalContext: portalContext))
        try Self.validate(turn.draft)
        draft = turn.draft
        isComplete = turn.isComplete && turn.question == nil
        transcript.append(ChatLogMessage(role: "assistant", text: turn.question ?? turn.reply))
        return ChatTurnResult(reply: turn.reply, question: turn.question, draft: draft, isComplete: isComplete,
                              detectedSensitiveConcepts: clean.detectedConcepts)
    }

    /// Das Modell ist Planer, nicht Security Authority: Entwürfe prüft die Runtime.
    static func validate(_ d: PortalIntentDraft) throws {
        var seen = Set<String>()
        for f in d.fields {
            guard !f.concept.isEmpty, f.concept.count <= 40, f.concept.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                throw ChatError.invalidDraft("Ungültiges Konzept")
            }
            guard seen.insert(f.concept).inserted else { throw ChatError.invalidDraft("Doppeltes Feld \(f.concept)") }
            if ["cardNumber", "cvv", "cvc", "iban", "creditCard"].contains(f.concept) {
                throw ChatError.invalidDraft("Zahlungsdaten sind nicht erlaubt")
            }
        }
        if d.fields.count > 8 { throw ChatError.invalidDraft("Zu viele Felder") }
    }

    public func intent() -> PortalIntent { draft.toIntent(originalText: originalText.isEmpty ? nil : originalText) }
}
