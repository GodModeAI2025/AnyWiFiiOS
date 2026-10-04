#if os(iOS) && canImport(NetworkExtension)
import CaptiveCore
import Foundation
import NetworkExtension

/// Transport im Provider-Modus: Requests an das Interface des Hotspot-Kommandos binden (01 §17.1).
public final class HotspotCommandTransport: NSObject, PortalTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private let command: NEHotspotHelperCommand
    private var session: URLSession!

    public init(command: NEHotspotHelperCommand, timeout: TimeInterval = 3) {
        self.command = command
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    public func send(_ request: PortalRequest) async throws -> PortalResponse {
        try await URLSessionWiFiTransport.send(request, using: session) { mutable in
            mutable.bind(to: command)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// Bildet Engine-Ergebnisse auf Hotspot-Ergebnisse ab (01 §27).
public enum HotspotResultMapping {
    public static func result(for outcome: RunOutcome) -> NEHotspotHelperResult {
        switch outcome {
        case .success: .success
        case .missingUserValue: .uiRequired
        case .unsupportedPortal, .manualInteractionRequired: .unsupportedNetwork
        case .temporaryFailure, .recipeMismatch, .networkError, .timeout, .aiUnavailable, .aiRejectedPlan: .temporaryFailure
        }
    }
}

/// WLAN-Profil auf dem Gerät einrichten (SPEC §3.1, Entitlement HotspotConfiguration).
public enum WiFiConfigurator {
    public static func install(_ wifi: WiFiConfig, passphrase: String?) async throws {
        let configuration: NEHotspotConfiguration
        switch wifi.security {
        case .open:
            configuration = NEHotspotConfiguration(ssid: wifi.ssid)
        case .wpaPersonal:
            configuration = NEHotspotConfiguration(ssid: wifi.ssid, passphrase: passphrase ?? "", isWEP: false)
        }
        configuration.joinOnce = false
        try await NEHotspotConfigurationManager.shared.apply(configuration)
    }

    public static func remove(ssid: String) {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
    }
}

/// Hotspot-Provider aktivieren (NEHotspotManager, iOS 26+). Beansprucht nur Profile-SSIDs (01 §7.2).
@available(iOS 26.0, *)
public enum HotspotProviderSetup {
    public static func enable(evaluationBundleID: String, authenticationBundleID: String, safariDomains: [String]) async throws {
        let manager = NEHotspotManager.shared
        try await manager.loadFromPreferences()
        manager.evaluationProviderBundleIdentifier = evaluationBundleID
        manager.authenticationProviderBundleIdentifier = authenticationBundleID
        manager.safariDomains = Array(safariDomains.prefix(10))
        manager.isEnabled = true
        try await manager.saveToPreferences()
    }
}
#endif
