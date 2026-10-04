import Foundation

public struct EngineConfig: Sendable {
    public var maxRounds: Int
    public var maxPlanActions: Int
    public var maxRedirects: Int
    public var probeURL: URL

    public init(maxRounds: Int = 8, maxPlanActions: Int = 4, maxRedirects: Int = 10,
                probeURL: URL = CaptiveProbe.url) {
        self.maxRounds = maxRounds
        self.maxPlanActions = maxPlanActions
        self.maxRedirects = maxRedirects
        self.probeURL = probeURL
    }
}

/// Ausführungskern für Replay und Lernlauf. Kennt weder Modus (Provider/Manuell) noch Modell:
/// Transport und Werte kommen über Protokolle (SPEC §3.5).
public struct RunEngine: Sendable {
    public var transport: any PortalTransport
    public var values: any ValueProvider
    public var intentPolicy: IntentPolicy
    public var bindings: [CredentialBinding]
    public var hostHints: [String]
    public var config: EngineConfig
    /// Wer die Aktionen geplant hat. Bestimmt das Outcome bei Sicherheitsverstößen.
    public var plannedByModel: Bool

    public init(transport: any PortalTransport, values: any ValueProvider,
                intentPolicy: IntentPolicy = .init(), bindings: [CredentialBinding] = [],
                hostHints: [String] = [], config: EngineConfig = .init(), plannedByModel: Bool = false) {
        self.transport = transport
        self.values = values
        self.intentPolicy = intentPolicy
        self.bindings = bindings
        self.hostHints = hostHints
        self.config = config
        self.plannedByModel = plannedByModel
    }

    // MARK: Replay

    /// Führt ein gespeichertes Recipe deterministisch aus, ohne Modell (01 §13).
    public func replay(_ recipe: Recipe) async -> RunResult {
        var run = Run(engine: self)
        let issues = SecurityValidator.errors(recipe, bindings: bindings)
        if let first = issues.first {
            return run.finish(.manualInteractionRequired, reason: "Recipe abgelehnt: \(first.description)")
        }
        guard await run.start() else { return run.result }
        for _ in 0..<config.maxRounds {
            if let stop = run.classifyPage() { return run.finish(stop.0, reason: stop.1) }
            guard let stage = StageMatcher.firstMatch(in: recipe, page: run.page, excluding: run.doneStages) else {
                if await run.isOnline() { return run.finish(.success) }
                return run.finish(.recipeMismatch, reason: "Keine Stage des Recipes passt zur Seite \(run.page.host)")
            }
            run.doneStages.insert(stage.id)
            if let end = await run.execute(stage.actions, stageId: stage.id) { return end }
            if await run.afterStage() { return run.finish(.success) }
        }
        return run.finish(.recipeMismatch, reason: "Rundenlimit erreicht")
    }

    // MARK: Lernlauf

    /// Lernlauf: Planer schlägt pro Seite eine kleine Aktionsgruppe vor (01 §12). Bei Erfolg
    /// liegt der Trace im Ergebnis und kann mit `TraceCompiler` zum Recipe werden.
    public func learn(intent: PortalIntent, planner: any PortalPlanner) async -> RunResult {
        var run = Run(engine: self)
        guard await run.start() else { return run.result }
        var completed: [Action] = []
        for _ in 0..<config.maxRounds {
            if let stop = run.classifyPage() { return run.finish(stop.0, reason: stop.1) }
            let plan: PortalPlan
            do {
                plan = try await planner.plan(PlanningInput(intent: intent, page: run.page.redactedForModel(),
                                                            completed: completed, bindings: bindings))
                run.result.modelCalls += 1
            } catch {
                return run.finish(.aiUnavailable, reason: "Planer nicht verfügbar")
            }
            if let issue = SecurityValidator.validate(plan: plan.actions, bindings: bindings,
                                                      maxActions: config.maxPlanActions).first(where: { $0.severity == .error }) {
                return run.finish(.aiRejectedPlan, reason: issue.description)
            }
            let before = run.pageIndex
            if let end = await run.execute(plan.actions, stageId: nil) { return end }
            completed = run.pageIndex == before ? completed + plan.actions : []
            if await run.afterStage() { return run.finish(.success) }
        }
        return run.finish(.temporaryFailure, reason: "Rundenlimit erreicht")
    }

    // MARK: Laufzustand

