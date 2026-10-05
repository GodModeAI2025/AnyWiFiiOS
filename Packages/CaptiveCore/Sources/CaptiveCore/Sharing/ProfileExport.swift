import Foundation

public struct CredentialSlot: Codable, Equatable, Sendable {
    public var concept: String
    public var keychainKey: String
    public var prompt: String
    public var persistence: PersistencePolicy
    public var sensitivity: Sensitivity
}

public struct EncryptionParams: Codable, Equatable, Sendable {
    public var algorithm: String
    public var kdf: String
    public var iterations: Int
    public var salt: String
    public var nonce: String

    public init(algorithm: String = "AES-256-GCM", kdf: String = "PBKDF2-HMAC-SHA256", iterations: Int, salt: String, nonce: String) {
        self.algorithm = algorithm
        self.kdf = kdf
        self.iterations = iterations
        self.salt = salt
        self.nonce = nonce
    }
}

/// `manifest.json` im `.captiveprofile` (01 §21.1, SPEC §3.4).
public struct ProfileManifest: Codable, Equatable, Sendable {
    public struct WiFiPart: Codable, Equatable, Sendable {
        public var ssid: String
        public var security: WiFiConfiguration.Security
        public var hasPassphrase: Bool
    }

    public static let currentFormat = 1

    public var formatVersion: Int
    public var createdWith: String
    public var profileName: String
    public var ssid: String
    public var portalHostHints: [String]
    public var recipeRevision: Int
    public var hasRecipe: Bool
    public var credentialSlots: [CredentialSlot]
    public var wifi: WiFiPart?
    public var containsCredentials: Bool
    public var credentialsEncrypted: Bool
    public var encryption: EncryptionParams?
}

/// Klartext-Inhalt von `credentials.json`. Nur mit Opt-in im Container.
public struct SharedCredentials: Codable, Equatable, Sendable {
    public var values: [String: String]
    public var wifiPassphrase: String?

    public init(values: [String: String], wifiPassphrase: String? = nil) {
        self.values = values
        self.wifiPassphrase = wifiPassphrase
    }
}

public enum SharingError: Error, Equatable, Sendable {
    case passphraseTooShort
    case unencryptedNotConfirmed
    case noCredentialsToShare
    case invalidContainer(String)
    case unsupportedFormat(Int)
    case wrongPassphrase
    case recipeRejected(String)
    case cancelled
}

/// AES-256-GCM mit PBKDF2-abgeleitetem Schlüssel. Die Apple-Implementierung nutzt CryptoKit und
/// CommonCrypto (`CaptiveCoreApple`), Tests im Core nutzen einen Fake.
public protocol CredentialCipher: Sendable {
    func seal(_ plaintext: Data, passphrase: String) throws -> (ciphertext: Data, params: EncryptionParams)
    func open(_ ciphertext: Data, passphrase: String, params: EncryptionParams) throws -> Data
}

public struct ExportOptions: Sendable {
    public var includeCredentials: Bool
    public var passphrase: String?
    /// Zweite Bestätigung "Unverschlüsselt teilen".
    public var confirmedUnencrypted: Bool
    public var appVersion: String

    public init(includeCredentials: Bool = false, passphrase: String? = nil, confirmedUnencrypted: Bool = false, appVersion: String = "1") {
        self.includeCredentials = includeCredentials
        self.passphrase = passphrase
        self.confirmedUnencrypted = confirmedUnencrypted
        self.appVersion = appVersion
    }

    public static let minPassphraseLength = 8
}

public enum ProfileExporter {
    public static let fileExtension = "captiveprofile"

    public static func filename(for profile: PortalProfile) -> String {
        let safe = profile.name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let cleaned = String(safe).split(separator: "-").joined(separator: "-")
        return "\(cleaned.isEmpty ? "Profil" : cleaned).\(fileExtension)"
    }

