import Testing
import Foundation
@testable import CaptiveCore

/// Nur für Containerlogik. Echte Kryptografie testet `CaptiveCoreAppleTests`.
struct FakeCipher: CredentialCipher {
    func seal(_ plaintext: Data, passphrase: String) throws -> (ciphertext: Data, params: EncryptionParams) {
        (Data(plaintext.map { $0 ^ 0x5A }) + Data(passphrase.utf8), EncryptionParams(iterations: 600_000, salt: "AAAA", nonce: "BBBB"))
    }
    func open(_ ciphertext: Data, passphrase: String, params: EncryptionParams) throws -> Data {
        let tail = Data(passphrase.utf8)
        guard ciphertext.suffix(tail.count) == tail else { throw SharingError.wrongPassphrase }
        return Data(ciphertext.dropLast(tail.count).map { $0 ^ 0x5A })
    }
}

@Suite struct SharingTests {
    let cipher = FakeCipher()

    private func profile() -> PortalProfile {
        var p = PortalProfile(name: "Hotel Muster", network: .init(ssidExact: "Hotel_Guest", portalHostHints: ["portal.example"]),
                              intent: PortalIntent(instructions: [.acceptRequiredTerms, .fill(concept: "lastName", source: .keychain), .submit],
                                                   originalText: "Mein Nachname ist Example"),
                              credentialBindings: [Kit.lastNameBinding])
        p.wifi = .init(ssid: "Hotel_Guest", security: .wpaPersonal, passphraseKeychainKey: "wifi.key")
        p.commit(Recipe(name: "Hotel Muster", ssid: "Hotel_Guest", stages: [Stage(id: "s1", actions: [
            .fill(target: Target(concept: "lastName"), value: .keychain("hotel.lastName")),
            .tap(target: Target(role: "button", labelAny: ["Connect"]))])]), note: "t")
        return p
    }

    private func allText(_ data: Data) throws -> String {
        try ZipArchive.read(data).map { String(decoding: $0.data, as: UTF8.self) }.joined(separator: "\n")
    }

    @Test func standardExportHasNoSecretsOrPersonalText() throws {
        let data = try ProfileExporter.export(profile: profile())
        let text = try allText(data)
        #expect(!text.contains("Example"))          // originalText bleibt zu Hause
        #expect(!text.contains("credentials.json") && !text.contains("credentials.enc"))
        let names = try ZipArchive.read(data).map(\.path)
        #expect(Set(names) == ["manifest.json", "recipe.yaml", "intent.json", "README.txt"])
        let m = try JSONDecoder().decode(ProfileManifest.self, from: ZipArchive.read(data).first { $0.path == "manifest.json" }!.data)
        #expect(!m.containsCredentials && !m.credentialsEncrypted)
        #expect(m.credentialSlots.first?.concept == "lastName")
    }

