import XCTest

final class ProfileCreationUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Phase-3-Abnahme: Profil anlegen.
    @MainActor func testCreateProfile() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest"]
        app.launch()

        let new = app.buttons["new-profile"].firstMatch.exists ? app.buttons["new-profile"].firstMatch : app.buttons["Neues Profil"].firstMatch
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        new.tap()

        let name = app.textFields["new-profile-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Hotel Muster")
        let ssid = app.textFields["new-profile-ssid"]
        ssid.tap()
        ssid.typeText("Hotel_Guest")
        app.buttons["create-profile"].tap()

        // Nach dem Anlegen öffnet sich das Profil (iPhone: Detail wird gepusht).
        let detailName = app.textFields["detail-name"]
        XCTAssertTrue(detailName.waitForExistence(timeout: 5))
        XCTAssertEqual(detailName.value as? String, "Hotel Muster")

        // Zurück zur Liste: das Profil ist gespeichert und sichtbar.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Hotel Muster"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Hotel_Guest"].firstMatch.exists)
    }
}
