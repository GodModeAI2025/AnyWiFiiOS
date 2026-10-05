#if canImport(CryptoKit) && canImport(CommonCrypto)
import Foundation
import CryptoKit
import CommonCrypto
import CaptiveCore

/// AES-256-GCM, Schlüssel per PBKDF2-HMAC-SHA256 (SPEC §3.4): mindestens 600 000 Iterationen,
/// zufälliger 16-Byte-Salt. Salt, Iterationen und Nonce stehen im Manifest.
public struct CryptoKitCredentialCipher: CredentialCipher {
    public static let defaultIterations = 600_000
    public let iterations: Int

    public init(iterations: Int = CryptoKitCredentialCipher.defaultIterations) {
        self.iterations = max(iterations, Self.defaultIterations)
    }

    public enum CipherError: Error, Equatable { case derivation, random, malformed }

    public func seal(_ plaintext: Data, passphrase: String) throws -> (ciphertext: Data, params: EncryptionParams) {
        var salt = Data(count: 16)
        let status = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard status == errSecSuccess else { throw CipherError.random }
        let key = try Self.deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let nonce = AES.GCM.Nonce()
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
        // `ciphertext || tag`, Nonce steht separat im Manifest.
        let params = EncryptionParams(iterations: iterations, salt: salt.base64EncodedString(),
                                      nonce: Data(nonce).base64EncodedString())
        return (Data(box.ciphertext + box.tag), params)
    }

    public func open(_ ciphertext: Data, passphrase: String, params: EncryptionParams) throws -> Data {
        guard params.algorithm == "AES-256-GCM", params.kdf == "PBKDF2-HMAC-SHA256",
              params.iterations >= Self.defaultIterations,
              let salt = Data(base64Encoded: params.salt), salt.count == 16,
              let nonceData = Data(base64Encoded: params.nonce), ciphertext.count > 16 else { throw CipherError.malformed }
        let key = try Self.deriveKey(passphrase: passphrase, salt: salt, iterations: params.iterations)
        // Eigenständige Kopien: Data-Slices behalten ihre Startindizes und sind für CryptoKit unzuverlässig.
        let bytes = Data(ciphertext)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonceData),
                                        ciphertext: Data(bytes.prefix(bytes.count - 16)), tag: Data(bytes.suffix(16)))
        return try AES.GCM.open(box, using: key)
    }

    static func deriveKey(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let pass = Array(passphrase.utf8)
        let status = derived.withUnsafeMutableBufferPointer { out in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     pass.map { Int8(bitPattern: $0) }, pass.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress!, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                     out.baseAddress!, 32)
            }
        }
        guard status == kCCSuccess else { throw CipherError.derivation }
        return SymmetricKey(data: derived)
    }
}
#endif
