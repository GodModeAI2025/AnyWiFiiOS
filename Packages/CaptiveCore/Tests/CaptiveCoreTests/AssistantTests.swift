import Testing
import Foundation
@testable import CaptiveCore

/// Skriptiertes Fake-Modell (Phase 5, CI ohne Apple Intelligence).
actor FakeAssistant: AssistantModel {
    var avail: AssistantAvailability = .available
    private(set) var seenTranscripts: [[ChatLogMessage]] = []
    private(set) var seenContexts: [NormalizedPage?] = []
    var draftOverride: PortalIntentDraft?
    var patchOverride: RecipePatch?

    var availability: AssistantAvailability { avail }
    func setAvailability(_ a: AssistantAvailability) { avail = a }
    func setDraft(_ d: PortalIntentDraft) { draftOverride = d }
    func setPatch(_ p: RecipePatch) { patchOverride = p }

    func chatTurn(_ input: IntentChatInput) async throws -> IntentChatTurn {
        seenTranscripts.append(input.transcript)
        seenContexts.append(input.portalContext)
        if let d = draftOverride { return IntentChatTurn(reply: "ok", draft: d, isComplete: true) }
        let userTurns = input.transcript.filter { $0.role == "user" }.count
        let base = PortalIntentDraft(acceptRequiredTerms: true, acceptRequiredPrivacy: true, fields: [
            .init(concept: "roomNumber", source: .askWhenMissing, persistence: .askEveryTime, prompt: "Zimmernummer"),
            .init(concept: "lastName", source: .keychain, persistence: .rememberInKeychain, prompt: "Nachname"),
        ])
        if userTurns == 1 {
            return IntentChatTurn(reply: "Verstanden.", question: "Soll ich die Zimmernummer speichern oder jedes Mal fragen?", draft: base, isComplete: false)
        }
        return IntentChatTurn(reply: "Fertig: Haken setzen, Zimmernummer erfragen, Nachname speichern, verbinden.", draft: base, isComplete: true)
    }

    func plan(_ input: PlanningInput) async throws -> PortalPlan { try await HeuristicPlanner().plan(input) }
    func proposePatch(_ input: RepairInput) async throws -> RecipePatch? {
        if let p = patchOverride { return p }
        return try await HeuristicRepairer().proposePatch(input)
    }
}

@Suite struct SanitizerTests {
    @Test func replacesKnownAndSpokenSecrets() {
        let r = PromptSanitizer.sanitize("Mein Passwort ist hunter22 und Zimmer 417, Nachname ist Example.",
                                         known: [SensitiveValue(value: "Example", placeholder: "<personal:lastName>")])
        #expect(!r.text.contains("hunter22"))
        #expect(!r.text.contains("417"))
        #expect(!r.text.contains("Example"))
        #expect(r.text.contains("<secret:password>"))
        #expect(r.text.contains("<personal:roomNumber>"))
        #expect(Set(r.detectedConcepts).isSuperset(of: ["password", "roomNumber"]))
    }

    @Test func plainInstructionsStayUntouched() {
        let t = "Datenschutz akzeptieren, Zimmernummer fragen, Nachname speichern, dann verbinden."
        let r = PromptSanitizer.sanitize(t)
        #expect(r.text == t)
        #expect(r.detectedConcepts.isEmpty)
    }

    @Test func emailIsMasked() {
        let r = PromptSanitizer.sanitize("Nimm gast@beispiel.de dafür")
        #expect(!r.text.contains("gast@beispiel.de"))
        #expect(r.detectedConcepts == ["email"])
    }
}