    struct Run {
        let engine: RunEngine
        let client: PortalHTTPClient
        var page: NormalizedPage
        var pageIndex = 0
        var doneStages: Set<String> = []
        var formValues: [String: String] = [:]
        var checked: [String: Bool] = [:]
        var lastTouchedForm: String?
        var hostPolicy: HostPolicy
        var result = RunResult(outcome: .temporaryFailure)
        var stepIndex = 0
        var lastProbe: FetchResult?
        var navigatedSinceProbe = false
        let clock = ContinuousClock()
        let startedAt: ContinuousClock.Instant

        init(engine: RunEngine) {
            self.engine = engine
            self.client = PortalHTTPClient(transport: engine.transport, maxRedirects: engine.config.maxRedirects)
            self.hostPolicy = HostPolicy(hints: engine.hostHints)
            self.page = NormalizedPage(url: "", host: "", title: "", status: 0, forms: [], links: [], text: "",
                                       hasScripts: false, hasCaptcha: false, redirectChain: [])
            self.startedAt = clock.now
        }

        mutating func finish(_ outcome: Outcome, reason: String? = nil, concept: String? = nil,
                             stage: String? = nil, action: Int? = nil) -> RunResult {
            result.outcome = outcome
            result.reason = reason
            result.requiredConcept = concept
            result.failedStageId = stage
            result.failedActionIndex = action
            result.durationMs = Self.ms(clock.now - startedAt)
            return result
        }

        static func ms(_ d: Duration) -> Int {
            Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
        }

        static func safeURL(_ s: String) -> String {
            guard let u = URL(string: s) else { return "" }
            return PortalHTTPClient.stripQuery(u)
        }

        /// Probe laden. `false` = Lauf beendet (online, Netzwerkfehler), Ergebnis in `result`.
        mutating func start() async -> Bool {
            do {
                let fetched = try await client.fetch(PortalRequest(url: engine.config.probeURL))
                record(fetched)
                if CaptiveProbe.isSuccess(fetched.response) {
                    _ = finish(.success, reason: "Bereits online")
                    return false
                }
                adopt(fetched)
                return true
            } catch {
                _ = finish(Self.outcome(for: error), reason: "Probe fehlgeschlagen")
                return false
            }
        }

        static func outcome(for error: Error) -> Outcome {
            if let e = error as? PortalError, e == .timeout { return .timeout }
            return .networkError
        }

        mutating func record(_ f: FetchResult) {
            result.network += f.entries
            for e in f.entries { hostPolicy.allow(e.host) }
        }

        mutating func adopt(_ f: FetchResult) {
            let chain = f.entries.map(\.url)
            page = PortalNormalizer.normalize(html: f.response.body, url: f.response.url,
                                              status: f.response.status, redirectChain: chain)
            result.pages.append(CapturedPage(normalized: page, html: f.response.body))
            pageIndex += 1
            formValues = [:]
            checked = [:]
            lastTouchedForm = nil
        }

        /// JS-only/Captcha-Seiten sofort klassifizieren statt endlos zu planen (S11).
        func classifyPage() -> (Outcome, String)? {
            if page.hasCaptcha { return (.manualInteractionRequired, "Captcha erkannt") }
            if page.looksJavaScriptOnly { return (.manualInteractionRequired, "Portal rendert nur per JavaScript") }
            if page.visibleControls.isEmpty && page.links.isEmpty {
                return (.unsupportedPortal, "Keine bedienbaren Elemente gefunden")
            }
            return nil
        }

        mutating func isOnline() async -> Bool {
            guard let f = try? await client.fetch(PortalRequest(url: engine.config.probeURL)) else { return false }
            record(f)
            if CaptiveProbe.isSuccess(f.response) { return true }
            lastProbe = f
            return false
        }

        /// Nach einer Aktionsgruppe: online? Sonst mit der aktuellen Portalseite weitermachen.
        mutating func afterStage() async -> Bool {
            lastProbe = nil
            if await isOnline() { return true }
            if !navigatedSinceProbe, let f = lastProbe { adopt(f) }
            navigatedSinceProbe = false
            return false
        }

        // MARK: Aktionen

        enum Flow { case ok, navigated }

        struct Failure: Error { var outcome: Outcome; var reason: String; var concept: String? }

