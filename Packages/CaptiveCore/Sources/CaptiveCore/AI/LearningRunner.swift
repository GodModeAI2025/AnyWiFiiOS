import Foundation

extension Concept: CodingKeyRepresentable {}

/// Prüft einen AI-Plan vor der Ausführung (01 §24). Das Modell plant, die Runtime entscheidet.
public enum PlanValidator {
    public enum Rejection: Error, Equatable, Sendable {
        case tooManyActions(Int)
        case emptyPlan
        case unknownElement(String)
        case wrongElementKind(String)
        case fillWithoutConcept(String)
        case conceptNotInIntent(Concept)
        case conceptMismatch(element: String, expected: Concept, planned: Concept)
        case commercialElement(String)
        case optionalConsent(String)
        case duplicateElement(String)
    }

    public static let maxActions = 4

    public static func validate(_ plan: PortalPlan, page: PortalPage, intent: PortalIntent) -> Rejection? {
        if plan.missingValue != nil { return nil } // Plan fordert nur einen Wert an.
        guard !plan.actions.isEmpty else { return .emptyPlan }
        guard plan.actions.count <= maxActions else { return .tooManyActions(plan.actions.count) }

        var seen = Set<String>()
        for action in plan.actions {
            guard let control = page.control(id: action.elementId), !control.isHidden else {
                return .unknownElement(action.elementId)
            }
            if action.kind != .submit, !seen.insert(action.elementId).inserted {
                return .duplicateElement(action.elementId)
            }
            let caption = control.captions.first ?? control.name ?? control.elementId
            switch action.kind {
            case .fill:
                guard control.role == .textField || control.role == .passwordField else {
                    return .wrongElementKind(action.elementId)
                }
                guard let concept = action.concept else { return .fillWithoutConcept(action.elementId) }
                guard intent.bindings[concept] != nil else { return .conceptNotInIntent(concept) }
                if let detected = control.concept, detected != concept {
                    return .conceptMismatch(element: action.elementId, expected: detected, planned: concept)
                }
            case .check:
                guard control.role == .checkbox || control.role == .radio else { return .wrongElementKind(action.elementId) }
                if ConsentClassifier.isCommercial(control.descriptors) { return .commercialElement(caption) }
                if !intent.policy.allowOptionalMarketingConsent, ConsentClassifier.isMarketing(control.descriptors) {
                    return .optionalConsent(caption)
                }
            case .uncheck:
                guard control.role == .checkbox else { return .wrongElementKind(action.elementId) }
            case .select:
                guard control.role == .select, let value = action.optionValue,
                      let option = control.options.first(where: { $0.value == value }) else {
                    return .wrongElementKind(action.elementId)
                }
                if ConsentClassifier.isCommercial([option.label, option.value]) { return .commercialElement(option.label) }
            case .tap, .submit:
                guard control.role == .button || control.role == .link else { return .wrongElementKind(action.elementId) }
                if ConsentClassifier.isCommercial(control.descriptors) { return .commercialElement(caption) }
            }
        }
        return nil
    }
}

/// Ergebnis eines Lernlaufs: bei Erfolg ein validiertes Recipe (01 §12).
public struct LearningResult: Sendable {
    public var run: RunResult
    public var recipe: Recipe?
    public var learnedPages: [LearnedPage]
    public var rejection: PlanValidator.Rejection?
    public var modelCalls: Int
}

/// Lernlauf: beobachten → planen → validieren → ausführen, Seite für Seite (01 §12, Gate S3).
/// Nach Erfolg wird der Trace zu einem Recipe kompiliert, das danach ohne AI läuft (Gate S8).
public struct LearningRunner: Sendable {
    public var runner: RecipeRunner
    public var planner: any PortalPlanner
    public var maxModelCalls = 5

    public init(runner: RecipeRunner, planner: any PortalPlanner) {
        self.runner = runner
        self.planner = planner
    }

