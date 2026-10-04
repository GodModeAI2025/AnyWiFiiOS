import Foundation
import XCTest
@testable import CaptiveCore

/// 02 §22 „Security Validator“, 01 §19 Consent-Regeln, 01 §24/§25.
final class RecipeValidatorTests: XCTestCase {
    private var validator: RecipeValidator!

    override func setUpWithError() throws {
        validator = RecipeValidator(keychainBindings: try Fixtures.bindings())
    }

    func testValidRecipesHaveNoIssues() throws {
        for file in try Fixtures.recipeFiles("valid") {
            let recipe = try PRLCodec.decode(yaml: String(contentsOf: file, encoding: .utf8))
            XCTAssertEqual(validator.validate(recipe), [], file.baseName)
        }
    }

    /// Jede Datei in invalid-policy/ braucht hier eine Erwartung.
    func testPolicyFixturesTriggerExpectedRule() throws {
        let expected: [String: ValidationIssue.Code] = [
            "ask_concept_mismatch": .askConceptMismatch,
            "javascript_literal": .scriptContent,
            "keychain_concept_mismatch": .keychainConceptMismatch,
            "literal_password": .literalForSensitiveConcept,
            "marketing_check": .optionalConsentWithoutPermission,
            "paid_upgrade_tap": .commercialAction,
            "selector_only_target": .selectorOnlyTarget,
            "too_many_total_actions": .tooManyActions,
            "unknown_keychain_key": .unknownKeychainKey,
        ]
        let files = try Fixtures.recipeFiles("invalid-policy")
        XCTAssertEqual(Set(files.map(\.baseName)), Set(expected.keys))
        for file in files {
            let recipe = try PRLCodec.decode(yaml: String(contentsOf: file, encoding: .utf8))
            let codes = validator.validate(recipe).map(\.code)
            XCTAssertTrue(codes.contains(expected[file.baseName]!), "\(file.baseName): \(codes)")
        }
    }

    func testMarketingConsentAllowedOnlyWithExplicitPolicy() throws {
        let recipe = try Fixtures.recipe("invalid-policy", "marketing_check")
        var permissive = validator!
        permissive.policy.allowOptionalMarketingConsent = true
        XCTAssertEqual(permissive.validate(recipe), [])
    }

    func testPaidUpgradeIsBlockedEvenWithMarketingPolicy() throws {
        let recipe = try Fixtures.recipe("invalid-policy", "paid_upgrade_tap")
        var permissive = validator!
        permissive.policy.allowOptionalMarketingConsent = true
        XCTAssertTrue(permissive.validate(recipe).contains { $0.code == .commercialAction })
    }

    func testCommercialSelectOptionIsBlocked() {
        let recipe = makeRecipe([
            .select(SelectAction(target: Target(role: .select, labelAny: ["Tarif"]),
                                 option: OptionSpec(labelAny: ["24 Stunden – 4,99 €"]))),
        ])
        XCTAssertEqual(validator.validate(recipe).map(\.code), [.commercialAction])
    }

    func testWordBoundariesAvoidFalsePositives() {
        XCTAssertFalse(ConsentClassifier.isCommercial(["Display settings", "Continue with free Wi-Fi"]))
        XCTAssertFalse(ConsentClassifier.isMarketing(["Accept required Terms", "Datenschutz"]))
        XCTAssertTrue(ConsentClassifier.isCommercial(["Upgrade to Premium"]))
        XCTAssertTrue(ConsentClassifier.isCommercial(["Nur 9,99 €"]))
        XCTAssertTrue(ConsentClassifier.isMarketing(["Subscribe to newsletter"]))
        XCTAssertTrue(ConsentClassifier.isMarketing(["Ich möchte Angebote erhalten"]))
    }

    func testKeychainValueNeedsConceptTarget() {
        let recipe = makeRecipe([
            .fill(FillAction(target: Target(nameAny: ["pw"]), value: .keychain("corp.password"))),
        ])
        XCTAssertEqual(validator.validate(recipe).map(\.code), [.keychainValueWithoutConcept])
    }

    func testLiteralWithoutConceptIsAllowed() {
        let recipe = makeRecipe([
            .fill(FillAction(target: Target(nameAny: ["language"]), value: .literal("de"))),
        ])
        XCTAssertEqual(validator.validate(recipe), [])
    }

    func testDuplicateStageIdsAndEmptyTargets() {
        var recipe = makeRecipe([.tap(TargetAction(target: Target()))])
        recipe.stages.append(recipe.stages[0])
        let codes = validator.validate(recipe).map(\.code)
        XCTAssertTrue(codes.contains(.duplicateStageId), "\(codes)")
        XCTAssertTrue(codes.contains(.emptyTarget), "\(codes)")
    }

    func testWaitTimeoutRange() {
        let recipe = makeRecipe([.waitFor(WaitCondition(redirect: true, timeoutSeconds: 120))])
        XCTAssertEqual(validator.validate(recipe).map(\.code), [.timeoutOutOfRange])
    }

    func testScriptMarkersAnywhereAreRejected() {
        let recipe = makeRecipe([
            .tap(TargetAction(target: Target(role: .link, labelAny: ["<SCRIPT>alert(1)</script>"]))),
        ])
        XCTAssertEqual(validator.validate(recipe).map(\.code), [.scriptContent])
    }

    private func makeRecipe(_ actions: [PortalAction]) -> Recipe {
        Recipe(
            profileId: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
            name: "Test",
            network: NetworkSpec(ssid: "Test"),
            stages: [Stage(id: "main", actions: actions)],
            success: SuccessCriteria(internetAccess: true)
        )
    }
}
