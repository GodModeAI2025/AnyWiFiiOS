import Foundation
import XCTest
@testable import CaptiveCore

/// 02 §22 „Recipe Parser“: valid YAML accepted, unknown opcode/field rejected, wrong version rejected.
final class PRLCodecTests: XCTestCase {
    func testAllValidRecipesDecode() throws {
        let files = try Fixtures.recipeFiles("valid")
        XCTAssertGreaterThanOrEqual(files.count, 12)
        for file in files {
            XCTAssertNoThrow(try PRLCodec.decode(yaml: String(contentsOf: file, encoding: .utf8)), file.baseName)
        }
    }

    func testDecodedHotelRecipeHasExpectedShape() throws {
        let recipe = try Fixtures.recipe("valid", "05_hotel")
        XCTAssertEqual(recipe.recipeVersion, 1)
        XCTAssertEqual(recipe.network.ssid, "Hotel_Guest")
        XCTAssertEqual(recipe.stages.map(\.id), ["guest"])
        XCTAssertEqual(recipe.stages[0].match?.fields, [.roomNumber, .lastName])
        XCTAssertEqual(recipe.stages[0].actions.map(\.opcode), [.fill, .fill, .tap])
        guard case .fill(let room) = recipe.stages[0].actions[0] else { return XCTFail("fill erwartet") }
        XCTAssertEqual(room.target.concept, .roomNumber)
        XCTAssertEqual(room.value, .ask(.roomNumber))
        guard case .fill(let last) = recipe.stages[0].actions[1] else { return XCTFail("fill erwartet") }
        XCTAssertEqual(last.value, .keychain("hotel.lastName"))
        XCTAssertTrue(recipe.success.internetAccess)
    }

    func testRoundTripPreservesEveryValidRecipe() throws {
        for file in try Fixtures.recipeFiles("valid") {
            let original = try PRLCodec.decode(yaml: String(contentsOf: file, encoding: .utf8))
            let yaml = try PRLCodec.encode(original)
            let again = try PRLCodec.decode(yaml: yaml)
            XCTAssertEqual(original, again, file.baseName)
        }
    }

    func testEncodedYamlHasNoNullsForAbsentOptionals() throws {
        let yaml = try PRLCodec.encode(Fixtures.recipe("valid", "01_clickthrough"))
        XCTAssertFalse(yaml.contains("null"), yaml)
        XCTAssertFalse(yaml.contains("~"), yaml)
    }

    /// Jede Datei in invalid-schema/ braucht hier eine Erwartung, damit neue Fixtures nicht ungeprüft bleiben.
    func testInvalidSchemaFixtures() throws {
        typealias Check = (Error) -> Bool
        let expectations: [String: Check] = [
            "unknown_opcode": { if case PRLError.unknownOpcode("executeScript", _) = $0 { true } else { false } },
            "unknown_field_top": { if case PRLError.unknownFields(["javascript"], _) = $0 { true } else { false } },
            "unknown_field_target": { if case PRLError.unknownFields(["xpath"], _) = $0 { true } else { false } },
            "wrong_version": { if case PRLError.unsupportedVersion(2) = $0 { true } else { false } },
            "two_opcodes_in_action": { if case PRLError.expectedSingleKey(["check", "tap"], _) = $0 { true } else { false } },
            "two_value_sources": { if case PRLError.expectedSingleKey(["ask", "literal"], _) = $0 { true } else { false } },
            "unknown_concept": { $0 is DecodingError },
        ]
        // Strukturell lesbar, Mengenlimit greift erst im Validator (Schema prüft es bereits).
        let validatorOnly: Set<String> = ["too_many_actions_in_stage"]

        let files = try Fixtures.recipeFiles("invalid-schema")
        XCTAssertEqual(Set(files.map(\.baseName)), Set(expectations.keys).union(validatorOnly))

        for file in files where !validatorOnly.contains(file.baseName) {
            let name = file.baseName
            XCTAssertThrowsError(try PRLCodec.decode(yaml: String(contentsOf: file, encoding: .utf8)), name) { error in
                XCTAssertTrue(expectations[name]?(error) ?? false, "\(name): unerwarteter Fehler \(error)")
            }
        }

        let tooMany = try Fixtures.recipe("invalid-schema", "too_many_actions_in_stage")
        let issues = RecipeValidator(keychainBindings: [:]).validate(tooMany)
        XCTAssertTrue(issues.contains { $0.code == .tooManyActions }, "\(issues)")
    }

    func testRejectsOversizedDocument() {
        let huge = String(repeating: "#", count: PRLCodec.maxDocumentBytes + 1)
        XCTAssertThrowsError(try PRLCodec.decode(yaml: huge)) { error in
            XCTAssertEqual(error as? PRLCodecError, .documentTooLarge(bytes: PRLCodec.maxDocumentBytes + 1))
        }
    }

    func testEmptySubmitDecodes() throws {
        let yaml = try Fixtures.recipeText("valid", "02_terms")
            .replacingOccurrences(of: "      - tap:\n          target:\n            role: button\n            labelAny: [Continue, Weiter]\n",
                                  with: "      - submit: {}\n")
        let recipe = try PRLCodec.decode(yaml: yaml)
        XCTAssertEqual(recipe.stages[0].actions.last, .submit(SubmitAction()))
        XCTAssertEqual(try PRLCodec.decode(yaml: PRLCodec.encode(recipe)), recipe)
    }
}
