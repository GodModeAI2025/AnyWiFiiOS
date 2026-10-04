import Foundation

// Portal Recipe Language v1 (docs/spec/01 §8–10). JSON-Schema: Schemas/prl-v1.schema.json.
// Die Typen hier sind das Laufzeitmodell. YAML ist nur das Persistenzformat (siehe PRLCodec).

// MARK: - Begriffe

/// Semantisches Konzept eines Formularfelds (01 §7.4).
public enum Concept: String, Codable, CaseIterable, Sendable {
    case username, password, lastName, roomNumber, email, voucherCode, accessCode, phoneNumber, otp

    /// Datenklassifikation (01 §20.3).
    public var sensitivity: Sensitivity {
        switch self {
        case .password, .voucherCode, .accessCode, .otp: .secret
        case .username, .lastName, .roomNumber, .email, .phoneNumber: .personal
        }
    }
}

public enum Sensitivity: String, Codable, Sendable {
    case secret, personal
}

public enum ElementRole: String, Codable, CaseIterable, Sendable {
    case textField, passwordField, checkbox, radio, select, button, link
}

// MARK: - Recipe

public struct Recipe: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var recipeVersion: Int
    public var profileId: UUID
    public var name: String
    public var network: NetworkSpec
    public var stages: [Stage]
    public var success: SuccessCriteria

    public init(profileId: UUID, name: String, network: NetworkSpec, stages: [Stage], success: SuccessCriteria) {
        self.recipeVersion = Self.currentVersion
        self.profileId = profileId
        self.name = name
        self.network = network
        self.stages = stages
        self.success = success
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case recipeVersion, profileId, name, network, stages, success
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Version zuerst prüfen, damit eine v2-Datei nicht als „unbekannte Felder“ gemeldet wird.
        let version = try c.decode(Int.self, forKey: .recipeVersion)
        guard version == Self.currentVersion else { throw PRLError.unsupportedVersion(version) }
        try decoder.rejectUnknownKeys(CodingKeys.self)
        recipeVersion = version
        profileId = try c.decode(UUID.self, forKey: .profileId)
        name = try c.decode(String.self, forKey: .name)
        network = try c.decode(NetworkSpec.self, forKey: .network)
        stages = try c.decode([Stage].self, forKey: .stages)
        success = try c.decode(SuccessCriteria.self, forKey: .success)
    }
}

public struct NetworkSpec: Codable, Equatable, Sendable {
    public var ssid: String

    public init(ssid: String) { self.ssid = ssid }

    enum CodingKeys: String, CodingKey, CaseIterable { case ssid }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        ssid = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .ssid)
    }
}

public struct SuccessCriteria: Codable, Equatable, Sendable {
    public var internetAccess: Bool
    public var pageContainsAny: [String]?

    public init(internetAccess: Bool, pageContainsAny: [String]? = nil) {
        self.internetAccess = internetAccess
        self.pageContainsAny = pageContainsAny
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case internetAccess, pageContainsAny }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        internetAccess = try c.decode(Bool.self, forKey: .internetAccess)
        pageContainsAny = try c.decodeIfPresent([String].self, forKey: .pageContainsAny)
    }
}

// MARK: - Stage

public struct Stage: Codable, Equatable, Sendable {
    public var id: String
    public var match: StageMatch?
    public var actions: [PortalAction]

    public init(id: String, match: StageMatch? = nil, actions: [PortalAction]) {
        self.id = id
        self.match = match
        self.actions = actions
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case id, match, actions }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        match = try c.decodeIfPresent(StageMatch.self, forKey: .match)
        actions = try c.decode([PortalAction].self, forKey: .actions)
    }
}

/// Woran die Runtime erkennt, dass eine Portalseite zu dieser Stage gehört (01 §13).
public struct StageMatch: Codable, Equatable, Sendable {
    public var anyText: [String]?
    public var fields: [Concept]?
    public var urlContains: [String]?

    public init(anyText: [String]? = nil, fields: [Concept]? = nil, urlContains: [String]? = nil) {
        self.anyText = anyText
        self.fields = fields
        self.urlContains = urlContains
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case anyText, fields, urlContains }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anyText = try c.decodeIfPresent([String].self, forKey: .anyText)
        fields = try c.decodeIfPresent([Concept].self, forKey: .fields)
        urlContains = try c.decodeIfPresent([String].self, forKey: .urlContains)
    }
}

