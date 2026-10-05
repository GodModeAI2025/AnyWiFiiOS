import Testing
import Foundation
@testable import CaptiveCore

@Suite struct RevisionTests {
    private func recipe(_ label: String) -> Recipe {
        Recipe(name: "n", ssid: "s", stages: [Stage(id: "a", actions: [.tap(target: Target(role: "button", labelAny: [label]))])])
    }

    @Test func commitKeepsLastFiveRevisions() {
        var p = PortalProfile(name: "x", network: .init(ssidExact: "s"), intent: .init(instructions: [.submit]))
        for i in 1...8 { p.commit(recipe("L\(i)"), note: "r\(i)") }
        #expect(p.recipeRevision == 8)
        #expect(p.revisionHistory.count == PortalProfile.maxHistory)
        #expect(p.revisionHistory.map(\.revision) == [3, 4, 5, 6, 7])
    }

    @Test func rollbackCreatesNewRevisionWithOldContent() throws {
        var p = PortalProfile(name: "x", network: .init(ssidExact: "s"), intent: .init(instructions: [.submit]))
        for i in 1...3 { p.commit(recipe("L\(i)"), note: "r\(i)") }
        try p.rollback(to: 2)
        #expect(p.recipeRevision == 4)
        #expect(p.recipe == recipe("L2"))
        #expect(p.revisionHistory.last?.revision == 3)
        #expect(throws: PortalProfile.RollbackError.revisionNotFound) { try p.rollback(to: 99) }
    }

    @Test func oldProfileFilesWithoutHistoryStillDecode() throws {
        let p = PortalProfile(name: "x", network: .init(ssidExact: "s"), intent: .init(instructions: [.submit]))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        var obj = try JSONSerialization.jsonObject(with: enc.encode(p)) as! [String: Any]
        obj.removeValue(forKey: "revisionHistory")
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(PortalProfile.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(back.revisionHistory.isEmpty)
    }

    @Test func historyIsStoredInProfileFile() throws {
        var p = PortalProfile(name: "x", network: .init(ssidExact: "s"), intent: .init(instructions: [.submit]))
        p.commit(recipe("A"), note: "1"); p.commit(recipe("B"), note: "2")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rev-\(UUID().uuidString)")
        let store = ProfileStore(directory: dir)
        try store.save(p)
        #expect(try store.load(p.id).revisionHistory.count == 1)
    }
}

@Suite struct DiffTests {
    @Test func marksAddedAndRemovedLines() {
        let d = RecipeDiff.lines(old: "a\nb\nc", new: "a\nB\nc\nd")
        #expect(d.filter { $0.kind == .removed }.map(\.text) == ["b"])
        #expect(d.filter { $0.kind == .added }.map(\.text) == ["B", "d"])
        #expect(d.filter { $0.kind == .same }.map(\.text) == ["a", "c"])
        #expect(RecipeDiff.changeCount(RecipeDiff.lines(old: "x", new: "x")) == 0)
    }
}

@Suite struct StabilityTests {
    private func log(_ o: Outcome, _ minutesAgo: Int, learned: Bool = false, repaired: Bool = false) -> RunLog {
        RunLog(profileId: UUID(), profileName: "p", startedAt: Date().addingTimeInterval(Double(-minutesAgo) * 60), durationMs: 1,
               outcome: o, reason: nil, requiredConcept: nil, failedStage: nil, usedRecipe: true, recipeRevision: 1,
               events: [], learned: learned, repaired: repaired)
    }

    @Test func stableAfterFiveSuccessesInARow() {
        let logs = (0..<5).map { log(.success, $0) }
        let m = StabilityMetrics(logs: logs)
        #expect(m.isStable)
        #expect(m.streak == 5)
        #expect(m.successRate == 1)
    }

    @Test func failureOrRepairResetsTheStreak() {
        #expect(!StabilityMetrics(logs: [log(.success, 0), log(.success, 1), log(.timeout, 2)] + (3..<10).map { log(.success, $0) }).isStable)
        let repaired = (0..<5).map { log(.success, $0, repaired: $0 == 3) }
        #expect(StabilityMetrics(logs: repaired).streak == 3)
        let learned = (0..<6).map { log(.success, $0, learned: $0 == 2) }
        #expect(StabilityMetrics(logs: learned).streak == 3)
    }

