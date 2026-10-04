import Foundation

/// Definierte Ergebnisse eines Login-Laufs (01 §23). Kein generisches „Es ging nicht“.
public enum RunOutcome: String, Codable, Sendable, CaseIterable {
    case success
    case temporaryFailure
    case unsupportedPortal
    case missingUserValue
    case recipeMismatch
    case networkError
    case timeout
    case aiUnavailable
    case aiRejectedPlan
    case manualInteractionRequired
}

/// Genauer Grund, z. B. für die Aktivitätsansicht und das Debug-Paket.
public enum RunReason: Error, Equatable, Sendable {
    case alreadyOnline
    case loggedIn
    case stageNotFound
    case loginNotAccepted(stage: String)
    case targetNotFound(stage: String, action: Int)
    case targetAmbiguous(stage: String, action: Int, candidates: [String])
    case wrongElementKind(stage: String, action: Int)
    case missingValue(Concept?)
    case commercialElement(String)
    case optionalConsent(String)
    case credentialHostNotTrusted(String)
    case javaScriptRequired
    case httpStatus(Int)
    case tooManyRedirects
    case responseTooLarge
    case transport(String)
    case stillCaptive
    case unknownAdapter(String)
    case adapterFailed(String)
    case conditionNotMet(stage: String, action: Int)
    case stopRequested(StopOutcome)
    case roundLimitReached
    case modelUnavailable
    case planRejected(String)

    public var outcome: RunOutcome {
        switch self {
        case .alreadyOnline, .loggedIn: .success
        case .stageNotFound, .targetNotFound, .targetAmbiguous, .wrongElementKind, .conditionNotMet: .recipeMismatch
        case .missingValue: .missingUserValue
        case .commercialElement, .optionalConsent, .credentialHostNotTrusted, .javaScriptRequired: .manualInteractionRequired
        case .loginNotAccepted, .httpStatus, .stillCaptive, .roundLimitReached: .temporaryFailure
        case .tooManyRedirects, .responseTooLarge, .transport: .networkError
        case .unknownAdapter: .unsupportedPortal
        case .adapterFailed: .temporaryFailure
        case .modelUnavailable: .aiUnavailable
        case .planRejected: .aiRejectedPlan
        case .stopRequested(let stop):
            switch stop {
            case .success: .success
            case .temporaryFailure: .temporaryFailure
            case .unsupported: .unsupportedPortal
            case .requiresManualInteraction: .manualInteractionRequired
            }
        }
    }
}

public struct RunResult: Sendable {
    public var reason: RunReason
    public var trace: RunTrace
    /// Alle normalisierten Seiten dieses Laufs in Reihenfolge (für Debug-Paket und Repair).
    /// Enthalten nur Werte aus dem Portal-HTML, nie eingegebene Werte.
    public var visitedPages: [PortalPage]
    public var lastPage: PortalPage? { visitedPages.last }
    public var failedStageId: String?
    public var failedActionIndex: Int?

    public var outcome: RunOutcome { reason.outcome }
}

// MARK: - Trace

/// Redigiertes Laufprotokoll (01 §12.3, §22). Enthält nie Klartextwerte von Secrets oder persönlichen Daten.
public struct RunTrace: Sendable, Codable, Equatable {
    public struct Event: Sendable, Codable, Equatable {
        public enum Kind: String, Sendable, Codable {
            case probe, request, page, stage, action, guardrail, adapter, outcome
        }

        public var kind: Kind
        public var stageId: String?
        public var actionIndex: Int?
        public var message: String
    }

    public private(set) var events: [Event] = []
    /// Klartextwerte, die in diesem Lauf verwendet wurden. Nur im Speicher, nie serialisiert.
    private var sensitiveValues: [(value: String, placeholder: String)] = []

    public init() {}

    enum CodingKeys: String, CodingKey { case events }

    public static func == (lhs: RunTrace, rhs: RunTrace) -> Bool { lhs.events == rhs.events }

    mutating func registerSensitive(_ value: String, placeholder: String) {
        guard value.count >= 2 else { return }
        sensitiveValues.append((value, placeholder))
        // Längere Werte zuerst ersetzen, damit Teilstrings nicht stehen bleiben.
        sensitiveValues.sort { $0.value.count > $1.value.count }
    }

    mutating func record(_ kind: Event.Kind, _ message: String, stage: String? = nil, action: Int? = nil) {
        events.append(Event(kind: kind, stageId: stage, actionIndex: action, message: redact(message)))
    }

    /// Ersetzt bekannte Klartextwerte durch Platzhalter. Zweite Verteidigungslinie nach der
    /// Regel, Werte gar nicht erst in Meldungen zu schreiben.
    func redact(_ text: String) -> String {
        var result = text
        for entry in sensitiveValues {
            result = result.replacingOccurrences(of: entry.value, with: entry.placeholder)
        }
        return result
    }
}

// MARK: - Wertquellen

/// Liefert Werte für `fill`/`requestValue` (Keychain, Profil, Laufzeit, Nutzerabfrage).
/// `nil` bedeutet: Wert fehlt → Outcome `missingUserValue` (Provider-Modus: `uiRequired`, 01 §4.5).
public protocol ValueProvider: Sendable {
    func value(for source: ValueSource) async -> String?
}

/// Einfache Implementierung für Tests und für vorab eingesammelte Werte.
public struct StaticValueProvider: ValueProvider {
    public var keychain: [String: String]
    public var asked: [Concept: String]
    public var profile: [String: String]
    public var runtime: [String: String]

    public init(keychain: [String: String] = [:], asked: [Concept: String] = [:],
                profile: [String: String] = [:], runtime: [String: String] = [:]) {
        self.keychain = keychain
        self.asked = asked
        self.profile = profile
        self.runtime = runtime
    }

    public func value(for source: ValueSource) async -> String? {
        switch source {
        case .literal(let v): v
        case .keychain(let key): keychain[key]
        case .ask(let concept): asked[concept]
        case .profile(let key): profile[key]
        case .runtime(let key): runtime[key]
        }
    }
}