        /// Führt Aktionen aus. Rückgabe ≠ nil beendet den Lauf.
        mutating func execute(_ actions: [Action], stageId: String?) async -> RunResult? {
            let startPage = pageIndex
            for (i, action) in actions.enumerated() {
                // Nach einer Navigation gehören weitere Interaktionen zur nächsten Seite/Stage.
                if pageIndex != startPage, !isPassive(action) { return nil }
                let t0 = clock.now
                var step = TraceStep(index: stepIndex, pageIndex: pageIndex, stageId: stageId, action: action,
                                     control: nil, matchScore: nil, valueRef: nil, urlBefore: Self.safeURL(page.url),
                                     urlAfter: nil, status: nil, durationMs: 0, result: "ok")
                stepIndex += 1
                switch await perform(action, step: &step) {
                case .success(let flow):
                    step.durationMs = Self.ms(clock.now - t0)
                    if flow == .navigated {
                        step.urlAfter = Self.safeURL(page.url)
                        step.status = page.status
                    }
                    result.trace.append(step)
                case .failure(let f):
                    step.durationMs = Self.ms(clock.now - t0)
                    step.result = f.reason
                    result.trace.append(step)
                    return finish(f.outcome, reason: f.reason, concept: f.concept, stage: stageId, action: i)
                }
            }
            return nil
        }

        func isPassive(_ a: Action) -> Bool {
            switch a {
            case .verify, .waitFor, .stop: true
            default: false
            }
        }

        var violationOutcome: Outcome { engine.plannedByModel ? .aiRejectedPlan : .manualInteractionRequired }

        mutating func perform(_ action: Action, step: inout TraceStep) async -> Swift.Result<Flow, Failure> {
            switch action {
            case .fill(let target, let source):
                guard let m = ElementMatcher.find(target, in: page),
                      [.textField, .password, .textArea, .select].contains(m.control.role) else {
                    return .failure(Failure(outcome: .recipeMismatch, reason: "Feld nicht gefunden: \(describe(target))"))
                }
                step.control = m.control
                step.matchScore = m.score
                if let sc = sourceConcept(source), let cc = m.control.concept, sc != cc {
                    return .failure(Failure(outcome: violationOutcome, reason: "Wert für '\(sc)' darf nicht in Feld '\(cc)'"))
                }
                guard let value = await engine.values.value(for: source), !value.isEmpty else {
                    return .failure(Failure(outcome: .missingUserValue, reason: "Wert fehlt",
                                            concept: target.concept ?? sourceConcept(source) ?? m.control.concept))
                }
                let concept = target.concept ?? sourceConcept(source) ?? m.control.concept ?? "value"
                let placeholder = ConceptCatalog.placeholder(for: concept)
                if ConceptCatalog.sensitivity(of: concept) != .public {
                    result.secretsUsed.append(SensitiveValue(value: value, placeholder: placeholder))
                }
                step.valueRef = placeholder
                formValues[m.control.elementId] = value
                lastTouchedForm = page.form(containing: m.control.elementId)?.id
                return .success(.ok)

            case .check(let target), .uncheck(let target):
                let isCheck: Bool = if case .check = action { true } else { false }
                guard let m = ElementMatcher.find(target, in: page), [.checkbox, .radio].contains(m.control.role) else {
                    return .failure(Failure(outcome: .recipeMismatch, reason: "Checkbox nicht gefunden: \(describe(target))"))
                }
                step.control = m.control
                step.matchScore = m.score
                if m.usedSelectorFallback {
                    return .failure(Failure(outcome: .recipeMismatch, reason: "Nur Selector-Treffer für \(describe(target)), Reparatur nötig"))
                }
                if case .block(let reason) = ConsentPolicy.evaluate(m.control, action: isCheck ? "check" : "uncheck", policy: engine.intentPolicy) {
                    return .failure(Failure(outcome: violationOutcome, reason: reason))
                }
                checked[m.control.elementId] = isCheck
                lastTouchedForm = page.form(containing: m.control.elementId)?.id
                return .success(.ok)

            case .select(let target, let option):
                guard let m = ElementMatcher.find(target, in: page) else {
                    return .failure(Failure(outcome: .recipeMismatch, reason: "Auswahl nicht gefunden: \(describe(target))"))
                }
                step.control = m.control
                step.matchScore = m.score
                if case .block(let reason) = ConsentPolicy.evaluate(m.control, action: "select", policy: engine.intentPolicy) {
                    return .failure(Failure(outcome: violationOutcome, reason: reason))
                }
                let fold = ConceptInference.fold(option)
                if m.control.role == .select {
                    guard let o = m.control.options.first(where: { ConceptInference.fold($0.value) == fold || ConceptInference.fold($0.text) == fold }) else {
                        return .failure(Failure(outcome: .recipeMismatch, reason: "Option nicht vorhanden"))
                    }
                    formValues[m.control.elementId] = o.value
                } else {
                    checked[m.control.elementId] = true
                }
                lastTouchedForm = page.form(containing: m.control.elementId)?.id
                return .success(.ok)

            case .tap(let target):
                return await tap(target, step: &step)

            case .submit:
                return await submit(button: nil, step: &step)

            case .requestValue(let concept, _):
                if await engine.values.value(for: .ask(concept)) == nil {
                    return .failure(Failure(outcome: .missingUserValue, reason: "Wert fehlt", concept: concept))
                }
                return .success(.ok)

            case .waitFor(let cond):
                let ok: Bool = switch cond {
                case .urlContains(let s): page.url.contains(s)
                case .textAny(let l): l.contains { ConceptInference.fold(page.text).contains(ConceptInference.fold($0)) }
                case .elementConcept(let c): page.visibleControls.contains { $0.concept == c }
                }
                return ok ? .success(.ok) : .failure(Failure(outcome: .recipeMismatch, reason: "Erwarteter Zustand nicht erreicht"))

            case .verify(let cond):
                switch cond {
                case .internetAccess(let expected):
                    let online = await isOnline()
                    return online == expected ? .success(.ok)
                        : .failure(Failure(outcome: .recipeMismatch, reason: "Internetzugang nicht wie erwartet"))
                case .pageContainsAny(let l):
                    let hay = ConceptInference.fold(page.text)
                    return l.contains { hay.contains(ConceptInference.fold($0)) } ? .success(.ok)
                        : .failure(Failure(outcome: .recipeMismatch, reason: "Erwarteter Text fehlt"))
                }

            case .stop(let state):
                let outcome: Outcome = switch state {
                case .success: .success
                case .temporaryFailure: .temporaryFailure
                case .unsupported: .unsupportedPortal
                case .requiresManualInteraction: .manualInteractionRequired
                }
                if outcome == .success { return .success(.ok) }
                return .failure(Failure(outcome: outcome, reason: "Stop: \(state.rawValue)"))
            }
        }

