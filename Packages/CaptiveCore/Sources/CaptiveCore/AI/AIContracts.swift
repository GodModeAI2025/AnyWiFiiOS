import Foundation

// AI-Verträge (01 §7.3, §16, 02 §20). Plattformneutral: Die Apple-Implementierung (Foundation Models,
// `@Generable`) lebt in CaptiveCoreApple und erzeugt genau diese Typen. Das Modell ist Planer, nie
// Security Authority (01 §24): Jede Ausgabe läuft durch `PlanValidator`.

// MARK: - Intent

/// Was der Nutzer will, unabhängig von einer konkreten Portalseite (01 §7.3).
public struct PortalIntent: Codable, Sendable, Equatable {
    public enum Instruction: Codable, Sendable, Equatable {
        case acceptRequiredTerms
        case acceptRequiredPrivacy
        case fill(Concept)
        case submit
    }

    /// Woher der Wert eines Konzepts kommt.
    public enum ValueBinding: Codable, Sendable, Equatable {
        case keychain(String)
        case askWhenMissing
        case profile(String)
    }

    public struct Policy: Codable, Sendable, Equatable {
        public var allowOptionalMarketingConsent: Bool
        /// In V1 immer `false`: Käufe sind nicht automatisierbar (01 §19).
        public var allowPaidUpgrade: Bool

        public init(allowOptionalMarketingConsent: Bool = false) {
            self.allowOptionalMarketingConsent = allowOptionalMarketingConsent
            self.allowPaidUpgrade = false
        }
    }

    public var intentVersion = 1
    public var instructions: [Instruction]
    public var bindings: [Concept: ValueBinding]
    public var policy: Policy
    /// Originale Nutzeranweisung (Text/Sprache), separat gespeichert (01 §7.3).
    public var originalInstruction: String

    public init(instructions: [Instruction], bindings: [Concept: ValueBinding], policy: Policy = .init(),
                originalInstruction: String) {
        self.instructions = instructions
        self.bindings = bindings
        self.policy = policy
        self.originalInstruction = originalInstruction
    }

    /// Wertquelle für ein Konzept, wie sie ins Recipe geschrieben wird.
    public func valueSource(for concept: Concept) -> ValueSource? {
        switch bindings[concept] {
        case .keychain(let key)?: .keychain(key)
        case .askWhenMissing?: .ask(concept)
        case .profile(let key)?: .profile(key)
        case nil: nil
        }
    }

    /// Lesbare Zusammenfassung für die Bestätigung im Chat (01 §4.2).
    public var summaryLines: [String] {
        var lines: [String] = []
        for instruction in instructions {
            switch instruction {
            case .acceptRequiredTerms: lines.append("✓ Nutzungsbedingungen akzeptieren")
            case .acceptRequiredPrivacy: lines.append("✓ Datenschutzhinweis akzeptieren")
            case .fill(let concept):
                switch bindings[concept] {
                case .keychain?: lines.append("🔐 \(concept.displayName) sicher gespeichert verwenden")
                case .askWhenMissing?: lines.append("? \(concept.displayName) bei Bedarf abfragen")
                case .profile?: lines.append("• \(concept.displayName) aus dem Profil")
                case nil: lines.append("⚠︎ \(concept.displayName): Quelle fehlt")
                }
            case .submit: lines.append("→ Verbindung absenden")
            }
        }
        if !policy.allowOptionalMarketingConsent { lines.append("✗ Keine Werbe- oder Newsletter-Einwilligung") }
        return lines
    }
}

extension Concept {
    public var displayName: String {
        switch self {
        case .username: "Benutzername"
        case .password: "Passwort"
        case .lastName: "Nachname"
        case .roomNumber: "Zimmernummer"
        case .email: "E-Mail"
        case .voucherCode: "Voucher"
        case .accessCode: "Zugangscode"
        case .phoneNumber: "Telefonnummer"
        case .otp: "Einmalcode"
        }
    }
}

// MARK: - Plan