    /// Slots, die der Export-Dialog nach Konzept auflisten kann, ohne Klartext (SPEC §3.4).
    public static func credentialSummary(_ profile: PortalProfile) -> [String] {
        var concepts = profile.credentialBindings.filter { $0.persistence == .rememberInKeychain }.map(\.concept)
        if profile.wifi?.security == .wpaPersonal { concepts.append("wifiPassphrase") }
        return concepts
    }

    public static func export(profile: PortalProfile, credentials: SharedCredentials? = nil, options: ExportOptions = .init(),
                              cipher: (any CredentialCipher)? = nil) throws -> Data {
        var entries: [ZipArchive.Entry] = []
        func add(_ path: String, _ data: Data) { entries.append(.init(path: path, data: data)) }

        var containsCredentials = false
        var encrypted = false
        var params: EncryptionParams?
        var credentialPayload: Data?

        if options.includeCredentials {
            guard let credentials, !credentials.values.isEmpty || credentials.wifiPassphrase != nil else {
                throw SharingError.noCredentialsToShare
            }
            let plain = try JSONEncoder.sorted.encode(credentials)
            containsCredentials = true
            if let pass = options.passphrase {
                guard pass.count >= ExportOptions.minPassphraseLength else { throw SharingError.passphraseTooShort }
                guard let cipher else { throw SharingError.invalidContainer("Kein Verschlüsselungsmodul") }
                let sealed = try cipher.seal(plain, passphrase: pass)
                credentialPayload = sealed.ciphertext
                params = sealed.params
                encrypted = true
            } else {
                guard options.confirmedUnencrypted else { throw SharingError.unencryptedNotConfirmed }
                credentialPayload = plain
            }
        }

        let slots = profile.credentialBindings.map {
            CredentialSlot(concept: $0.concept, keychainKey: $0.keychainKey, prompt: $0.prompt,
                           persistence: $0.persistence, sensitivity: $0.sensitivity)
        }
        let manifest = ProfileManifest(
            formatVersion: ProfileManifest.currentFormat, createdWith: "CaptiveAI \(options.appVersion)",
            profileName: profile.name, ssid: profile.network.ssidExact, portalHostHints: profile.network.portalHostHints,
            recipeRevision: profile.recipeRevision, hasRecipe: profile.recipe != nil, credentialSlots: slots,
            wifi: profile.wifi.map { .init(ssid: $0.ssid, security: $0.security, hasPassphrase: $0.passphraseKeychainKey != nil) },
            containsCredentials: containsCredentials, credentialsEncrypted: encrypted, encryption: params)
        add("manifest.json", try JSONEncoder.sorted.encode(manifest))
        if let recipe = profile.recipe {
            var r = recipe
            r.profileId = nil
            add("recipe.yaml", Data(try PRLCodec.serialize(r).utf8))
        }
        // Der Originaltext der Anweisung kann Persönliches enthalten und bleibt zu Hause.
        var intent = profile.intent
        intent.originalText = nil
        add("intent.json", try JSONEncoder.sorted.encode(intent))
        add("README.txt", Data(readme(profile, manifest).utf8))
        if let payload = credentialPayload { add(encrypted ? "credentials.enc" : "credentials.json", payload) }
        return ZipArchive.write(entries)
    }

    static func readme(_ p: PortalProfile, _ m: ProfileManifest) -> String {
        """
        CaptiveAI-Profil: \(p.name)
        WLAN: \(p.network.ssidExact)

        Diese Datei öffnest du in CaptiveAI (iPhone oder iPad). Sie enthält den Anmeldeablauf für das genannte WLAN.
        Zugangsdaten: \(m.containsCredentials ? (m.credentialsEncrypted ? "ja, verschlüsselt (Passphrase nötig)" : "ja, UNVERSCHLÜSSELT") : "nein, du trägst sie nach dem Import selbst ein")

        This file opens in CaptiveAI (iPhone or iPad). It contains the sign-in flow for the named Wi-Fi network.
        """
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }
}
