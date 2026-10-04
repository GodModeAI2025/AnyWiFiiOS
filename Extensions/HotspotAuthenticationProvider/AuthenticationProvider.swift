import CaptiveCore
import CaptiveCoreApple
import Foundation
import NetworkExtension

// Authentication Provider (01 §27, Phase 9). Noch NICHT im Xcode-Projekt: Extension-Point-ID und
// Info.plist-Schlüssel kommen nach Spike S0 aus der Xcode-Target-Vorlage (siehe project.yml).
//
// Profile liest der Provider aus der App Group (profiles.json, von der App geschrieben), Werte aus dem
// gemeinsamen Keychain. Fehlt ein Wert: PendingAuthentication + lokale Notification + `.uiRequired`.

@available(iOS 26.0, *)
final class AuthenticationProvider: NSObject, NEHotspotAuthenticationProvider {
    // TEAMID durch die echte Team-ID ersetzen (SPEC §8). Muss zur keychain-access-groups-Entitlement passen.
    private let keychain = KeychainStore(service: "com.captiveai.credentials",
                                         accessGroup: "TEAMID.com.example.captiveai.shared")
    private let appGroup = "group.com.example.captiveai"

    func start() async -> Bool { true }

    func stop(reason: NEProviderStopReason) async {}

    func handleCommand(_ command: NEHotspotHelperCommand) async -> NEHotspotHelperResponse {
        switch command.commandType {
        case .authenticate, .presentUI:
            return await authenticate(command)
        case .maintain:
            return await maintain(command)
        case .logoff:
            return command.createResponse(.success)
        default:
            return command.createResponse(.commandNotRecognized)
        }
    }

    private func authenticate(_ command: NEHotspotHelperCommand) async -> NEHotspotHelperResponse {
        guard let ssid = command.network?.ssid, let profile = SharedProfiles(appGroup: appGroup).profile(ssid: ssid),
              let recipe = profile.recipe else {
            return command.createResponse(.unsupportedNetwork)
        }
        let values = KeychainValueProvider(keychain: keychain, askedKeys: pendingKeys(profileId: profile.id))
        var runner = RecipeRunner(transport: HotspotCommandTransport(command: command), values: values)
        runner.portalHostHints = profile.portalHostHints
        let result = await runner.run(recipe)

        if case .missingValue(let concept) = result.reason {
            try? PendingAuthenticationStore(directory: pendingDirectory).save(
                PendingAuthentication(runId: UUID(), profileId: profile.id, requiredConcept: concept,
                                      status: .awaitingUser, updatedAt: .now))
            // Lokale Notification ohne Wert (01 §4.5) schickt die App beim presentUI-Start.
        }
        return command.createResponse(HotspotResultMapping.result(for: result.outcome))
    }

    private func maintain(_ command: NEHotspotHelperCommand) async -> NEHotspotHelperResponse {
        var session = PortalHTTPSession(transport: HotspotCommandTransport(command: command))
        guard let url = URL(string: "http://captive.apple.com/hotspot-detect.html"),
              let probe = try? await session.get(url) else {
            return command.createResponse(.failure)
        }
        let online = probe.responses.count == 1 && probe.final.text.contains("Success")
        return command.createResponse(online ? .success : .authenticationRequired)
    }

    private var pendingDirectory: URL {
        (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("Pending", isDirectory: true)
    }

    private func pendingKeys(profileId: UUID) -> [Concept: String] {
        let store = PendingAuthenticationStore(directory: pendingDirectory)
        guard let files = try? FileManager.default.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil) else {
            return [:]
        }
        var keys: [Concept: String] = [:]
        for file in files {
            let id = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "pending-", with: "")
            guard let runId = UUID(uuidString: id), let pending = try? store.load(runId: runId),
                  pending.profileId == profileId, pending.status == .valueProvided,
                  let concept = pending.requiredConcept, let key = pending.valueKeychainKey else { continue }
            keys[concept] = key
        }
        return keys
    }
}

/// Profile, die die App für die Extensions in die App Group spiegelt (ohne Secrets).
struct SharedProfiles {
    struct Entry: Codable {
        var id: UUID
        var ssid: String
        var enabled: Bool
        var portalHostHints: [String]
        var recipeYAML: String?

        var recipe: Recipe? { recipeYAML.flatMap { try? PRLCodec.decode(yaml: $0) } }
    }

    let appGroup: String

    func all() -> [Entry] {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("profiles.json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// Exakter SSID-Match, nur aktive Profile (01 §7.2: nie pauschal alle WLANs beanspruchen).
    func profile(ssid: String) -> Entry? {
        all().first { $0.enabled && $0.ssid == ssid }
    }
}
