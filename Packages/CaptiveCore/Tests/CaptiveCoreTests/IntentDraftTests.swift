import Foundation
import XCTest
@testable import CaptiveCore

final class IntentDraftTests: XCTestCase {
    func testHotelInstructionFromSpec() {
        // Beispiel aus 01 §4.2.
        let text = """
        Datenschutz und Nutzungsbedingungen akzeptieren. Danach Zimmernummer und Nachname eintragen. \
        Nach der Zimmernummer fragst du mich bei jedem Aufenthalt. Nachname darf gespeichert werden. \
        Dann auf Verbinden drücken.
        """
        let draft = InstructionParser.parse(text)
        XCTAssertTrue(draft.acceptTerms)
        XCTAssertTrue(draft.acceptPrivacy)
        XCTAssertFalse(draft.allowMarketing)
        XCTAssertEqual(Set(draft.fields.map(\.concept)), [.roomNumber, .lastName])

        let intent = draft.makeIntent(keychainPrefix: "p1", originalInstruction: text)
        XCTAssertEqual(intent.bindings[.lastName], .keychain("p1.lastName"))
        XCTAssertEqual(draft.credentialSlots(keychainPrefix: "p1").map(\.key), ["p1.lastName"])
    }

    func testAskVersusRemember() {
        let draft = InstructionParser.parse("Zimmernummer fragen, Nachname speichern, dann verbinden")
        XCTAssertEqual(draft.fields, [.init(concept: .roomNumber, storage: .askEachTime),
                                      .init(concept: .lastName, storage: .remember)])
        XCTAssertNil(draft.followUpQuestion)
        let intent = draft.makeIntent(keychainPrefix: "x", originalInstruction: "")
        XCTAssertEqual(intent.bindings[.roomNumber], .askWhenMissing)
        XCTAssertEqual(intent.instructions.last, .submit)
    }

    func testUndecidedFieldTriggersFollowUp() {
        let draft = InstructionParser.parse("Voucher eintragen und weiter")
        XCTAssertEqual(draft.fields.map(\.concept), [.voucherCode])
        XCTAssertEqual(draft.followUpQuestion, "Soll ich Voucher speichern oder bei jeder Anmeldung fragen?")
    }

    func testUsernamePassword() {
        let draft = InstructionParser.parse("Benutzername und Passwort speichern und Login drücken")
        XCTAssertEqual(Set(draft.fields.map(\.concept)), [.username, .password])
    }

    func testDraftIsCodableForChatHistory() throws {
        let draft = InstructionParser.parse("AGB akzeptieren, Zimmernummer fragen")
        let data = try JSONEncoder().encode(draft)
        XCTAssertEqual(try JSONDecoder().decode(IntentDraft.self, from: data), draft)
    }
}
