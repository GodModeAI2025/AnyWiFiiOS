import Foundation

/// Die abschließende Menge erlaubter Recipe-Primitive (01 §9). Kein JavaScript, kein freier Code.
///
/// Im YAML ist jede Aktion ein Objekt mit genau einem Schlüssel, dem Opcode:
/// ```yaml
/// - fill:
///     target: { concept: roomNumber }
///     value: { ask: roomNumber }
/// ```
public enum PortalAction: Codable, Equatable, Sendable {
    case fill(FillAction)
    case check(TargetAction)
    case uncheck(TargetAction)
    case select(SelectAction)
    case tap(TargetAction)
    case submit(SubmitAction)
    case requestValue(RequestValueAction)
    case waitFor(WaitCondition)
    case verify(VerifyCondition)
    case stop(StopAction)

    public enum Opcode: String, CaseIterable, Sendable {
        case fill, check, uncheck, select, tap, submit, requestValue, waitFor, verify, stop
    }

    public var opcode: Opcode {
        switch self {
        case .fill: .fill
        case .check: .check
        case .uncheck: .uncheck
        case .select: .select
        case .tap: .tap
        case .submit: .submit
        case .requestValue: .requestValue
        case .waitFor: .waitFor
        case .verify: .verify
        case .stop: .stop
        }
    }

    /// Das Element, auf das die Aktion wirkt (falls vorhanden).
    public var target: Target? {
        switch self {
        case .fill(let a): return a.target
        case .check(let a), .uncheck(let a), .tap(let a): return a.target
        case .select(let a): return a.target
        case .submit(let a): return a.target
        case .waitFor(let w): return w.element
        case .requestValue, .verify, .stop: return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let (c, key) = try decoder.singleKey()
        guard let op = Opcode(rawValue: key.stringValue) else {
            throw PRLError.unknownOpcode(key.stringValue, path: decoder.pathString)
        }
        switch op {
        case .fill: self = .fill(try c.decode(FillAction.self, forKey: key))
        case .check: self = .check(try c.decode(TargetAction.self, forKey: key))
        case .uncheck: self = .uncheck(try c.decode(TargetAction.self, forKey: key))
        case .select: self = .select(try c.decode(SelectAction.self, forKey: key))
        case .tap: self = .tap(try c.decode(TargetAction.self, forKey: key))
        case .submit: self = .submit(try c.decode(SubmitAction.self, forKey: key))
        case .requestValue: self = .requestValue(try c.decode(RequestValueAction.self, forKey: key))
        case .waitFor: self = .waitFor(try c.decode(WaitCondition.self, forKey: key))
        case .verify: self = .verify(try c.decode(VerifyCondition.self, forKey: key))
        case .stop: self = .stop(try c.decode(StopAction.self, forKey: key))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        let key = AnyKey(opcode.rawValue)
        switch self {
        case .fill(let a): try c.encode(a, forKey: key)
        case .check(let a), .uncheck(let a), .tap(let a): try c.encode(a, forKey: key)
        case .select(let a): try c.encode(a, forKey: key)
        case .submit(let a): try c.encode(a, forKey: key)
        case .requestValue(let a): try c.encode(a, forKey: key)
        case .waitFor(let a): try c.encode(a, forKey: key)
        case .verify(let a): try c.encode(a, forKey: key)
        case .stop(let a): try c.encode(a, forKey: key)
        }
    }
}

// MARK: - Nutzdaten der Aktionen

public struct FillAction: Codable, Equatable, Sendable {
    public var target: Target
    public var value: ValueSource

    public init(target: Target, value: ValueSource) {
        self.target = target
        self.value = value
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case target, value }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(Target.self, forKey: .target)
        value = try c.decode(ValueSource.self, forKey: .value)
    }
}

/// Für `check`, `uncheck` und `tap`.
public struct TargetAction: Codable, Equatable, Sendable {
    public var target: Target

    public init(target: Target) { self.target = target }

