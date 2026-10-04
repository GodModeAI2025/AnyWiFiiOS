import Foundation
import Yams

public enum PRLError: Error, Equatable, CustomStringConvertible, Sendable {
    case yamlSyntax(String)
    case notAMapping(path: String)
    case notASequence(path: String)
    case notAScalar(path: String)
    case missingField(path: String)
    case unknownField(path: String)
    case duplicateField(path: String)
    case unknownOpcode(String)
    case unsupportedVersion(Int)
    case invalidValue(path: String, reason: String)

    public var description: String {
        switch self {
        case .yamlSyntax(let m): "YAML-Syntaxfehler: \(m)"
        case .notAMapping(let p): "\(p): Mapping erwartet"
        case .notASequence(let p): "\(p): Liste erwartet"
        case .notAScalar(let p): "\(p): einfacher Wert erwartet"
        case .missingField(let p): "\(p): Pflichtfeld fehlt"
        case .unknownField(let p): "\(p): unbekanntes Feld"
        case .duplicateField(let p): "\(p): doppeltes Feld"
        case .unknownOpcode(let o): "unbekannter Opcode '\(o)'"
        case .unsupportedVersion(let v): "recipeVersion \(v) wird nicht unterstützt"
        case .invalidValue(let p, let r): "\(p): \(r)"
        }
    }
}

/// Strikter Parser und Serializer für PRL v1. Arbeitet auf dem YAML-Node-Baum, damit Skalare
/// nie implizit typisiert werden ("yes", "417" bleiben Strings). Unbekannte Felder und Opcodes
/// werden abgelehnt.
public enum PRLCodec {
    public static func parse(yaml: String) throws -> Recipe {
        let root: Node
        do {
            guard let node = try Yams.compose(yaml: yaml) else {
                throw PRLError.yamlSyntax("leeres Dokument")
            }
            root = node
        } catch let e as PRLError {
            throw e
        } catch {
            throw PRLError.yamlSyntax(String(describing: error))
        }
        var map = try StrictMap(root, path: "recipe")
        let version = try map.int("recipeVersion")
        guard version == Recipe.currentVersion else { throw PRLError.unsupportedVersion(version) }
        let profileId = try map.optString("profileId")
        let name = try map.string("name")
        var netMap = try map.map("network")
        let ssid = try netMap.string("ssid")
        try netMap.finish()

        let stagesNode = try map.node("stages")
        guard case .sequence(let seq) = stagesNode else { throw PRLError.notASequence(path: "recipe.stages") }
        var stages: [Stage] = []
        for (i, n) in seq.enumerated() { stages.append(try parseStage(n, path: "recipe.stages[\(i)]")) }

        var success = SuccessCriteria()
        if map.has("success") {
            var s = try map.map("success")
            success.internetAccess = try s.optBool("internetAccess") ?? true
            try s.finish()
        }
        try map.finish()
        return Recipe(recipeVersion: version, profileId: profileId, name: name, ssid: ssid,
                      stages: stages, success: success)
    }

    // MARK: Parsing

    private static func parseStage(_ node: Node, path: String) throws -> Stage {
        var m = try StrictMap(node, path: path)
        let id = try m.string("id")
        var match = StageMatch()
        if m.has("match") {
            var mm = try m.map("match")
            match.anyText = try mm.optStringList("anyText") ?? []
            match.fields = try mm.optStringList("fields") ?? []
            match.urlContains = try mm.optStringList("urlContains") ?? []
            try mm.finish()
        }
        guard case .sequence(let seq) = try m.node("actions") else {
            throw PRLError.notASequence(path: "\(path).actions")
        }
        var actions: [Action] = []
        for (i, n) in seq.enumerated() { actions.append(try parseAction(n, path: "\(path).actions[\(i)]")) }
        try m.finish()
        return Stage(id: id, match: match, actions: actions)
    }

