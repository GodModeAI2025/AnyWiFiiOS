import Foundation
import XCTest
@testable import CaptiveCore

/// Phase 5 (plattformneutraler Teil): Lernlauf, Plan-Validierung, Adaptive Repair.
/// DoD 01 §38 Nr. 12, 13, 14, 18, 19.
final class LearningTests: XCTestCase {
    private var manifest: PortalManifest!

    override func setUpWithError() throws {
        manifest = try PortalManifest.load()
    }

    private var intent: PortalIntent {
        PortalIntent(
            instructions: [.acceptRequiredTerms, .acceptRequiredPrivacy, .fill(.roomNumber), .fill(.lastName), .submit],
            bindings: [
                .roomNumber: .askWhenMissing, .lastName: .keychain("hotel.lastName"),
                .username: .keychain("corp.username"), .password: .keychain("corp.password"),
                .voucherCode: .keychain("hotspot.voucher"), .email: .keychain("freewifi.email"),
            ],
            originalInstruction: "Bedingungen akzeptieren, Zimmernummer fragen, Nachname speichern, verbinden.")
    }

    private var values: StaticValueProvider {
        let v = manifest.testValues
        return StaticValueProvider(
            keychain: ["corp.username": v["username"]!, "corp.password": v["password"]!, "hotel.lastName": v["lastName"]!,
                       "hotspot.voucher": v["voucherCode"]!, "freewifi.email": v["email"]!],
            asked: [.roomNumber: v["roomNumber"]!])
    }

    private func learner(_ portal: FakePortal, planner: any PortalPlanner = HeuristicPlanner()) -> LearningRunner {
        LearningRunner(runner: RecipeRunner(transport: portal, values: values), planner: planner)
    }

    /// Lernen → Recipe → zweiter Lauf ohne AI auf frischem Portal (Gate S8, DoD 12/13).
    func testLearnThenReplayWithoutAI() async throws {
        let learnable = ["01_clickthrough", "02_terms", "03_terms_privacy", "04_userpass", "05_hotel", "06_voucher",
                         "07_email", "08_multistage_terms", "11_hidden_csrf", "12_optional_marketing", "13_paid_upgrade",
                         "15_malformed_html", "16_icomera_form", "18_hotsplots_uam", "19_meraki_clickthrough"]
        let bindings: [String: Concept] = ["hotel.lastName": .lastName, "corp.username": .username,
                                           "corp.password": .password, "hotspot.voucher": .voucherCode,
                                           "freewifi.email": .email]
        for fixture in learnable {
            let learning = await learner(FakePortal(portal: fixture, manifest: manifest))
                .learn(intent: intent, profileId: UUID(), name: fixture, ssid: "Test")
            XCTAssertEqual(learning.run.outcome, .success, "\(fixture): \(learning.run.reason) \(String(describing: learning.rejection))")
            guard let recipe = learning.recipe else { XCTFail("\(fixture): kein Recipe"); continue }
            XCTAssertEqual(RecipeValidator(keychainBindings: bindings).validate(recipe), [], fixture)

            let stored = try PRLCodec.decode(yaml: PRLCodec.encode(recipe))
            let replayPortal = FakePortal(portal: fixture, manifest: manifest)
            let replay = await RecipeRunner(transport: replayPortal, values: values).run(stored)
            XCTAssertEqual(replay.outcome, .success, "\(fixture) Replay: \(replay.reason)")
        }
    }

    func testMultistageNeedsOneModelCallPerPage() async throws {
        let learning = await learner(FakePortal(portal: "08_multistage_terms", manifest: manifest))
            .learn(intent: intent, profileId: UUID(), name: "Hotel", ssid: "Hotel")
        XCTAssertEqual(learning.modelCalls, 2)
        XCTAssertEqual(learning.recipe?.stages.map(\.id), ["consent", "guest"])
    }

    func testJavaScriptPortalIsNotLearnable() async throws {
        let learning = await learner(FakePortal(portal: "14_js_only", manifest: manifest))
            .learn(intent: intent, profileId: UUID(), name: "JS", ssid: "JS")
        XCTAssertEqual(learning.run.outcome, .manualInteractionRequired)
        XCTAssertEqual(learning.modelCalls, 0, "Keine AI-Schleife auf JS-Portalen (S11)")
    }