    @Test func credentialsNeedOptInPassphraseOrSecondConfirmation() throws {
        let creds = SharedCredentials(values: ["lastName": "Example"])
        #expect(throws: SharingError.unencryptedNotConfirmed) {
            try ProfileExporter.export(profile: profile(), credentials: creds, options: .init(includeCredentials: true), cipher: cipher)
        }
        #expect(throws: SharingError.passphraseTooShort) {
            try ProfileExporter.export(profile: profile(), credentials: creds, options: .init(includeCredentials: true, passphrase: "kurz"), cipher: cipher)
        }
        #expect(throws: SharingError.noCredentialsToShare) {
            try ProfileExporter.export(profile: profile(), credentials: nil, options: .init(includeCredentials: true, passphrase: "langgenug1"), cipher: cipher)
        }
        // Ohne Opt-in landen übergebene Werte nie im Container.
        let data = try ProfileExporter.export(profile: profile(), credentials: creds, options: .init(), cipher: cipher)
        #expect(!(try allText(data)).contains("Example"))
    }

    @Test func manifestReflectsEncryptionState() throws {
        let creds = SharedCredentials(values: ["lastName": "Example"], wifiPassphrase: "wifi-pass-9")
        let enc = try ProfileExporter.export(profile: profile(), credentials: creds, options: .init(includeCredentials: true, passphrase: "teilen-123"), cipher: cipher)
        let plain = try ProfileExporter.export(profile: profile(), credentials: creds, options: .init(includeCredentials: true, confirmedUnencrypted: true), cipher: cipher)
        func manifest(_ d: Data) throws -> ProfileManifest {
            try JSONDecoder().decode(ProfileManifest.self, from: ZipArchive.read(d).first { $0.path == "manifest.json" }!.data)
        }
        let me = try manifest(enc), mp = try manifest(plain)
        #expect(me.containsCredentials && me.credentialsEncrypted && me.encryption?.iterations == 600_000)
        #expect(mp.containsCredentials && !mp.credentialsEncrypted && mp.encryption == nil)
        #expect(try ZipArchive.read(enc).map(\.path).contains("credentials.enc"))
        #expect(!(try allText(enc)).contains("Example"))
        #expect(!(try allText(enc)).contains("wifi-pass-9"))
        #expect(try ZipArchive.read(plain).map(\.path).contains("credentials.json"))
        #expect((try allText(plain)).contains("Example"))   // bewusst unverschlüsselt
    }

    @Test func roundTripWithoutCredentialsAsksForValues() throws {
        let data = try ProfileExporter.export(profile: profile())
        let preview = try ProfileImporter.preview(data: data, existing: [])
        #expect(!preview.containsCredentials)
        #expect(preview.recipeIssues.isEmpty)
        let secrets = InMemorySecretStore()
        let out = try ProfileImporter.apply(preview, credentials: nil, strategy: .importAsCopy, existing: [], secrets: secrets)
        #expect(out.profile.name == "Hotel Muster")
        #expect(out.profile.recipeRevision == 1)
        #expect(out.missingConcepts == ["lastName"])
        // Recipe zeigt auf den neuen Schlüssel des neuen Profils.
        let key = out.profile.credentialBindings[0].keychainKey
        #expect(key == "profile.\(out.profile.id.uuidString).lastName")
        let yaml = try PRLCodec.serialize(out.profile.recipe!)
        #expect(yaml.contains(key) && !yaml.contains("hotel.lastName"))
        #expect(out.profile.recipe?.profileId == out.profile.id.uuidString)
    }

    @Test func importWithEncryptedCredentialsStoresValues() throws {
        let creds = SharedCredentials(values: ["lastName": "Example"], wifiPassphrase: "wifi-pass-9")
        let data = try ProfileExporter.export(profile: profile(), credentials: creds, options: .init(includeCredentials: true, passphrase: "teilen-123"), cipher: cipher)
        let preview = try ProfileImporter.preview(data: data, existing: [])
        #expect(preview.needsPassphrase)
        #expect(throws: SharingError.wrongPassphrase) { try ProfileImporter.credentials(of: preview, passphrase: "falsch-123", cipher: cipher) }
        #expect(throws: SharingError.wrongPassphrase) { try ProfileImporter.credentials(of: preview, passphrase: nil, cipher: cipher) }
        let got = try ProfileImporter.credentials(of: preview, passphrase: "teilen-123", cipher: cipher)
        let secrets = InMemorySecretStore()
        let out = try ProfileImporter.apply(preview, credentials: got, strategy: .importAsCopy, existing: [], secrets: secrets)
        #expect(try secrets.read(out.profile.credentialBindings[0].keychainKey) == "Example")
        #expect(try secrets.read(out.profile.wifi!.passphraseKeychainKey!) == "wifi-pass-9")
        #expect(out.missingConcepts.isEmpty)
    }

    @Test func unencryptedCredentialsImport() throws {
        let data = try ProfileExporter.export(profile: profile(), credentials: .init(values: ["lastName": "Example"]),
                                              options: .init(includeCredentials: true, confirmedUnencrypted: true))
        let preview = try ProfileImporter.preview(data: data, existing: [])
        #expect(preview.containsCredentials && !preview.needsPassphrase)
        let creds = try ProfileImporter.credentials(of: preview, passphrase: nil, cipher: nil)
        #expect(creds?.values["lastName"] == "Example")
    }

    @Test func existingKeychainValuesAreNeverOverwrittenSilently() throws {
        let existing = profile()
        let creds = SharedCredentials(values: ["lastName": "NeuerName"])
        let data = try ProfileExporter.export(profile: existing, credentials: creds, options: .init(includeCredentials: true, confirmedUnencrypted: true))
        let preview = try ProfileImporter.preview(data: data, existing: [existing])
        #expect(preview.hasConflict)
        let secrets = InMemorySecretStore()
        // Erst als Kopie importieren, damit der Schlüssel existiert, dann zweiter Import auf dasselbe Profil.
        let first = try ProfileImporter.apply(preview, credentials: .init(values: ["lastName": "AlterName"]), strategy: .importAsCopy, existing: [existing], secrets: secrets)
        let copy = first.profile
        let preview2 = try ProfileImporter.preview(data: data, existing: [copy])
        let second = try ProfileImporter.apply(preview2, credentials: creds, strategy: .replaceRecipe, existing: [copy], secrets: secrets)
        #expect(second.credentialConflicts == ["lastName"])
        #expect(try secrets.read(copy.credentialBindings[0].keychainKey) == "AlterName")
        let keep = try ProfileImporter.apply(preview2, credentials: creds, strategy: .replaceRecipe, existing: [copy], secrets: secrets, decisions: ["lastName": .keepExisting])
        #expect(keep.credentialConflicts.isEmpty)
        #expect(try secrets.read(copy.credentialBindings[0].keychainKey) == "AlterName")
        let replace = try ProfileImporter.apply(preview2, credentials: creds, strategy: .replaceRecipe, existing: [copy], secrets: secrets, decisions: ["lastName": .replace])
        #expect(replace.storedConcepts == ["lastName"])
        #expect(try secrets.read(copy.credentialBindings[0].keychainKey) == "NeuerName")
    }

    @Test func conflictStrategies() throws {
        let existing = profile()
        let data = try ProfileExporter.export(profile: existing)
        let preview = try ProfileImporter.preview(data: data, existing: [existing])
        #expect(preview.existingProfileID == existing.id)
        #expect(throws: SharingError.cancelled) {
            try ProfileImporter.apply(preview, credentials: nil, strategy: .cancel, existing: [existing], secrets: InMemorySecretStore())
        }
        let copy = try ProfileImporter.apply(preview, credentials: nil, strategy: .importAsCopy, existing: [existing], secrets: InMemorySecretStore())
        #expect(copy.profile.id != existing.id)
        #expect(copy.profile.name.hasSuffix("(Kopie)"))
        let replaced = try ProfileImporter.apply(preview, credentials: nil, strategy: .replaceRecipe, existing: [existing], secrets: InMemorySecretStore())
        #expect(replaced.profile.id == existing.id)
        #expect(replaced.profile.recipeRevision == existing.recipeRevision + 1)
        #expect(replaced.profile.revisionHistory.last?.revision == existing.recipeRevision)
    }

    @Test func hostileContainersAreRejected() throws {
        #expect(throws: SharingError.self) { try ProfileImporter.preview(data: Data("kein zip".utf8), existing: []) }
        let slip = ZipArchive.write([.init(path: "../evil.sh", data: Data("x".utf8))])
        #expect(throws: SharingError.self) { try ProfileImporter.preview(data: slip, existing: []) }
        let big = Data(count: ProfileImporter.maxContainerBytes + 1)
        #expect(throws: SharingError.self) { try ProfileImporter.preview(data: big, existing: []) }
        let noManifest = ZipArchive.write([.init(path: "intent.json", data: Data("{}".utf8))])
        #expect(throws: SharingError.self) { try ProfileImporter.preview(data: noManifest, existing: []) }
    }

    @Test func unsafeRecipeInContainerIsRejectedOnApply() throws {
        let good = try ProfileExporter.export(profile: profile())
        var entries = try ZipArchive.read(good)
        let i = entries.firstIndex { $0.path == "recipe.yaml" }!
        entries[i].data = Data("""
        recipeVersion: 1
        name: x
        network: {ssid: Hotel_Guest}
        stages:
          - id: a
            actions:
              - check: {target: {role: checkbox, labelAny: ["Buy Premium € 9.99"]}}
        """.utf8)
        let preview = try ProfileImporter.preview(data: ZipArchive.write(entries), existing: [])
        #expect(!preview.recipeIssues.isEmpty)
        #expect(throws: SharingError.self) {
            try ProfileImporter.apply(preview, credentials: nil, strategy: .importAsCopy, existing: [], secrets: InMemorySecretStore())
        }
    }

    @Test func futureFormatVersionIsRejected() throws {
        let data = try ProfileExporter.export(profile: profile())
        var entries = try ZipArchive.read(data)
        let i = entries.firstIndex { $0.path == "manifest.json" }!
        let text = String(decoding: entries[i].data, as: UTF8.self).replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 9")
        entries[i].data = Data(text.utf8)
        #expect(throws: SharingError.unsupportedFormat(9)) { try ProfileImporter.preview(data: ZipArchive.write(entries), existing: []) }
    }

    @Test func exportDialogSummaryListsConceptsWithoutValues() {
        let s = ProfileExporter.credentialSummary(profile())
        #expect(s == ["lastName", "wifiPassphrase"])
        #expect(ProfileExporter.filename(for: profile()) == "Hotel-Muster.captiveprofile")
    }
}
