import Foundation

public enum AssistantAvailability: Equatable, Sendable {
    case available
    case unavailable(Reason)

    public enum Reason: String, Sendable {
        case deviceNotEligible, appleIntelligenceDisabled, modelNotReady, entitlementMissing, offline, other
    }

    public var isAvailable: Bool { if case .available = self { true } else { false } }
}

/// Strukturierter Entwurf des Intents (`@Generable`-Spiegel). Das Modell füllt ihn über mehrere
/// Chatrunden, bis er vollständig ist (SPEC §3.2).
public struct PortalIntentDraft: Codable, Equatable, Sendable {
    public struct Field: Codable, Equatable, Sendable {
        public var concept: String
        public var source: IntentValueSource
        public var persistence: PersistencePolicy
        public var prompt: String?

        public init(concept: String, source: IntentValueSource, persistence: PersistencePolicy, prompt: String? = nil) {
            self.concept = concept
            self.source = source
            self.persistence = persistence
            self.prompt = prompt
        }
    }

    public var acceptRequiredTerms: Bool
    public var acceptRequiredPrivacy: Bool
    public var fields: [Field]
    public var allowOptionalMarketingConsent: Bool
    public var submit: Bool

    public init(acceptRequiredTerms: Bool = false, acceptRequiredPrivacy: Bool = false, fields: [Field] = [],
                allowOptionalMarketingConsent: Bool = false, submit: Bool = true) {
        self.acceptRequiredTerms = acceptRequiredTerms
        self.acceptRequiredPrivacy = acceptRequiredPrivacy
        self.fields = fields
        self.allowOptionalMarketingConsent = allowOptionalMarketingConsent
        self.submit = submit
    }

    public func toIntent(originalText: String? = nil) -> PortalIntent {
        var ins: [IntentInstruction] = []
        if acceptRequiredTerms { ins.append(.acceptRequiredTerms) }
        if acceptRequiredPrivacy { ins.append(.acceptRequiredPrivacy) }
        for f in fields { ins.append(.fill(concept: f.concept, source: f.source)) }
        if submit { ins.append(.submit) }
        // Bezahlen ist nie Teil eines Intents (01 §19). Marketing nur auf ausdrückliche Anweisung.
        return PortalIntent(instructions: ins,
                            policy: IntentPolicy(allowOptionalMarketingConsent: allowOptionalMarketingConsent, allowPaidUpgrade: false),
                            originalText: originalText)
    }

    public func bindings(profileId: UUID) -> [CredentialBinding] {
        fields.compactMap { f in
            guard f.source != .profile else { return nil }
            let persistence = f.source == .askWhenMissing && f.persistence == .rememberInKeychain ? f.persistence : f.persistence
            return CredentialBinding(concept: f.concept,
                                     keychainKey: "profile.\(profileId.uuidString).\(f.concept)",
                                     prompt: f.prompt ?? f.concept, persistence: persistence)
        }
    }

    /// Strukturierte Zusammenfassung für die UI (✓ ? 🔐 →), lokalisiert in der UI-Schicht.
    public var summary: [SummaryLine] {
        var lines: [SummaryLine] = []
        if acceptRequiredTerms || acceptRequiredPrivacy { lines.append(.init(kind: .acceptRequired, concept: nil)) }
        for f in fields {
            switch (f.source, f.persistence) {
            case (.keychain, _), (_, .rememberInKeychain): lines.append(.init(kind: .storeSecurely, concept: f.concept, prompt: f.prompt))
            default: lines.append(.init(kind: .askWhenNeeded, concept: f.concept, prompt: f.prompt))
            }
        }
        if allowOptionalMarketingConsent { lines.append(.init(kind: .allowMarketing, concept: nil)) }
        if submit { lines.append(.init(kind: .submit, concept: nil)) }
        return lines
    }

