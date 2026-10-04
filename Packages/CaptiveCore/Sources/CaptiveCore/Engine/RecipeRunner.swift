import Foundation

/// Führt ein Recipe deterministisch aus, ohne AI (01 §13 Replay-Modus, Gate S8).
///
/// Ablauf: Probe → Portalseite normalisieren → passende Stage wählen → Aktionen ausführen →
/// Formular absenden → erneut prüfen, bis online oder ein definierter Fehler vorliegt.
/// Die Runtime-Regeln aus ADR 0001 (Consent, Credential-Hosts, Query-Parameter) gelten immer.
public struct RecipeRunner: Sendable {
    public var transport: any PortalTransport
    public var values: any ValueProvider
    public var probeURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!
    /// Zusätzliche vertrauenswürdige Portal-Hosts aus dem Profil (NetworkMatcher.portalHostHints, 01 §7.2).
    public var portalHostHints: [String] = []
    public var maxRounds = 6
    public var maxMetaRefreshes = 3
    public var allowOptionalMarketingConsent = false
    public var adapters = PortalAdapterRegistry.standard

    public init(transport: any PortalTransport, values: any ValueProvider) {
        self.transport = transport
        self.values = values
    }

    public func run(_ recipe: Recipe) async -> RunResult {
        let context = RunContext(session: PortalHTTPSession(transport: transport))
        context.trusted.formUnion(portalHostHints.map { $0.lowercased() })
        do {
            return try await execute(recipe, context)
        } catch let error as PortalHTTPError {
            switch error {
            case .tooManyRedirects: return context.result(.tooManyRedirects)
            case .responseTooLarge: return context.result(.responseTooLarge)
            case .invalidRedirect: return context.result(.transport("Ungültiger Redirect"))
            }
        } catch {
            return context.result(.transport(String(describing: type(of: error))))
        }
    }

    // MARK: - Hauptschleife

    private func execute(_ recipe: Recipe, _ ctx: RunContext) async throws -> RunResult {
        let probe = try await ctx.session.get(probeURL)
        ctx.trace.record(.probe, "Probe \(probeURL.host ?? "?") → \(Self.statusChain(probe))")
        if Self.isOnline(probe) { return ctx.result(.alreadyOnline) }
        ctx.trusted.formUnion(probe.hosts)

        var page = try await load(probe.final, ctx)
        var lastStage: Stage?

        for _ in 0..<maxRounds {
            ctx.page = page
            guard let stage = pickStage(recipe, page: page, excluding: lastStage?.id) else {
                if let last = lastStage, stageMatches(last, page) {
                    ctx.failedStage = last.id
                    return ctx.result(.loginNotAccepted(stage: last.id))
                }
                if page.requiresJavaScript { return ctx.result(.javaScriptRequired) }
                return ctx.result(.stageNotFound)
            }
            ctx.trace.record(.stage, "Stage '\(stage.id)' auf \(Self.hostPath(page.url))", stage: stage.id)

            let stageResult = try await runStage(stage, page: page, ctx)
            switch stageResult {
            case .finished(let reason):
                return ctx.result(reason)

            case .navigated(let exchange, let remaining):
                ctx.trusted.formUnion(exchange.hosts.dropFirst())
                if exchange.final.status >= 400 {
                    ctx.failedStage = stage.id
                    return ctx.result(.httpStatus(exchange.final.status))
                }
                page = try await load(exchange.final, ctx)
                ctx.page = page
                if let reason = checkAfterNavigation(remaining, stage: stage, page: page, ctx) {
                    return ctx.result(reason)
                }

            case .adapterLoggedIn, .noNavigation:
                break
            }

            if try await isOnlineNow(ctx) { return ctx.result(.loggedIn) }
            if !recipe.success.internetAccess, let texts = recipe.success.pageContainsAny,
               Self.contains(page, any: texts) {
                return ctx.result(.loggedIn)
            }
            if case .navigated = stageResult {
                lastStage = stage
                continue
            }
            ctx.failedStage = stage.id
            return ctx.result(.stillCaptive)
        }
        return ctx.result(.roundLimitReached)
    }

    // MARK: - Stage-Auswahl

    func pickStage(_ recipe: Recipe, page: PortalPage, excluding excluded: String?) -> Stage? {
        recipe.stages.first { $0.id != excluded && stageMatches($0, page) }
    }

