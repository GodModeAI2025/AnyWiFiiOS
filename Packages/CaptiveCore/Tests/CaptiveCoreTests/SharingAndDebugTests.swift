import Foundation
import XCTest
@testable import CaptiveCore

final class ZipArchiveTests: XCTestCase {
    func testCRC32KnownVector() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testRoundTripAndDeterminism() throws {
        let entries = [ZipArchive.Entry(path: "a.txt", text: "Hallo"), .init(path: "dir/ü.json", text: "{}")]
        let first = try ZipArchive.write(entries)
        XCTAssertEqual(first, try ZipArchive.write(entries), "Gleiche Eingabe → gleiche Bytes")
        XCTAssertEqual(try ZipArchive.read(first), entries)
        XCTAssertEqual(first.prefix(4), Data([0x50, 0x4B, 0x03, 0x04]))
    }

    func testRejectsUnsafePaths() {
        for path in ["../evil", "/etc/passwd", "a/../../b", "a\\b", ""] {
            XCTAssertThrowsError(try ZipArchive.write([.init(path: path, text: "x")]), path)
        }
    }

    func testDetectsCorruption() throws {
        var data = try ZipArchive.write([.init(path: "a.txt", text: "Hallo Welt")])
        data[36] ^= 0xFF // ein Byte im Inhalt kippen (Header 30 + Name 5 → Inhalt ab 35)
        XCTAssertThrowsError(try ZipArchive.read(data)) { error in
            XCTAssertEqual(error as? ZipArchive.Failure, .checksumMismatch("a.txt"))
        }
    }
}

final class PBKDF2Tests: XCTestCase {
    /// Testvektoren PBKDF2-HMAC-SHA256 (RFC 7914 §11 bzw. verbreitete Referenzwerte).
    func testKnownVectors() {
        let one = PBKDF2.derive(password: Data("password".utf8), salt: Data("salt".utf8), iterations: 1, byteCount: 32)
        XCTAssertEqual(hex(one), "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        let two = PBKDF2.derive(password: Data("password".utf8), salt: Data("salt".utf8), iterations: 2, byteCount: 32)
        XCTAssertEqual(hex(two), "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
        let rfc = PBKDF2.derive(password: Data("passwd".utf8), salt: Data("salt".utf8), iterations: 1, byteCount: 64)
        XCTAssertEqual(hex(rfc), "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc"
                       + "49ca9cccf179b645991664b39d77ef317c71b845b1e30bd509112041d3a19783")
    }

    private func hex(_ data: Data) -> String {
        let digits = Array("0123456789abcdef")
        return String(data.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0x0F)]] })
    }
}

/// SPEC §3.4 Export-Roundtrips: ohne / mit verschlüsselt / mit unverschlüsselt / falsche Passphrase.
final class ProfilePackageTests: XCTestCase {
    private let slots = [
        CredentialSlot(key: "hotel.lastName", concept: .lastName, label: "Nachname"),
        CredentialSlot(key: "wifi.passphrase", concept: nil, label: "WLAN-Passwort"),
    ]
    private let wifi = WiFiConfig(ssid: "Hotel_Guest", security: .wpaPersonal, passphraseKey: "wifi.passphrase")
    private let secrets = ["hotel.lastName": "Example", "wifi.passphrase": "Sommer2026!"]
    private let iterations = ProfilePackage.minimumIterations

    private func recipe() throws -> Recipe { try Fixtures.recipe("valid", "05_hotel") }

    func testDefaultExportContainsNoSecrets() throws {
        let data = try ProfilePackage.export(profileName: "Hotel Muster", recipe: recipe(), wifi: wifi,
                                             slots: slots, credentials: .none)
        let raw = String(decoding: data, as: UTF8.self)
        for value in secrets.values { XCTAssertFalse(raw.contains(value)) }
        let imported = try ProfilePackage.importProfile(data)
        XCTAssertNil(imported.credentials)
        XCTAssertEqual(imported.recipe, try recipe())
        XCTAssertEqual(imported.manifest.wifi, wifi)
        XCTAssertFalse(imported.manifest.containsCredentials)
    }

    func testEncryptedCredentialsRoundTrip() throws {
        let data = try ProfilePackage.export(profileName: "Hotel Muster", recipe: recipe(), wifi: wifi, slots: slots,
                                             credentials: .encrypted(secrets, passphrase: "korrekt pferd"),
                                             iterations: iterations)
        let raw = String(decoding: data, as: UTF8.self)
        for value in secrets.values { XCTAssertFalse(raw.contains(value), "Klartext im verschlüsselten Export") }

        let manifest = try ProfilePackage.inspect(data)
        XCTAssertTrue(manifest.containsCredentials)
        XCTAssertTrue(manifest.credentialsEncrypted)
        XCTAssertEqual(manifest.cipher, "AES-256-GCM")

        XCTAssertThrowsError(try ProfilePackage.importProfile(data)) {
            XCTAssertEqual($0 as? ProfilePackage.Failure, .passphraseRequired)
        }
        XCTAssertThrowsError(try ProfilePackage.importProfile(data, passphrase: "falsch")) {
            XCTAssertEqual($0 as? ProfilePackage.Failure, .wrongPassphrase)
        }
        XCTAssertEqual(try ProfilePackage.importProfile(data, passphrase: "korrekt pferd").credentials, secrets)
    }

