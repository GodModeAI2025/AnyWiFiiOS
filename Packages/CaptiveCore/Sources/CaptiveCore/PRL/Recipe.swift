import Foundation

/// Semantischer Descriptor eines Elements (01 §10). CSS-Selector nur als Fallback.
public struct Target: Equatable, Sendable {
    public var role: String?
    public var concept: String?
    public var labelAny: [String]
    public var nameAny: [String]
    public var placeholderAny: [String]
    public var ariaAny: [String]
    public var nearbyAny: [String]
    public var ordinal: Int?
    public var lastKnownSelector: String?

    public init(role: String? = nil, concept: String? = nil, labelAny: [String] = [],
                nameAny: [String] = [], placeholderAny: [String] = [], ariaAny: [String] = [],
                nearbyAny: [String] = [], ordinal: Int? = nil, lastKnownSelector: String? = nil) {
        self.role = role
        self.concept = concept
        self.labelAny = labelAny
        self.nameAny = nameAny
        self.placeholderAny = placeholderAny
        self.ariaAny = ariaAny
        self.nearbyAny = nearbyAny
        self.ordinal = ordinal
        self.lastKnownSelector = lastKnownSelector
    }

    public var isEmpty: Bool {
        role == nil && concept == nil && labelAny.isEmpty && nameAny.isEmpty
            && placeholderAny.isEmpty && ariaAny.isEmpty && nearbyAny.isEmpty
            && ordinal == nil && lastKnownSelector == nil
    }
}

/// Wertquellen (01 §9.1). `literal` ist nur für nicht-sensible Werte zulässig (Validator).
public enum ValueSource: Equatable, Sendable {
    case literal(String)
    case profile(String)
    case keychain(String)
    case ask(String)
    case runtime(String)
}

public struct StageMatch: Equatable, Sendable {
    public var anyText: [String]
    public var fields: [String]
    public var urlContains: [String]

    public init(anyText: [String] = [], fields: [String] = [], urlContains: [String] = []) {
        self.anyText = anyText
        self.fields = fields
        self.urlContains = urlContains
    }

    public var isEmpty: Bool { anyText.isEmpty && fields.isEmpty && urlContains.isEmpty }
}

public enum WaitCondition: Equatable, Sendable {
    case urlContains(String)
    case textAny([String])
    case elementConcept(String)
}

public enum VerifyCondition: Equatable, Sendable {
    case internetAccess(Bool)
    case pageContainsAny([String])
}

public enum StopState: String, Equatable, Sendable, CaseIterable {
    case success
    case temporaryFailure
    case unsupported
    case requiresManualInteraction
}

/// Die geschlossene Menge der PRL-Primitive (01 §9). Keine Skripte, kein freier Code.
public enum Action: Equatable, Sendable {
    case fill(target: Target, value: ValueSource)
    case check(target: Target)
    case uncheck(target: Target)
    case select(target: Target, option: String)
    case tap(target: Target)
    case submit
    case requestValue(concept: String, prompt: String?)
    case waitFor(WaitCondition)
    case verify(VerifyCondition)
    case stop(StopState)

    public var opcode: String {
        switch self {
        case .fill: "fill"
        case .check: "check"
        case .uncheck: "uncheck"
        case .select: "select"
        case .tap: "tap"
        case .submit: "submit"
        case .requestValue: "requestValue"
        case .waitFor: "waitFor"
        case .verify: "verify"
        case .stop: "stop"
        }
    }
}

public struct Stage: Equatable, Sendable {
    public var id: String
    public var match: StageMatch
    public var actions: [Action]

    public init(id: String, match: StageMatch = .init(), actions: [Action]) {
        self.id = id
        self.match = match
        self.actions = actions
    }
}

public struct SuccessCriteria: Equatable, Sendable {
    public var internetAccess: Bool

    public init(internetAccess: Bool = true) { self.internetAccess = internetAccess }
}

public struct Recipe: Equatable, Sendable {
    public static let currentVersion = 1

    public var recipeVersion: Int
    public var profileId: String?
    public var name: String
    public var ssid: String
    public var stages: [Stage]
    public var success: SuccessCriteria

    public init(recipeVersion: Int = Recipe.currentVersion, profileId: String? = nil,
                name: String, ssid: String, stages: [Stage],
                success: SuccessCriteria = .init()) {
        self.recipeVersion = recipeVersion
        self.profileId = profileId
        self.name = name
        self.ssid = ssid
        self.stages = stages
        self.success = success
    }
}

// Profile speichert Recipes als Codable (JSON im App Group Store). Intern als PRL-YAML-String,
// damit es genau eine Serialisierung gibt.
extension Recipe: Codable {
    public init(from decoder: Decoder) throws {
        let yaml = try decoder.singleValueContainer().decode(String.self)
        self = try PRLCodec.parse(yaml: yaml)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(PRLCodec.serialize(self))
    }
}
