import Crypto
import Foundation

// `.captiveprofile`: teilbares Profil (01 §21, SPEC §3.4).
// ZIP-Container: manifest.json, recipe.yaml, README.txt, optional intent.json und credentials.json/.enc.

public enum WiFiSecurity: String, Codable, Sendable, CaseIterable {
    case open, wpaPersonal
}

/// WLAN-Teil eines Profils (SPEC §3.1). Die Passphrase liegt im Keychain unter `passphraseKey`.
public struct WiFiConfig: Codable, Sendable, Equatable {
    public var ssid: String
    public var security: WiFiSecurity
    public var passphraseKey: String?

    public init(ssid: String, security: WiFiSecurity, passphraseKey: String? = nil) {
        self.ssid = ssid
        self.security = security
        self.passphraseKey = passphraseKey
    }
}

/// Ein Keychain-Platz des Profils, ohne Wert (01 §7.4).
public struct CredentialSlot: Codable, Sendable, Equatable {
    public var key: String
    public var concept: Concept?
    public var label: String

    public init(key: String, concept: Concept?, label: String) {
        self.key = key
        self.concept = concept
        self.label = label
    }
}

public struct ProfileManifest: Codable, Sendable, Equatable {
    public struct KeyDerivation: Codable, Sendable, Equatable {
        public var algorithm: String
        public var iterations: Int
        public var salt: String
    }

    public var format: String
    public var formatVersion: Int
    public var profileName: String
    public var wifi: WiFiConfig?
    public var credentialSlots: [CredentialSlot]
    public var containsCredentials: Bool
    public var credentialsEncrypted: Bool
    public var keyDerivation: KeyDerivation?
    public var cipher: String?

    public static let formatName = "captiveprofile"
    public static let currentVersion = 1
}

public struct ImportedProfile: Sendable, Equatable {
    public var manifest: ProfileManifest
    public var recipe: Recipe
    public var intentJSON: Data?
    /// Keychain-Schlüssel → Wert. Nur vorhanden, wenn der Absender Zugangsdaten mitgeteilt hat.
    public var credentials: [String: String]?
}

public enum ProfilePackage {
    public enum Credentials: Sendable {
        /// Standard: keine Werte, nur die leeren Slots (01 §21.2).
        case none
        /// Opt-in mit zweiter Bestätigung (SPEC §3.4).
        case plain([String: String])
        /// Opt-in, vorausgewählt: AES-256-GCM, Schlüssel per PBKDF2-HMAC-SHA256.
        case encrypted([String: String], passphrase: String)
    }

    public enum Failure: Error, Equatable, Sendable {
        case notAProfile
        case unsupportedVersion(Int)
        case missingFile(String)
        case passphraseRequired
        case wrongPassphrase
        case weakKeyDerivation
        case unknownCredentialKey(String)
    }

    public static let defaultIterations = 600_000
    /// Untergrenze beim Import, damit manipulierte Dateien keine triviale Ableitung erzwingen.
    public static let minimumIterations = 100_000

    // MARK: Export

    public static func export(profileName: String, recipe: Recipe, wifi: WiFiConfig?, slots: [CredentialSlot],
                              intentJSON: Data? = nil, credentials: Credentials,
                              iterations: Int = defaultIterations) throws -> Data {
        var manifest = ProfileManifest(
            format: ProfileManifest.formatName, formatVersion: ProfileManifest.currentVersion,
            profileName: profileName, wifi: wifi, credentialSlots: slots,
            containsCredentials: false, credentialsEncrypted: false, keyDerivation: nil, cipher: nil)

        var entries: [ZipArchive.Entry] = [
            .init(path: "recipe.yaml", text: try PRLCodec.encode(recipe)),
        ]
        if let intentJSON { entries.append(.init(path: "intent.json", data: intentJSON)) }

        let knownKeys = Set(slots.map(\.key))
        switch credentials {
        case .none:
            break
        case .plain(let values):
            try checkKeys(values, knownKeys)
            manifest.containsCredentials = true
            entries.append(.init(path: "credentials.json", data: try sortedJSON(values)))
        case .encrypted(let values, let passphrase):
            try checkKeys(values, knownKeys)
            var salt = [UInt8](repeating: 0, count: 16)
            var rng = SystemRandomNumberGenerator()
            for i in salt.indices { salt[i] = UInt8.random(in: .min ... .max, using: &rng) }
            let key = PBKDF2.deriveKey(password: passphrase, salt: Data(salt), iterations: iterations)
            let sealed = try AES.GCM.seal(try sortedJSON(values), using: key, authenticating: Data(profileName.utf8))
            guard let combined = sealed.combined else { throw Failure.notAProfile }
            manifest.containsCredentials = true
            manifest.credentialsEncrypted = true
            manifest.keyDerivation = .init(algorithm: "PBKDF2-HMAC-SHA256", iterations: iterations,
                                           salt: Data(salt).base64EncodedString())
            manifest.cipher = "AES-256-GCM"
            entries.append(.init(path: "credentials.enc", data: combined))
        }

        entries.insert(.init(path: "manifest.json", data: try sortedJSON(manifest)), at: 0)
        entries.append(.init(path: "README.txt", text: readme(manifest)))
        return try ZipArchive.write(entries)
    }

    // MARK: Import

