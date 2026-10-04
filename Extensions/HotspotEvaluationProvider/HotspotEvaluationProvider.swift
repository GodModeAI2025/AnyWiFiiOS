import ExtensionFoundation
import Foundation
import NetworkExtension
import os.log
import CaptiveCore

/// Evaluation Provider (01 §26): absichtlich simpel. Keine AI, keine HTTP-Analyse.
/// Beansprucht nur exakte SSIDs aktivierter Profile.
@main
class HotspotEvaluationProvider: NEHotspotEvaluationProvider {
    private let logger = os.Logger(subsystem: "com.example.captiveai.evaluation", category: "Provider")
    var localizedDisplayName: String

    required init() {
        localizedDisplayName = "CaptiveAI"
    }

    func start() async -> Bool {
        logger.log("start")
        return true
    }

    func stop(reason: NEProviderStopReason) async {
        logger.log("stop")
    }

    func handleCommand(_ command: NEHotspotHelperCommand) async -> NEHotspotHelperResponse {
        let core = EvaluationCore(profiles: AppEnvironment.profileStore())
        switch command.commandType {
        case .filterScanList:
            let list = command.networkList ?? []
            let keep = core.filter(list.map { ($0.ssid, $0.bssid) })
            let response = command.createResponse(.success)
            response.setNetworkList(keep.map { list[$0] })
            logger.log("filterScanList: \(keep.count, privacy: .public) von \(list.count, privacy: .public)")
            return response
        case .evaluate:
            guard let network = command.network else { return command.createResponse(.failure) }
            switch core.confidence(ssid: network.ssid, bssid: network.bssid) {
            case .high: network.setConfidence(.high)
            case .low: network.setConfidence(.low)
            case .none: network.setConfidence(.none)
            }
            let response = command.createResponse(.success)
            response.setNetwork(network)
            return response
        default:
            return command.createResponse(.commandNotRecognized)
        }
    }
}