    func testMissingBindingAsksUser() async throws {
        var limited = intent
        limited.bindings[.voucherCode] = nil
        let html = #"<form method="post" action="/auth"><input name="code" placeholder="Voucher code" required><button>Connect</button></form>"#
        var portal = FakePortal(portal: "06_voucher", manifest: manifest)
        portal.extraPages["/v"] = html
        portal.entryURL = "http://portal.test/v"
        let learning = await LearningRunner(runner: RecipeRunner(transport: portal, values: values), planner: HeuristicPlanner())
            .learn(intent: limited, profileId: UUID(), name: "V", ssid: "V")
        XCTAssertEqual(learning.run.reason, .missingValue(.voucherCode))
    }

    func testModelUnavailable() async throws {
        let learning = await learner(FakePortal(portal: "02_terms", manifest: manifest), planner: FailingPlanner())
            .learn(intent: intent, profileId: UUID(), name: "x", ssid: "x")
        XCTAssertEqual(learning.run.outcome, .aiUnavailable)
    }

    // MARK: Plan-Validierung (01 §24, DoD 18/19)

    func testMaliciousPlansAreRejected() throws {
        let page13 = try PortalNormalizer.normalize(html: FakePortal.fixtureHTML("13_paid_upgrade"), url: URL(string: "http://portal.test/")!)
        let premium = page13.interactiveControls.first { $0.name == "premium" }!
        let newsletter = page13.interactiveControls.first { $0.name == "newsletter" }!
        let upgrade = page13.interactiveControls.first { $0.text?.contains("Premium") == true }!

        func plan(_ actions: [PlannedAction]) -> PortalPlan {
            PortalPlan(reasoningSummary: "", actions: actions, expectedTransition: .newPage)
        }
        XCTAssertEqual(PlanValidator.validate(plan([.init(kind: .check, elementId: premium.elementId)]), page: page13, intent: intent),
                       .commercialElement("Buy Premium Wi-Fi – € 9.99"))
        XCTAssertEqual(PlanValidator.validate(plan([.init(kind: .tap, elementId: upgrade.elementId)]), page: page13, intent: intent),
                       .commercialElement("Upgrade to Premium – € 9.99"))
        XCTAssertEqual(PlanValidator.validate(plan([.init(kind: .check, elementId: newsletter.elementId)]), page: page13, intent: intent),
                       .optionalConsent("Subscribe to newsletter"))
        XCTAssertEqual(PlanValidator.validate(plan([.init(kind: .tap, elementId: "e99")]), page: page13, intent: intent),
                       .unknownElement("e99"))
        XCTAssertEqual(PlanValidator.validate(plan(Array(repeating: .init(kind: .tap, elementId: "e1"), count: 5)),
                                              page: page13, intent: intent), .tooManyActions(5))

        let page04 = try PortalNormalizer.normalize(html: FakePortal.fixtureHTML("04_userpass"), url: URL(string: "http://portal.test/")!)
        let user = page04.interactiveControls.first { $0.concept == .username }!
        XCTAssertEqual(PlanValidator.validate(plan([.init(kind: .fill, elementId: user.elementId, concept: .password)]),
                                              page: page04, intent: intent),
                       .conceptMismatch(element: user.elementId, expected: .username, planned: .password))
        XCTAssertEqual(PlanValidator.validate(plan([.init(kind: .fill, elementId: user.elementId)]), page: page04, intent: intent),
                       .fillWithoutConcept(user.elementId))
    }

    func testRejectedPlanStopsLearning() async throws {
        let learning = await learner(FakePortal(portal: "13_paid_upgrade", manifest: manifest), planner: GreedyPlanner())
            .learn(intent: intent, profileId: UUID(), name: "x", ssid: "x")
        XCTAssertEqual(learning.run.outcome, .aiRejectedPlan)
        XCTAssertNotNil(learning.rejection)
        let online = await FakePortal(portal: "13_paid_upgrade", manifest: manifest).state.online
        XCTAssertFalse(online)
    }

    // MARK: Adaptive Repair (01 §14, Gate S9, DoD 14)

