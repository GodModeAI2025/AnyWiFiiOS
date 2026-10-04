import Foundation

/// Zwischenstand des Chats (SPEC §3.2): was das Modell bzw. der Parser aus der Anweisung verstanden hat.
/// Daraus entsteht nach Bestätigung ein `PortalIntent` mit Keychain-Schlüsseln.
public struct IntentDraft: Codable, Sendable, Equatable {
    public enum Storage: String, Codable, Sendable {
        /// Wert einmal abfragen und im Keychain merken.
        case remember
        /// Bei jedem Login fragen (z. B. Zimmernummer pro Aufenthalt).
        case askEachTime
    }

    public struct Field: Codable, Sendable, Equatable {
        public var concept: Concept
        public var storage: Storage

        public init(concept: Concept, storage: Storage) {
            self.concept = concept
            self.storage = storage
        }
    }

    public var acceptTerms: Bool
    public var acceptPrivacy: Bool
    public var fields: [Field]
    public var allowMarketing: Bool
    /// Rückfrage an den Nutzer, wenn etwas unklar ist (z. B. „Zimmernummer merken oder jedes Mal fragen?“).
    public var followUpQuestion: String?

    public init(acceptTerms: Bool = false, acceptPrivacy: Bool = false, fields: [Field] = [],
                allowMarketing: Bool = false, followUpQuestion: String? = nil) {
        self.acceptTerms = acceptTerms
        self.acceptPrivacy = acceptPrivacy
        self.fields = fields
        self.allowMarketing = allowMarketing
        self.followUpQuestion = followUpQuestion
    }

    /// Keychain-Schlüssel nach Schema `<prefix>.<concept>`, z. B. `profile-1234.lastName`.
    public func makeIntent(keychainPrefix: String, originalInstruction: String) -> PortalIntent {
        var instructions: [PortalIntent.Instruction] = []
        if acceptTerms { instructions.append(.acceptRequiredTerms) }
        if acceptPrivacy { instructions.append(.acceptRequiredPrivacy) }
        var bindings: [Concept: PortalIntent.ValueBinding] = [:]
        for field in fields where bindings[field.concept] == nil {
            instructions.append(.fill(field.concept))
            bindings[field.concept] = field.storage == .remember
                ? .keychain("\(keychainPrefix).\(field.concept.rawValue)") : .askWhenMissing
        }
        instructions.append(.submit)
        return PortalIntent(instructions: instructions, bindings: bindings,
                            policy: .init(allowOptionalMarketingConsent: allowMarketing),
                            originalInstruction: originalInstruction)
    }

    /// Slots, die beim Speichern/Export angelegt werden (01 §7.4).
    public func credentialSlots(keychainPrefix: String) -> [CredentialSlot] {
        fields.filter { $0.storage == .remember }.map {
            CredentialSlot(key: "\(keychainPrefix).\($0.concept.rawValue)", concept: $0.concept, label: $0.concept.displayName)
        }
    }
}

/// Regelbasierter Parser für Anweisungen ohne Sprachmodell (DE/EN). Rückfallebene für Geräte ohne
/// Apple Intelligence und Vorbelegung des Chats. Versteht typische Formulierungen, nicht alles.
public enum InstructionParser {
    static let conceptWords: [(Concept, [String])] = [
        (.roomNumber, ["zimmernummer", "zimmer", "room number", "room"]),
        (.lastName, ["nachname", "familienname", "last name", "surname"]),
        (.voucherCode, ["voucher", "gutschein", "ticket", "coupon"]),
        (.accessCode, ["zugangscode", "access code"]),
        (.password, ["passwort", "kennwort", "password"]),
        (.username, ["benutzername", "benutzer", "username", "user name"]),
        (.email, ["e-mail", "email", "mail"]),
        (.phoneNumber, ["telefonnummer", "handynummer", "phone"]),
    ]
    static let askWords = ["frag", "jedes mal", "jedesmal", "each time", "ask"]
    static let rememberWords = ["speicher", "merk", "save", "remember", "darfst du", "kannst du"]
    static let termsWords = ["agb", "nutzungsbedingung", "bedingung", "terms", "haken", "akzeptier", "accept"]
    static let privacyWords = ["datenschutz", "privacy"]

    public static func parse(_ text: String) -> IntentDraft {
        let lower = text.lowercased()
        var draft = IntentDraft()
        draft.acceptPrivacy = privacyWords.contains { lower.contains($0) }
        draft.acceptTerms = termsWords.contains { lower.contains($0) } || draft.acceptPrivacy
        draft.allowMarketing = ["newsletter erlaubt", "newsletter ja", "werbung erlaubt"].contains { lower.contains($0) }

        // Satzweise betrachten: Ein Konzept kann zuerst genannt und erst später präzisiert werden
        // („Zimmernummer und Nachname eintragen. Nach der Zimmernummer fragst du mich jedes Mal.“).
        let clauses = lower.split(whereSeparator: { ".,;\n".contains($0) }).map(String.init)
        var order: [Concept] = []
        for clause in clauses {
            let found = conceptWords.filter { _, words in words.contains { clause.contains($0) } }
                .map(\.0)
                .sorted { first(of: $0, in: clause) < first(of: $1, in: clause) }
            for concept in found where !order.contains(concept) { order.append(concept) }
        }
        var undecided: [Concept] = []
        for concept in order {
            let words = conceptWords.first { $0.0 == concept }?.1 ?? []
            let relevant = clauses.filter { clause in words.contains { clause.contains($0) } }
            let ask = relevant.contains { clause in askWords.contains { clause.contains($0) } }
            let remember = relevant.contains { clause in rememberWords.contains { clause.contains($0) } }
            if ask == remember { undecided.append(concept) }
            draft.fields.append(.init(concept: concept, storage: ask && !remember ? .askEachTime : .remember))
        }
        if let first = undecided.first {
            draft.followUpQuestion = "Soll ich \(first.displayName) speichern oder bei jeder Anmeldung fragen?"
        }
        return draft
    }

    /// Position des ersten Treffers eines Konzepts im Satz (für die Reihenfolge).
    static func first(of concept: Concept, in clause: String) -> Int {
        let words = conceptWords.first { $0.0 == concept }?.1 ?? []
        let positions = words.compactMap { word in clause.range(of: word).map { clause.distance(from: clause.startIndex, to: $0.lowerBound) } }
        return positions.min() ?? Int.max
    }
}
