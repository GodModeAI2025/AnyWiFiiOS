import XCTest

/// End-to-End im Simulator gegen tools/test-portal (Phase 3/4 Abnahme):
/// Profil im Chat anlegen → Lernlauf → Anmeldung → „Verbunden“.
/// Erwartet das Testportal auf http://127.0.0.1:8080 mit `--portal 02_terms` (siehe CI).
final class CaptiveAIUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    func testCreateProfileInChatAndLoginAgainstTestPortal() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-CaptiveAIProbeURL", "http://127.0.0.1:8080/hotspot-detect.html",
            "-CaptiveAIInMemoryStore", "YES",
            "-AppleLanguages", "(de)", "-AppleLocale", "de_DE",
        ]
        app.launch()

        let newProfile = element(app, "root.newProfile")
        XCTAssertTrue(newProfile.waitForExistence(timeout: 20))
        newProfile.tap()

        let name = element(app, "setup.name")
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        name.typeText("Testportal")
        let ssid = element(app, "setup.ssid")
        ssid.tap()
        ssid.typeText("TestWLAN")

        let input = element(app, "setup.input")
        input.tap()
        input.typeText("AGB akzeptieren und verbinden")
        element(app, "setup.send").tap()

        // „Speichern“ wird erst aktiv, wenn der Chat die Anweisung verstanden hat (Entwurf nicht leer).
        // Die Zusammenfassung selbst liegt in der lazy gerenderten Form ggf. außerhalb des sichtbaren Bereichs.
        let save = element(app, "setup.save")
        let enabled = expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: save)
        wait(for: [enabled], timeout: 30)
        save.tap()

        let login = element(app, "detail.login")
        if !login.waitForExistence(timeout: 10) {
            // iPhone: Detail ggf. erst über die Liste öffnen.
            app.staticTexts["Testportal"].firstMatch.tap()
        }
        XCTAssertTrue(login.waitForExistence(timeout: 10))
        login.tap()

        let outcome = element(app, "detail.outcome")
        XCTAssertTrue(outcome.waitForExistence(timeout: 60), "Kein Ergebnis angezeigt")
        let reason = element(app, "detail.reason")
        XCTAssertTrue(outcome.label.contains("Verbunden"),
                      "Ergebnis: \(outcome.label), Grund: \(reason.exists ? reason.label : "?")")
    }
}
