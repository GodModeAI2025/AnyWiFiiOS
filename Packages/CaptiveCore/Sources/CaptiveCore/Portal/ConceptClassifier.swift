import Foundation

/// Ordnet Eingabefeldern ein semantisches Konzept zu (01 §10, Gate S7).
/// Deterministisch und mehrsprachig (DE/EN/FR/ES/IT), ohne AI.
public enum ConceptClassifier {
    /// Reihenfolge ist Priorität: Spezifische Konzepte zuerst, `username` zuletzt.
    static let keywordRules: [(Concept, [String])] = [
        (.roomNumber, ["room", "zimmer", "chambre", "habitacion", "habitación", "zimmernummer"]),
        (.lastName, ["last name", "lastname", "surname", "family name", "nachname", "familienname", "nom de famille", "apellido", "cognome"]),
        (.voucherCode, ["voucher", "gutschein", "coupon", "ticket"]),
        (.accessCode, ["access code", "accesscode", "zugangscode", "zugangsschlüssel", "pin code", "passcode"]),
        (.otp, ["otp", "one time", "einmal", "sms code", "verification code", "bestätigungscode"]),
        (.email, ["email", "e mail", "mail adresse", "mailadresse", "courriel"]),
        (.phoneNumber, ["phone", "telefon", "handy", "mobile number", "mobilnummer", "téléphone"]),
        (.username, ["username", "user name", "benutzername", "benutzer", "login name", "loginname", "user id", "userid", "kennung"]),
    ]

    public static func classify(_ control: PortalControl) -> Concept? {
        guard let role = control.role, role == .textField || role == .passwordField else { return nil }
        let type = control.inputType ?? ""
        let autocomplete = (control.autocomplete ?? "").lowercased()

        if role == .passwordField || autocomplete == "current-password" || autocomplete == "new-password" {
            return .password
        }
        if type == "email" || autocomplete == "email" { return .email }
        if type == "tel" || autocomplete == "tel" { return .phoneNumber }

        // Eigene Merkmale des Felds zuerst, umgebender Text nur als Rückfallebene.
        let own: [String?] = [control.name, control.htmlId, control.label, control.ariaLabel, control.placeholder]
        if let concept = matchKeywords(normalize(own.compactMap { $0 })) { return concept }
        if let nearby = control.nearbyText, let concept = matchKeywords(normalize([nearby])) { return concept }
        if autocomplete == "username" { return .username }
        if autocomplete == "one-time-code" { return .otp }
        // Kurze technische Namen, die zu allgemein für die Stichwortsuche sind.
        if let name = control.name?.lowercased(), ["user", "login", "uid"].contains(name) { return .username }
        return nil
    }

    /// Stichwörter müssen am Wortanfang stehen (" otp" trifft nicht "hotpot").
    static func matchKeywords(_ haystack: String) -> Concept? {
        for (concept, keywords) in keywordRules where keywords.contains(where: { haystack.contains(" " + $0) }) {
            return concept
        }
        return nil
    }

    /// Kleinschreibung, camelCase/Unterstriche/Bindestriche → Leerzeichen, Whitespace zusammenfassen.
    /// Ergebnis ist mit führendem/abschließendem Leerzeichen gepolstert.
    static func normalize(_ parts: [String]) -> String {
        var result = " "
        for part in parts {
            var previousWasLower = false
            for ch in part {
                if ch.isUppercase && previousWasLower { result.append(" ") }
                previousWasLower = ch.isLowercase
                if ch.isLetter || ch.isNumber {
                    result.append(contentsOf: ch.lowercased())
                } else if result.last != " " {
                    result.append(" ")
                }
            }
            if result.last != " " { result.append(" ") }
        }
        return result
    }
}
