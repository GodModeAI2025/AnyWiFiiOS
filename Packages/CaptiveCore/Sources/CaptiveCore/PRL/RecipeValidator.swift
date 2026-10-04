import Foundation

/// Sicherheits- und Semantikprüfung eines strukturell gültigen Recipes (01 §19, §24, §25, §29).
///
/// Gilt für **jede** Recipe-Quelle gleichermaßen: Lernlauf, lokale AI, PCC, Import, Handbearbeitung,
/// externer Patch aus einem Debug-Paket. Das Modell ist Planer, die Runtime hat das letzte Wort.
/// Diese Prüfung ist statisch. Seitenabhängige Regeln (Host-Menge, Preis auf der Seite) prüft später die Runtime.
public struct RecipeValidator: Sendable {
    public struct Limits: Sendable {
        public var maxStages = 10
        public var maxActionsPerStage = 20
        public var maxTotalActions = 40
        public var maxWaitSeconds = 15
        public init() {}
    }

    public struct Policy: Sendable {
        /// Optionale Marketing-/Newsletter-/Partner-Einwilligungen nur bei expliziter Nutzeranweisung (01 §19).
        public var allowOptionalMarketingConsent = false
        public init() {}
    }

    public var limits: Limits
    public var policy: Policy
    /// Keychain-Schlüssel des Profils → Konzept, für das der Wert angelegt wurde (CredentialBinding, 01 §7.4).
    public var keychainBindings: [String: Concept]

    public init(keychainBindings: [String: Concept], limits: Limits = .init(), policy: Policy = .init()) {
        self.keychainBindings = keychainBindings
        self.limits = limits
        self.policy = policy
    }

    public func validate(_ recipe: Recipe) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func add(_ code: ValidationIssue.Code, _ path: String, _ message: String) {
            issues.append(ValidationIssue(code: code, path: path, message: message))
        }

        if recipe.stages.isEmpty { add(.noStages, "stages", "Recipe hat keine Stages") }
        if recipe.stages.count > limits.maxStages {
            add(.tooManyStages, "stages", "\(recipe.stages.count) Stages, erlaubt sind \(limits.maxStages)")
        }
        let total = recipe.stages.reduce(0) { $0 + $1.actions.count }
        if total > limits.maxTotalActions {
            add(.tooManyActions, "stages", "\(total) Aktionen insgesamt, erlaubt sind \(limits.maxTotalActions)")
        }

        var seenStageIds = Set<String>()
        for (si, stage) in recipe.stages.enumerated() {
            let stagePath = "stages[\(si)]"
            if !seenStageIds.insert(stage.id).inserted {
                add(.duplicateStageId, stagePath, "Stage-ID '\(stage.id)' ist doppelt")
            }
            if stage.actions.isEmpty { add(.noActions, stagePath, "Stage '\(stage.id)' hat keine Aktionen") }
            if stage.actions.count > limits.maxActionsPerStage {
                add(.tooManyActions, stagePath, "\(stage.actions.count) Aktionen, erlaubt sind \(limits.maxActionsPerStage)")
            }
            for (ai, action) in stage.actions.enumerated() {
                validate(action, path: "\(stagePath).actions[\(ai)]", add: add)
            }
        }

