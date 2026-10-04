import Foundation
import XCTest
@testable import CaptiveCore

/// Gate S6 (02 §12): Provider schreibt Pending → App liest → App ergänzt → Provider liest.
final class PendingAuthenticationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("pending-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testHandOffBetweenProviderAndApp() throws {
        let store = PendingAuthenticationStore(directory: directory)
        let runId = UUID()
        let t0 = Date(timeIntervalSince1970: 1_000)

        // Provider: Zimmernummer fehlt → uiRequired
        try store.save(PendingAuthentication(runId: runId, profileId: UUID(), requiredConcept: .roomNumber,
                                             status: .awaitingUser, updatedAt: t0))
        // App: offene Anfrage sehen
        let open = try store.openRequests()
        XCTAssertEqual(open.map(\.runId), [runId])
        XCTAssertEqual(open[0].notificationText(profileName: "Hotel Muster"),
                       "Hotel Muster benötigt Zimmernummer für die WLAN-Anmeldung.")

        // App: Wert liegt im Keychain, nur die Referenz kommt in die Datei
        var answered = open[0]
        answered.status = .valueProvided
        answered.valueKeychainKey = "pending.\(runId.uuidString).roomNumber"
        answered.updatedAt = t0.addingTimeInterval(5)
        try store.save(answered)

        // Provider: liest die Antwort
        let seen = try XCTUnwrap(store.load(runId: runId))
        XCTAssertEqual(seen.status, .valueProvided)
        XCTAssertTrue(try store.openRequests().isEmpty)

        // Ein verspäteter alter Stand darf den neuen nicht überschreiben
        var stale = answered
        stale.status = .awaitingUser
        stale.updatedAt = t0
        XCTAssertThrowsError(try store.save(stale)) { XCTAssertEqual($0 as? PendingAuthenticationStore.Failure, .staleUpdate) }

        try store.remove(runId: runId)
        XCTAssertNil(try store.load(runId: runId))
    }

    func testFileNeverContainsValues() throws {
        let store = PendingAuthenticationStore(directory: directory)
        let runId = UUID()
        try store.save(PendingAuthentication(runId: runId, profileId: UUID(), requiredConcept: .roomNumber,
                                             status: .valueProvided, valueKeychainKey: "pending.x", updatedAt: Date()))
        let raw = try String(contentsOf: store.url(for: runId), encoding: .utf8)
        XCTAssertFalse(raw.contains("417"))
        XCTAssertTrue(raw.contains("\"valueKeychainKey\":\"pending.x\""))
    }
}
