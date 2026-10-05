import Foundation

/// Klassifikation von Werten (01 §20.3).
public enum Sensitivity: String, Codable, Sendable, CaseIterable {
    case secret
    case personal
    case `public`
}

/// Bekannte semantische Konzepte für Formularfelder (01 §7.4) mit Datenklassifikation.
public enum ConceptCatalog {
    public static let known: Set<String> = [
        "username", "password", "lastName", "roomNumber", "email",
        "voucherCode", "accessCode", "phoneNumber", "otp",
    ]

    /// Unbekannte Konzepte gelten konservativ als personenbezogen.
    public static func sensitivity(of concept: String) -> Sensitivity {
        switch concept {
        case "password", "voucherCode", "accessCode", "otp", "token":
            return .secret
        default:
            return .personal
        }
    }

    public static func placeholder(for concept: String) -> String {
        switch sensitivity(of: concept) {
        case .secret: return "<secret:\(concept)>"
        case .personal: return "<personal:\(concept)>"
        case .public: return "<public:\(concept)>"
        }
    }
}

/// Definierte Outcomes (01 §23).
public enum Outcome: String, Codable, Sendable, CaseIterable {
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