@Suite struct ChatTests {
    @Test func multiTurnChatBuildsCompleteIntentWithFollowUp() async throws {
        let model = FakeAssistant()
        var chat = ProfileChatSession()
        let first = try await chat.send("Datenschutz und Nutzungsbedingungen akzeptieren, Zimmernummer und Nachname eintragen, verbinden.", model: model)
        #expect(first.question?.contains("Zimmernummer") == true)
        #expect(!first.isComplete)
        let second = try await chat.send("Jedes Mal fragen.", model: model)
        #expect(second.isComplete)
        let intent = chat.intent()
        #expect(intent.instructions == [.acceptRequiredTerms, .acceptRequiredPrivacy,
                                        .fill(concept: "roomNumber", source: .askWhenMissing),
                                        .fill(concept: "lastName", source: .keychain), .submit])
        #expect(intent.policy.allowOptionalMarketingConsent == false)
        #expect(intent.policy.allowPaidUpgrade == false)
        #expect(chat.draft.summary.map(\.kind) == [.acceptRequired, .askWhenNeeded, .storeSecurely, .submit])
        #expect(chat.transcript.count == 4)
    }

    @Test func modelNeverSeesSensitiveValues() async throws {
        let model = FakeAssistant()
        var chat = ProfileChatSession()
        let r = try await chat.send("Mein Passwort ist hunter22, Zimmer 417", model: model,
                                    knownSensitive: [SensitiveValue(value: "Example", placeholder: "<personal:lastName>")])
        #expect(r.detectedSensitiveConcepts.contains("password"))
        let seen = await model.seenTranscripts.flatMap { $0 }.map(\.text).joined()
        #expect(!seen.contains("hunter22"))
        #expect(!seen.contains("417"))
        #expect(!chat.transcript.map(\.text).joined().contains("hunter22"))
    }

    @Test func unavailableModelDisablesChat() async {
        let model = FakeAssistant()
        await model.setAvailability(.unavailable(.deviceNotEligible))
        var chat = ProfileChatSession()
        await #expect(throws: ChatError.modelUnavailable) { _ = try await chat.send("hallo", model: model) }
    }

    @Test func invalidDraftIsRejected() async {
        let model = FakeAssistant()
        await model.setDraft(PortalIntentDraft(fields: [.init(concept: "cardNumber", source: .askWhenMissing, persistence: .askEveryTime)]))
        var chat = ProfileChatSession()
        await #expect(throws: ChatError.self) { _ = try await chat.send("zahle", model: model) }
    }

    @Test func portalContextIsRedactedAndPassedAlong() async throws {
        let html = #"<form><input type="hidden" name="csrf" value="SECRETTOKEN"><label for="room">Room number</label><input id="room" name="room"></form>"#
        let page = PortalNormalizer.normalize(html: html, url: URL(string: "http://p.test/")!)
        let model = FakeAssistant()
        var chat = ProfileChatSession(portalContext: page)
        _ = try await chat.send("Zimmernummer fragen", model: model)
        let ctx = await model.seenContexts.last ?? nil
        let json = String(decoding: try JSONEncoder().encode(ctx), as: UTF8.self)
        #expect(!json.contains("SECRETTOKEN"))
        #expect(json.contains("roomNumber"))
    }

    @Test func chatIntentDrivesLearningRun() async throws {
        let model = FakeAssistant()
        var chat = ProfileChatSession()
        _ = try await chat.send("alles für das Hotel", model: model)
        _ = try await chat.send("jedes Mal fragen", model: model)
        let id = UUID()
        let profile = PortalProfile(id: id, name: "Hotel", network: .init(ssidExact: "H"), intent: chat.intent(),
                                    credentialBindings: chat.draft.bindings(profileId: id))
        let secrets = InMemorySecretStore([profile.credentialBindings.first { $0.concept == "lastName" }!.keychainKey: "Example"])
        let r = await LoginCoordinator(transport: MockPortalSite(steps: Scenarios.hotel), secrets: secrets, planner: model)
            .login(profile: profile, askValues: ["roomNumber": "417"])
        #expect(r.result.outcome == .success)
        #expect(r.learned)
    }

    @Test func bindingsUseStableKeychainKeys() {
        let id = UUID()
        let b = PortalIntentDraft(fields: [.init(concept: "lastName", source: .keychain, persistence: .rememberInKeychain, prompt: "Nachname")]).bindings(profileId: id)
        #expect(b.first?.keychainKey == "profile.\(id.uuidString).lastName")
        #expect(b.first?.sensitivity == .personal)
    }
}

@Suite struct RepairTests {
    private func learnedHotel() async -> PortalProfile {
        let secrets = InMemorySecretStore(["hotel.lastName": "Example"])
        let profile = PortalProfile(name: "Hotel", network: .init(ssidExact: "H"), intent: Kit.hotelIntent,
                                    credentialBindings: [Kit.lastNameBinding])
        let r = await LoginCoordinator(transport: MockPortalSite(steps: Scenarios.hotel), secrets: secrets)
            .login(profile: profile, askValues: ["roomNumber": "417"])
        return r.profile
    }