    public func learn(intent: PortalIntent, profileId: UUID, name: String, ssid: String) async -> LearningResult {
        let ctx = RunContext(session: PortalHTTPSession(transport: runner.transport))
        ctx.trusted.formUnion(runner.portalHostHints.map { $0.lowercased() })
        var learned: [LearnedPage] = []
        var calls = 0
        var completed: [PlannedAction] = []

        func finish(_ reason: RunReason, rejection: PlanValidator.Rejection? = nil, recipe: Recipe? = nil) -> LearningResult {
            LearningResult(run: ctx.result(reason), recipe: recipe, learnedPages: learned, rejection: rejection,
                           modelCalls: calls)
        }

        do {
            let probe = try await ctx.session.get(runner.probeURL)
            ctx.trace.record(.probe, "Probe → \(RecipeRunner.statusChain(probe))")
            if RecipeRunner.isOnline(probe) { return finish(.alreadyOnline) }
            ctx.trusted.formUnion(probe.hosts)
            var page = try await runner.load(probe.final, ctx)

            while calls < maxModelCalls {
                ctx.page = page
                if page.requiresJavaScript { return finish(.javaScriptRequired) }

                let plan: PortalPlan
                do {
                    plan = try await planner.nextPlan(PlanningInput(intent: intent, page: page,
                                                                    completedActions: completed, round: calls))
                } catch {
                    return finish(.modelUnavailable)
                }
                calls += 1
                ctx.trace.record(.stage, "Plan \(calls): \(plan.actions.map { "\($0.kind.rawValue) \($0.elementId)" }.joined(separator: ", "))")

                if let missing = plan.missingValue { return finish(.missingValue(missing)) }
                if let rejection = PlanValidator.validate(plan, page: page, intent: intent) {
                    ctx.trace.record(.guardrail, "Plan abgelehnt: \(rejection)")
                    return finish(.planRejected("\(rejection)"), rejection: rejection)
                }

                // Plan → Stage mit semantischen Targets, damit dieselbe Ausführung wie im Replay gilt.
                var actions: [LearnedAction] = []
                for planned in plan.actions {
                    let value = planned.concept.flatMap { intent.valueSource(for: $0) }
                    let kind = LearnedAction.Kind(rawValue: planned.kind.rawValue) ?? .tap
                    actions.append(LearnedAction(kind: kind, elementId: planned.elementId, value: value,
                                                 optionValue: planned.optionValue))
                }
                let pageTrace = LearnedPage(page: page, actions: actions)
                let stage: Stage
                do {
                    stage = try TraceCompiler.compile([pageTrace], profileId: profileId, name: name, ssid: ssid).stages[0]
                } catch {
                    return finish(.conditionNotMet(stage: "learn", action: calls))
                }

                let stageResult = try await runner.runStage(stage, page: page, ctx)
                learned.append(pageTrace)
                completed.append(contentsOf: plan.actions)

                switch stageResult {
                case .finished(let reason):
                    if reason.outcome != .success { return finish(reason) }
                case .navigated(let exchange, _):
                    ctx.trusted.formUnion(exchange.hosts.dropFirst())
                    if exchange.final.status >= 400 { return finish(.httpStatus(exchange.final.status)) }
                    page = try await runner.load(exchange.final, ctx)
                case .adapterLoggedIn, .noNavigation:
                    break
                }

                if try await runner.isOnlineNow(ctx) {
                    let recipe = try TraceCompiler.compile(learned, profileId: profileId, name: name, ssid: ssid)
                    return finish(.loggedIn, recipe: recipe)
                }
                if case .noNavigation = stageResult { return finish(.stillCaptive) }
            }
            return finish(.roundLimitReached)
        } catch {
            return finish(.transport(String(describing: type(of: error))))
        }
    }
}

/// Adaptive Repair (01 §14, Gate S9): Nur das nicht gefundene Target wird neu bestimmt.
/// Der Patch wird erst nach erfolgreichem Login übernommen (Revision +1 macht der Aufrufer).
public struct RecipeRepairer: Sendable {
    public var runner: RecipeRunner
    public var planner: any PortalPlanner

    public init(runner: RecipeRunner, planner: any PortalPlanner) {
        self.runner = runner
        self.planner = planner
    }

    public struct Outcome: Sendable {
        public var run: RunResult
        /// Gesetzt, wenn die Reparatur zum Erfolg geführt hat.
        public var patchedRecipe: Recipe?
    }

    public func runWithRepair(_ recipe: Recipe, intent: PortalIntent) async -> Outcome {
        let first = await runner.run(recipe)
        guard case .targetNotFound(let stageId, let actionIndex) = first.reason,
              let page = first.lastPage,
              let stageIndex = recipe.stages.firstIndex(where: { $0.id == stageId }),
              actionIndex < recipe.stages[stageIndex].actions.count,
              let oldTarget = recipe.stages[stageIndex].actions[actionIndex].target else {
            return Outcome(run: first, patchedRecipe: nil)
        }
        let action = recipe.stages[stageIndex].actions[actionIndex]

        guard let suggestion = try? await planner.repairTarget(old: oldTarget, opcode: action.opcode, intent: intent, page: page),
              let control = page.control(id: suggestion.elementId), !control.isHidden else {
            return Outcome(run: first, patchedRecipe: nil)
        }
        // Gleiche Sicherheitsregeln wie für einen Plan.
        let kind = PlannedAction.Kind(rawValue: action.opcode.rawValue) ?? .tap
        let probe = PortalPlan(reasoningSummary: suggestion.reasoningSummary,
                               actions: [PlannedAction(kind: kind, elementId: control.elementId, concept: oldTarget.concept)],
                               expectedTransition: .newPage)
        if PlanValidator.validate(probe, page: page, intent: intent) != nil { return Outcome(run: first, patchedRecipe: nil) }

        var patched = recipe
        let newTarget = Self.merge(old: oldTarget, with: TraceCompiler.target(for: control, on: page))
        patched.stages[stageIndex].actions[actionIndex] = Self.replacingTarget(action, with: newTarget)

        let second = await runner.run(patched)
        return Outcome(run: second, patchedRecipe: second.outcome == .success ? patched : nil)
    }

    /// Alte Labels behalten, neue ergänzen (01 §14: `labelAny: [Connect, Join Wi-Fi]`).
    static func merge(old: Target, with new: Target) -> Target {
        var merged = new
        merged.labelAny = TraceCompiler.uniqued((old.labelAny ?? []) + (new.labelAny ?? []))
        merged.nameAny = TraceCompiler.uniqued((old.nameAny ?? []) + (new.nameAny ?? [])).nilIfEmpty
        merged.concept = old.concept ?? new.concept
        return merged
    }

    static func replacingTarget(_ action: PortalAction, with target: Target) -> PortalAction {
        switch action {
        case .fill(var a): a.target = target; return .fill(a)
        case .check(var a): a.target = target; return .check(a)
        case .uncheck(var a): a.target = target; return .uncheck(a)
        case .tap(var a): a.target = target; return .tap(a)
        case .select(var a): a.target = target; return .select(a)
        case .submit(var a): a.target = target; return .submit(a)
        case .waitFor(var w): w.element = target; return .waitFor(w)
        case .requestValue, .verify, .stop, .adapter: return action
        }
    }
}

extension Array {
    var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}
