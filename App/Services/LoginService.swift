import CaptiveCore
import CaptiveCoreApple
import Foundation
import Observation
import SwiftData

/// Manueller Modus (SPEC §3.5): Login aus der App heraus, mit Replay, Lernen und Adaptive Repair.
@MainActor
@Observable
final class LoginService {
    enum State: Equatable {
        case idle
        case running(String)
        case needsValue(Concept)
        case finished(RunOutcome, String)
    }

    private(set) var state: State = .idle
    /// Portal-URL des letzten Laufs, z. B. um ein JavaScript-Portal im Browser zu öffnen.
    private(set) var lastPortalURL: URL?
    /// Werte, die der Nutzer in diesem Lauf eingegeben hat. Nur im Speicher.
    private var asked: [Concept: String] = [:]

    func provide(_ value: String, for concept: Concept, remember: Bool, profile: ProfileRecord) {
        asked[concept] = value
        state = .running("Melde an …")
        guard remember, var intent = profile.intent else { return }
        let key = "\(profile.keychainPrefix).\(concept.rawValue)"
        try? AppConfig.keychain.set(value, for: key)
        intent.bindings[concept] = .keychain(key)
        profile.intent = intent
    }

    func login(_ profile: ProfileRecord, context: ModelContext) async {
        state = .running("Prüfe Verbindung …")
        let values = SessionValueProvider(keychain: AppConfig.keychain, asked: asked)
        var runner = RecipeRunner(transport: URLSessionWiFiTransport(), values: values)
        runner.portalHostHints = profile.portalHostHints
        runner.probeURL = AppConfig.probeURL
        let planner = PlannerFactory.make()

        let result: RunResult
        var recipeToRun = profile.recipe
        if let recipe = recipeToRun, let intent = profile.intent {
            state = .running("Melde an …")
            let repaired = await RecipeRepairer(runner: runner, planner: planner).runWithRepair(recipe, intent: intent)
            result = repaired.run
            if let patched = repaired.patchedRecipe { try? profile.replaceRecipe(patched) }
        } else if let intent = profile.intent {
            state = .running("Lerne das Portal kennen …")
            let learning = await LearningRunner(runner: runner, planner: planner)
                .learn(intent: intent, profileId: profile.id, name: profile.name, ssid: profile.ssid)
            result = learning.run
            if let recipe = learning.recipe {
                try? profile.replaceRecipe(recipe)
                recipeToRun = recipe
            }
        } else {
            state = .finished(.recipeMismatch, "Profil hat noch keinen Ablauf.")
            return
        }

        lastPortalURL = result.lastPage?.url
        profile.record(result.outcome)
        var bundleFile: String?
        if result.outcome != .success, let recipe = recipeToRun ?? profile.recipe {
            bundleFile = try? writeDebugBundle(profile: profile, recipe: recipe, result: result)
        }
        context.insert(RunRecord(profileId: profile.id, profileName: profile.name, outcome: result.outcome,
                                 reason: result.reason.explanation, debugBundleFile: bundleFile))
        try? context.save()

        if case .missingValue(let concept?) = result.reason {
            state = .needsValue(concept)
        } else {
            asked = [:]
            state = .finished(result.outcome, result.reason.explanation)
        }
    }

    func reset() {
        state = .idle
        asked = [:]
    }

    /// Debug-Paket (SPEC §3.3) in Documents/DebugBundles. Gibt den Dateinamen zurück.
    private func writeDebugBundle(profile: ProfileRecord, recipe: Recipe, result: RunResult) throws -> String {
        let secrets = profile.credentialSlots.compactMap { try? AppConfig.keychain.get($0.key) } + Array(asked.values)
        let builder = DebugBundleBuilder(
            profileName: profile.name, recipe: recipe, recipeRevision: profile.recipeRevision, result: result,
            environment: DebugEnvironment(appVersion: AppConfig.appVersion, osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                                          device: "iOS", mode: "manual", modelAvailability: PlannerFactory.modelDescription),
            createdAt: .now, knownSecrets: secrets, intentJSON: profile.intentJSON)
        try FileManager.default.createDirectory(at: AppConfig.debugBundleDirectory, withIntermediateDirectories: true)
        let file = AppConfig.debugBundleDirectory.appendingPathComponent(builder.fileName)
        try builder.archive().write(to: file, options: [.atomic, .completeFileProtection])
        return builder.fileName
    }
}