    @Test func changedLabelIsRepairedLocallyAndRevisionBumps() async throws {
        let learned = await learnedHotel()
        #expect(learned.recipeRevision == 1)
        let secrets = InMemorySecretStore(["hotel.lastName": "Example"])
        let r = await LoginCoordinator(transport: MockPortalSite(steps: Scenarios.changed), secrets: secrets)
            .login(profile: learned, askValues: ["roomNumber": "417"])
        #expect(r.result.outcome == .success)
        #expect(r.repairedWith != nil)
        #expect(r.profile.recipeRevision == 2)
        let labels = r.profile.recipe!.stages.flatMap(\.actions).compactMap { a -> [String]? in
            if case .tap(let t) = a { return t.labelAny } else { return nil }
        }.flatMap { $0 }
        #expect(labels.contains("Connect") && labels.contains("Join Wi-Fi"))

        // Folgelauf nutzt das reparierte Recipe, ohne weitere Reparatur.
        let again = await LoginCoordinator(transport: MockPortalSite(steps: Scenarios.changed), secrets: secrets)
            .login(profile: r.profile, askValues: ["roomNumber": "417"])
        #expect(again.result.outcome == .success)
        #expect(again.repairedWith == nil)
        #expect(again.profile.recipeRevision == 2)
    }

    @Test func failedRepairIsNeverPersisted() async throws {
        let learned = await learnedHotel()
        let secrets = InMemorySecretStore(["hotel.lastName": "Example"])
        // Falsche Werte: Reparatur kann den Login nicht retten.
        let site = MockPortalSite(steps: [SiteStep(fixture: "10_changed_labels", expect: ["room": "999", "lastname": "Example"])])
        let r = await LoginCoordinator(transport: site, secrets: secrets).login(profile: learned, askValues: ["roomNumber": "417"])
        #expect(r.result.outcome != .success)
        #expect(r.repairedWith == nil)
        #expect(r.profile.recipe == learned.recipe)
        #expect(r.profile.recipeRevision == learned.recipeRevision)
    }

    @Test func maliciousPatchesAreRejected() async throws {
        let learned = await learnedHotel()
        let recipe = learned.recipe!
        let stage = recipe.stages[0]
        let tapIndex = stage.actions.firstIndex { if case .tap = $0 { true } else { false } }!
        guard case .tap(let old) = stage.actions[tapIndex] else { return }

        var paid = old; paid.labelAny = ["Buy Premium Wi-Fi € 9.99"]
        #expect(throws: RecipePatch.PatchError.self) {
            try RecipePatch(stageId: stage.id, actionIndex: tapIndex, replace: old, with: paid).apply(to: recipe)
        }
        var script = old; script.labelAny = ["javascript:alert(1)"]
        #expect(throws: RecipePatch.PatchError.self) {
            try RecipePatch(stageId: stage.id, actionIndex: tapIndex, replace: old, with: script).apply(to: recipe)
        }
        var roleChange = old; roleChange.role = "checkbox"
        #expect(throws: RecipePatch.PatchError.self) {
            try RecipePatch(stageId: stage.id, actionIndex: tapIndex, replace: old, with: roleChange).apply(to: recipe)
        }
        #expect(throws: RecipePatch.PatchError.targetMismatch) {
            try RecipePatch(stageId: stage.id, actionIndex: tapIndex, replace: Target(role: "button", labelAny: ["x"]), with: old).apply(to: recipe)
        }
        #expect(throws: RecipePatch.PatchError.stageNotFound) {
            try RecipePatch(stageId: "nope", actionIndex: 0, replace: old, with: old).apply(to: recipe)
        }
    }

    @Test func modelProposedBadPatchDoesNotRunAnyRequest() async throws {
        let learned = await learnedHotel()
        let stage = learned.recipe!.stages[0]
        let tapIndex = stage.actions.firstIndex { if case .tap = $0 { true } else { false } }!
        guard case .tap(let old) = stage.actions[tapIndex] else { return }
        var paid = old; paid.labelAny = ["Buy Premium"]
        let model = FakeAssistant()
        await model.setPatch(RecipePatch(stageId: stage.id, actionIndex: tapIndex, replace: old, with: paid))
        let site = MockPortalSite(steps: Scenarios.changed)
        let secrets = InMemorySecretStore(["hotel.lastName": "Example"])
        let r = await LoginCoordinator(transport: site, secrets: secrets, repairer: model).login(profile: learned, askValues: ["roomNumber": "417"])
        #expect(r.result.outcome == .recipeMismatch)
        #expect(await site.log.allSatisfy { $0.method != "POST" })
    }
}