// MARK: - Target (semantischer Element-Deskriptor, 01 §10)

public struct Target: Codable, Equatable, Sendable {
    public var role: ElementRole?
    public var concept: Concept?
    public var labelAny: [String]?
    public var nameAny: [String]?
    public var placeholderAny: [String]?
    public var id: String?
    public var name: String?
    public var type: String?
    public var autocomplete: String?
    public var nearbyText: [String]?
    public var ordinal: Int?
    /// Nur Fallback, niemals Hauptidentität (01 §10).
    public var lastKnownSelector: String?

    public init(
        role: ElementRole? = nil, concept: Concept? = nil, labelAny: [String]? = nil,
        nameAny: [String]? = nil, placeholderAny: [String]? = nil, id: String? = nil,
        name: String? = nil, type: String? = nil, autocomplete: String? = nil,
        nearbyText: [String]? = nil, ordinal: Int? = nil, lastKnownSelector: String? = nil
    ) {
        self.role = role
        self.concept = concept
        self.labelAny = labelAny
        self.nameAny = nameAny
        self.placeholderAny = placeholderAny
        self.id = id
        self.name = name
        self.type = type
        self.autocomplete = autocomplete
        self.nearbyText = nearbyText
        self.ordinal = ordinal
        self.lastKnownSelector = lastKnownSelector
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case role, concept, labelAny, nameAny, placeholderAny, id, name, type, autocomplete,
             nearbyText, ordinal, lastKnownSelector
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(ElementRole.self, forKey: .role)
        concept = try c.decodeIfPresent(Concept.self, forKey: .concept)
        labelAny = try c.decodeIfPresent([String].self, forKey: .labelAny)
        nameAny = try c.decodeIfPresent([String].self, forKey: .nameAny)
        placeholderAny = try c.decodeIfPresent([String].self, forKey: .placeholderAny)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        autocomplete = try c.decodeIfPresent(String.self, forKey: .autocomplete)
        nearbyText = try c.decodeIfPresent([String].self, forKey: .nearbyText)
        ordinal = try c.decodeIfPresent(Int.self, forKey: .ordinal)
        lastKnownSelector = try c.decodeIfPresent(String.self, forKey: .lastKnownSelector)
    }

    /// Alle für Menschen sichtbaren bzw. technischen Bezeichner, z. B. für die Consent-Prüfung.
    public var allDescriptors: [String] {
        var result: [String] = []
        for list in [labelAny, nameAny, placeholderAny, nearbyText] {
            result.append(contentsOf: list ?? [])
        }
        if let id { result.append(id) }
        if let name { result.append(name) }
        return result
    }

    /// `true`, wenn das Target nur über den CSS-Selector identifiziert wird. Das ist unzulässig (01 §10).
    public var isSelectorOnly: Bool {
        guard lastKnownSelector != nil else { return false }
        if role != nil || concept != nil { return false }
        if type != nil || autocomplete != nil || ordinal != nil { return false }
        return allDescriptors.isEmpty
    }

    /// `true`, wenn das Target überhaupt nichts zur Identifikation enthält.
    public var isEmpty: Bool { self == Target() }
}

// MARK: - Wertquellen (01 §9.1)

public enum ValueSource: Codable, Equatable, Sendable {
    case literal(String)
    case profile(String)
    case keychain(String)
    case ask(Concept)
    case runtime(String)

    public init(from decoder: Decoder) throws {
        let (c, key) = try decoder.singleKey()
        switch key.stringValue {
        case "literal": self = .literal(try c.decode(String.self, forKey: key))
        case "profile": self = .profile(try c.decode(String.self, forKey: key))
        case "keychain": self = .keychain(try c.decode(String.self, forKey: key))
        case "ask": self = .ask(try c.decode(Concept.self, forKey: key))
        case "runtime": self = .runtime(try c.decode(String.self, forKey: key))
        default: throw PRLError.unknownFields([key.stringValue], path: decoder.pathString)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        switch self {
        case .literal(let v): try c.encode(v, forKey: AnyKey("literal"))
        case .profile(let v): try c.encode(v, forKey: AnyKey("profile"))
        case .keychain(let v): try c.encode(v, forKey: AnyKey("keychain"))
        case .ask(let v): try c.encode(v, forKey: AnyKey("ask"))
        case .runtime(let v): try c.encode(v, forKey: AnyKey("runtime"))
        }
    }
}
