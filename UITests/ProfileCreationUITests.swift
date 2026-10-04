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

/// Phase-4-Abnahme: Replay gegen tools/test-portal im Simulator (Server auf Port 8099 nötig).
final class ManualModeUITests: XCTestCase {
    static let portal = "http://127.0.0.1:8099"

    override func setUp() { continueAfterFailure = false }

    private func resetPortal(_ scenario: String) {
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: URL(string: "\(Self.portal)/_control/reset?scenario=\(scenario)")!) { _, _, _ in sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 5)
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-seedHotel", "-probeURL", "\(Self.portal)/hotspot-detect.html"]
        app.launch()
        return app
    }

    @MainActor private func loginWithRoom(_ app: XCUIApplication) {
        app.buttons["login-now"].tap()
        let field = app.textFields["ask-value"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Zimmernummer wird erfragt (P9)")
        field.tap()
        field.typeText("417")
        app.buttons["ask-submit"].tap()
    }

    @MainActor func testLearnThenReplayWithoutModel() {
        resetPortal("hotel")
        let app = launch()
        XCTAssertTrue(app.staticTexts["Testhotel"].firstMatch.waitForExistence(timeout: 10))
        app.staticTexts["Testhotel"].firstMatch.tap()

        loginWithRoom(app)
        let status = app.staticTexts["login-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        XCTAssertTrue(status.label.contains("gelernt"), "Erster Lauf lernt: \(status.label)")

        // Zweiter Lauf: Portal zurücksetzen, Recipe wird ohne Lernen abgespielt.
        resetPortal("hotel")
        loginWithRoom(app)
        let again = app.staticTexts["login-status"]
        XCTAssertTrue(again.waitForExistence(timeout: 20))
        let deadline = Date().addingTimeInterval(20)
        while again.label.contains("gelernt") == false && !again.label.hasPrefix("Angemeldet") && Date() < deadline { usleep(200_000) }
        XCTAssertTrue(again.label.hasPrefix("Angemeldet"))
        XCTAssertFalse(again.label.contains("gelernt"), "Zweiter Lauf nutzt das Recipe: \(again.label)")

        app.tabBars.buttons["Aktivität"].tap()
        XCTAssertTrue(app.otherElements["activity-list"].waitForExistence(timeout: 5) || app.collectionViews["activity-list"].waitForExistence(timeout: 5))
    }
}

/// Phase 5: Der Chat öffnet sich. Ohne Modell (Simulator) ist er deaktiviert, der Erweitert-Editor bleibt nutzbar.
final class ChatUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testChatOpensAndDegradesGracefully() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitest", "-seedHotel"]
        app.launch()
        app.staticTexts["Testhotel"].firstMatch.tap()
        let chat = app.buttons["open-chat"]
        for _ in 0..<6 where !chat.exists || !chat.isHittable { app.swipeUp() }
        chat.tap()
        let input = app.textFields["chat-input"]
        let unavailable = app.staticTexts["Chat nicht verfügbar"]
        XCTAssertTrue(input.waitForExistence(timeout: 10) || unavailable.waitForExistence(timeout: 5))
        app.buttons["Schließen"].tap()
        let adv = app.buttons["open-advanced"]
        for _ in 0..<6 where !adv.exists || !adv.isHittable { app.swipeUp() }
        adv.tap()
        XCTAssertTrue(app.textViews["recipe-text"].waitForExistence(timeout: 5))
    }
}
