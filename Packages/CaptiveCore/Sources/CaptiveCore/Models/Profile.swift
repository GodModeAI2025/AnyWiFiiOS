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

/// Frühere Recipe-Revision (01 §30). Aufbewahrt werden die letzten fünf.
public struct RecipeRevision: Codable, Equatable, Sendable {
    public var revision: Int
    public var yaml: String
    public var savedAt: Date
    public var note: String

    public init(revision: Int, yaml: String, savedAt: Date = Date(), note: String) {
        self.revision = revision
        self.yaml = yaml
        self.savedAt = savedAt
        self.note = note
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
    public var revisionHistory: [RecipeRevision]

    public static let maxHistory = 5

    public init(id: UUID = UUID(), name: String, enabled: Bool = true,
                network: NetworkMatcher, intent: PortalIntent, recipe: Recipe? = nil,
                credentialBindings: [CredentialBinding] = [], wifi: WiFiConfiguration? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), recipeRevision: Int = 0,
                revisionHistory: [RecipeRevision] = []) {
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
        self.revisionHistory = revisionHistory
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, enabled, network, intent, recipe, credentialBindings, wifi, createdAt, updatedAt
        case recipeRevision, revisionHistory
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        network = try c.decode(NetworkMatcher.self, forKey: .network)
        intent = try c.decode(PortalIntent.self, forKey: .intent)
        recipe = try c.decodeIfPresent(Recipe.self, forKey: .recipe)
        credentialBindings = try c.decode([CredentialBinding].self, forKey: .credentialBindings)
        wifi = try c.decodeIfPresent(WiFiConfiguration.self, forKey: .wifi)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        recipeRevision = try c.decode(Int.self, forKey: .recipeRevision)
        revisionHistory = try c.decodeIfPresent([RecipeRevision].self, forKey: .revisionHistory) ?? []
    }

    /// Übernimmt ein neues Recipe als nächste Revision. Die bisherige Fassung wandert in die Historie.
    public mutating func commit(_ new: Recipe, note: String, at date: Date = Date()) {
        if let old = recipe, let yaml = try? PRLCodec.serialize(old) {
            revisionHistory.append(RecipeRevision(revision: recipeRevision, yaml: yaml, savedAt: date, note: note))
            if revisionHistory.count > Self.maxHistory { revisionHistory.removeFirst(revisionHistory.count - Self.maxHistory) }
        }
        recipe = new
        recipeRevision += 1
        updatedAt = date
    }

    public enum RollbackError: Error, Equatable, Sendable { case revisionNotFound, corrupt }

    /// Stellt eine frühere Revision wieder her. Es entsteht eine neue Revision mit altem Inhalt,
    /// damit die Historie linear bleibt ("Seit Version 7 schlägt es fehl → Version 6").
    public mutating func rollback(to revision: Int, at date: Date = Date()) throws {
        guard let old = revisionHistory.first(where: { $0.revision == revision }) else { throw RollbackError.revisionNotFound }
        guard let restored = try? PRLCodec.parse(yaml: old.yaml) else { throw RollbackError.corrupt }
        commit(restored, note: "Rollback auf Revision \(revision)", at: date)
    }
}
