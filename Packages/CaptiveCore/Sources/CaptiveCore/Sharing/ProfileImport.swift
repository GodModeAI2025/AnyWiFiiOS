import Foundation

public enum ConflictStrategy: Equatable, Sendable {
    case cancel
    case importAsCopy
    case replaceRecipe
}

public enum CredentialDecision: Equatable, Sendable {
    case keepExisting
    case replace
}

public struct SharedProfilePreview: Sendable {
    public var manifest: ProfileManifest
    public var recipe: Recipe?
    public var intent: PortalIntent
    public var recipeIssues: [String]
    public var existingProfileID: UUID?
    var credentialsBlob: Data?

    public var needsPassphrase: Bool { manifest.containsCredentials && manifest.credentialsEncrypted }
    public var containsCredentials: Bool { manifest.containsCredentials }
    public var hasConflict: Bool { existingProfileID != nil }
}

public struct ImportOutcome: Sendable {
    public var profile: PortalProfile
    /// Werte, die lokal schon existieren und eine Entscheidung "Behalten / Ersetzen" brauchen.
    public var credentialConflicts: [String]
    public var storedConcepts: [String]
    public var missingConcepts: [String]
}

public enum ProfileImporter {
    static let allowedNames: Set<String> = ["manifest.json", "recipe.yaml", "intent.json", "README.txt", "credentials.json", "credentials.enc"]
    public static let maxContainerBytes = 2_000_000

    public static func preview(data: Data, existing: [PortalProfile]) throws -> SharedProfilePreview {
        guard data.count <= maxContainerBytes else { throw SharingError.invalidContainer("Datei zu groß") }
        let entries: [ZipArchive.Entry]
        do { entries = try ZipArchive.read(data) } catch { throw SharingError.invalidContainer("Kein gültiger Container") }
        var files: [String: Data] = [:]
        for e in entries {
            // Nur bekannte Dateinamen, keine Pfade: schließt Zip-Slip und Überraschungen aus.
            guard allowedNames.contains(e.path), files[e.path] == nil else { throw SharingError.invalidContainer("Unerwarteter Eintrag \(e.path)") }
            files[e.path] = e.data
        }
        guard let mData = files["manifest.json"], let manifest = try? JSONDecoder().decode(ProfileManifest.self, from: mData) else {
            throw SharingError.invalidContainer("manifest.json fehlt oder ist ungültig")
        }
        guard manifest.formatVersion == ProfileManifest.currentFormat else { throw SharingError.unsupportedFormat(manifest.formatVersion) }
        guard !manifest.ssid.isEmpty, manifest.ssid.count <= 64, !manifest.profileName.isEmpty, manifest.profileName.count <= 120 else {
            throw SharingError.invalidContainer("Profilname oder SSID ungültig")
        }
        guard let iData = files["intent.json"], let intent = try? JSONDecoder().decode(PortalIntent.self, from: iData) else {
            throw SharingError.invalidContainer("intent.json fehlt oder ist ungültig")
        }
        var recipe: Recipe?
        var issues: [String] = []
        if let yaml = files["recipe.yaml"].flatMap({ String(data: $0, encoding: .utf8) }) {
            do {
                let r = try PRLCodec.parse(yaml: yaml)
                let bindings = manifest.credentialSlots.map { CredentialBinding(concept: $0.concept, keychainKey: $0.keychainKey, prompt: $0.prompt, persistence: $0.persistence, sensitivity: $0.sensitivity) }
                issues = SecurityValidator.errors(r, bindings: bindings).map(\.description)
                if issues.isEmpty { recipe = r }
            } catch { issues = [String(describing: error)] }
        } else if manifest.hasRecipe {
            issues = ["recipe.yaml fehlt"]
        }
        if manifest.containsCredentials, files[manifest.credentialsEncrypted ? "credentials.enc" : "credentials.json"] == nil {
            throw SharingError.invalidContainer("Zugangsdaten fehlen im Container")
        }
        let existingID = existing.first { $0.network.ssidExact == manifest.ssid }?.id
        return SharedProfilePreview(manifest: manifest, recipe: recipe, intent: intent, recipeIssues: issues, existingProfileID: existingID,
                                    credentialsBlob: files[manifest.credentialsEncrypted ? "credentials.enc" : "credentials.json"])
    }