    private static func parseAction(_ node: Node, path: String) throws -> Action {
        // Aktionen sind Einzel-Mappings ("- tap: {...}") oder ein skalarer Opcode ("- submit").
        if case .scalar(let s) = node {
            if s.string == "submit" { return .submit }
            throw PRLError.unknownOpcode(s.string)
        }
        guard case .mapping(let mapping) = node, mapping.count == 1, let (keyNode, value) = mapping.first,
              let op = keyNode.string else {
            throw PRLError.invalidValue(path: path, reason: "Aktion muss genau einen Opcode enthalten")
        }
        let p = "\(path).\(op)"
        switch op {
        case "fill":
            var m = try StrictMap(value, path: p)
            let target = try parseTarget(try m.node("target"), path: "\(p).target")
            let source = try parseValueSource(try m.node("value"), path: "\(p).value")
            try m.finish()
            return .fill(target: target, value: source)
        case "check", "uncheck", "tap":
            var m = try StrictMap(value, path: p)
            let target = try parseTarget(try m.node("target"), path: "\(p).target")
            try m.finish()
            return op == "check" ? .check(target: target) : op == "uncheck" ? .uncheck(target: target) : .tap(target: target)
        case "select":
            var m = try StrictMap(value, path: p)
            let target = try parseTarget(try m.node("target"), path: "\(p).target")
            let option = try m.string("option")
            try m.finish()
            return .select(target: target, option: option)
        case "submit":
            if case .mapping(let mm) = value, mm.isEmpty { return .submit }
            if case .scalar(let s) = value, s.string.isEmpty || s.string == "~" || s.string == "null" { return .submit }
            throw PRLError.invalidValue(path: p, reason: "submit hat keine Parameter")
        case "requestValue":
            var m = try StrictMap(value, path: p)
            let concept = try m.string("concept")
            let prompt = try m.optString("prompt")
            try m.finish()
            return .requestValue(concept: concept, prompt: prompt)
        case "waitFor":
            var m = try StrictMap(value, path: p)
            let cond: WaitCondition
            if m.has("urlContains") { cond = .urlContains(try m.string("urlContains")) }
            else if m.has("textAny") { cond = .textAny(try m.optStringList("textAny") ?? []) }
            else if m.has("elementConcept") { cond = .elementConcept(try m.string("elementConcept")) }
            else { throw PRLError.invalidValue(path: p, reason: "urlContains, textAny oder elementConcept erwartet") }
            try m.finish()
            return .waitFor(cond)
        case "verify":
            var m = try StrictMap(value, path: p)
            let cond: VerifyCondition
            if m.has("internetAccess") { cond = .internetAccess(try m.bool("internetAccess")) }
            else if m.has("pageContainsAny") { cond = .pageContainsAny(try m.optStringList("pageContainsAny") ?? []) }
            else { throw PRLError.invalidValue(path: p, reason: "internetAccess oder pageContainsAny erwartet") }
            try m.finish()
            return .verify(cond)
        case "stop":
            guard case .scalar(let s) = value, let state = StopState(rawValue: s.string) else {
                throw PRLError.invalidValue(path: p, reason: "success, temporaryFailure, unsupported oder requiresManualInteraction erwartet")
            }
            return .stop(state)
        default:
            throw PRLError.unknownOpcode(op)
        }
    }

    private static func parseTarget(_ node: Node, path: String) throws -> Target {
        var m = try StrictMap(node, path: path)
        var t = Target()
        t.role = try m.optString("role")
        t.concept = try m.optString("concept")
        t.labelAny = try m.optStringList("labelAny") ?? []
        t.nameAny = try m.optStringList("nameAny") ?? []
        t.placeholderAny = try m.optStringList("placeholderAny") ?? []
        t.ariaAny = try m.optStringList("ariaAny") ?? []
        t.nearbyAny = try m.optStringList("nearbyAny") ?? []
        t.ordinal = try m.optInt("ordinal")
        t.lastKnownSelector = try m.optString("lastKnownSelector")
        try m.finish()
        guard !t.isEmpty else { throw PRLError.invalidValue(path: path, reason: "Target darf nicht leer sein") }
        return t
    }

