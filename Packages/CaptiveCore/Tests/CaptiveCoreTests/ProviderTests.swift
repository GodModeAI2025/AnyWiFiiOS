import Testing
import Foundation
@testable import CaptiveCore

final class CapturingNotifier: UserNotifier, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, String, UUID)] = []
    var messages: [(profile: String, prompt: String, runId: UUID)] { lock.withLock { items.map { (profile: $0.0, prompt: $0.1, runId: $0.2) } } }
    func notifyValueNeeded(profileName: String, prompt: String, runId: UUID) async { lock.withLock { items.append((profileName, prompt, runId)) } }
}

struct HangingTransport: PortalTransport {
    func send(_ request: PortalRequest) async throws -> PortalResponse {
        try await Task.sleep(for: .seconds(30))
        return PortalResponse(url: request.url, status: 200)
    }
}

private func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("prov-\(UUID().uuidString)", isDirectory: true) }

private struct Rig {
    var core: AuthenticationCore
    var profiles: ProfileStore
    var secrets: InMemorySecretStore
    var pending: PendingStore
    var notifier: CapturingNotifier

    init(profile: PortalProfile?, secrets initial: [String: String] = ["hotel.lastName": "Example"],
         authenticateBudget: Duration = .seconds(10), presentUIBudget: Duration = .seconds(5), allowLearning: Bool = true) throws {
        let base = tmp()
        profiles = ProfileStore(directory: base.appendingPathComponent("p"))
        pending = PendingStore(directory: base.appendingPathComponent("pending"))
        secrets = InMemorySecretStore(initial)
        notifier = CapturingNotifier()
        if let profile { try profiles.save(profile) }
        core = AuthenticationCore(profiles: profiles, runLogs: RunLogStore(directory: base.appendingPathComponent("logs")),
                                  pending: pending, secrets: secrets, notifier: notifier,
                                  authenticateBudget: authenticateBudget, presentUIBudget: presentUIBudget,
                                  pollInterval: .milliseconds(20), allowLearningInProvider: allowLearning)
    }
}

private func hotelProfile(recipe: Bool = false, enabled: Bool = true) async -> PortalProfile {
    var p = PortalProfile(name: "Hotel Muster", enabled: enabled, network: .init(ssidExact: "Hotel_Guest"), intent: Kit.hotelIntent,
                          credentialBindings: [Kit.lastNameBinding,
                                               CredentialBinding(concept: "roomNumber", keychainKey: "hotel.room", prompt: "Zimmernummer", persistence: .askEveryTime)])
    if recipe {
        let r = await LoginCoordinator(transport: MockPortalSite(steps: Scenarios.hotel), secrets: InMemorySecretStore(["hotel.lastName": "Example"]))
            .login(profile: p, askValues: ["roomNumber": "417"])
        p = r.profile
        p.enabled = enabled
    }
    return p
}

@Suite struct EvaluationTests {
    @Test func claimsOnlyExactSSIDOfEnabledProfiles() async throws {
        let rig = try Rig(profile: await hotelProfile())
        let e = EvaluationCore(profiles: rig.profiles)
        #expect(e.confidence(ssid: "Hotel_Guest") == .high)
        #expect(e.confidence(ssid: "hotel_guest") == .none)
        #expect(e.confidence(ssid: "Other") == .none)
        #expect(e.confidence(ssid: nil) == .none)
        #expect(e.confidence(ssid: "") == .none)
    }

    @Test func disabledProfilesAreNeverClaimed() async throws {
        let rig = try Rig(profile: await hotelProfile(enabled: false))
        #expect(EvaluationCore(profiles: rig.profiles).confidence(ssid: "Hotel_Guest") == .none)
    }

    @Test func scanListFilterKeepsOnlyConfiguredNetworks() async throws {
        let rig = try Rig(profile: await hotelProfile())
        let list: [(ssid: String, bssid: String?)] = [("Cafe", nil), ("Hotel_Guest", nil), ("Hotel_Guest_5G", nil)]
        #expect(EvaluationCore(profiles: rig.profiles).filter(list) == [1])
    }
}

@Suite struct AuthenticationProviderTests {
    @Test func unknownNetworkIsNotRecognized() async throws {
        let rig = try Rig(profile: await hotelProfile())
        let r = await rig.core.authenticate(ssid: "Other", transport: MockPortalSite(steps: Scenarios.hotel))
        #expect(r.hotspot == .commandNotRecognized)
    }

    @Test func recipeRunSucceedsWithoutModel() async throws {
        let rig = try Rig(profile: await hotelProfile(recipe: true))
        let r = await rig.core.authenticate(ssid: "Hotel_Guest", transport: MockPortalSite(steps: Scenarios.hotel), askValues: ["roomNumber": "417"])
        #expect(r.hotspot == .success)
        #expect(r.outcome == .success)
    }

