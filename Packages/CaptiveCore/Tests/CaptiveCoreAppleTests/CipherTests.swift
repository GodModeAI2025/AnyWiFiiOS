#if canImport(CryptoKit) && canImport(CommonCrypto)
import Testing
import Foundation
import CaptiveCore
@testable import CaptiveCoreApple

@Suite struct CipherTests {
    let cipher = CryptoKitCredentialCipher()

    @Test func roundTrip() throws {
        let plain = Data("{\"values\":{\"password\":\"SuperSecret123\"}}".utf8)
        let sealed = try cipher.seal(plain, passphrase: "correct horse")
        #expect(sealed.params.iterations >= 600_000)
        #expect(Data(base64Encoded: sealed.params.salt)?.count == 16)
        #expect(!String(decoding: sealed.ciphertext, as: UTF8.self).contains("SuperSecret123"))
        #expect(try cipher.open(sealed.ciphertext, passphrase: "correct horse", params: sealed.params) == plain)
    }

    @Test func wrongPassphraseAndTamperingFail() throws {
        let sealed = try cipher.seal(Data("geheim".utf8), passphrase: "correct horse")
        #expect(throws: (any Error).self) { try cipher.open(sealed.ciphertext, passphrase: "wrong horse", params: sealed.params) }
        var bad = sealed.ciphertext
        bad[0] ^= 0xFF
        #expect(throws: (any Error).self) { try cipher.open(bad, passphrase: "correct horse", params: sealed.params) }
    }

    @Test func saltAndNonceAreFreshEachTime() throws {
        let a = try cipher.seal(Data("x".utf8), passphrase: "passphrase1")
        let b = try cipher.seal(Data("x".utf8), passphrase: "passphrase1")
        #expect(a.params.salt != b.params.salt)
        #expect(a.params.nonce != b.params.nonce)
        #expect(a.ciphertext != b.ciphertext)
    }

    @Test func weakIterationCountsAreRejected() throws {
        #expect(CryptoKitCredentialCipher(iterations: 1000).iterations == 600_000)
        let sealed = try cipher.seal(Data("x".utf8), passphrase: "passphrase1")
        var weak = sealed.params
        weak.iterations = 1000
        #expect(throws: (any Error).self) { try cipher.open(sealed.ciphertext, passphrase: "passphrase1", params: weak) }
    }

    @Test func fullShareRoundTripWithRealCrypto() throws {
        let secrets = InMemorySecretStore()
        let id = UUID()
        var p = PortalProfile(id: id, name: "Hotel", network: .init(ssidExact: "H"),
                              intent: .init(instructions: [.fill(concept: "password", source: .keychain), .submit]),
                              credentialBindings: [.init(concept: "password", keychainKey: "k.pw", prompt: "Passwort", persistence: .rememberInKeychain)])
        p.commit(Recipe(name: "Hotel", ssid: "H", stages: [Stage(id: "a", actions: [
            .fill(target: Target(concept: "password"), value: .keychain("k.pw")), .submit])]), note: "t")
        let data = try ProfileExporter.export(profile: p, credentials: SharedCredentials(values: ["password": "SuperSecret123"]),
                                              options: .init(includeCredentials: true, passphrase: "teilen-123"), cipher: cipher)
        for e in try ZipArchive.read(data) { #expect(!String(decoding: e.data, as: UTF8.self).contains("SuperSecret123")) }
        let preview = try ProfileImporter.preview(data: data, existing: [])
        #expect(preview.needsPassphrase)
        #expect(throws: SharingError.wrongPassphrase) { try ProfileImporter.credentials(of: preview, passphrase: "falsch-123", cipher: cipher) }
        let creds = try ProfileImporter.credentials(of: preview, passphrase: "teilen-123", cipher: cipher)
        let out = try ProfileImporter.apply(preview, credentials: creds, strategy: .importAsCopy, existing: [], secrets: secrets)
        #expect(try secrets.read(out.profile.credentialBindings[0].keychainKey) == "SuperSecret123")
    }
}
#endif
