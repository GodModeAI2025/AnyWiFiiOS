#if os(iOS) && canImport(NetworkExtension)
import Foundation
import NetworkExtension
import CaptiveCore

public enum WiFiConfigError: Error, Equatable, Sendable {
    case missingPassphrase
    case invalidPassphrase
    case failed(String)
}

/// Legt ein Netz per `NEHotspotConfigurationManager` an (SPEC §3.1).
/// Entitlement: com.apple.developer.networking.HotspotConfiguration (Self-Service).
public struct WiFiConfigurator: Sendable {
    public init() {}

    public static func makeConfiguration(_ wifi: WiFiConfiguration, passphrase: String?) throws -> NEHotspotConfiguration {
        switch wifi.security {
        case .open:
            return NEHotspotConfiguration(ssid: wifi.ssid)
        case .wpaPersonal:
            guard let passphrase, !passphrase.isEmpty else { throw WiFiConfigError.missingPassphrase }
            guard (8...63).contains(passphrase.count) else { throw WiFiConfigError.invalidPassphrase }
            return NEHotspotConfiguration(ssid: wifi.ssid, passphrase: passphrase, isWEP: false)
        }
    }

    public func apply(_ wifi: WiFiConfiguration, secrets: any SecretStore) async throws {
        let pass = try wifi.passphraseKeychainKey.flatMap { try secrets.read($0) }
        let config = try Self.makeConfiguration(wifi, passphrase: pass)
        config.joinOnce = false
        do {
            try await NEHotspotConfigurationManager.shared.apply(config)
        } catch let e as NSError where e.domain == NEHotspotConfigurationErrorDomain
            && e.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
            return // bereits verbunden zählt als Erfolg
        } catch {
            throw WiFiConfigError.failed((error as NSError).localizedDescription)
        }
    }
}

/// QR-Inhalt für den WLAN-Teil. Nur nach Opt-in aus SPEC §3.4 verwenden.
public enum WiFiQRCode {
    public static func payload(ssid: String, security: WiFiConfiguration.Security, passphrase: String?) -> String {
        func esc(_ s: String) -> String {
            let special: Set<Character> = ["\\", ";", ",", ":", "\""]
            var out = ""
            for ch in s {
                if special.contains(ch) { out.append("\\") }
                out.append(ch)
            }
            return out
        }
        switch security {
        case .open: return "WIFI:T:nopass;S:\(esc(ssid));;"
        case .wpaPersonal: return "WIFI:T:WPA;S:\(esc(ssid));P:\(esc(passphrase ?? ""));;"
        }
    }
}
#endif