    /// Gate S4: fehlender Wert → uiRequired → App liefert Wert → presentUI führt zu Ende.
    @Test func missingValueFlowEndToEnd() async throws {
        let rig = try Rig(profile: await hotelProfile(recipe: true))
        let site = MockPortalSite(steps: Scenarios.hotel)

        let first = await rig.core.authenticate(ssid: "Hotel_Guest", transport: site)
        #expect(first.hotspot == .uiRequired)
        let runId = try #require(first.runId)
        let pend = try #require(rig.pending.read(runId))
        #expect(pend.status == .awaitingUser)
        #expect(pend.requiredConcept == "roomNumber")

        // Notification: Profil und Frage, nie ein Wert
        let note = try #require(rig.notifier.messages.first)
        #expect(note.profile == "Hotel Muster")
        #expect(note.prompt == "Zimmernummer")
        #expect(await site.log.allSatisfy { $0.method != "POST" })

        // Die App schreibt den Wert in den Keychain und setzt nur die Referenz in den Pending-Eintrag.
        let key = PendingAuthentication.valueKey(runId: runId, concept: "roomNumber")
        try rig.secrets.write("417", for: key)
        #expect(rig.pending.transition(runId, to: .valueProvided, valueKey: key))
        let pendingJSON = String(decoding: try Data(contentsOf: rig.pending.directory.appendingPathComponent("\(runId.uuidString).json")), as: UTF8.self)
        #expect(!pendingJSON.contains("417"))

        let done = await rig.core.presentUI(runId: runId, ssid: "Hotel_Guest", transport: site)
        #expect(done.hotspot == .success)
        #expect(await site.log.filter { $0.method == "POST" }.count == 1, "keine zweite Anmeldung")
        #expect(!rig.secrets.contains(key), "Wert wird nach Gebrauch gelöscht")
        #expect(rig.pending.read(runId) == nil)
    }

    @Test func presentUIWaitsForValueAndExpires() async throws {
        let rig = try Rig(profile: await hotelProfile(recipe: true), presentUIBudget: .milliseconds(150))
        let site = MockPortalSite(steps: Scenarios.hotel)
        let first = await rig.core.authenticate(ssid: "Hotel_Guest", transport: site)
        let runId = try #require(first.runId)
        let r = await rig.core.presentUI(runId: runId, ssid: "Hotel_Guest", transport: site)
        #expect(r.hotspot == .failure)
        #expect(rig.pending.read(runId)?.status == .expired)
    }

    @Test func budgetCutsOffBeforeSystemLimit() async throws {
        let rig = try Rig(profile: await hotelProfile(recipe: true), authenticateBudget: .milliseconds(200))
        let t0 = ContinuousClock.now
        let r = await rig.core.authenticate(ssid: "Hotel_Guest", transport: HangingTransport())
        #expect(r.hotspot == .temporaryFailure)
        #expect(r.outcome == .timeout)
        #expect(ContinuousClock.now - t0 < .seconds(3))
    }

    @Test func unsupportedPortalMapsToUnsupportedNetwork() async throws {
        var p = await hotelProfile()
        p.network = .init(ssidExact: "Hotel_Guest")
        let rig = try Rig(profile: p)
        let r = await rig.core.authenticate(ssid: "Hotel_Guest", transport: MockPortalSite(steps: Scenarios.js))
        #expect(r.hotspot == .unsupportedNetwork)
    }

    @Test func learningCanBeDisabledInProvider() async throws {
        let rig = try Rig(profile: await hotelProfile(), allowLearning: false)
        let site = MockPortalSite(steps: Scenarios.hotel)
        let r = await rig.core.authenticate(ssid: "Hotel_Guest", transport: site)
        #expect(r.hotspot == .uiRequired)
        #expect(await site.log.isEmpty)
    }

    @Test func maintainDetectsCaptivityAgain() async throws {
        let rig = try Rig(profile: await hotelProfile(recipe: true))
        let site = MockPortalSite(steps: Scenarios.clickthrough)
        #expect(await rig.core.maintain(transport: site) == .authenticationRequired)
        let login = await Kit.engine(site).learn(intent: Kit.intent([]), planner: HeuristicPlanner())
        #expect(login.outcome == .success)
        #expect(await rig.core.maintain(transport: site) == .success)
        #expect(await rig.core.maintain(transport: HangingFailTransport()) == .temporaryFailure)
        #expect(rig.core.logoff() == .success)
    }
}

struct HangingFailTransport: PortalTransport {
    func send(_ request: PortalRequest) async throws -> PortalResponse { throw PortalError.network("offline") }
}

@Suite struct PendingStoreTests {
    @Test func transitionsOnlyMoveForward() throws {
        let store = PendingStore(directory: tmp())
        let p = PendingAuthentication(profileId: UUID(), profileName: "x", requiredConcept: "roomNumber", prompt: "Zimmer")
        try store.write(p)
        #expect(store.transition(p.runId, to: .valueProvided, valueKey: "k"))
        #expect(!store.transition(p.runId, to: .awaitingUser))
        #expect(store.transition(p.runId, to: .completed))
        #expect(!store.transition(p.runId, to: .failed), "Endzustände bleiben")
        #expect(store.read(p.runId)?.status == .completed)
        #expect(!store.transition(UUID(), to: .completed))
    }

    @Test func concurrentWritesStayIntactAndCorruptFilesAreIgnored() async throws {
        let dir = tmp()
        let store = PendingStore(directory: dir)
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<40 {
                g.addTask { try? store.write(PendingAuthentication(profileId: UUID(), profileName: "p\(i)", requiredConcept: "c", prompt: "q")) }
            }
        }
        try Data("{kaputt".utf8).write(to: dir.appendingPathComponent("bad.json"))
        #expect(store.all().count == 40)
        #expect(store.awaiting().count == 40)
    }

    @Test func awaitingHonorsAgeAndPurge() throws {
        let store = PendingStore(directory: tmp())
        let old = PendingAuthentication(profileId: UUID(), profileName: "alt", requiredConcept: "c", prompt: "q", createdAt: Date().addingTimeInterval(-7200))
        let fresh = PendingAuthentication(profileId: UUID(), profileName: "neu", requiredConcept: "c", prompt: "q")
        try store.write(old); try store.write(fresh)
        #expect(store.awaiting().map(\.profileName) == ["neu"])
        store.purge()
        #expect(store.all().map(\.profileName) == ["neu"])
    }
}