    func testChangedLabelIsRepairedLocally() async throws {
        let recipe = try Fixtures.recipe("valid", "05_hotel")
        let portal = FakePortal(portal: "10_changed_labels", manifest: manifest)
        let repairer = RecipeRepairer(runner: RecipeRunner(transport: portal, values: values), planner: HeuristicPlanner())
        let outcome = await repairer.runWithRepair(recipe, intent: intent)
        XCTAssertEqual(outcome.run.outcome, .success, "\(outcome.run.reason)")
        guard let patched = outcome.patchedRecipe, case .tap(let tap) = patched.stages[0].actions[2] else {
            return XCTFail("kein Patch")
        }
        XCTAssertEqual(tap.target.labelAny, ["Connect", "Verbinden", "Join Wi-Fi"])
        // Neu gespeichertes Recipe läuft künftig ohne AI auf beiden Varianten.
        for fixture in ["05_hotel", "10_changed_labels"] {
            let replay = await RecipeRunner(transport: FakePortal(portal: fixture, manifest: manifest), values: values).run(patched)
            XCTAssertEqual(replay.outcome, .success, fixture)
        }
    }

    func testPromptRenderingHasNoValues() throws {
        var html = try FakePortal.fixtureHTML("11_hidden_csrf")
        html = html.replacingOccurrences(of: "{{csrf}}", with: "TOKEN-XYZ")
        let page = try PortalNormalizer.normalize(html: html, url: URL(string: "http://portal.test/login?mac=02:00:00:00:00:01")!)
        let text = PageRenderer.render(page)
        XCTAssertTrue(text.contains("concept=username"))
        XCTAssertTrue(text.contains("concept=password"))
        XCTAssertFalse(text.contains("TOKEN-XYZ"))
        XCTAssertFalse(text.contains("mac="))
    }

    func testIntentSummary() {
        XCTAssertEqual(intent.summaryLines.prefix(4), [
            "✓ Nutzungsbedingungen akzeptieren", "✓ Datenschutzhinweis akzeptieren",
            "? Zimmernummer bei Bedarf abfragen", "🔐 Nachname sicher gespeichert verwenden",
        ])
        XCTAssertEqual(intent.summaryLines.last, "✗ Keine Werbe- oder Newsletter-Einwilligung")
    }
}

/// Planner, der immer scheitert (Modell nicht verfügbar).
struct FailingPlanner: PortalPlanner {
    func nextPlan(_ input: PlanningInput) async throws -> PortalPlan { throw PlannerError.modelUnavailable }
    func repairTarget(old: Target, opcode: PortalAction.Opcode, intent: PortalIntent, page: PortalPage) async throws -> RepairSuggestion? {
        throw PlannerError.modelUnavailable
    }
}

/// Planner, der „alle Haken setzen“ wörtlich nimmt (S10). Muss abgelehnt werden.
struct GreedyPlanner: PortalPlanner {
    func nextPlan(_ input: PlanningInput) async throws -> PortalPlan {
        let checks = input.page.interactiveControls.filter { $0.role == .checkbox }
            .map { PlannedAction(kind: .check, elementId: $0.elementId) }
        return PortalPlan(reasoningSummary: "Alle Haken", actions: Array(checks.prefix(4)), expectedTransition: .newPage)
    }
    func repairTarget(old: Target, opcode: PortalAction.Opcode, intent: PortalIntent, page: PortalPage) async throws -> RepairSuggestion? { nil }
}

final class FallbackPlannerTests: XCTestCase {
    func testFallsBackWhenModelFails() async throws {
        let manifest = try PortalManifest.load()
        let portal = FakePortal(portal: "02_terms", manifest: manifest)
        let intent = PortalIntent(instructions: [.acceptRequiredTerms, .submit], bindings: [:], originalInstruction: "AGB")
        let learning = await LearningRunner(runner: RecipeRunner(transport: portal, values: StaticValueProvider()),
                                            planner: FallbackPlanner(primary: FailingPlanner()))
            .learn(intent: intent, profileId: UUID(), name: "x", ssid: "x")
        XCTAssertEqual(learning.run.outcome, .success, "\(learning.run.reason)")
        XCTAssertNotNil(learning.recipe)
    }
}