    /// Entschlüsselt die Zugangsdaten. Falsche Passphrase liefert `.wrongPassphrase`, nie Teildaten.
    public static func credentials(of preview: SharedProfilePreview, passphrase: String?, cipher: (any CredentialCipher)?) throws -> SharedCredentials? {
        guard preview.manifest.containsCredentials, let blob = preview.credentialsBlob else { return nil }
        let plain: Data
        if preview.manifest.credentialsEncrypted {
            guard let pass = passphrase, let params = preview.manifest.encryption, let cipher else { throw SharingError.wrongPassphrase }
            do { plain = try cipher.open(blob, passphrase: pass, params: params) } catch { throw SharingError.wrongPassphrase }
        } else {
            plain = blob
        }
        guard let creds = try? JSONDecoder().decode(SharedCredentials.self, from: plain) else { throw SharingError.wrongPassphrase }
        return creds
    }

    public static func apply(_ preview: SharedProfilePreview, credentials: SharedCredentials?, strategy: ConflictStrategy,
                             existing: [PortalProfile], secrets: any SecretStore,
                             decisions: [String: CredentialDecision] = [:], now: Date = Date()) throws -> ImportOutcome {
        if let first = preview.recipeIssues.first { throw SharingError.recipeRejected(first) }
        if preview.hasConflict && strategy == .cancel { throw SharingError.cancelled }
        let m = preview.manifest

        let target: PortalProfile? = (strategy == .replaceRecipe) ? existing.first { $0.id == preview.existingProfileID } : nil
        var profile = target ?? PortalProfile(name: m.profileName, network: .init(ssidExact: m.ssid, portalHostHints: m.portalHostHints),
                                              intent: preview.intent, createdAt: now, updatedAt: now)
        if target == nil, preview.hasConflict, strategy == .importAsCopy { profile.name = m.profileName + " (Kopie)" }

        // Keychain-Schlüssel gehören dem neuen/bestehenden Profil, das Recipe wird umgeschrieben.
        var keyMap: [String: String] = [:]
        var bindings: [CredentialBinding] = []
        for slot in m.credentialSlots {
            let existingBinding = profile.credentialBindings.first { $0.concept == slot.concept }
            let key = existingBinding?.keychainKey ?? "profile.\(profile.id.uuidString).\(slot.concept)"
            keyMap[slot.keychainKey] = key
            bindings.append(CredentialBinding(concept: slot.concept, keychainKey: key, prompt: slot.prompt,
                                              persistence: slot.persistence, sensitivity: slot.sensitivity))
        }
        if target != nil {
            profile.credentialBindings = profile.credentialBindings.filter { b in !bindings.contains { $0.concept == b.concept } } + bindings
        } else {
            profile.credentialBindings = bindings
            profile.intent = preview.intent
            profile.network.portalHostHints = m.portalHostHints
        }
        if let w = m.wifi, target == nil || profile.wifi == nil {
            profile.wifi = WiFiConfiguration(ssid: w.ssid, security: w.security,
                                             passphraseKeychainKey: w.hasPassphrase ? "profile.\(profile.id.uuidString).wifi" : nil)
        }
        if var recipe = preview.recipe {
            recipe = recipe.rewritingKeychainKeys(keyMap)
            recipe.profileId = profile.id.uuidString
            profile.commit(recipe, note: "Import", at: now)
        }

        // Werte: nie stillschweigend überschreiben (01 §31).
        var conflicts: [String] = []
        var stored: [String] = []
        var write: [(String, String, String)] = [] // concept, key, value
        if let credentials {
            for b in bindings {
                guard let v = credentials.values[b.concept], !v.isEmpty else { continue }
                write.append((b.concept, b.keychainKey, v))
            }
            if let pass = credentials.wifiPassphrase, let key = profile.wifi?.passphraseKeychainKey { write.append(("wifiPassphrase", key, pass)) }
        }
        for (concept, key, value) in write {
            if secrets.contains(key) {
                switch decisions[concept] {
                case .replace: try secrets.write(value, for: key); stored.append(concept)
                case .keepExisting: break
                case nil: conflicts.append(concept)
                }
            } else {
                try secrets.write(value, for: key)
                stored.append(concept)
            }
        }
        let missing = bindings.filter { $0.persistence == .rememberInKeychain && !secrets.contains($0.keychainKey) }.map(\.concept)
        return ImportOutcome(profile: profile, credentialConflicts: conflicts, storedConcepts: stored, missingConcepts: missing)
    }
}

extension Recipe {
    /// Ersetzt Keychain-Referenzen (alter Schlüssel → neuer Schlüssel).
    public func rewritingKeychainKeys(_ map: [String: String]) -> Recipe {
        var r = self
        r.stages = stages.map { stage in
            var s = stage
            s.actions = stage.actions.map { a in
                if case .fill(let t, .keychain(let k)) = a, let n = map[k] { return .fill(target: t, value: .keychain(n)) }
                return a
            }
            return s
        }
        return r
    }
}