        // Kein JavaScript / keine Script-URLs in irgendeinem Text des Recipes (01 §8.1, §24).
        for (path, text) in recipe.allStrings() where ScriptHeuristics.looksLikeScript(text) {
            add(.scriptContent, path, "Text sieht nach Skript aus: \(text.prefix(40))")
        }
        return issues
    }

    public func isValid(_ recipe: Recipe) -> Bool { validate(recipe).isEmpty }

    // MARK: - Einzelaktionen

    private func validate(_ action: PortalAction, path: String,
                          add: (ValidationIssue.Code, String, String) -> Void) {
        if let target = action.target {
            if target.isEmpty {
                add(.emptyTarget, path, "Target ohne Merkmale")
            } else if target.isSelectorOnly {
                add(.selectorOnlyTarget, path, "CSS-Selector darf nur Fallback sein, nicht einziges Merkmal (01 §10)")
            }
        }

        switch action {
        case .fill(let fill):
            validateFill(fill, path: path, add: add)

        case .check(let a):
            checkCommercial(a.target, path: path, add: add)
            if !policy.allowOptionalMarketingConsent, ConsentClassifier.isMarketing(a.target.allDescriptors) {
                add(.optionalConsentWithoutPermission, path,
                    "Marketing-/Newsletter-Einwilligung ohne ausdrückliche Erlaubnis (01 §19)")
            }

        case .uncheck:
            break // Abwählen ist immer erlaubt (z. B. vorausgewählter Newsletter).

        case .tap(let a):
            checkCommercial(a.target, path: path, add: add)

        case .select(let s):
            checkCommercial(s.target, path: path, add: add)
            let optionTexts = s.option.allTexts
            if ConsentClassifier.isCommercial(optionTexts) {
                add(.commercialAction, path, "Auswahl einer kostenpflichtigen Option ist in V1 nicht erlaubt (01 §19)")
            }

        case .submit(let s):
            if let target = s.target { checkCommercial(target, path: path, add: add) }

        case .waitFor(let w):
            if let t = w.timeoutSeconds, !(1...limits.maxWaitSeconds).contains(t) {
                add(.timeoutOutOfRange, path, "timeoutSeconds \(t) außerhalb 1…\(limits.maxWaitSeconds)")
            }

        case .adapter(let a):
            if !PortalAdapterRegistry.knownIDs.contains(a.id) {
                add(.unknownAdapter, path, "Unbekannter Portal-Adapter '\(a.id)'")
            }

        case .requestValue, .verify, .stop:
            break
        }
    }

    private func validateFill(_ fill: FillAction, path: String,
                              add: (ValidationIssue.Code, String, String) -> Void) {
        let concept = fill.target.concept
        switch fill.value {
        case .literal:
            if let concept {
                // Secrets und persönliche Werte gehören in den Keychain, nie ins Recipe (01 §20.1).
                add(.literalForSensitiveConcept, path,
                    "Literal für Konzept '\(concept.rawValue)' (\(concept.sensitivity.rawValue)) ist unzulässig")
            }
        case .keychain(let key):
            guard let bound = keychainBindings[key] else {
                add(.unknownKeychainKey, path, "Keychain-Schlüssel '\(key)' ist im Profil nicht angelegt")
                return
            }
            // Credential-Regel: Ein Secret nur in das Feld seines semantischen Zwecks (01 §25).
            guard let concept else {
                add(.keychainValueWithoutConcept, path, "Keychain-Wert '\(key)' braucht ein Target mit concept")
                return
            }
            if bound != concept {
                add(.keychainConceptMismatch, path,
                    "Keychain-Wert '\(key)' gehört zu '\(bound.rawValue)', Feld ist '\(concept.rawValue)'")
            }
        case .ask(let asked):
            if let concept, asked != concept {
                add(.askConceptMismatch, path, "Abgefragt wird '\(asked.rawValue)', Feld ist '\(concept.rawValue)'")
            }
        case .profile, .runtime:
            break
        }
    }

    private func checkCommercial(_ target: Target, path: String,
                                 add: (ValidationIssue.Code, String, String) -> Void) {
        if ConsentClassifier.isCommercial(target.allDescriptors) {
            add(.commercialAction, path, "Kauf/Upgrade/Abo ist in V1 nicht automatisierbar (01 §19)")
        }
    }
}

public struct ValidationIssue: Equatable, Sendable, CustomStringConvertible {
    public enum Code: String, Sendable, CaseIterable {
        case noStages, tooManyStages, duplicateStageId, noActions, tooManyActions
        case emptyTarget, selectorOnlyTarget
        case literalForSensitiveConcept, unknownKeychainKey, keychainValueWithoutConcept,
             keychainConceptMismatch, askConceptMismatch
        case commercialAction, optionalConsentWithoutPermission
        case timeoutOutOfRange
        case scriptContent
        case unknownAdapter
    }

