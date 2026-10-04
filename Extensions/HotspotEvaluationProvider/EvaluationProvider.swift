import Foundation
import NetworkExtension

// Evaluation Provider (01 §26, Phase 9). Absichtlich simpel: keine AI, keine HTTP-Analyse.
// Beansprucht nur Netze mit aktivem Profil (exakter SSID-Match). Noch nicht im Xcode-Projekt (Spike S0).

@available(iOS 26.0, *)
final class EvaluationProvider: NSObject, NEHotspotEvaluationProvider {
    private let appGroup = "group.com.example.captiveai"

    var localizedDisplayName: String { "CaptiveAI" }

    func start() async -> Bool { true }

    func stop(reason: NEProviderStopReason) async {}

    func handleCommand(_ command: NEHotspotHelperCommand) async -> NEHotspotHelperResponse {
        let ssids = Set(enabledSSIDs())
        switch command.commandType {
        case .filterScanList:
            let matches = (command.networkList ?? []).filter { ssids.contains($0.ssid) }
            matches.forEach { $0.setConfidence(.high) }
            let response = command.createResponse(.success)
            response.setNetworkList(matches)
            return response
        case .evaluate:
            guard let network = command.network else { return command.createResponse(.success) }
            network.setConfidence(ssids.contains(network.ssid) ? .high : .none)
            let response = command.createResponse(.success)
            response.setNetwork(network)
            return response
        default:
            return command.createResponse(.commandNotRecognized)
        }
    }

    private func enabledSSIDs() -> [String] {
        struct Entry: Decodable { var ssid: String; var enabled: Bool }
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("profiles.json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.filter(\.enabled).map(\.ssid)
    }
}
