import Foundation

/// Eine während eines Lern- oder Aufzeichnungslaufs ausgeführte Aktion, bezogen auf seitenlokale Element-IDs.
/// Werte stehen nie im Klartext darin, nur als Quelle (Keychain-Schlüssel, Nutzerabfrage …).
public struct LearnedAction: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case fill, check, uncheck, select, tap, submit
    }

    public var kind: Kind
    public var elementId: String?
    public var value: ValueSource?
    public var optionValue: String?

    public init(kind: Kind, elementId: String?, value: ValueSource? = nil, optionValue: String? = nil) {
        self.kind = kind
        self.elementId = elementId
        self.value = value
        self.optionValue = optionValue
    }
}

/// Eine Portalseite mit den Aktionen, die darauf erfolgreich ausgeführt wurden.
public struct LearnedPage: Sendable, Equatable {
    public var page: PortalPage
    public var actions: [LearnedAction]

    public init(page: PortalPage, actions: [LearnedAction]) {
        self.page = page
        self.actions = actions
    }
}

/// Kompiliert einen erfolgreichen Lauf zu einem wiederholbaren Recipe (01 §12.4):
/// semantische Targets statt Selektoren, keine Hidden-/CSRF-Werte, keine Klartext-Secrets.
public enum TraceCompiler {
    public enum Failure: Error, Equatable, Sendable {
        case emptyTrace
        case unknownElement(page: Int, elementId: String)
        case missingValue(page: Int, action: Int)
        case literalForSensitiveField(page: Int, action: Int)
    }

    public static func compile(_ pages: [LearnedPage], profileId: UUID, name: String, ssid: String) throws -> Recipe {
        guard !pages.isEmpty else { throw Failure.emptyTrace }
        var stages: [Stage] = []
        var usedIds = Set<String>()

        for (pageIndex, learned) in pages.enumerated() where !learned.actions.isEmpty {
            var actions: [PortalAction] = []
            var filledConcepts: [Concept] = []

            for (actionIndex, step) in learned.actions.enumerated() {
                let control: PortalControl?
                if let elementId = step.elementId {
                    guard let found = learned.page.control(id: elementId) else {
                        throw Failure.unknownElement(page: pageIndex, elementId: elementId)
                    }
                    control = found
                } else {
                    control = nil
                }
                let target = control.map { self.target(for: $0, on: learned.page) }

                switch step.kind {
                case .fill:
                    guard let target, let value = step.value else {
                        throw Failure.missingValue(page: pageIndex, action: actionIndex)
                    }
                    if case .literal = value, target.concept != nil {
                        throw Failure.literalForSensitiveField(page: pageIndex, action: actionIndex)
                    }
                    if let concept = target.concept { filledConcepts.append(concept) }
                    actions.append(.fill(FillAction(target: target, value: value)))
                case .check:
                    guard let target else { throw Failure.missingValue(page: pageIndex, action: actionIndex) }
                    actions.append(.check(TargetAction(target: target)))
                case .uncheck:
                    guard let target else { throw Failure.missingValue(page: pageIndex, action: actionIndex) }
                    actions.append(.uncheck(TargetAction(target: target)))
                case .select:
                    guard let target, let control, let optionValue = step.optionValue else {
                        throw Failure.missingValue(page: pageIndex, action: actionIndex)
                    }
                    let label = control.options.first { $0.value == optionValue }?.label
                    actions.append(.select(SelectAction(
                        target: target, option: OptionSpec(labelAny: label.map { [$0] }, value: optionValue))))
                case .tap:
                    guard let target else { throw Failure.missingValue(page: pageIndex, action: actionIndex) }
                    actions.append(.tap(TargetAction(target: target)))
                case .submit:
                    actions.append(.submit(SubmitAction(target: target)))
                }
            }

            let id = uniqueStageId(base: stageName(filledConcepts: filledConcepts, actions: actions), used: &usedIds)
            let match = filledConcepts.isEmpty ? nil : StageMatch(fields: uniqued(filledConcepts))
            stages.append(Stage(id: id, match: match, actions: actions))
        }
        guard !stages.isEmpty else { throw Failure.emptyTrace }

        return Recipe(profileId: profileId, name: name, network: NetworkSpec(ssid: ssid),
                      stages: stages, success: SuccessCriteria(internetAccess: true))
    }

    /// Semantischer Deskriptor eines Elements (01 §10). Selector nur als Fallback.
    static func target(for control: PortalControl, on page: PortalPage) -> Target {
        var target = Target(role: control.role, concept: control.concept)
        let captions = uniqued(control.captions).prefix(3)
        if !captions.isEmpty { target.labelAny = Array(captions) }
        if let name = control.name { target.nameAny = [name] }
        if control.captions.isEmpty, let nearby = control.nearbyText { target.nearbyText = [nearby] }
        if let htmlId = control.htmlId, isSimpleIdentifier(htmlId) {
            target.lastKnownSelector = "#\(htmlId)"
        } else if let name = control.name, isSimpleIdentifier(name) {
            target.lastKnownSelector = "\(control.tag)[name=\(name)]"
        }
        // Gleich beschriftete Geschwister: Position festhalten, damit der Matcher eindeutig bleibt.
        let twins = page.interactiveControls.filter {
            $0.role == control.role && $0.captions == control.captions && $0.name == control.name
        }
        if twins.count > 1, let position = twins.firstIndex(where: { $0.elementId == control.elementId }) {
            target.ordinal = position
        }
        return target
    }

    static func stageName(filledConcepts: [Concept], actions: [PortalAction]) -> String {
        let concepts = Set(filledConcepts)
        if concepts.contains(.roomNumber) || concepts.contains(.lastName) { return "guest" }
        if concepts.contains(.password) || concepts.contains(.username) { return "login" }
        if concepts.contains(.voucherCode) || concepts.contains(.accessCode) { return "voucher" }
        if concepts.contains(.email) { return "email" }
        if actions.contains(where: { $0.opcode == .check }) { return "consent" }
        return "continue"
    }

    static func uniqueStageId(base: String, used: inout Set<String>) -> String {
        var candidate = base
        var n = 2
        while used.contains(candidate) {
            candidate = "\(base)\(n)"
            n += 1
        }
        used.insert(candidate)
        return candidate
    }

    static func isSimpleIdentifier(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" } && s.count <= 60
    }

    static func uniqued<T: Hashable>(_ items: [T]) -> [T] {
        var seen = Set<T>()
        return items.filter { seen.insert($0).inserted }
    }
}