    private static func parseValueSource(_ node: Node, path: String) throws -> ValueSource {
        guard case .mapping(let mapping) = node, mapping.count == 1, let (k, v) = mapping.first,
              let key = k.string, case .scalar(let s) = v else {
            throw PRLError.invalidValue(path: path, reason: "genau eine Wertquelle erwartet")
        }
        switch key {
        case "literal": return .literal(s.string)
        case "profile": return .profile(s.string)
        case "keychain": return .keychain(s.string)
        case "ask": return .ask(s.string)
        case "runtime": return .runtime(s.string)
        default: throw PRLError.unknownField(path: "\(path).\(key)")
        }
    }

    // MARK: Serialisierung (deterministische Feldreihenfolge)

    public static func serialize(_ r: Recipe) throws -> String {
        var top: [(String, Node)] = [("recipeVersion", scalar(String(r.recipeVersion), plain: true))]
        if let id = r.profileId { top.append(("profileId", scalar(id))) }
        top.append(("name", scalar(r.name)))
        top.append(("network", mapping([("ssid", scalar(r.ssid))])))
        top.append(("stages", sequence(r.stages.map(stageNode))))
        top.append(("success", mapping([("internetAccess", scalar(r.success.internetAccess ? "true" : "false", plain: true))])))
        return try Yams.serialize(node: mapping(top), allowUnicode: true)
    }

    private static func scalar(_ s: String, plain: Bool = false) -> Node {
        .scalar(Node.Scalar(s, plain ? .implicit : Tag(.str), .any))
    }

    private static func mapping(_ pairs: [(String, Node)]) -> Node {
        .mapping(Node.Mapping(pairs.map { (scalar($0.0, plain: true), $0.1) }, .implicit, .block))
    }

    private static func sequence(_ nodes: [Node]) -> Node {
        .sequence(Node.Sequence(nodes, .implicit, .block))
    }

    private static func stringList(_ l: [String]) -> Node { sequence(l.map { scalar($0) }) }

    private static func stageNode(_ s: Stage) -> Node {
        var pairs: [(String, Node)] = [("id", scalar(s.id))]
        if !s.match.isEmpty {
            var m: [(String, Node)] = []
            if !s.match.anyText.isEmpty { m.append(("anyText", stringList(s.match.anyText))) }
            if !s.match.fields.isEmpty { m.append(("fields", stringList(s.match.fields))) }
            if !s.match.urlContains.isEmpty { m.append(("urlContains", stringList(s.match.urlContains))) }
            pairs.append(("match", mapping(m)))
        }
        pairs.append(("actions", sequence(s.actions.map(actionNode))))
        return mapping(pairs)
    }

    private static func targetNode(_ t: Target) -> Node {
        var p: [(String, Node)] = []
        if let v = t.role { p.append(("role", scalar(v))) }
        if let v = t.concept { p.append(("concept", scalar(v))) }
        if !t.labelAny.isEmpty { p.append(("labelAny", stringList(t.labelAny))) }
        if !t.nameAny.isEmpty { p.append(("nameAny", stringList(t.nameAny))) }
        if !t.placeholderAny.isEmpty { p.append(("placeholderAny", stringList(t.placeholderAny))) }
        if !t.ariaAny.isEmpty { p.append(("ariaAny", stringList(t.ariaAny))) }
        if !t.nearbyAny.isEmpty { p.append(("nearbyAny", stringList(t.nearbyAny))) }
        if let v = t.ordinal { p.append(("ordinal", scalar(String(v), plain: true))) }
        if let v = t.lastKnownSelector { p.append(("lastKnownSelector", scalar(v))) }
        return mapping(p)
    }