    @Test func lastTenOutcomesAndRate() {
        let logs = (0..<12).map { log($0 % 2 == 0 ? .success : .networkError, $0) }
        let m = StabilityMetrics(logs: logs)
        #expect(m.lastOutcomes.count == 10)
        #expect(m.totalRuns == 12)
        #expect(m.successRate == 0.5)
    }
}

@Suite struct DebugRoundTripTests {
    /// Phase-6-Abnahme: Fehlschlag, Paket, externer Patch (Mensch oder KI-Agent), Re-Import, Erfolg.
    @Test func externalPatchRepairsFailureViaDebugBundle() async throws {
        let secrets = InMemorySecretStore(["hotel.lastName": "Example"])
        let id = UUID()
        var profile = PortalProfile(id: id, name: "Hotel", network: .init(ssidExact: "H"), intent: Kit.hotelIntent,
                                    credentialBindings: [Kit.lastNameBinding])
        let learn = await LoginCoordinator(transport: MockPortalSite(steps: Scenarios.hotel), secrets: secrets)
            .login(profile: profile, askValues: ["roomNumber": "417"])
        profile = learn.profile
        #expect(profile.recipeRevision == 1)

        // Portal ändert das Label, die automatische Reparatur ist aus: der Lauf scheitert.
        let failed = await LoginCoordinator(transport: MockPortalSite(steps: Scenarios.changed), secrets: secrets, repairer: nil)
            .login(profile: profile, askValues: ["roomNumber": "417"])
        #expect(failed.result.outcome == .recipeMismatch)
        #expect(failed.profile.recipeRevision == 1)

        // Debug-Paket erzeugen
        let (name, zip) = try DebugBundleBuilder.build(DebugBundleInput(
            profileName: profile.name, recipeRevision: profile.recipeRevision, startedAt: failed.log.startedAt,
            intent: profile.intent, recipe: profile.recipe, run: failed.result,
            environment: DebugEnvironment(appVersion: "1", osVersion: "27", device: "sim", modelAvailability: "none", mode: "manual")))
        #expect(name.hasSuffix(".zip"))
        let files = Dictionary(uniqueKeysWithValues: try ZipArchive.read(zip).map { ($0.path, String(decoding: $0.data, as: UTF8.self)) })
        let summary = try JSONSerialization.jsonObject(with: Data(files["summary.json"]!.utf8)) as! [String: Any]
        #expect(summary["outcome"] as? String == "recipeMismatch")
        #expect(files["pages/01.yaml"]!.contains("Join Wi-Fi"))
        #expect(files["trace.jsonl"] != nil)

        // Externer Agent: liest recipe.yaml, erweitert das Button-Label, gibt recipe.yaml zurück.
        var lines = files["recipe.yaml"]!.components(separatedBy: "\n")
        let at = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "- Connect" })
        lines.insert(lines[at].replacingOccurrences(of: "Connect", with: "Join Wi-Fi"), at: at + 1)
        let patched = lines.joined(separator: "\n")
        let preview = RecipeImporter.prepare(yaml: patched, for: profile)
        #expect(preview.isValid, "\(preview.issues)")
        #expect(preview.matchesProfile)
        #expect(RecipeDiff.changeCount(preview.diff) > 0)
        let imported = try RecipeImporter.apply(preview, to: profile)
        #expect(imported.recipeRevision == 2)
        #expect(imported.revisionHistory.last?.revision == 1)

        // Erneuter Test: Erfolg ohne Reparatur und ohne Modell.
        let again = await LoginCoordinator(transport: MockPortalSite(steps: Scenarios.changed), secrets: secrets, repairer: nil)
            .login(profile: imported, askValues: ["roomNumber": "417"])
        #expect(again.result.outcome == .success)
        #expect(again.result.modelCalls == 0)
        #expect(again.repairedWith == nil)
    }

    @Test func importRejectsUnsafeOrBrokenRecipes() async throws {
        let profile = PortalProfile(name: "H", network: .init(ssidExact: "H"), intent: .init(instructions: [.submit]),
                                    credentialBindings: [Kit.lastNameBinding])
        let paid = """
        recipeVersion: 1
        name: x
        network: {ssid: H}
        stages:
          - id: a
            actions:
              - check: {target: {role: checkbox, labelAny: ["Buy Premium € 9.99"]}}
        """
        let p1 = RecipeImporter.prepare(yaml: paid, for: profile)
        #expect(!p1.isValid)
        #expect(throws: RecipeImporter.ApplyError.invalid) { try RecipeImporter.apply(p1, to: profile) }
        let p2 = RecipeImporter.prepare(yaml: "recipeVersion: 1\nname: x\nnetwork: {ssid: H}\nstages:\n  - id: a\n    actions:\n      - eval: x", for: profile)
        #expect(!p2.isValid)
        let other = RecipeImporter.prepare(yaml: paid.replacingOccurrences(of: "ssid: H", with: "ssid: Other").replacingOccurrences(of: "Buy Premium € 9.99", with: "Terms"), for: profile)
        #expect(other.isValid)
        #expect(!other.matchesProfile)
    }
}