    func stageMatches(_ stage: Stage, _ page: PortalPage) -> Bool {
        if let match = stage.match {
            if let texts = match.anyText, !Self.contains(page, any: texts) { return false }
            if let fields = match.fields,
               !fields.allSatisfy({ concept in page.interactiveControls.contains { $0.concept == concept } }) {
                return false
            }
            if let parts = match.urlContains, !parts.contains(where: { page.url.absoluteString.contains($0) }) {
                return false
            }
        }
        for action in stage.actions {
            if case .adapter(let a) = action {
                return adapters.adapter(id: a.id)?.detect(page) ?? false
            }
            if let target = action.target, action.opcode != .waitFor {
                // Ohne match-Block entscheidet das erste Element, ob die Stage zur Seite passt.
                if stage.match == nil, case .failure = ElementMatcher.resolve(target, in: page) { return false }
                return true
            }
        }
        return true
    }

    // MARK: - Stage-Ausführung

    enum StageResult {
        case finished(RunReason)
        case navigated(PortalExchange, remaining: [(Int, PortalAction)])
        case adapterLoggedIn
        case noNavigation
    }

    struct FormState {
        var values: [String: String] = [:]
        var checks: [String: Bool] = [:]
        var explicitlyChecked: Set<String> = []
        var sensitiveForms: Set<Int> = []
        var lastFormIndex: Int?
    }