    func testPlainCredentialsRoundTripIsMarked() throws {
        let data = try ProfilePackage.export(profileName: "Hotel Muster", recipe: recipe(), wifi: wifi, slots: slots,
                                             credentials: .plain(secrets))
        let manifest = try ProfilePackage.inspect(data)
        XCTAssertTrue(manifest.containsCredentials)
        XCTAssertFalse(manifest.credentialsEncrypted)
        XCTAssertEqual(try ProfilePackage.importProfile(data).credentials, secrets)
        let readme = try ZipArchive.read(data).first { $0.path == "README.txt" }
        XCTAssertTrue(String(decoding: readme!.data, as: UTF8.self).contains("unverschlüsselt"))
    }

    func testUnknownCredentialKeysAreRejected() throws {
        XCTAssertThrowsError(try ProfilePackage.export(profileName: "x", recipe: recipe(), wifi: nil, slots: slots,
                                                       credentials: .plain(["other.key": "v"]))) {
            XCTAssertEqual($0 as? ProfilePackage.Failure, .unknownCredentialKey("other.key"))
        }
    }

    func testWeakKeyDerivationIsRejectedOnImport() throws {
        let data = try ProfilePackage.export(profileName: "x", recipe: recipe(), wifi: nil, slots: slots,
                                             credentials: .encrypted(secrets, passphrase: "p"), iterations: 10)
        XCTAssertThrowsError(try ProfilePackage.importProfile(data, passphrase: "p")) {
            XCTAssertEqual($0 as? ProfilePackage.Failure, .weakKeyDerivation)
        }
    }

    func testGarbageIsNotAProfile() {
        XCTAssertThrowsError(try ProfilePackage.inspect(Data("hello".utf8))) {
            XCTAssertEqual($0 as? ProfilePackage.Failure, .notAProfile)
        }
    }
}

/// SPEC §3.3: Debug-Paket vollständig, für Agenten lesbar, ohne Secrets (02 §18, Gate S12).
final class DebugBundleTests: XCTestCase {
    func testFailedRunProducesCompleteRedactedBundle() async throws {
        let manifest = try PortalManifest.load()
        let tv = manifest.testValues
        let portal = FakePortal(portal: "10_changed_labels", manifest: manifest)
        let values = StaticValueProvider(keychain: ["hotel.lastName": tv["lastName"]!], asked: [.roomNumber: tv["roomNumber"]!])
        let recipe = try Fixtures.recipe("valid", "05_hotel")
        let result = await RecipeRunner(transport: portal, values: values).run(recipe)
        XCTAssertEqual(result.outcome, .recipeMismatch)

        let builder = DebugBundleBuilder(
            profileName: "Hotel Muster", recipe: recipe, recipeRevision: 3, result: result,
            environment: DebugEnvironment(appVersion: "1.0", osVersion: "iOS 27.0", device: "iPhone",
                                          mode: "manual", modelAvailability: "available"),
            createdAt: Date(timeIntervalSince1970: 1_790_000_000),
            knownSecrets: Array(tv.values))
        let zip = try builder.archive()
        let files = Dictionary(try ZipArchive.read(zip).map { ($0.path, String(decoding: $0.data, as: UTF8.self)) },
                               uniquingKeysWith: { a, _ in a })

        for required in ["README.md", "summary.json", "recipe.yaml", "trace.jsonl", "pages/01.yaml",
                         "environment.json", "schema/prl-v1.json"] {
            XCTAssertNotNil(files[required], "\(required) fehlt")
        }
        XCTAssertTrue(files["summary.json"]!.contains("\"outcome\" : \"recipeMismatch\""))
        XCTAssertTrue(files["README.md"]!.contains("Stage `guest`, Aktion 2"))
        XCTAssertTrue(files["pages/01.yaml"]!.contains("Join Wi-Fi"), "Seite muss das geänderte Label zeigen")
        XCTAssertTrue(builder.fileName.hasPrefix("CaptiveAI-Debug-Hotel-Muster-"))
        _ = try PRLCodec.decode(yaml: files["recipe.yaml"]!)

        // Gate S12: keiner der Testwerte, keine Session-/CSRF-Token im Klartext.
        let corpus = files.filter { !$0.key.hasPrefix("schema/") }.values.joined(separator: "\n")
        for (key, secret) in tv {
            let regex = try NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: secret) + "\\b")
            XCTAssertEqual(regex.numberOfMatches(in: corpus, range: NSRange(corpus.startIndex..., in: corpus)), 0,
                           "\(key) steht im Debug-Paket")
        }
        XCTAssertFalse(corpus.contains(portal.state.session))
        XCTAssertFalse(corpus.contains(portal.state.csrf))
    }

    func testPageRedactionKeepsStructure() throws {
        let page = try PortalNormalizer.normalize(
            html: #"<form action="/auth?token=abc"><input type="hidden" name="csrf" value="s3cr3t"><input name="room" value="417"><input type="checkbox" name="terms" value="1"></form>"#,
            url: URL(string: "http://portal.test/p?mac=02:00:00:00:00:01")!)
        let redacted = DebugBundleBuilder.redacted(page)
        let controls = redacted.forms[0].controls
        XCTAssertEqual(controls.map(\.name), ["csrf", "room", "terms"])
        XCTAssertEqual(controls.map(\.value), ["<hidden>", "<value>", "1"])
        XCTAssertEqual(redacted.url.query, "mac=x")
        XCTAssertEqual(redacted.forms[0].action.query, "token=x")
    }
}