    public struct SummaryLine: Equatable, Sendable {
        public enum Kind: String, Sendable { case acceptRequired, askWhenNeeded, storeSecurely, allowMarketing, submit }
        public var kind: Kind
        public var concept: String?
        public var prompt: String?
        public init(kind: Kind, concept: String?, prompt: String? = nil) { self.kind = kind; self.concept = concept; self.prompt = prompt }
    }
}

public struct IntentChatInput: Sendable {
    /// Verlauf mit Platzhaltern. Nie Klartextwerte sensibler Konzepte.
    public var transcript: [ChatLogMessage]
    public var currentDraft: PortalIntentDraft
    /// Elementliste der Portalseite als Kontext (SOLL, SPEC §3.2). Redigiert.
    public var portalContext: NormalizedPage?

    public init(transcript: [ChatLogMessage], currentDraft: PortalIntentDraft, portalContext: NormalizedPage? = nil) {
        self.transcript = transcript
        self.currentDraft = currentDraft
        self.portalContext = portalContext
    }
}

public struct IntentChatTurn: Equatable, Sendable {
    public var reply: String
    /// Rückfrage des Modells. Solange gesetzt, ist der Entwurf nicht vollständig.
    public var question: String?
    public var draft: PortalIntentDraft
    public var isComplete: Bool

    public init(reply: String, question: String? = nil, draft: PortalIntentDraft, isComplete: Bool) {
        self.reply = reply
        self.question = question
        self.draft = draft
        self.isComplete = isComplete
    }
}

public struct RepairInput: Sendable {
    public var intent: PortalIntent
    public var recipe: Recipe
    public var failedStageId: String?
    public var failedActionIndex: Int?
    public var reason: String?
    public var page: NormalizedPage
    public var chat: [ChatLogMessage]

    public init(intent: PortalIntent, recipe: Recipe, failedStageId: String?, failedActionIndex: Int?, reason: String?,
                page: NormalizedPage, chat: [ChatLogMessage] = []) {
        self.intent = intent
        self.recipe = recipe
        self.failedStageId = failedStageId
        self.failedActionIndex = failedActionIndex
        self.reason = reason
        self.page = page
        self.chat = chat
    }
}

/// Gemeinsame Schnittstelle der Modelle (SPEC §3.2): `OnDeviceAssistant` (Foundation Models) und
/// `PCCAssistant`. Die Ausgabe ist immer typisiert und läuft durch dieselben Validatoren.
public protocol AssistantModel: PortalPlanner, RecipeRepairer {
    var availability: AssistantAvailability { get async }
    func chatTurn(_ input: IntentChatInput) async throws -> IntentChatTurn
}

/// Probiert zuerst das Modell. Fehler oder leere Antwort fallen auf die regelbasierte Variante zurück,
/// damit ein Login nie an einem Modellausfall scheitert.
public struct FallbackPlanner: PortalPlanner {
    public var primary: any PortalPlanner
    public var fallback: any PortalPlanner

    public init(primary: any PortalPlanner, fallback: any PortalPlanner = HeuristicPlanner()) {
        self.primary = primary
        self.fallback = fallback
    }

    public func plan(_ input: PlanningInput) async throws -> PortalPlan {
        // Modellplan nur, wenn er eine echte Aktion enthält und nicht aufgibt und prüfbar ist.
        if let p = try? await primary.plan(input), !p.actions.isEmpty,
           !p.actions.contains(where: { if case .stop = $0 { true } else { false } }),
           SecurityValidator.validate(plan: p.actions).allSatisfy({ $0.severity != .error }) { return p }
        return try await fallback.plan(input)
    }
}

public struct FallbackRepairer: RecipeRepairer {
    public var primary: any RecipeRepairer
    public var fallback: any RecipeRepairer

    public init(primary: any RecipeRepairer, fallback: any RecipeRepairer = HeuristicRepairer()) {
        self.primary = primary
        self.fallback = fallback
    }

    public func proposePatch(_ input: RepairInput) async throws -> RecipePatch? {
        if let p = try? await primary.proposePatch(input) { return p }
        return try await fallback.proposePatch(input)
    }
}