    private func runStage(_ stage: Stage, page: PortalPage, _ ctx: RunContext) async throws -> StageResult {
        var form = FormState()
        let actions: [(Int, PortalAction)] = stage.actions.enumerated().map { ($0.offset, $0.element) }

        for (position, (index, action)) in actions.enumerated() {
            let remaining = Array(actions[(position + 1)...])
            func fail(_ reason: RunReason) -> StageResult {
                ctx.failedStage = stage.id
                ctx.failedAction = index
                return .finished(reason)
            }
            func resolve(_ target: Target) -> Result<PortalControl, RunReason> {
                switch ElementMatcher.resolve(target, in: page) {
                case .success(let match): return .success(match.control)
                case .failure(.notFound): return .failure(.targetNotFound(stage: stage.id, action: index))
                case .failure(.ambiguous(let ids)):
                    return .failure(.targetAmbiguous(stage: stage.id, action: index, candidates: ids))
                }
            }

            switch action {
            case .fill(let fill):
                let control: PortalControl
                switch resolve(fill.target) {
                case .success(let c): control = c
                case .failure(let reason): return fail(reason)
                }
                guard control.role == .textField || control.role == .passwordField else {
                    return fail(.wrongElementKind(stage: stage.id, action: index))
                }
                guard let value = await lookup(fill.value) else {
                    return fail(.missingValue(Self.concept(of: fill)))
                }
                let placeholder = Self.placeholder(for: fill)
                if Self.isSensitive(fill) {
                    ctx.trace.registerSensitive(value, placeholder: placeholder)
                    form.sensitiveForms.insert(control.formIndex ?? -1)
                }
                form.values[control.elementId] = value
                form.lastFormIndex = control.formIndex
                ctx.trace.record(.action, "fill \(control.elementId) ← \(placeholder)", stage: stage.id, action: index)

            case .check(let a):
                let control: PortalControl
                switch resolve(a.target) {
                case .success(let c): control = c
                case .failure(let reason): return fail(reason)
                }
                guard control.role == .checkbox || control.role == .radio else {
                    return fail(.wrongElementKind(stage: stage.id, action: index))
                }
                if ConsentClassifier.isCommercial(control.descriptors) {
                    return fail(.commercialElement(Self.caption(control)))
                }
                if !allowOptionalMarketingConsent && ConsentClassifier.isMarketing(control.descriptors) {
                    return fail(.optionalConsent(Self.caption(control)))
                }
                if control.role == .radio, let formIndex = control.formIndex {
                    for other in page.forms[formIndex].controls where other.role == .radio && other.name == control.name {
                        form.checks[other.elementId] = false
                    }
                }
                form.checks[control.elementId] = true
                form.explicitlyChecked.insert(control.elementId)
                form.lastFormIndex = control.formIndex
                ctx.trace.record(.action, "check \(control.elementId)", stage: stage.id, action: index)

            case .uncheck(let a):
                let control: PortalControl
                switch resolve(a.target) {
                case .success(let c): control = c
                case .failure(let reason): return fail(reason)
                }
                guard control.role == .checkbox else { return fail(.wrongElementKind(stage: stage.id, action: index)) }
                form.checks[control.elementId] = false
                form.lastFormIndex = control.formIndex
                ctx.trace.record(.action, "uncheck \(control.elementId)", stage: stage.id, action: index)

            case .select(let s):
                let control: PortalControl
                switch resolve(s.target) {
                case .success(let c): control = c
                case .failure(let reason): return fail(reason)
                }
                guard control.role == .select,
                      let option = Self.pickOption(s.option, control.options) else {
                    return fail(.wrongElementKind(stage: stage.id, action: index))
                }
                if ConsentClassifier.isCommercial([option.label, option.value]) {
                    return fail(.commercialElement(option.label))
                }
                form.values[control.elementId] = option.value
                form.lastFormIndex = control.formIndex
                ctx.trace.record(.action, "select \(control.elementId) = \(option.value)", stage: stage.id, action: index)

            case .tap(let a):
                let control: PortalControl
                switch resolve(a.target) {
                case .success(let c): control = c
                case .failure(let reason): return fail(reason)
                }
                if control.role == .link, let href = control.href {
                    if ConsentClassifier.isCommercial(control.descriptors) {
                        return fail(.commercialElement(Self.caption(control)))
                    }
                    let exchange = try await ctx.session.perform(PortalRequest(
                        method: "GET", url: href, headers: ["Referer": page.url.absoluteString]))
                    ctx.trace.record(.request, "GET \(Self.hostPath(href)) → \(Self.statusChain(exchange))",
                                     stage: stage.id, action: index)
                    return .navigated(exchange, remaining: remaining)
                }
                guard control.role == .button, control.isSubmit, let formIndex = control.formIndex else {
                    // Buttons ohne Formular-Submit funktionieren nur per JavaScript.
                    return fail(.javaScriptRequired)
                }
                switch try await submit(formIndex: formIndex, submitter: control, page: page, form: form, ctx,
                                        stage: stage.id, action: index) {
                case .success(let exchange): return .navigated(exchange, remaining: remaining)
                case .failure(let reason): return fail(reason)
                }

            case .submit(let s):
                var submitter: PortalControl?
                var formIndex = form.lastFormIndex ?? (page.forms.count == 1 ? 0 : nil)
                if let target = s.target {
                    switch resolve(target) {
                    case .success(let c):
                        guard c.isSubmit else { return fail(.wrongElementKind(stage: stage.id, action: index)) }
                        submitter = c
                        formIndex = c.formIndex
                    case .failure(let reason): return fail(reason)
                    }
                }
                guard let formIndex else { return fail(.wrongElementKind(stage: stage.id, action: index)) }
                if submitter == nil { submitter = page.forms[formIndex].submitButtons.first }
                switch try await submit(formIndex: formIndex, submitter: submitter, page: page, form: form, ctx,
                                        stage: stage.id, action: index) {
                case .success(let exchange): return .navigated(exchange, remaining: remaining)
                case .failure(let reason): return fail(reason)
                }

            case .requestValue(let r):
                guard await values.value(for: .ask(r.concept)) != nil else { return fail(.missingValue(r.concept)) }

            case .waitFor(let w):
                if !conditionHolds(w, page: page) { return fail(.conditionNotMet(stage: stage.id, action: index)) }

            case .verify(let v):
                if let texts = v.pageContainsAny, !Self.contains(page, any: texts) {
                    return fail(.conditionNotMet(stage: stage.id, action: index))
                }
                if v.internetAccess == true {
                    return try await isOnlineNow(ctx) ? .finished(.loggedIn)
                        : fail(.conditionNotMet(stage: stage.id, action: index))
                }

            case .stop(let s):
                if s.outcome == .success {
                    return try await isOnlineNow(ctx) ? .finished(.loggedIn) : fail(.stillCaptive)
                }
                return fail(.stopRequested(s.outcome))

            case .adapter(let a):
                guard let adapter = adapters.adapter(id: a.id) else { return fail(.unknownAdapter(a.id)) }
                ctx.trace.record(.adapter, "Adapter \(a.id)", stage: stage.id, action: index)
                switch try await adapter.login(session: &ctx.session, page: page, values: values, trace: &ctx.trace) {
                case .loggedIn: return .adapterLoggedIn
                case .failed(let message): return fail(.adapterFailed(message))
                }
            }
        }
        return .noNavigation
    }

    // MARK: - Formular absenden (01 §9.6, ADR 0001)

