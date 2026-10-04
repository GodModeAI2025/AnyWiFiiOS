import Foundation
import XCTest
@testable import CaptiveCore

/// 02 §22 „Trace Compiler“ und 02 §23: Lernlauf → Recipe → Replay ohne AI.
final class TraceCompilerTests: XCTestCase {
    private let base = URL(string: "http://portal.test/portal")!

    private func page(_ fixture: String) throws -> PortalPage {
        var html = try FakePortal.fixtureHTML(fixture)
        html = html.replacingOccurrences(of: "{{csrf}}", with: "tok123").replacingOccurrences(of: "{{stage_token}}", with: "st456")
        return try PortalNormalizer.normalize(html: html, url: base)
    }

    private func id(_ page: PortalPage, _ predicate: (PortalControl) -> Bool) -> String {
        page.interactiveControls.first(where: predicate)!.elementId
    }

    private func hotelTrace() throws -> [LearnedPage] {
        let p = try page("05_hotel")
        return [LearnedPage(page: p, actions: [
            LearnedAction(kind: .fill, elementId: id(p) { $0.concept == .roomNumber }, value: .ask(.roomNumber)),
            LearnedAction(kind: .fill, elementId: id(p) { $0.concept == .lastName }, value: .keychain("hotel.lastName")),
            LearnedAction(kind: .tap, elementId: id(p) { $0.role == .button }),
        ])]
    }

    func testCompiledRecipeUsesSemanticTargetsAndNoVolatileData() throws {
        let recipe = try TraceCompiler.compile(try hotelTrace(), profileId: UUID(), name: "Hotel", ssid: "Hotel_Guest")
        XCTAssertEqual(recipe.stages.map(\.id), ["guest"])
        XCTAssertEqual(recipe.stages[0].match?.fields, [.roomNumber, .lastName])
        guard case .fill(let room) = recipe.stages[0].actions[0] else { return XCTFail() }
        XCTAssertEqual(room.target.concept, .roomNumber)
        XCTAssertEqual(room.target.labelAny, ["Room number"])
        XCTAssertEqual(room.target.nameAny, ["room"])
        XCTAssertEqual(room.target.lastKnownSelector, "#room")
        XCTAssertEqual(room.value, .ask(.roomNumber))

        let yaml = try PRLCodec.encode(recipe)
        XCTAssertFalse(yaml.contains("fixture"), "Hidden Fields gehören nicht ins Recipe")
        XCTAssertEqual(RecipeValidator(keychainBindings: ["hotel.lastName": .lastName]).validate(recipe), [])
    }

    func testCsrfTokensAreNotStored() throws {
        let p = try page("11_hidden_csrf")
        let trace = [LearnedPage(page: p, actions: [
            LearnedAction(kind: .fill, elementId: id(p) { $0.concept == .username }, value: .keychain("corp.username")),
            LearnedAction(kind: .fill, elementId: id(p) { $0.concept == .password }, value: .keychain("corp.password")),
            LearnedAction(kind: .tap, elementId: id(p) { $0.role == .button }),
        ])]
        let yaml = try PRLCodec.encode(TraceCompiler.compile(trace, profileId: UUID(), name: "Corp", ssid: "Corp"))
        XCTAssertFalse(yaml.contains("tok123"))
        XCTAssertFalse(yaml.contains("csrf"))
    }

    func testLiteralForSensitiveFieldIsRejected() throws {
        let p = try page("04_userpass")
        let trace = [LearnedPage(page: p, actions: [
            LearnedAction(kind: .fill, elementId: id(p) { $0.concept == .password }, value: .literal("SuperSecret123")),
        ])]
        XCTAssertThrowsError(try TraceCompiler.compile(trace, profileId: UUID(), name: "x", ssid: "x")) { error in
            XCTAssertEqual(error as? TraceCompiler.Failure, .literalForSensitiveField(page: 0, action: 0))
        }
    }

    /// Integration (02 §23): Lernlauf → Recipe → Replay ohne AI gegen das Fake-Portal.
    func testCompiledMultistageRecipeReplaysWithoutAI() async throws {
        let p1 = try page("08_multistage_terms")
        let p2 = try page("09_multistage_guest")
        let trace = [
            LearnedPage(page: p1, actions: [
                LearnedAction(kind: .check, elementId: id(p1) { $0.role == .checkbox }),
                LearnedAction(kind: .tap, elementId: id(p1) { $0.role == .button }),
            ]),
            LearnedPage(page: p2, actions: [
                LearnedAction(kind: .fill, elementId: id(p2) { $0.concept == .roomNumber }, value: .ask(.roomNumber)),
                LearnedAction(kind: .fill, elementId: id(p2) { $0.concept == .lastName }, value: .keychain("hotel.lastName")),
                LearnedAction(kind: .tap, elementId: id(p2) { $0.role == .button }),
            ]),
        ]
        let recipe = try TraceCompiler.compile(trace, profileId: UUID(), name: "Hotel", ssid: "Hotel_Guest")
        XCTAssertEqual(recipe.stages.map(\.id), ["consent", "guest"])
        // Roundtrip über YAML, wie beim Speichern.
        let stored = try PRLCodec.decode(yaml: PRLCodec.encode(recipe))

        let manifest = try PortalManifest.load()
        let portal = FakePortal(portal: "08_multistage_terms", manifest: manifest)
        let values = StaticValueProvider(keychain: ["hotel.lastName": manifest.testValues["lastName"]!],
                                         asked: [.roomNumber: manifest.testValues["roomNumber"]!])
        let result = await RecipeRunner(transport: portal, values: values).run(stored)
        XCTAssertEqual(result.outcome, .success, "\(result.reason)")
    }

    func testTwinButtonsGetOrdinal() throws {
        let p = try PortalNormalizer.normalize(html: "<form><button>Go</button><button>Go</button></form>", url: base)
        let target = TraceCompiler.target(for: p.interactiveControls[1], on: p)
        XCTAssertEqual(target.ordinal, 1)
        XCTAssertEqual(try ElementMatcher.resolve(target, in: p).get().control.elementId, "e2")
    }
}
