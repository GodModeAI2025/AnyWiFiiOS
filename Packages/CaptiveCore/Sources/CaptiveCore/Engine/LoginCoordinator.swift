import Foundation

public struct LoginReport: Sendable {
    public var profile: PortalProfile
    public var result: RunResult
    public var log: RunLog
    public var learned: Bool
    public var usedRecipe: Bool
    /// Bei Erfolg nach einer Reparatur der angewandte Patch. Persistiert wird er erst dann (01 §14).
    public var repairedWith: RecipePatch?
}

/// Orchestriert einen Anmeldeversuch für ein Profil, unabhängig vom Modus (SPEC §3.5):
/// vorhandenes Recipe → Replay ohne Modell, sonst Lernlauf mit Planer. Bei Erfolg eines
/// Lernlaufs wird das Recipe kompiliert und als nächste Revision gespeichert.
public struct LoginCoordinator: Sendable {
    public var transport: any PortalTransport
    public var secrets: any SecretStore
    public var planner: any PortalPlanner
    public var repairer: (any RecipeRepairer)?
    public var config: EngineConfig

    public init(transport: any PortalTransport, secrets: any SecretStore,
                planner: any PortalPlanner = HeuristicPlanner(), repairer: (any RecipeRepairer)? = HeuristicRepairer(),
                config: EngineConfig = .init()) {
        self.transport = transport
        self.secrets = secrets
        self.planner = planner
        self.repairer = repairer
        self.config = config
    }

    /// `askValues` enthält einmalig eingegebene Werte (Konzept → Wert). Werte mit
    /// Persistenz `rememberInKeychain` landen nach erfolgreicher Anmeldung im Secret-Store.
    public func login(profile: PortalProfile, askValues: [String: String] = [:]) async -> LoginReport {
        let started = Date()
        let provider = StoreValueProvider(secrets: secrets, askValues: askValues, bindings: profile.credentialBindings)
        let engine = RunEngine(transport: transport, values: provider, intentPolicy: profile.intent.policy,
                               bindings: profile.credentialBindings, hostHints: profile.network.portalHostHints,
                               config: config, plannedByModel: true)
        var updated = profile
        var learned = false
        let usedRecipe = profile.recipe != nil
        var result: RunResult
        var repairedWith: RecipePatch?
        if let recipe = profile.recipe {
            result = await engine.replay(recipe)
            // Live Adaptive Repair (01 §14): ein kleiner Patch, einmal, nur im Speicher bis zum Erfolg.
            if result.outcome == .recipeMismatch, let repairer, let page = result.pages.last?.normalized,
               let patch = try? await repairer.proposePatch(RepairInput(
                intent: profile.intent, recipe: recipe, failedStageId: result.failedStageId,
                failedActionIndex: result.failedActionIndex, reason: result.reason, page: page)),
               let patched = try? patch.apply(to: recipe, bindings: profile.credentialBindings) {
                let retry = await engine.replay(patched)
                if retry.outcome == .success {
                    updated.recipe = patched
                    updated.recipeRevision += 1
                    repairedWith = patch
                    result = retry
                }
            }
        } else {
            result = await engine.learn(intent: profile.intent, planner: planner)
            if result.outcome == .success, !result.trace.isEmpty {
                let recipe = TraceCompiler.compile(trace: result.trace, name: profile.name,
                                                   ssid: profile.network.ssidExact, profileId: profile.id.uuidString)
                if SecurityValidator.errors(recipe, bindings: profile.credentialBindings).isEmpty {
                    updated.recipe = recipe
                    updated.recipeRevision += 1
                    learned = true
                }
            }
        }
        if result.outcome == .success {
            for b in profile.credentialBindings where b.persistence == .rememberInKeychain {
                if let v = askValues[b.concept], !v.isEmpty { try? secrets.write(v, for: b.keychainKey) }
            }
            updated.updatedAt = Date()
        }
        let log = RunLog(profileId: profile.id, profileName: profile.name, startedAt: started,
                         durationMs: result.durationMs, outcome: result.outcome, reason: result.reason,
                         requiredConcept: result.requiredConcept, failedStage: result.failedStageId,
                         usedRecipe: usedRecipe, recipeRevision: updated.recipeRevision,
                         events: result.trace.map(TraceRecord.init))
        return LoginReport(profile: updated, result: result, log: log, learned: learned, usedRecipe: usedRecipe, repairedWith: repairedWith)
    }
}