    private func submit(formIndex: Int, submitter: PortalControl?, page: PortalPage, form: FormState,
                        _ ctx: RunContext, stage: String, action: Int) async throws -> Result<PortalExchange, RunReason> {
        let portalForm = page.forms[formIndex]
        var checks = form.checks

        // Consent-Leitplanken (01 §19): kommerziell → Abbruch, vorausgewähltes Marketing → abwählen.
        for control in portalForm.controls where control.role == .checkbox {
            guard checks[control.elementId] ?? control.checked else { continue }
            if ConsentClassifier.isCommercial(control.descriptors) {
                return .failure(.commercialElement(Self.caption(control)))
            }
            if !allowOptionalMarketingConsent, ConsentClassifier.isMarketing(control.descriptors),
               !form.explicitlyChecked.contains(control.elementId) {
                checks[control.elementId] = false
                ctx.trace.record(.guardrail, "Marketing-Haken \(control.elementId) abgewählt", stage: stage, action: action)
            }
        }
        if let submitter, ConsentClassifier.isCommercial(submitter.descriptors) {
            return .failure(.commercialElement(Self.caption(submitter)))
        }

        // Credential-Regel (01 §25): Werte nur an vertrauenswürdige Hosts.
        let actionHost = portalForm.action.host?.lowercased() ?? ""
        if form.sensitiveForms.contains(formIndex), !ctx.trusted.contains(actionHost) {
            return .failure(.credentialHostNotTrusted(actionHost))
        }

        let pairs = Self.formData(portalForm, values: form.values, checks: checks, submitter: submitter)
        var request: PortalRequest
        if portalForm.method == "POST" {
            request = PortalRequest(method: "POST", url: portalForm.action,
                                    headers: ["Content-Type": "application/x-www-form-urlencoded"],
                                    body: Data(FormEncoding.encode(pairs).utf8))
        } else {
            var components = URLComponents(url: portalForm.action, resolvingAgainstBaseURL: true)
            components?.percentEncodedQuery = pairs.isEmpty ? nil : FormEncoding.encode(pairs)
            guard let url = components?.url else { return .failure(.transport("Ungültige Formular-URL")) }
            request = PortalRequest(method: "GET", url: url)
        }
        request.headers["Referer"] = page.url.absoluteString

        let exchange = try await ctx.session.perform(request)
        let fields = pairs.map(\.0).joined(separator: ", ")
        ctx.trace.record(.request, "\(request.method) \(Self.hostPath(portalForm.action)) [\(fields)] → \(Self.statusChain(exchange))",
                         stage: stage, action: action)
        return .success(exchange)
    }

    /// Erfolgreiche Formularfelder nach HTML-Standard (vereinfachte Fassung).
    static func formData(_ form: PortalForm, values: [String: String], checks: [String: Bool],
                         submitter: PortalControl?) -> [(String, String)] {
        var pairs: [(String, String)] = []
        for control in form.controls {
            guard !control.disabled, let name = control.name, !name.isEmpty else { continue }
            switch control.role {
            case nil:
                pairs.append((name, control.value ?? ""))
            case .checkbox?, .radio?:
                if checks[control.elementId] ?? control.checked { pairs.append((name, control.value ?? "on")) }
            case .button?:
                if control.elementId == submitter?.elementId, control.inputType != "image" {
                    pairs.append((name, control.value ?? ""))
                }
            case .link?:
                break
            case .select?, .textField?, .passwordField?:
                pairs.append((name, values[control.elementId] ?? control.value ?? ""))
            }
        }
        return pairs
    }

    // MARK: - Hilfen

    private func load(_ response: PortalResponse, _ ctx: RunContext) async throws -> PortalPage {
        var page = try PortalNormalizer.normalize(html: response.text, url: response.url)
        var hops = 0
        while let target = page.metaRefresh, hops < maxMetaRefreshes, page.interactiveControls.isEmpty {
            let exchange = try await ctx.session.get(target)
            ctx.trusted.formUnion(exchange.hosts)
            ctx.trace.record(.page, "Meta-Refresh → \(Self.hostPath(target)) → \(Self.statusChain(exchange))")
            page = try PortalNormalizer.normalize(html: exchange.final.text, url: exchange.final.url)
            hops += 1
        }
        ctx.trace.record(.page, "Seite \(Self.hostPath(page.url)): \(page.forms.count) Formular(e), "
                         + "\(page.interactiveControls.count) Elemente")
        return page
    }