    public let code: Code
    public let path: String
    public let message: String

    public var description: String { "[\(code.rawValue)] \(path): \(message)" }
}

// MARK: - Heuristiken

/// Erkennt kommerzielle und Marketing-Elemente anhand ihrer Beschriftung (01 §19).
/// Bewusst konservativ: Lieber eine Aktion zu viel blockieren als ungewollt etwas kaufen.
public enum ConsentClassifier {
    static let commercialWords: Set<String> = [
        "buy", "purchase", "premium", "upgrade", "pay", "paid", "payment", "subscription", "checkout",
        "kaufen", "kauf", "buchen", "bezahlen", "zahlen", "kostenpflichtig", "zahlungspflichtig",
        "abonnement", "abonnieren", "eur", "usd", "chf", "gbp",
    ]
    static let currencySymbols: [Character] = ["€", "$", "£"]
    static let marketingWords: Set<String> = [
        "newsletter", "marketing", "werbung", "promotion", "promotions", "offers", "angebote",
        "partner", "partners", "partnern", "advertising", "werbezwecke", "dritte", "third",
    ]

    public static func isCommercial(_ texts: [String]) -> Bool {
        texts.contains { text in
            text.contains(where: currencySymbols.contains) || !words(text).isDisjoint(with: commercialWords)
        }
    }

    public static func isMarketing(_ texts: [String]) -> Bool {
        texts.contains { !words($0).isDisjoint(with: marketingWords) }
    }

    /// Zerlegt in kleingeschriebene Wörter (Buchstaben/Ziffern), damit „pay“ nicht in „display“ trifft.
    static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }
}

enum ScriptHeuristics {
    static let markers = ["javascript:", "<script", "vbscript:", "data:text/html", "onerror=", "onload=", "eval("]

    static func looksLikeScript(_ text: String) -> Bool {
        let lower = text.lowercased().replacingOccurrences(of: " ", with: "")
        return markers.contains { lower.contains($0) }
    }
}

// MARK: - Alle Texte eines Recipes (für Skript-Prüfung)

extension Recipe {
    func allStrings() -> [(String, String)] {
        var out: [(String, String)] = [("name", name), ("network.ssid", network.ssid)]
        out += (success.pageContainsAny ?? []).map { ("success.pageContainsAny", $0) }
        for (si, stage) in stages.enumerated() {
            let sp = "stages[\(si)]"
            out.append(("\(sp).id", stage.id))
            if let m = stage.match {
                for text in (m.anyText ?? []) { out.append(("\(sp).match", text)) }
                for text in (m.urlContains ?? []) { out.append(("\(sp).match", text)) }
            }
            for (ai, action) in stage.actions.enumerated() {
                let ap = "\(sp).actions[\(ai)]"
                if let t = action.target {
                    var texts: [String] = t.allDescriptors
                    for extra in [t.type, t.autocomplete, t.lastKnownSelector] {
                        if let extra { texts.append(extra) }
                    }
                    for text in texts { out.append(("\(ap).target", text)) }
                }
                switch action {
                case .fill(let f):
                    switch f.value {
                    case .literal(let v), .profile(let v), .keychain(let v), .runtime(let v):
                        out.append(("\(ap).value", v))
                    case .ask:
                        break
                    }
                case .select(let s):
                    for text in s.option.allTexts { out.append(("\(ap).option", text)) }
                case .requestValue(let r):
                    if let p = r.prompt { out.append(("\(ap).prompt", p)) }
                case .waitFor(let w):
                    for text in (w.urlContains ?? []) { out.append(("\(ap).waitFor", text)) }
                    for text in (w.pageContainsAny ?? []) { out.append(("\(ap).waitFor", text)) }
                case .verify(let v):
                    out += (v.pageContainsAny ?? []).map { ("\(ap).verify", $0) }
                case .adapter(let a):
                    out.append(("\(ap).adapter", a.id))
                case .check, .uncheck, .tap, .submit, .stop:
                    break
                }
            }
        }
        return out
    }
}