        func sourceConcept(_ s: ValueSource) -> String? {
            switch s {
            case .ask(let c), .runtime(let c): c
            case .keychain(let k): engine.bindings.first { $0.keychainKey == k }?.concept
            default: nil
            }
        }

        func describe(_ t: Target) -> String {
            t.concept ?? t.labelAny.first ?? t.nameAny.first ?? t.role ?? "?"
        }

        mutating func tap(_ target: Target, step: inout TraceStep) async -> Swift.Result<Flow, Failure> {
            if target.role != "link", let m = ElementMatcher.find(target, in: page), m.control.role == .button {
                step.control = m.control
                step.matchScore = m.score
                if m.usedSelectorFallback {
                    return .failure(Failure(outcome: .recipeMismatch, reason: "Nur Selector-Treffer für \(describe(target)), Reparatur nötig"))
                }
                if case .block(let reason) = ConsentPolicy.evaluate(m.control, action: "tap", policy: engine.intentPolicy) {
                    return .failure(Failure(outcome: violationOutcome, reason: reason))
                }
                guard m.control.submit, page.form(containing: m.control.elementId) != nil else {
                    return .failure(Failure(outcome: .manualInteractionRequired, reason: "Button ohne Formular benötigt JavaScript"))
                }
                return await submit(button: m.control, step: &step)
            }
            if target.role == nil || target.role == "link" {
                let needles = target.labelAny
                if let link = page.links.first(where: { l in needles.contains { ConceptInference.fold(l.text).contains(ConceptInference.fold($0)) } }) {
                    if ConsentPolicy.isPaid(link.text) {
                        return .failure(Failure(outcome: violationOutcome, reason: "Kostenpflichtige Aktion ist in V1 nicht automatisierbar"))
                    }
                    guard let url = URL(string: link.href, relativeTo: URL(string: page.url))?.absoluteURL else {
                        return .failure(Failure(outcome: .recipeMismatch, reason: "Ungültiger Link"))
                    }
                    return await navigate(PortalRequest(url: url))
                }
            }
            return .failure(Failure(outcome: .recipeMismatch, reason: "Button nicht gefunden: \(describe(target))"))
        }

