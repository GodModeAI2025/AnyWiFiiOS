import Foundation

public enum HotspotResult: Equatable, Sendable {
    case success, failure, uiRequired, authenticationRequired, unsupportedNetwork, temporaryFailure, commandNotRecognized
}

public enum HotspotConfidence: Equatable, Sendable { case none, low, high }

/// Lokale Benachrichtigung bei fehlendem Wert. Der Text enthält nie Werte (01 §4.5).
public protocol UserNotifier: Sendable {
    func notifyValueNeeded(profileName: String, prompt: String, runId: UUID) async
}

public struct NoopNotifier: UserNotifier {
    public init() {}
    public func notifyValueNeeded(profileName: String, prompt: String, runId: UUID) async {}
}

/// Evaluation Provider: absichtlich simpel, keine AI, keine HTTP-Analyse (01 §26).
public struct EvaluationCore: Sendable {
    public var profiles: ProfileStore

    public init(profiles: ProfileStore) { self.profiles = profiles }

    /// Beansprucht nur exakte SSIDs aktivierter Profile (V1 beansprucht nie pauschal).
    public func confidence(ssid: String?, bssid: String? = nil) -> HotspotConfidence {
        guard let ssid, !ssid.isEmpty else { return .none }
        return profiles.enabledProfile(ssid: ssid, bssid: bssid) == nil ? .none : .high
    }

    /// Filter für `filterScanList`: Indizes der Netze, die ein aktives Profil hat.
    public func filter(_ networks: [(ssid: String, bssid: String?)]) -> [Int] {
        let enabled = profiles.loadAll().filter(\.enabled)
        return networks.indices.filter { i in enabled.contains { $0.network.matches(ssid: networks[i].ssid, bssid: networks[i].bssid) } }
    }
}

/// Authentication Provider (01 §27): authenticate, presentUI, maintain, logoff. Zustandslos
/// außer dem `PendingStore`. Zeitbudget und Abbruch vor dem Systemlimit (01 §28).
public struct AuthenticationCore: Sendable {
    public var profiles: ProfileStore
    public var runLogs: RunLogStore
    public var pending: PendingStore
    public var secrets: any SecretStore
    public var notifier: any UserNotifier
    public var planner: any PortalPlanner
    public var repairer: (any RecipeRepairer)?
    public var config: EngineConfig
    /// Hartes Zeitbudget für `authenticate`. Danach `temporaryFailure` statt Systemabbruch.
    public var authenticateBudget: Duration
    /// Wie lange `presentUI` auf den Nutzer wartet.
    public var presentUIBudget: Duration
    public var pollInterval: Duration
    /// Spike S1: Lernlauf im Provider erlaubt? Sonst nur Replay, Lernen in der App.
    public var allowLearningInProvider: Bool

    public init(profiles: ProfileStore, runLogs: RunLogStore, pending: PendingStore, secrets: any SecretStore,
                notifier: any UserNotifier = NoopNotifier(), planner: any PortalPlanner = HeuristicPlanner(),
                repairer: (any RecipeRepairer)? = HeuristicRepairer(), config: EngineConfig = .init(),
                authenticateBudget: Duration = .seconds(25), presentUIBudget: Duration = .seconds(600),
                pollInterval: Duration = .milliseconds(500), allowLearningInProvider: Bool = true) {
        self.profiles = profiles
        self.runLogs = runLogs
        self.pending = pending
        self.secrets = secrets
        self.notifier = notifier
        self.planner = planner
        self.repairer = repairer
        self.config = config
        self.authenticateBudget = authenticateBudget
        self.presentUIBudget = presentUIBudget
        self.pollInterval = pollInterval
        self.allowLearningInProvider = allowLearningInProvider
    }

    public struct Result: Sendable {
        public var hotspot: HotspotResult
        public var runId: UUID?
        public var outcome: Outcome?
    }

    // MARK: authenticate

