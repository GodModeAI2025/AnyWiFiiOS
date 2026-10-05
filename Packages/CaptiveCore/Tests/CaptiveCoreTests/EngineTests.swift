import Testing
import Foundation
@testable import CaptiveCore

private func control(_ page: NormalizedPage, concept: String) -> NormalizedControl? {
    page.visibleControls.first { $0.concept == concept }
}

@Suite struct NormalizerTests {
    private func norm(_ html: String) -> NormalizedPage {
        PortalNormalizer.normalize(html: html, url: URL(string: "http://portal.test/x")!)
    }

    @Test func roomNumberVariantsMapToSameConcept() {
        let a = norm(#"<form><label for="room">Room Number</label><input id="room" name="room"></form>"#)
        let b = norm(#"<form><input name="room_no" placeholder="Zimmernummer"></form>"#)
        let c = norm(#"<form><div>Room</div><input aria-label="Room number"></form>"#)
        for p in [a, b, c] { #expect(control(p, concept: "roomNumber") != nil) }
    }

    @Test func compactAndNoScriptContent() {
        let p = norm(Fixtures.html("11_hidden_csrf"))
        #expect(p.forms.count == 1)
        #expect(p.forms[0].method == "POST")
        #expect(p.forms[0].controls.filter { $0.role == .hidden }.count == 1)
        let yaml = try! JSONEncoder().encode(p)
        #expect(yaml.count < 4000)
    }

    @Test func fixtureConcepts() {
        #expect(control(norm(Fixtures.html("04_userpass")), concept: "username") != nil)
        #expect(control(norm(Fixtures.html("04_userpass")), concept: "password") != nil)
        #expect(control(norm(Fixtures.html("05_hotel")), concept: "lastName") != nil)
        #expect(control(norm(Fixtures.html("06_voucher")), concept: "voucherCode") != nil)
        #expect(control(norm(Fixtures.html("07_email")), concept: "email") != nil)
    }

    @Test func malformedHTMLStillYieldsLoginForm() {
        let p = norm(Fixtures.html("15_malformed_html"))
        #expect(control(p, concept: "username") != nil)
        #expect(control(p, concept: "password") != nil)
        #expect(p.visibleControls.contains { $0.role == .button })
    }

    @Test func jsOnlyDetected() {
        let p = norm(Fixtures.html("14_js_only"))
        #expect(p.looksJavaScriptOnly)
        #expect(!norm(Fixtures.html("01_clickthrough")).looksJavaScriptOnly)
    }

    @Test func checkboxLabelAndRequired() {
        let p = norm(Fixtures.html("03_terms_privacy"))
        let boxes = p.visibleControls.filter { $0.role == .checkbox }
        #expect(boxes.count == 2)
        #expect(boxes.allSatisfy { $0.required })
        #expect(boxes[0].label?.contains("Datenschutz") == true)
    }

    @Test func redactedPageHidesHiddenAndPrefilled() {
        let html = #"<form><input type="hidden" name="csrf" value="SECRETTOKEN"><input name="username" value="prefilled"></form>"#
        let json = String(decoding: try! JSONEncoder().encode(norm(html).redactedForModel()), as: UTF8.self)
        #expect(!json.contains("SECRETTOKEN"))
        #expect(!json.contains("prefilled"))
    }
}

@Suite struct MatcherTests {
    let page = PortalNormalizer.normalize(html: Fixtures.html("05_hotel"), url: URL(string: "http://p.test/")!)

    @Test func matchesByConceptLabelNamePlaceholder() {
        #expect(ElementMatcher.find(Target(concept: "roomNumber"), in: page)?.control.name == "room")
        #expect(ElementMatcher.find(Target(labelAny: ["Last name"]), in: page)?.control.name == "lastname")
        #expect(ElementMatcher.find(Target(nameAny: ["lastname"]), in: page)?.control.concept == "lastName")
        let ph = PortalNormalizer.normalize(html: #"<form><input name="x" placeholder="Zimmernummer"></form>"#, url: URL(string: "http://p.test/")!)
        #expect(ElementMatcher.find(Target(placeholderAny: ["Zimmernummer"]), in: ph) != nil)
        let aria = PortalNormalizer.normalize(html: #"<form><input aria-label="Room number"></form>"#, url: URL(string: "http://p.test/")!)
        #expect(ElementMatcher.find(Target(ariaAny: ["room number"]), in: aria) != nil)
    }

    @Test func matchesByNearbyText() {
        let p = PortalNormalizer.normalize(html: #"<form><div>Your voucher here</div><input name="q1"></form>"#, url: URL(string: "http://p.test/")!)
        #expect(ElementMatcher.find(Target(nearbyAny: ["voucher"]), in: p)?.reasons.contains(.nearby) == true)
    }

    @Test func selectorIsOnlyFallback() {
        let m = ElementMatcher.find(Target(labelAny: ["Gone"], lastKnownSelector: "input#room"), in: page)
        #expect(m?.usedSelectorFallback == true)
        #expect(ElementMatcher.find(Target(labelAny: ["Gone"]), in: page) == nil)
    }

    @Test func conceptConflictNeverMatches() {
        #expect(ElementMatcher.find(Target(role: "textField", concept: "password"), in: page) == nil)
    }

    @Test func buttonByRoleAndLabel() {
        #expect(ElementMatcher.find(Target(role: "button", labelAny: ["Connect", "Login"]), in: page) != nil)
        #expect(ElementMatcher.find(Target(role: "button", labelAny: ["Join Wi-Fi"]), in: page) == nil)
    }
}

@Suite struct SecurityValidatorTests {
    private func recipe(_ actions: [Action]) -> Recipe { Recipe(name: "n", ssid: "s", stages: [Stage(id: "a", actions: actions)]) }

    @Test func paymentActionRejected() {
        let r = recipe([.check(target: Target(role: "checkbox", labelAny: ["Buy Premium Wi-Fi – € 9.99"]))])
        #expect(!SecurityValidator.errors(r).isEmpty)
        let r2 = recipe([.fill(target: Target(concept: "cardNumber"), value: .ask("cardNumber"))])
        #expect(!SecurityValidator.errors(r2).isEmpty)
    }

    @Test func literalForSecretRejected() {
        let r = recipe([.fill(target: Target(concept: "password"), value: .literal("x"))])
        #expect(SecurityValidator.errors(r).contains { $0.message.contains("Literal") })
    }

    @Test func unknownKeychainReferenceRejected() {
        let r = recipe([.fill(target: Target(concept: "lastName"), value: .keychain("nope"))])
        #expect(!SecurityValidator.errors(r, bindings: [Kit.lastNameBinding]).isEmpty)
        let ok = recipe([.fill(target: Target(concept: "lastName"), value: .keychain("hotel.lastName"))])
        #expect(SecurityValidator.errors(ok, bindings: [Kit.lastNameBinding]).isEmpty)
    }

    @Test func secretMustMatchItsPurpose() {
        let r = recipe([.fill(target: Target(concept: "email"), value: .keychain("portal.password"))])
        #expect(!SecurityValidator.errors(r, bindings: Kit.allBindings).isEmpty)
        let r2 = recipe([.fill(target: Target(concept: "email"), value: .ask("password"))])
        #expect(!SecurityValidator.errors(r2).isEmpty)
    }

    @Test func codeFragmentsRejected() {
        let r = recipe([.tap(target: Target(labelAny: ["javascript:alert(1)"]))])
        #expect(SecurityValidator.errors(r).contains { $0.message.contains("Script") })
    }

    @Test func planActionLimit() {
        let acts = (0..<5).map { _ in Action.submit }
        #expect(!SecurityValidator.validate(plan: acts).isEmpty)
        #expect(SecurityValidator.validate(plan: Array(acts.prefix(4))).isEmpty)
    }

    @Test func hostPolicy() {
        var p = HostPolicy(hints: ["Portal.Example"])
        #expect(p.permitsCredentials(to: "portal.example"))
        #expect(!p.permitsCredentials(to: "evil.example"))
        p.allow("login.vendor.net")
        #expect(p.permitsCredentials(to: "LOGIN.vendor.net"))
        #expect(!p.permitsCredentials(to: nil))
    }
}

@Suite struct ConsentTests {
    private func page(_ name: String) -> NormalizedPage {
        PortalNormalizer.normalize(html: Fixtures.html(name), url: URL(string: "http://p.test/")!)
    }

    @Test func acceptAllOnlyTakesRequiredNonCommercial() {
        let p = page("13_paid_upgrade")
        let ok = ConsentPolicy.acceptable(in: p, intent: Kit.intent(Kit.terms))
        #expect(ok.map { $0.name } == ["terms"])
    }

    @Test func marketingNeedsExplicitPermission() {
        let p = page("12_optional_marketing")
        #expect(ConsentPolicy.acceptable(in: p, intent: Kit.intent(Kit.terms)).map { $0.name } == ["terms"])
        let allowed = Kit.intent(Kit.terms, policy: .init(allowOptionalMarketingConsent: true))
        #expect(Set(ConsentPolicy.acceptable(in: p, intent: allowed).compactMap { $0.name }) == ["terms", "newsletter"])
    }

    @Test func paidAlwaysBlocked() {
        let box = page("13_paid_upgrade").visibleControls.first { $0.name == "premium" }!
        #expect(ConsentPolicy.classify(box) == .paid)
        let policy = IntentPolicy(allowOptionalMarketingConsent: true, allowPaidUpgrade: true)
        #expect(ConsentPolicy.evaluate(box, action: "check", policy: policy) != .allow)
    }
}

/// Fixtures 01 bis 16: Lernlauf, Kompilierung und Replay ohne Modell.
@Suite struct FixtureFlowTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var steps: [SiteStep]
        var intent: PortalIntent
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "P1 click through", steps: Scenarios.clickthrough, intent: Kit.intent([])),
        Case(name: "P2 terms", steps: Scenarios.terms, intent: Kit.intent(Kit.terms)),
        Case(name: "P3 privacy and terms", steps: Scenarios.termsPrivacy, intent: Kit.intent(Kit.terms)),
        Case(name: "P4 user and password", steps: Scenarios.userpass, intent: Kit.userpassIntent),
        Case(name: "P5 room and last name", steps: Scenarios.hotel, intent: Kit.hotelIntent),
        Case(name: "P6 voucher", steps: Scenarios.voucher, intent: Kit.intent([.fill(concept: "voucherCode", source: .keychain)])),
        Case(name: "P7 email and consent", steps: Scenarios.email, intent: Kit.intent(Kit.terms + [.fill(concept: "email", source: .keychain)])),
        Case(name: "P8 multi stage", steps: Scenarios.multistage, intent: Kit.hotelIntent),
        Case(name: "11 hidden csrf", steps: Scenarios.csrf, intent: Kit.userpassIntent),
        Case(name: "12 optional marketing", steps: Scenarios.marketing, intent: Kit.intent(Kit.terms)),
        Case(name: "13 paid upgrade present", steps: Scenarios.paid, intent: Kit.intent(Kit.terms)),
        Case(name: "15 malformed html", steps: Scenarios.malformed, intent: Kit.userpassIntent),
    ]

    @Test(arguments: cases)
    func learnCompileReplay(_ c: Case) async throws {
        let learnSite = MockPortalSite(steps: c.steps)
        let learned = await Kit.engine(learnSite, policy: c.intent.policy, model: true)
            .learn(intent: c.intent, planner: HeuristicPlanner())
        #expect(learned.outcome == .success, "learn: \(learned.reason ?? "")")
        #expect(learned.modelCalls >= 1)

        let recipe = TraceCompiler.compile(trace: learned.trace, name: c.name, ssid: "Test")
        #expect(SecurityValidator.errors(recipe, bindings: Kit.allBindings).isEmpty)
        // Recipe übersteht Serialisierung
        let reparsed = try PRLCodec.parse(yaml: PRLCodec.serialize(recipe))
        #expect(reparsed == recipe)

        // Replay ohne Modell, frisches Portal
        let replaySite = MockPortalSite(steps: c.steps)
        let replayed = await Kit.engine(replaySite, policy: c.intent.policy).replay(reparsed)
        #expect(replayed.outcome == .success, "replay: \(replayed.reason ?? "")")
        #expect(replayed.modelCalls == 0)
        #expect(await replaySite.rejectedPosts == 0)
    }

    @Test func serverSawCorrectRequest() async throws {
        let site = MockPortalSite(steps: Scenarios.csrf)
        let r = await Kit.engine(site).learn(intent: Kit.userpassIntent, planner: HeuristicPlanner())
        #expect(r.outcome == .success)
        let post = await site.log.first { $0.method == "POST" }
        #expect(post?.form["csrf"]?.hasPrefix("tok") == true)
        #expect(post?.form["action"] == "login")
        #expect(post?.form["username"] == TestValues.username)
        #expect(post?.cookie?.hasPrefix("session=") == true)
        #expect(r.network.contains { $0.status == 302 })
    }

    @Test func marketingAndPaidNeverPosted() async {
        for steps in [Scenarios.marketing, Scenarios.paid] {
            let site = MockPortalSite(steps: steps)
            let r = await Kit.engine(site).learn(intent: Kit.intent(Kit.terms), planner: HeuristicPlanner())
            #expect(r.outcome == .success)
            let post = await site.log.first { $0.method == "POST" }
            #expect(post?.form["terms"] == "1")
            #expect(post?.form["newsletter"] == nil)
            #expect(post?.form["premium"] == nil)
        }
    }

    @Test func alreadyOnlineIsSuccess() async {
        let site = MockPortalSite(steps: Scenarios.clickthrough)
        let first = await Kit.engine(site).learn(intent: Kit.intent([]), planner: HeuristicPlanner())
        #expect(first.outcome == .success)
        let again = await Kit.engine(site).replay(Recipe(name: "n", ssid: "s", stages: [Stage(id: "a", actions: [.submit])]))
        #expect(again.outcome == .success)
        #expect(again.trace.isEmpty)
    }

    @Test func jsOnlyIsManualInteraction() async {
        let site = MockPortalSite(steps: Scenarios.js)
        let r = await Kit.engine(site).learn(intent: Kit.hotelIntent, planner: HeuristicPlanner())
        #expect(r.outcome == .manualInteractionRequired)
        #expect(r.modelCalls == 0)
    }

    @Test func missingRoomNumberAsksUser() async {
        let site = MockPortalSite(steps: Scenarios.hotel)
        let noRoom = StaticValueProvider(keychain: Kit.values.keychain, ask: [:])
        let r = await Kit.engine(site, values: noRoom).learn(intent: Kit.hotelIntent, planner: HeuristicPlanner())
        #expect(r.outcome == .missingUserValue)
        #expect(r.requiredConcept == "roomNumber")
        #expect(await site.log.allSatisfy { $0.method != "POST" })
        // Mit nachgelieferten Wert gelingt der Lauf
        let r2 = await Kit.engine(MockPortalSite(steps: Scenarios.hotel)).learn(intent: Kit.hotelIntent, planner: HeuristicPlanner())
        #expect(r2.outcome == .success)
    }

    @Test func changedLabelCausesMismatchNotGuessing() async throws {
        let learned = await Kit.engine(MockPortalSite(steps: Scenarios.hotel), model: true)
            .learn(intent: Kit.hotelIntent, planner: HeuristicPlanner())
        let recipe = TraceCompiler.compile(trace: learned.trace, name: "Hotel", ssid: "S")
        let site = MockPortalSite(steps: Scenarios.changed)
        let r = await Kit.engine(site).replay(recipe)
        #expect(r.outcome == .recipeMismatch)
        #expect(r.failedStageId != nil)
        #expect(await site.log.allSatisfy { $0.method != "POST" })
    }

    @Test func externalFormActionDoesNotGetCredentials() async {
        let site = MockPortalSite(steps: Scenarios.external)
        let intent = Kit.intent([.fill(concept: "username", source: .keychain), .fill(concept: "password", source: .keychain)])
        let r = await Kit.engine(site).learn(intent: intent, planner: HeuristicPlanner())
        #expect(r.outcome == .manualInteractionRequired)
        #expect(await site.evilHits == 0)
        let m = await Kit.engine(MockPortalSite(steps: Scenarios.external), model: true).learn(intent: intent, planner: HeuristicPlanner())
        #expect(m.outcome == .aiRejectedPlan)
    }

    @Test func plannerOutputIsValidated() async {
        struct Rogue: PortalPlanner {
            func plan(_ input: PlanningInput) async throws -> PortalPlan {
                PortalPlan(actions: [.check(target: Target(role: "checkbox", labelAny: ["Buy Premium Wi-Fi"]))])
            }
        }
        let r = await Kit.engine(MockPortalSite(steps: Scenarios.paid), model: true).learn(intent: Kit.intent(Kit.terms), planner: Rogue())
        #expect(r.outcome == .aiRejectedPlan)
    }

    @Test func rogueRecipeCannotCheckPaidBox() async {
        let recipe = Recipe(name: "n", ssid: "s", stages: [Stage(id: "a", actions: [
            .check(target: Target(role: "checkbox", nameAny: ["premium"])), .submit])])
        let site = MockPortalSite(steps: Scenarios.paid)
        let r = await Kit.engine(site).replay(recipe)
        #expect(r.outcome == .manualInteractionRequired)
        #expect(await site.log.allSatisfy { $0.method != "POST" })
    }

    @Test func multistageProducesTwoStages() async {
        let learned = await Kit.engine(MockPortalSite(steps: Scenarios.multistage), model: true)
            .learn(intent: Kit.hotelIntent, planner: HeuristicPlanner())
        let recipe = TraceCompiler.compile(trace: learned.trace, name: "M", ssid: "S")
        #expect(recipe.stages.count == 2)
        #expect(recipe.stages[1].match.fields.sorted() == ["lastName", "roomNumber"])
        #expect(learned.modelCalls == 2)
    }
}

@Suite struct TraceCompilerTests {
    @Test func recipeHasNoRawValuesHiddenTokensOrCookies() async throws {
        let site = MockPortalSite(steps: Scenarios.csrf)
        let r = await Kit.engine(site, model: true).learn(intent: Kit.userpassIntent, planner: HeuristicPlanner())
        let yaml = try PRLCodec.serialize(TraceCompiler.compile(trace: r.trace, name: "n", ssid: "s"))
        for secret in [TestValues.password, TestValues.username, "csrf", "tok", "session="] {
            #expect(!yaml.contains(secret), "\(secret) im Recipe")
        }
        #expect(yaml.contains("keychain: portal.password"))
    }

    @Test func runtimeAndLiteralValuesDropped() {
        let step = { (i: Int, a: Action) in
            TraceStep(index: i, pageIndex: 1, stageId: nil, action: a, control: nil, matchScore: nil, valueRef: nil,
                      urlBefore: "", urlAfter: nil, status: nil, durationMs: 0, result: "ok")
        }
        let r = TraceCompiler.compile(trace: [
            step(0, .fill(target: Target(concept: "roomNumber"), value: .ask("roomNumber"))),
            step(1, .fill(target: Target(concept: "otp"), value: .runtime("otp"))),
            step(2, .tap(target: Target(role: "button", labelAny: ["Go"]))),
        ], name: "n", ssid: "s")
        #expect(r.stages.count == 1)
        #expect(r.stages[0].actions.count == 2)
        #expect(r.stages[0].actions[0] == .fill(target: Target(concept: "roomNumber"), value: .ask("roomNumber")))
    }
}

@Suite struct HTTPClientTests {
    struct Loop: PortalTransport {
        func send(_ r: PortalRequest) async throws -> PortalResponse {
            PortalResponse(url: r.url, status: 302, headers: ["Location": "/again"], body: "")
        }
    }

    @Test func redirectLimit() async {
        let client = PortalHTTPClient(transport: Loop())
        await #expect(throws: PortalError.tooManyRedirects) {
            _ = try await client.fetch(PortalRequest(url: URL(string: "http://p.test/")!))
        }
    }

    @Test func queryNeverLogged() async throws {
        let site = MockPortalSite(steps: Scenarios.clickthrough)
        let f = try await PortalHTTPClient(transport: site).fetch(PortalRequest(url: URL(string: "http://portal.test/page/0?token=ABC")!))
        #expect(f.entries.allSatisfy { !$0.url.contains("ABC") })
    }
}

@Suite struct DebugBundleTests {
    /// SPEC §3.3: Kein Testwert aus 02 §18 darf in irgendeiner Datei des ZIPs vorkommen.
    @Test func redactionRemovesAllTestValues() async throws {
        let values = StaticValueProvider(
            keychain: ["portal.username": TestValues.username, "portal.password": TestValues.password],
            ask: [:])
        let engine = RunEngine(transport: LeakyPortal(), values: values, bindings: Kit.allBindings)
        let result = await engine.learn(intent: Kit.userpassIntent, planner: HeuristicPlanner())
        #expect(result.outcome != .success)
        #expect(result.secretsUsed.count >= 2)

        let extras = [
            SensitiveValue(value: TestValues.room, placeholder: "<personal:roomNumber>"),
            SensitiveValue(value: TestValues.surname, placeholder: "<personal:lastName>"),
            SensitiveValue(value: TestValues.cookie, placeholder: "<cookie>"),
        ]
        let input = DebugBundleInput(
            profileName: "Hotel \(TestValues.surname)", recipeRevision: 3, startedAt: Date(), intent: Kit.userpassIntent,
            recipe: Recipe(name: "Hotel", ssid: "S", stages: [Stage(id: "a", actions: [.submit])]), run: result,
            environment: DebugEnvironment(appVersion: "1.0", osVersion: "27.0", device: "iPhone", modelAvailability: "available", mode: "manual"),
            chat: [ChatLogMessage(role: "user", text: "Mein Nachname ist \(TestValues.surname), Zimmer \(TestValues.room), Passwort \(TestValues.password)")],
            extraSensitive: extras)
        let (name, data) = try DebugBundleBuilder.build(input)
        #expect(name.hasPrefix("CaptiveAI-Debug-Hotel-"))
        #expect(name.hasSuffix(".zip"))

        let entries = try ZipArchive.read(data)
        let paths = Set(entries.map(\.path))
        for required in ["README.md", "summary.json", "intent.json", "recipe.yaml", "trace.jsonl", "network.json",
                         "environment.json", "chat.json", "schema/prl-v1.json", "pages/01.yaml", "pages/01.html"] {
            #expect(paths.contains(required), "fehlt: \(required)")
        }
        let forbidden = [TestValues.username, TestValues.password, TestValues.room, TestValues.surname,
                         TestValues.cookie, "abcdef", "CSRFSECRET"]
        for e in entries {
            let text = String(decoding: e.data, as: UTF8.self)
            for f in forbidden {
                #expect(!text.contains(f), "\(f) in \(e.path)")
            }
            #expect(!e.path.contains(TestValues.surname))
        }
        let chat = String(decoding: entries.first { $0.path == "chat.json" }!.data, as: UTF8.self)
        #expect(chat.contains("<personal:lastName>"))
        #expect(chat.contains("<secret:password>"))
        let readme = String(decoding: entries.first { $0.path == "README.md" }!.data, as: UTF8.self)
        #expect(readme.contains("schema/prl-v1.json"))
    }

    /// Portal, das nach dem Absenden den Login ablehnt und Werte zurückspiegelt.
    struct LeakyPortal: PortalTransport {
        func send(_ r: PortalRequest) async throws -> PortalResponse {
            let url = r.url
            if url.host == "captive.apple.com" {
                return PortalResponse(url: url, status: 302, headers: ["Location": "http://portal.test/login"], body: "")
            }
            var echo = ""
            if let b = r.body { echo = String(decoding: b, as: UTF8.self) }
            let html = """
            <html><body><p class="err">Login failed for \(echo.contains("mark") ? "mark" : "")</p>
            <form method="post" action="/auth">
            <input type="hidden" name="csrf" value="CSRFSECRET">
            <label for="u">Username</label><input id="u" name="username" value="mark">
            <label for="p">Password</label><input id="p" name="password" type="password" value="SuperSecret123">
            <button name="action" value="login">Login</button></form>
            <!-- Cookie: SESSION=abcdef --></body></html>
            """
            return PortalResponse(url: url, status: 200, headers: ["Set-Cookie": "SESSION=abcdef"], body: html)
        }
    }

    @Test func zipRoundTrip() throws {
        let entries = [ZipArchive.Entry(path: "a.txt", data: Data("hallo".utf8)),
                       ZipArchive.Entry(path: "dir/ü.json", data: Data("{}".utf8)),
                       ZipArchive.Entry(path: "empty", data: Data())]
        #expect(try ZipArchive.read(ZipArchive.write(entries)) == entries)
        #expect(throws: ZipError.self) { try ZipArchive.read(Data([1, 2, 3])) }
    }

    @Test func redactorHandlesEncodings() {
        let r = Redactor(values: [SensitiveValue(value: "a b&c", placeholder: "<secret:x>")])
        #expect(r.redact("q=a%20b%26c and a+b%26c and a b&amp;c and a b&c") == "q=<secret:x> and <secret:x> and <secret:x> and <secret:x>")
        #expect(r.redact("Cookie: SESSION=1\nSet-Cookie: x=y").contains("<cookie>"))
        #expect(!r.redact("Cookie: SESSION=1").contains("SESSION"))
    }

    @Test func debugBundleReadmeMentionsTemplate() {
        #expect(DebugBundleBuilder.template.contains("prl-v1.json"))
    }
}
