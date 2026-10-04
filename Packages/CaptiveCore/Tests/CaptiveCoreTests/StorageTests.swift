import Testing
import Foundation
@testable import CaptiveCore

@Suite struct StorageTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("captive-\(UUID().uuidString)")
    }

    private func profile(_ name: String, ssid: String, enabled: Bool = true) -> PortalProfile {
        PortalProfile(name: name, enabled: enabled, network: .init(ssidExact: ssid),
                      intent: .init(instructions: [.submit]))
    }

    @Test func saveLoadDeleteRoundTrip() throws {
        let store = ProfileStore(directory: tempDir())
        let p = profile("Hotel", ssid: "Hotel_Guest")
        try store.save(p)
        #expect(try store.load(p.id).name == "Hotel")
        try store.delete(p.id)
        #expect(throws: ProfileStoreError.notFound) { try store.load(p.id) }
        #expect(throws: ProfileStoreError.notFound) { try store.delete(p.id) }
    }

    @Test func loadAllSortsAndSkipsCorrupt() throws {
        let dir = tempDir()
        let store = ProfileStore(directory: dir)
        try store.save(profile("b-Zug", ssid: "Z"))
        try store.save(profile("A-Hotel", ssid: "H"))
        try Data("kaputt".utf8).write(to: dir.appendingPathComponent("bad.json"))
        #expect(store.loadAll().map(\.name) == ["A-Hotel", "b-Zug"])
    }

    @Test func providerOnlyClaimsEnabledExactSSID() throws {
        let store = ProfileStore(directory: tempDir())
        try store.save(profile("On", ssid: "Net"))
        try store.save(profile("Off", ssid: "Other", enabled: false))
        #expect(store.enabledProfile(ssid: "Net")?.name == "On")
        #expect(store.enabledProfile(ssid: "net") == nil)
        #expect(store.enabledProfile(ssid: "Other") == nil)
        #expect(store.enabledProfile(ssid: "Unknown") == nil)
    }

    @Test func profileFilesContainNoSecrets() throws {
        let dir = tempDir()
        let store = ProfileStore(directory: dir)
        var p = profile("Hotel", ssid: "S")
        p.credentialBindings = [.init(concept: "password", keychainKey: "k.pw", prompt: "Passwort", persistence: .rememberInKeychain)]
        p.wifi = .init(ssid: "S", security: .wpaPersonal, passphraseKeychainKey: "k.wifi")
        try store.save(p)
        let secrets = InMemorySecretStore(["k.pw": "SuperSecret123", "k.wifi": "wifi-pass-9"])
        let text = try String(contentsOf: dir.appendingPathComponent("\(p.id.uuidString).json"), encoding: .utf8)
        #expect(!text.contains("SuperSecret123"))
        #expect(!text.contains("wifi-pass-9"))
        #expect(text.contains("k.pw"))
        #expect(secrets.contains("k.pw"))
    }

    @Test func storeValueProviderResolvesSources() async throws {
        let secrets = InMemorySecretStore(["hotel.lastName": "Example"])
        let provider = StoreValueProvider(secrets: secrets, askValues: ["roomNumber": "417"])
        #expect(await provider.value(for: .keychain("hotel.lastName")) == "Example")
        #expect(await provider.value(for: .ask("roomNumber")) == "417")
        #expect(await provider.value(for: .ask("other")) == nil)
        #expect(await provider.value(for: .keychain("missing")) == nil)
        try secrets.delete("hotel.lastName")
        #expect(await provider.value(for: .keychain("hotel.lastName")) == nil)
    }
}