    private static func actionNode(_ a: Action) -> Node {
        switch a {
        case .fill(let t, let v):
            let (k, val): (String, String) = switch v {
            case .literal(let s): ("literal", s)
            case .profile(let s): ("profile", s)
            case .keychain(let s): ("keychain", s)
            case .ask(let s): ("ask", s)
            case .runtime(let s): ("runtime", s)
            }
            return mapping([("fill", mapping([("target", targetNode(t)), ("value", mapping([(k, scalar(val))]))]))])
        case .check(let t): return mapping([("check", mapping([("target", targetNode(t))]))])
        case .uncheck(let t): return mapping([("uncheck", mapping([("target", targetNode(t))]))])
        case .tap(let t): return mapping([("tap", mapping([("target", targetNode(t))]))])
        case .select(let t, let o): return mapping([("select", mapping([("target", targetNode(t)), ("option", scalar(o))]))])
        case .submit: return mapping([("submit", mapping([]))])
        case .requestValue(let c, let p):
            var pairs: [(String, Node)] = [("concept", scalar(c))]
            if let p { pairs.append(("prompt", scalar(p))) }
            return mapping([("requestValue", mapping(pairs))])
        case .waitFor(let c):
            let inner: (String, Node) = switch c {
            case .urlContains(let s): ("urlContains", scalar(s))
            case .textAny(let l): ("textAny", stringList(l))
            case .elementConcept(let s): ("elementConcept", scalar(s))
            }
            return mapping([("waitFor", mapping([inner]))])
        case .verify(let c):
            let inner: (String, Node) = switch c {
            case .internetAccess(let b): ("internetAccess", scalar(b ? "true" : "false", plain: true))
            case .pageContainsAny(let l): ("pageContainsAny", stringList(l))
            }
            return mapping([("verify", mapping([inner]))])
        case .stop(let s): return mapping([("stop", scalar(s.rawValue))])
        }
    }
}

/// Mapping-Wrapper, der verbrauchte Schlüssel verfolgt, damit `finish()` unbekannte Felder meldet.
struct StrictMap {
    private var entries: [(key: String, value: Node)] = []
    private var used: Set<String> = []
    let path: String

    init(_ node: Node, path: String) throws {
        self.path = path
        guard case .mapping(let m) = node else { throw PRLError.notAMapping(path: path) }
        var seen = Set<String>()
        for (k, v) in m {
            guard let key = k.string else { throw PRLError.notAScalar(path: path) }
            guard seen.insert(key).inserted else { throw PRLError.duplicateField(path: "\(path).\(key)") }
            entries.append((key, v))
        }
    }

    func has(_ key: String) -> Bool { entries.contains { $0.key == key } }

    mutating func node(_ key: String) throws -> Node {
        guard let e = entries.first(where: { $0.key == key }) else {
            throw PRLError.missingField(path: "\(path).\(key)")
        }
        used.insert(key)
        return e.value
    }

    mutating func map(_ key: String) throws -> StrictMap { try StrictMap(try node(key), path: "\(path).\(key)") }

    mutating func string(_ key: String) throws -> String {
        guard case .scalar(let s) = try node(key) else { throw PRLError.notAScalar(path: "\(path).\(key)") }
        return s.string
    }

    mutating func optString(_ key: String) throws -> String? { has(key) ? try string(key) : nil }

    mutating func int(_ key: String) throws -> Int {
        let s = try string(key)
        guard let v = Int(s) else { throw PRLError.invalidValue(path: "\(path).\(key)", reason: "Ganzzahl erwartet") }
        return v
    }

    mutating func optInt(_ key: String) throws -> Int? { has(key) ? try int(key) : nil }

    mutating func bool(_ key: String) throws -> Bool {
        switch try string(key) {
        case "true": return true
        case "false": return false
        default: throw PRLError.invalidValue(path: "\(path).\(key)", reason: "true oder false erwartet")
        }
    }

    mutating func optBool(_ key: String) throws -> Bool? { has(key) ? try bool(key) : nil }

    mutating func optStringList(_ key: String) throws -> [String]? {
        guard has(key) else { return nil }
        guard case .sequence(let seq) = try node(key) else { throw PRLError.notASequence(path: "\(path).\(key)") }
        return try seq.map {
            guard case .scalar(let s) = $0 else { throw PRLError.notAScalar(path: "\(path).\(key)") }
            return s.string
        }
    }

    mutating func finish() throws {
        if let extra = entries.first(where: { !used.contains($0.key) }) {
            throw PRLError.unknownField(path: "\(path).\(extra.key)")
        }
    }
}