    enum CodingKeys: String, CodingKey, CaseIterable { case target }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        target = try decoder.container(keyedBy: CodingKeys.self).decode(Target.self, forKey: .target)
    }
}

public struct SelectAction: Codable, Equatable, Sendable {
    public var target: Target
    public var option: OptionSpec

    public init(target: Target, option: OptionSpec) {
        self.target = target
        self.option = option
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case target, option }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(Target.self, forKey: .target)
        option = try c.decode(OptionSpec.self, forKey: .option)
    }
}

public struct OptionSpec: Codable, Equatable, Sendable {
    public var labelAny: [String]?
    public var value: String?

    public init(labelAny: [String]? = nil, value: String? = nil) {
        self.labelAny = labelAny
        self.value = value
    }

    /// Beschriftungen und Wert, z. B. für Consent- und Skriptprüfung.
    public var allTexts: [String] {
        var texts = labelAny ?? []
        if let value { texts.append(value) }
        return texts
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case labelAny, value }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        labelAny = try c.decodeIfPresent([String].self, forKey: .labelAny)
        value = try c.decodeIfPresent(String.self, forKey: .value)
    }
}

/// Formular explizit absenden (01 §9.6). Ohne Target wird das Formular des zuletzt bearbeiteten Felds abgesendet.
public struct SubmitAction: Codable, Equatable, Sendable {
    public var target: Target?

    public init(target: Target? = nil) { self.target = target }

    enum CodingKeys: String, CodingKey, CaseIterable { case target }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        target = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(Target.self, forKey: .target)
    }
}

public struct RequestValueAction: Codable, Equatable, Sendable {
    public var concept: Concept
    public var prompt: String?

    public init(concept: Concept, prompt: String? = nil) {
        self.concept = concept
        self.prompt = prompt
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case concept, prompt }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        concept = try c.decode(Concept.self, forKey: .concept)
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
    }
}

public struct WaitCondition: Codable, Equatable, Sendable {
    public var redirect: Bool?
    public var urlContains: [String]?
    public var pageContainsAny: [String]?
    public var element: Target?
    public var timeoutSeconds: Int?

    public init(redirect: Bool? = nil, urlContains: [String]? = nil, pageContainsAny: [String]? = nil,
                element: Target? = nil, timeoutSeconds: Int? = nil) {
        self.redirect = redirect
        self.urlContains = urlContains
        self.pageContainsAny = pageContainsAny
        self.element = element
        self.timeoutSeconds = timeoutSeconds
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case redirect, urlContains, pageContainsAny, element, timeoutSeconds }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        redirect = try c.decodeIfPresent(Bool.self, forKey: .redirect)
        urlContains = try c.decodeIfPresent([String].self, forKey: .urlContains)
        pageContainsAny = try c.decodeIfPresent([String].self, forKey: .pageContainsAny)
        element = try c.decodeIfPresent(Target.self, forKey: .element)
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
    }
}

public struct VerifyCondition: Codable, Equatable, Sendable {
    public var internetAccess: Bool?
    public var pageContainsAny: [String]?

    public init(internetAccess: Bool? = nil, pageContainsAny: [String]? = nil) {
        self.internetAccess = internetAccess
        self.pageContainsAny = pageContainsAny
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case internetAccess, pageContainsAny }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        internetAccess = try c.decodeIfPresent(Bool.self, forKey: .internetAccess)
        pageContainsAny = try c.decodeIfPresent([String].self, forKey: .pageContainsAny)
    }
}

/// Terminale Zustände (01 §9.10).
public enum StopOutcome: String, Codable, CaseIterable, Sendable {
    case success, temporaryFailure, unsupported, requiresManualInteraction
}

public struct StopAction: Codable, Equatable, Sendable {
    public var outcome: StopOutcome

    public init(outcome: StopOutcome) { self.outcome = outcome }

    enum CodingKeys: String, CodingKey, CaseIterable { case outcome }

    public init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(CodingKeys.self)
        outcome = try decoder.container(keyedBy: CodingKeys.self).decode(StopOutcome.self, forKey: .outcome)
    }
}
