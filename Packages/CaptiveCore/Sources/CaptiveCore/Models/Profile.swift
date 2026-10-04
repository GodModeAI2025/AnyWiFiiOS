import Foundation

/// V1 beansprucht niemals pauschal alle WLANs (01 §7.2).
public struct NetworkMatcher: Codable, Equatable, Sendable {
    public var ssidExact: String
    public var bssidAllowList: [String]?
    public var portalHostHints: [String]

    public init(ssidExact: String, bssidAllowList: [String]? = nil, portalHostHints: [String] = []) {
        self.ssidExact = ssidExact
        self.bssidAllowList = bssidAllowList
        self.portalHostHints = portalHostHints
    }

    public func matches(ssid: String, bssid: String? = nil) -> Bool {
        guard !ssidExact.isEmpty, ssid == ssidExact else { return false }
        guard let allow = bssidAllowList, !allow.isEmpty else { return true }
        guard let bssid else { return false }
        return allow.contains { $0.caseInsensitiveCompare(bssid) == .orderedSame }
    }
}

public enum PersistencePolicy: String, Codable, Sendable {
    case askEveryTime
    case rememberInKeychain
    case useOnce
}

public struct CredentialBinding: Codable, Equatable, Sendable {
    public var concept: String
    public var keychainKey: String
    public var prompt: String
    public var persistence: PersistencePolicy
    public var sensitivity: Sensitivity

    public init(concept: String, keychainKey: String, prompt: String,
                persistence: PersistencePolicy, sensitivity: Sensitivity? = nil) {
        self.concept = concept
        self.keychainKey = keychainKey
        self.prompt = prompt
        self.persistence = persistence
        self.sensitivity = sensitivity ?? ConceptCatalog.sensitivity(of: concept)
    }
}

/// Woher ein Wert im Intent kommt (01 §7.3).
public enum IntentValueSource: String, Codable, Sendable {
    case askWhenMissing
    case keychain
    case profile
}

public enum IntentInstruction: Codable, Equatable, Sendable {
    case acceptRequiredTerms
    case acceptRequiredPrivacy
    case fill(concept: String, source: IntentValueSource)
    case submit
}

public struct IntentPolicy: Codable, Equatable, Sendable {
    public var allowOptionalMarketingConsent: Bool
    public var allowPaidUpgrade: Bool

    public init(allowOptionalMarketingConsent: Bool = false, allowPaidUpgrade: Bool = false) {
        self.allowOptionalMarketingConsent = allowOptionalMarketingConsent
        self.allowPaidUpgrade = allowPaidUpgrade
    }
}

public struct PortalIntent: Codable, Equatable, Sendable {
    public var intentVersion: Int
    public var goal: String
    public var instructions: [IntentInstruction]
    public var policy: IntentPolicy
    /// Originalanweisung des Nutzers, separat gespeichert (01 §7.3).
    public var originalText: String?

    public init(intentVersion: Int = 1, goal: String = "authenticate",
                instructions: [IntentInstruction], policy: IntentPolicy = .init(),
                originalText: String? = nil) {
        self.intentVersion = intentVersion
        self.goal = goal
        self.instructions = instructions
        self.policy = policy
        self.originalText = originalText
    }
}

/// Optionaler WLAN-Teil eines Profils (SPEC §3.1). Die Passphrase liegt nie hier, nur im Keychain.
public struct WiFiConfiguration: Codable, Equatable, Sendable {
    public enum Security: String, Codable, Sendable {
        case open
        case wpaPersonal
    }

    public var ssid: String
    public var security: Security
    public var passphraseKeychainKey: String?

    public init(ssid: String, security: Security, passphraseKeychainKey: String? = nil) {
        self.ssid = ssid
        self.security = security
        self.passphraseKeychainKey = passphraseKeychainKey
    }
}

public struct PortalProfile: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var enabled: Bool
    public var network: NetworkMatcher
    public var intent: PortalIntent
    public var recipe: Recipe?
    public var credentialBindings: [CredentialBinding]
    public var wifi: WiFiConfiguration?
    public var createdAt: Date
    public var updatedAt: Date
    public var recipeRevision: Int

    public init(id: UUID = UUID(), name: String, enabled: Bool = true,
                network: NetworkMatcher, intent: PortalIntent, recipe: Recipe? = nil,
                credentialBindings: [CredentialBinding] = [], wifi: WiFiConfiguration? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), recipeRevision: Int = 0) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.network = network
        self.intent = intent
        self.recipe = recipe
        self.credentialBindings = credentialBindings
        self.wifi = wifi
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.recipeRevision = recipeRevision
    }
}