    private func isOnlineNow(_ ctx: RunContext) async throws -> Bool {
        let probe = try await ctx.session.get(probeURL)
        ctx.trace.record(.probe, "Probe → \(Self.statusChain(probe))")
        return Self.isOnline(probe)
    }

    private func lookup(_ source: ValueSource) async -> String? {
        if case .literal(let value) = source { return value }
        return await values.value(for: source)
    }

    private func checkAfterNavigation(_ remaining: [(Int, PortalAction)], stage: Stage, page: PortalPage,
                                      _ ctx: RunContext) -> RunReason? {
        for (index, action) in remaining {
            switch action {
            case .waitFor(let w):
                if !conditionHolds(w, page: page) {
                    ctx.failedStage = stage.id
                    ctx.failedAction = index
                    return .conditionNotMet(stage: stage.id, action: index)
                }
            case .verify(let v):
                if let texts = v.pageContainsAny, !Self.contains(page, any: texts) {
                    ctx.failedStage = stage.id
                    ctx.failedAction = index
                    return .conditionNotMet(stage: stage.id, action: index)
                }
            case .stop(let s):
                if s.outcome != .success { return .stopRequested(s.outcome) }
            default:
                ctx.trace.record(.stage, "Aktion \(index) nach Navigation ignoriert", stage: stage.id, action: index)
            }
        }
        return nil
    }

    func conditionHolds(_ w: WaitCondition, page: PortalPage) -> Bool {
        if let parts = w.urlContains, !parts.contains(where: { page.url.absoluteString.contains($0) }) { return false }
        if let texts = w.pageContainsAny, !Self.contains(page, any: texts) { return false }
        if let element = w.element, case .failure = ElementMatcher.resolve(element, in: page) { return false }
        return true
    }

    static func isOnline(_ exchange: PortalExchange) -> Bool {
        exchange.responses.count == 1 && exchange.final.status == 200 && exchange.final.text.contains("Success")
    }

    static func contains(_ page: PortalPage, any texts: [String]) -> Bool {
        let haystack = page.searchableText
        return texts.contains { haystack.contains($0.lowercased()) }
    }

    static func pickOption(_ spec: OptionSpec, _ options: [PortalControl.Option]) -> PortalControl.Option? {
        if let value = spec.value, let option = options.first(where: { $0.value == value }) { return option }
        guard let labels = spec.labelAny?.map({ $0.lowercased() }) else { return nil }
        return options.first { option in labels.contains { option.label.lowercased().contains($0) } }
    }

    static func concept(of fill: FillAction) -> Concept? {
        if case .ask(let concept) = fill.value { return concept }
        return fill.target.concept
    }

    static func isSensitive(_ fill: FillAction) -> Bool {
        if case .literal = fill.value { return fill.target.concept != nil }
        return true
    }

    /// Platzhalter im Trace (01 §12.3): `<secret:hotel.lastName>`, `<runtime:roomNumber>`.
    static func placeholder(for fill: FillAction) -> String {
        switch fill.value {
        case .keychain(let key): "<secret:\(key)>"
        case .ask(let concept): "<runtime:\(concept.rawValue)>"
        case .profile(let key): "<profile:\(key)>"
        case .runtime(let key): "<runtime:\(key)>"
        case .literal: fill.target.concept.map { "<personal:\($0.rawValue)>" } ?? "<literal>"
        }
    }

    static func caption(_ control: PortalControl) -> String {
        control.captions.first ?? control.name ?? control.elementId
    }

    static func statusChain(_ exchange: PortalExchange) -> String {
        exchange.responses.map { String($0.status) }.joined(separator: " → ")
    }

    /// Host und Pfad ohne Query (Query-Werte können Gerätekennungen enthalten).
    static func hostPath(_ url: URL) -> String {
        (url.host ?? "") + url.path
    }
}

/// Zustand eines einzelnen Laufs. Lebt nur innerhalb von `RecipeRunner.run`.
final class RunContext {
    var session: PortalHTTPSession
    var trace = RunTrace()
    var trusted: Set<String> = []
    var page: PortalPage?
    var failedStage: String?
    var failedAction: Int?

    init(session: PortalHTTPSession) {
        self.session = session
    }

    func result(_ reason: RunReason) -> RunResult {
        trace.record(.outcome, "\(reason.outcome.rawValue): \(reason)")
        return RunResult(reason: reason, trace: trace, lastPage: page,
                         failedStageId: failedStage, failedActionIndex: failedAction)
    }
}