    /// Liest nur das Manifest, z. B. für die Import-Vorschau („Enthält Zugangsdaten“).
    public static func inspect(_ data: Data) throws -> ProfileManifest {
        try manifest(in: try files(data))
    }

    public static func importProfile(_ data: Data, passphrase: String? = nil) throws -> ImportedProfile {
        let files = try files(data)
        let manifest = try manifest(in: files)
        guard let recipeData = files["recipe.yaml"] else { throw Failure.missingFile("recipe.yaml") }
        let recipe = try PRLCodec.decode(data: recipeData)

        var credentials: [String: String]?
        if manifest.containsCredentials {
            if manifest.credentialsEncrypted {
                guard let passphrase else { throw Failure.passphraseRequired }
                guard let kdf = manifest.keyDerivation, kdf.algorithm == "PBKDF2-HMAC-SHA256",
                      kdf.iterations >= minimumIterations, let salt = Data(base64Encoded: kdf.salt), salt.count >= 16 else {
                    throw Failure.weakKeyDerivation
                }
                guard let sealed = files["credentials.enc"] else { throw Failure.missingFile("credentials.enc") }
                let key = PBKDF2.deriveKey(password: passphrase, salt: salt, iterations: kdf.iterations)
                do {
                    let box = try AES.GCM.SealedBox(combined: sealed)
                    let plain = try AES.GCM.open(box, using: key, authenticating: Data(manifest.profileName.utf8))
                    credentials = try JSONDecoder().decode([String: String].self, from: plain)
                } catch {
                    throw Failure.wrongPassphrase
                }
            } else {
                guard let plain = files["credentials.json"] else { throw Failure.missingFile("credentials.json") }
                credentials = try JSONDecoder().decode([String: String].self, from: plain)
            }
            try checkKeys(credentials ?? [:], Set(manifest.credentialSlots.map(\.key)))
        }
        return ImportedProfile(manifest: manifest, recipe: recipe, intentJSON: files["intent.json"], credentials: credentials)
    }

    // MARK: Hilfen

    private static func files(_ data: Data) throws -> [String: Data] {
        let entries: [ZipArchive.Entry]
        do { entries = try ZipArchive.read(data) } catch { throw Failure.notAProfile }
        return Dictionary(entries.map { ($0.path, $0.data) }, uniquingKeysWith: { first, _ in first })
    }

    private static func manifest(in files: [String: Data]) throws -> ProfileManifest {
        guard let data = files["manifest.json"],
              let manifest = try? JSONDecoder().decode(ProfileManifest.self, from: data),
              manifest.format == ProfileManifest.formatName else { throw Failure.notAProfile }
        guard manifest.formatVersion == ProfileManifest.currentVersion else {
            throw Failure.unsupportedVersion(manifest.formatVersion)
        }
        return manifest
    }

    private static func checkKeys(_ values: [String: String], _ known: Set<String>) throws {
        if let unknown = values.keys.sorted().first(where: { !known.contains($0) }) {
            throw Failure.unknownCredentialKey(unknown)
        }
    }

    private static func sortedJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    static func readme(_ manifest: ProfileManifest) -> String {
        var text = """
        CaptiveAI-Profil „\(manifest.profileName)“

        Öffne diese Datei auf einem iPhone oder iPad mit CaptiveAI, um das Profil zu importieren.
        Enthalten: Anmeldeablauf (recipe.yaml)\(manifest.wifi != nil ? ", WLAN-Einstellungen" : "").

        """
        if !manifest.containsCredentials {
            text += "Zugangsdaten sind nicht enthalten. CaptiveAI fragt beim Import danach.\n"
        } else if manifest.credentialsEncrypted {
            text += "Zugangsdaten sind enthalten und mit einer Passphrase verschlüsselt.\n"
        } else {
            text += "ACHTUNG: Zugangsdaten sind unverschlüsselt enthalten. Datei nur an vertraute Personen geben.\n"
        }
        return text
    }
}

/// PBKDF2-HMAC-SHA256 (RFC 8018) auf Basis von swift-crypto, damit es auch unter Linux läuft.
public enum PBKDF2 {
    public static func deriveKey(password: String, salt: Data, iterations: Int, byteCount: Int = 32) -> SymmetricKey {
        SymmetricKey(data: derive(password: Data(password.utf8), salt: salt, iterations: iterations, byteCount: byteCount))
    }

    public static func derive(password: Data, salt: Data, iterations: Int, byteCount: Int) -> Data {
        let key = SymmetricKey(data: password)
        var output = Data()
        var blockIndex: UInt32 = 1
        while output.count < byteCount {
            var message = salt
            message.append(contentsOf: [UInt8(blockIndex >> 24), UInt8((blockIndex >> 16) & 0xFF),
                                        UInt8((blockIndex >> 8) & 0xFF), UInt8(blockIndex & 0xFF)])
            var u = [UInt8](HMAC<SHA256>.authenticationCode(for: message, using: key))
            var t = u
            if iterations > 1 {
                for _ in 2...iterations {
                    u = [UInt8](HMAC<SHA256>.authenticationCode(for: u, using: key))
                    for i in t.indices { t[i] ^= u[i] }
                }
            }
            output.append(contentsOf: t)
            blockIndex += 1
        }
        return output.prefix(byteCount)
    }
}