        mutating func submit(button: NormalizedControl?, step: inout TraceStep) async -> Swift.Result<Flow, Failure> {
            let form: NormalizedForm? = {
                if let b = button { return page.form(containing: b.elementId) }
                if let id = lastTouchedForm { return page.forms.first { $0.id == id } }
                return page.forms.first { $0.controls.contains { $0.role != .hidden } } ?? page.forms.first
            }()
            guard let form else { return .failure(Failure(outcome: .recipeMismatch, reason: "Kein Formular zum Absenden")) }
            let btn = button ?? form.controls.first { $0.role == .button && $0.submit }
            if let b = btn, step.control == nil { step.control = b }
            if let b = btn, case .block(let reason) = ConsentPolicy.evaluate(b, action: "tap", policy: engine.intentPolicy) {
                return .failure(Failure(outcome: violationOutcome, reason: reason))
            }

            // Formularwerte wie ein Browser zusammenstellen.
            var pairs: [(String, String)] = []
            var carriesPersonalData = false
            for c in form.controls {
                guard let name = c.name else { continue }
                switch c.role {
                case .hidden:
                    pairs.append((name, c.value ?? ""))
                case .textField, .password, .textArea:
                    if let v = formValues[c.elementId] {
                        pairs.append((name, v))
                        if c.concept == nil || ConceptCatalog.sensitivity(of: c.concept!) != .public { carriesPersonalData = true }
                    } else {
                        pairs.append((name, c.value ?? ""))
                    }
                case .checkbox, .radio:
                    if checked[c.elementId] ?? c.checked { pairs.append((name, c.value ?? "on")) }
                case .select:
                    let v = formValues[c.elementId] ?? c.options.first(where: \.selected)?.value ?? c.options.first?.value ?? ""
                    pairs.append((name, v))
                case .button:
                    if c.elementId == btn?.elementId { pairs.append((name, c.value ?? c.text ?? "")) }
                }
            }
            guard let pageURL = URL(string: page.url) else {
                return .failure(Failure(outcome: .networkError, reason: "Ungültige Seiten-URL"))
            }
            let target = form.action.isEmpty ? pageURL : (URL(string: form.action, relativeTo: pageURL)?.absoluteURL ?? pageURL)
            guard let scheme = target.scheme, scheme == "http" || scheme == "https" else {
                return .failure(Failure(outcome: violationOutcome, reason: "Unzulässiges Formularziel"))
            }
            if carriesPersonalData, !hostPolicy.permitsCredentials(to: target.host) {
                return .failure(Failure(outcome: violationOutcome,
                                        reason: "Zugangsdaten dürfen nicht an \(target.host ?? "?") gesendet werden"))
            }
            let body = Self.encode(pairs)
            if form.method == "POST" {
                return await navigate(PortalRequest(method: .post, url: target,
                                                    headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                                    body: Data(body.utf8)))
            }
            var comps = URLComponents(url: target, resolvingAgainstBaseURL: false)
            comps?.percentEncodedQuery = body
            return await navigate(PortalRequest(url: comps?.url ?? target))
        }

        mutating func navigate(_ request: PortalRequest) async -> Swift.Result<Flow, Failure> {
            do {
                let f = try await client.fetch(request)
                record(f)
                adopt(f)
                navigatedSinceProbe = true
                return .success(.navigated)
            } catch {
                return .failure(Failure(outcome: Self.outcome(for: error), reason: "Anfrage fehlgeschlagen"))
            }
        }

        static func encode(_ pairs: [(String, String)]) -> String {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._*")
            func enc(_ s: String) -> String {
                (s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s).replacingOccurrences(of: "%20", with: "+")
            }
            return pairs.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&")
        }
    }
}

extension NormalizedPage {
    /// Variante für Modell, Export und Debug-Paket: keine Hidden-Werte, keine vorbelegten Eingaben.
    public func redactedForModel() -> NormalizedPage {
        var copy = self
        copy.forms = forms.map { f in
            var f = f
            f.controls = f.controls.map { c in
                var c = c
                switch c.role {
                case .hidden: c.value = c.value == nil ? nil : "<hidden>"
                case .textField, .password, .textArea: c.value = (c.value?.isEmpty ?? true) ? nil : "<value>"
                default: break
                }
                return c
            }
            return f
        }
        return copy
    }
}