/// Eine vom Modell vorgeschlagene Aktion auf einem Element der aktuellen Seite.
/// Für `fill` nennt das Modell nur das Konzept. Den Wert setzt die Runtime aus dem Intent ein.
public struct PlannedAction: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case fill, check, uncheck, select, tap, submit
    }

    public var kind: Kind
    public var elementId: String
    public var concept: Concept?
    public var optionValue: String?

    public init(kind: Kind, elementId: String, concept: Concept? = nil, optionValue: String? = nil) {
        self.kind = kind
        self.elementId = elementId
        self.concept = concept
        self.optionValue = optionValue
    }
}

/// Nächster Schritt auf einer Seite (02 §20). Höchstens vier Aktionen, nie mehrere Seiten im Voraus.
public struct PortalPlan: Codable, Sendable, Equatable {
    public enum Transition: String, Codable, Sendable {
        case newPage, samePage, online
    }

    public var reasoningSummary: String
    public var actions: [PlannedAction]
    public var expectedTransition: Transition
    /// Konzept, für das ein Wert fehlt (→ `missingUserValue` / `uiRequired`).
    public var missingValue: Concept?

    public init(reasoningSummary: String, actions: [PlannedAction], expectedTransition: Transition,
                missingValue: Concept? = nil) {
        self.reasoningSummary = reasoningSummary
        self.actions = actions
        self.expectedTransition = expectedTransition
        self.missingValue = missingValue
    }
}

/// Eingabe für einen Planungsschritt. Enthält keine Werte, nur Konzepte und die normalisierte Seite.
public struct PlanningInput: Sendable, Equatable {
    public var intent: PortalIntent
    public var page: PortalPage
    public var completedActions: [PlannedAction]
    public var round: Int
}

/// Vorschlag für ein Ersatz-Element, wenn ein Recipe-Target nicht mehr passt (01 §14).
public struct RepairSuggestion: Codable, Sendable, Equatable {
    public var elementId: String
    public var reasoningSummary: String

    public init(elementId: String, reasoningSummary: String) {
        self.elementId = elementId
        self.reasoningSummary = reasoningSummary
    }
}

public enum PlannerError: Error, Equatable, Sendable {
    case modelUnavailable
    case generationFailed(String)
}

/// Schnittstelle zum Sprachmodell. Implementierungen: Foundation Models (on-device), PCC (optional), Fakes in Tests.
public protocol PortalPlanner: Sendable {
    func nextPlan(_ input: PlanningInput) async throws -> PortalPlan
    /// Welches Element der Seite erfüllt dieselbe Aufgabe wie das alte Target? `nil` = keins.
    func repairTarget(old: Target, opcode: PortalAction.Opcode, intent: PortalIntent,
                      page: PortalPage) async throws -> RepairSuggestion?
}

// MARK: - Seitendarstellung für den Prompt

/// Kompakte Textform der Seite für das Modell (SPEC 5.3 alt / 01 §11). Hidden Fields und Werte fehlen absichtlich.
public enum PageRenderer {
    public static func render(_ page: PortalPage, maxCharacters: Int = 6000) -> String {
        var lines: [String] = ["URL: \((page.url.host ?? "") + page.url.path)", "Titel: \(page.title)"]
        if !page.text.isEmpty { lines.append("Text: \(page.text.prefix(300))") }
        for control in page.interactiveControls {
            var line = "[\(control.elementId)] \(control.role?.rawValue ?? "?")"
            if let caption = control.captions.first { line += " \"\(caption.prefix(80))\"" }
            if let name = control.name { line += " name=\(name)" }
            if let concept = control.concept { line += " concept=\(concept.rawValue)" }
            if control.role == .checkbox || control.role == .radio { line += control.checked ? " (checked)" : " (unchecked)" }
            if control.required { line += " required" }
            if control.role == .select {
                line += " options=" + control.options.map { "\($0.label)=\($0.value)" }.joined(separator: "|")
            }
            lines.append(line)
        }
        var text = lines.joined(separator: "\n")
        if text.count > maxCharacters { text = String(text.prefix(maxCharacters)) + "\n…" }
        return text
    }
}
