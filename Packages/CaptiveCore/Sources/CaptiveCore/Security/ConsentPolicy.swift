import Foundation

public enum ConsentClass: String, Sendable {
    case requiredTerms, privacy, marketing, paid, unknown
}

/// Consent- und Zahlungsregeln (01 §19, S10). "Setz alle Haken" heißt: alle notwendigen,
/// nicht-kommerziellen Checkboxen.
public enum ConsentPolicy {
    private static let paidWords = ["€", "$", "£", "eur", "usd", "kaufen", "buy", "purchase", "premium", "upgrade",
                                    "subscribe to premium", "abo", "subscription", "abonnement", "bezahl", "payment",
                                    "pay ", "checkout", "preis", "price", "kostenpflichtig", "per month", "pro monat"]
    private static let marketingWords = ["newsletter", "marketing", "werbung", "promotion", "angebote", "offers",
                                         "partner", "tracking", "third part", "dritte", "advertis", "subscribe", "mailing", "special deals"]
    private static let privacyWords = ["datenschutz", "privacy", "dsgvo", "gdpr"]
    private static let termsWords = ["terms", "agb", "nutzungsbedingung", "bedingungen", "conditions", "usage policy", "acceptable use", "i agree", "ich akzeptiere", "ich stimme", "accept"]

    public static func isPaid(_ text: String) -> Bool {
        let t = text.lowercased()
        return paidWords.contains { t.contains($0) }
    }

    public static func classify(_ control: NormalizedControl) -> ConsentClass {
        let text = [control.label, control.text, control.ariaLabel, control.nearbyText, control.name]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        if isPaid(text) { return .paid }
        if marketingWords.contains(where: { text.contains($0) }) {
            // "Terms and Partner conditions" bleibt marketing: explizite Erlaubnis nötig.
            return .marketing
        }
        if privacyWords.contains(where: { text.contains($0) }) { return .privacy }
        if termsWords.contains(where: { text.contains($0) }) { return .requiredTerms }
        return .unknown
    }

    public enum Decision: Equatable, Sendable {
        case allow
        case block(reason: String)
    }

    /// Prüfung vor `check`/`select`/`tap` auf dem aufgelösten Control.
    public static func evaluate(_ control: NormalizedControl, action: String, policy: IntentPolicy) -> Decision {
        let cls = classify(control)
        if cls == .paid { return .block(reason: "Kostenpflichtige Aktion ist in V1 nicht automatisierbar") }
        if action == "check", cls == .marketing, !policy.allowOptionalMarketingConsent {
            return .block(reason: "Optionale Marketing-/Tracking-Einwilligung nicht freigegeben")
        }
        if action == "check", cls == .unknown, !control.required {
            return .block(reason: "Unbekannte optionale Checkbox wird nicht automatisch gesetzt")
        }
        return .allow
    }

    /// Alle Checkboxen, die bei "alle notwendigen Haken" gesetzt werden dürfen.
    public static func acceptable(in page: NormalizedPage, intent: PortalIntent) -> [NormalizedControl] {
        let wantTerms = intent.instructions.contains(.acceptRequiredTerms)
        let wantPrivacy = intent.instructions.contains(.acceptRequiredPrivacy)
        return page.visibleControls.filter { c in
            guard c.role == .checkbox, !c.checked else { return false }
            guard evaluate(c, action: "check", policy: intent.policy) == .allow else { return false }
            switch classify(c) {
            case .requiredTerms: return wantTerms || c.required
            case .privacy: return wantPrivacy || c.required
            case .marketing: return intent.policy.allowOptionalMarketingConsent
            case .paid: return false
            case .unknown: return c.required
            }
        }
    }
}
