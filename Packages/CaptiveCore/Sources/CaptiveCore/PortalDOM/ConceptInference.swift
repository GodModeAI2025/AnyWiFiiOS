import Foundation

/// Bildet Beschriftung/Name/Placeholder/ARIA auf semantische Konzepte ab (S7).
public enum ConceptInference {
    private static let rules: [(concept: String, needles: [String])] = [
        ("roomNumber", ["roomnumber", "roomno", "room", "zimmernummer", "zimmer"]),
        ("lastName", ["lastname", "nachname", "surname", "familyname", "familienname"]),
        ("voucherCode", ["voucher", "gutschein", "coupon"]),
        ("otp", ["otp", "smscode", "verificationcode", "bestaetigungscode", "einmalcode"]),
        ("accessCode", ["accesscode", "zugangscode", "zugangsnummer", "passcode", "pincode"]),
        ("phoneNumber", ["phone", "telefon", "mobile", "handynummer", "mobil"]),
        ("email", ["email", "mail"]),
        ("password", ["password", "passwort", "kennwort", "passwd"]),
        ("username", ["username", "benutzername", "benutzer", "loginname", "userid", "user", "login"]),
    ]

    /// Normalisiert für Vergleiche: klein, ohne Diakritika und Satzzeichen.
    public static func fold(_ s: String) -> String {
        let base = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return String(base.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    public static func concept(for c: NormalizedControl) -> String? {
        guard [.textField, .password, .textArea, .select].contains(c.role) else { return nil }
        if c.role == .password { return "password" }
        switch c.inputType {
        case "email": return "email"
        case "tel": return "phoneNumber"
        default: break
        }
        switch c.autocomplete?.lowercased() {
        case "username": return "username"
        case "email": return "email"
        case "tel": return "phoneNumber"
        case "family-name": return "lastName"
        case "one-time-code": return "otp"
        case "current-password", "new-password": return "password"
        default: break
        }
        // Beschriftung vor Name vor Placeholder vor Nähe: spezifischste Quelle gewinnt.
        let sources = [c.label, c.ariaLabel, c.name, c.placeholder, c.htmlId, c.nearbyText].compactMap { $0 }
        for source in sources {
            let folded = fold(source)
            guard !folded.isEmpty else { continue }
            for rule in rules where rule.needles.contains(where: { folded.contains($0) }) {
                return rule.concept
            }
        }
        return nil
    }
}
