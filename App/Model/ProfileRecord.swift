import CaptiveCore
import Foundation
import SwiftData

/// Gespeichertes WLAN-Profil (01 §7.1, SPEC §3.1). Secrets liegen nie hier, sondern im Keychain.
@Model
final class ProfileRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var enabled: Bool
    var ssid: String
    var portalHostHints: [String]
    /// `nil` = kein WLAN-Teil, sonst `WiFiSecurity.rawValue`.
    var wifiSecurityRaw: String?
    var recipeYAML: String?
    var recipeRevision: Int
    /// Letzte erfolgreiche Revisionen für Rollback (01 §30), neueste zuerst, max. 5.
    var previousRecipes: [String]
    var intentJSON: Data?
    var originalInstruction: String
    var createdAt: Date
    var updatedAt: Date
    /// Letzte 10 Outcomes (`RunOutcome.rawValue`), neueste zuerst (SPEC §3.3).
    var recentOutcomes: [String]
    var runCount: Int
    var successCount: Int

    init(name: String, ssid: String, wifiSecurity: WiFiSecurity?, intent: PortalIntent, recipe: Recipe? = nil) {
        id = UUID()
        self.name = name
        enabled = true
        self.ssid = ssid
        portalHostHints = []
        wifiSecurityRaw = wifiSecurity?.rawValue
        recipeYAML = recipe.flatMap { try? PRLCodec.encode($0) }
        recipeRevision = recipe == nil ? 0 : 1
        previousRecipes = []
        intentJSON = try? JSONEncoder().encode(intent)
        originalInstruction = intent.originalInstruction
        createdAt = .now
        updatedAt = .now
        recentOutcomes = []
        runCount = 0
        successCount = 0
    }
}

extension ProfileRecord {
    var keychainPrefix: String { "profile-\(id.uuidString)" }
    var wifiPassphraseKey: String { "\(keychainPrefix).wifi" }

    var recipe: Recipe? { recipeYAML.flatMap { try? PRLCodec.decode(yaml: $0) } }

    var intent: PortalIntent? {
        get { intentJSON.flatMap { try? JSONDecoder().decode(PortalIntent.self, from: $0) } }
        set { intentJSON = newValue.flatMap { try? JSONEncoder().encode($0) } }
    }

    var wifi: WiFiConfig? {
        guard let raw = wifiSecurityRaw, let security = WiFiSecurity(rawValue: raw) else { return nil }
        return WiFiConfig(ssid: ssid, security: security, passphraseKey: security == .open ? nil : wifiPassphraseKey)
    }

    /// Keychain-Schlüssel → Konzept, für den `RecipeValidator`.
    var keychainBindings: [String: Concept] {
        var result: [String: Concept] = [:]
        for (concept, binding) in intent?.bindings ?? [:] {
            if case .keychain(let key) = binding { result[key] = concept }
        }
        return result
    }

    var credentialSlots: [CredentialSlot] {
        var slots = keychainBindings.map { CredentialSlot(key: $0.key, concept: $0.value, label: $0.value.displayName) }
            .sorted { $0.key < $1.key }
        if wifi?.passphraseKey != nil {
            slots.append(CredentialSlot(key: wifiPassphraseKey, concept: nil, label: "WLAN-Passwort"))
        }
        return slots
    }

    /// Stabil ab 5 Erfolgen in Folge (SPEC §3.3).
    var isStable: Bool {
        recentOutcomes.count >= 5 && recentOutcomes.prefix(5).allSatisfy { $0 == RunOutcome.success.rawValue }
    }

    var successRate: Double { runCount == 0 ? 0 : Double(successCount) / Double(runCount) }

    func record(_ outcome: RunOutcome) {
        runCount += 1
        if outcome == .success { successCount += 1 }
        recentOutcomes.insert(outcome.rawValue, at: 0)
        if recentOutcomes.count > 10 { recentOutcomes.removeLast(recentOutcomes.count - 10) }
        updatedAt = .now
    }

    /// Neue Revision speichern (01 §30). Wirft, wenn das Recipe den Validator nicht besteht.
    func replaceRecipe(_ recipe: Recipe) throws {
        let issues = RecipeValidator(keychainBindings: keychainBindings).validate(recipe)
        guard issues.isEmpty else { throw RecipeRejected(issues: issues) }
        if let current = recipeYAML {
            previousRecipes.insert(current, at: 0)
            if previousRecipes.count > 5 { previousRecipes.removeLast(previousRecipes.count - 5) }
        }
        recipeYAML = try PRLCodec.encode(recipe)
        recipeRevision += 1
        updatedAt = .now
    }

    func rollback() {
        guard !previousRecipes.isEmpty else { return }
        recipeYAML = previousRecipes.removeFirst()
        recipeRevision += 1
        updatedAt = .now
    }
}

struct RecipeRejected: Error, LocalizedError {
    var issues: [ValidationIssue]
    var errorDescription: String? { issues.map(\.message).joined(separator: "\n") }
}

/// Protokollierter Login-Lauf für die Aktivitätsansicht (01 §23).
@Model
final class RunRecord {
    var id: UUID
    var profileId: UUID
    var profileName: String
    var startedAt: Date
    var outcomeRaw: String
    var reasonText: String
    /// Dateiname des Debug-Pakets in Documents/DebugBundles, falls erzeugt.
    var debugBundleFile: String?

    init(profileId: UUID, profileName: String, outcome: RunOutcome, reason: String, debugBundleFile: String?) {
        id = UUID()
        self.profileId = profileId
        self.profileName = profileName
        startedAt = .now
        outcomeRaw = outcome.rawValue
        reasonText = reason
        self.debugBundleFile = debugBundleFile
    }

    var outcome: RunOutcome { RunOutcome(rawValue: outcomeRaw) ?? .temporaryFailure }
}