    public func authenticate(ssid: String, bssid: String? = nil, transport: any PortalTransport,
                             askValues: [String: String] = [:], runId: UUID = UUID()) async -> Result {
        guard let profile = profiles.enabledProfile(ssid: ssid, bssid: bssid) else {
            return Result(hotspot: .commandNotRecognized, runId: nil, outcome: nil)
        }
        if profile.recipe == nil, !allowLearningInProvider {
            // Ergebnis C/D der Spike-Matrix: Lernen nur in der App.
            return Result(hotspot: .uiRequired, runId: runId, outcome: nil)
        }
        let coordinator = LoginCoordinator(transport: transport, secrets: secrets, planner: planner, repairer: repairer, config: config)
        guard let report = await withDeadline(authenticateBudget, { await coordinator.login(profile: profile, askValues: askValues) }) else {
            return Result(hotspot: .temporaryFailure, runId: runId, outcome: .timeout)
        }
        if report.profile != profile { try? profiles.save(report.profile) }
        try? runLogs.append(report.log)

        if report.result.outcome == .missingUserValue {
            let concept = report.result.requiredConcept
            let prompt = profile.credentialBindings.first { $0.concept == concept }?.prompt ?? concept ?? ""
            let p = PendingAuthentication(runId: runId, profileId: profile.id, profileName: profile.name,
                                          requiredConcept: concept, prompt: prompt)
            try? pending.write(p)
            await notifier.notifyValueNeeded(profileName: profile.name, prompt: prompt, runId: runId)
            return Result(hotspot: .uiRequired, runId: runId, outcome: .missingUserValue)
        }
        return Result(hotspot: Self.map(report.result.outcome), runId: runId, outcome: report.result.outcome)
    }

    // MARK: presentUI

    /// Läuft im Hintergrund, bis die App den Wert geliefert hat, und führt dann die Anmeldung zu Ende.
    public func presentUI(runId: UUID, ssid: String, transport: any PortalTransport) async -> Result {
        let deadline = ContinuousClock.now.advanced(by: presentUIBudget)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            guard let p = pending.read(runId) else { return Result(hotspot: .failure, runId: runId, outcome: nil) }
            if p.status == .valueProvided, let concept = p.requiredConcept, let key = p.valueKey,
               let value = (try? secrets.read(key)) ?? nil, !value.isEmpty {
                defer { try? secrets.delete(key) }
                let r = await authenticate(ssid: ssid, transport: transport, askValues: [concept: value], runId: runId)
                pending.transition(runId, to: r.hotspot == .success ? .completed : .failed)
                if r.hotspot != .uiRequired { pending.delete(runId) }
                return r
            }
            if p.status == .failed || p.status == .expired { return Result(hotspot: .failure, runId: runId, outcome: nil) }
            try? await Task.sleep(for: pollInterval)
        }
        pending.transition(runId, to: .expired)
        return Result(hotspot: .failure, runId: runId, outcome: .timeout)
    }

    // MARK: maintain / logoff

    /// Prüft, ob das Netz noch Daten trägt. Sonst `authenticationRequired` (01 §27).
    public func maintain(transport: any PortalTransport) async -> HotspotResult {
        guard let r = try? await PortalHTTPClient(transport: transport).fetch(PortalRequest(url: config.probeURL)) else { return .temporaryFailure }
        return CaptiveProbe.isSuccess(r.response) ? .success : .authenticationRequired
    }

    public func logoff() -> HotspotResult { .success }

    // MARK: Hilfen

    static func map(_ o: Outcome) -> HotspotResult {
        switch o {
        case .success: .success
        case .temporaryFailure, .networkError, .timeout: .temporaryFailure
        case .unsupportedPortal, .manualInteractionRequired: .unsupportedNetwork
        case .missingUserValue: .uiRequired
        case .recipeMismatch, .aiUnavailable, .aiRejectedPlan: .failure
        }
    }
}

/// Führt `work` aus und bricht nach `limit` ab. `nil` bei Zeitüberschreitung.
public func withDeadline<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await work() }
        group.addTask {
            try? await Task.sleep(for: limit)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
