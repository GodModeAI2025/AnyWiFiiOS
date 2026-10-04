import Testing
import Foundation
@testable import CaptiveCore

let hotelYAML = """
recipeVersion: 1
profileId: 4FA8
name: Hotel Muster
network:
  ssid: Hotel_Guest
stages:
  - id: terms
    match:
      anyText: [Datenschutz, Privacy, Terms]
    actions:
      - check:
          target:
            role: checkbox
            labelAny: [Datenschutz, Privacy, Terms]
      - tap:
          target:
            role: button
            labelAny: [Weiter, Continue, Accept]
  - id: guest
    match:
      fields: [roomNumber, lastName]
    actions:
      - fill:
          target:
            concept: roomNumber
          value:
            ask: roomNumber
      - fill:
          target:
            concept: lastName
          value:
            keychain: hotel.lastName
      - tap:
          target:
            role: button
            labelAny: [Verbinden, Connect, Login]
success:
  internetAccess: true
"""

@Suite struct PRLParserTests {
    @Test func validYAMLAccepted() throws {
        let r = try PRLCodec.parse(yaml: hotelYAML)
        #expect(r.name == "Hotel Muster")
        #expect(r.ssid == "Hotel_Guest")
        #expect(r.stages.count == 2)
        #expect(r.stages[1].actions.count == 3)
        #expect(r.stages[1].actions[0] == .fill(target: Target(concept: "roomNumber"), value: .ask("roomNumber")))
        #expect(RecipeValidator.errors(r).isEmpty)
    }

    @Test func roundTripIsStable() throws {
        let r = try PRLCodec.parse(yaml: hotelYAML)
        let out = try PRLCodec.serialize(r)
        let again = try PRLCodec.parse(yaml: out)
        #expect(again == r)
        #expect(try PRLCodec.serialize(again) == out)
    }

    @Test func ambiguousScalarsStayStrings() throws {
        let r = Recipe(name: "yes", ssid: "417", stages: [
            Stage(id: "s", actions: [
                .tap(target: Target(labelAny: ["Yes", "no", "417", "true"])),
                .fill(target: Target(concept: "roomNumber"), value: .literal("007")),
            ])
        ])
        let again = try PRLCodec.parse(yaml: PRLCodec.serialize(r))
        #expect(again == r)
    }

    @Test func unknownOpcodeRejected() {
        let y = hotelYAML.replacingOccurrences(of: "- check:", with: "- eval:")
        #expect(throws: PRLError.unknownOpcode("eval")) { try PRLCodec.parse(yaml: y) }
    }

    @Test func javascriptOpcodeRejected() {
        let y = """
        recipeVersion: 1
        name: x
        network: {ssid: x}
        stages:
          - id: a
            actions:
              - script: "document.forms[0].submit()"
        """
        #expect(throws: PRLError.unknownOpcode("script")) { try PRLCodec.parse(yaml: y) }
    }

    @Test func unknownFieldRejected() {
        let y = hotelYAML.replacingOccurrences(of: "success:", with: "extra: 1\nsuccess:")
        #expect(throws: PRLError.unknownField(path: "recipe.extra")) { try PRLCodec.parse(yaml: y) }
    }

    @Test func unknownNestedFieldRejected() {
        let y = hotelYAML.replacingOccurrences(of: "role: checkbox", with: "role: checkbox\n            onclick: x")
        #expect(throws: (any Error).self) { try PRLCodec.parse(yaml: y) }
    }

    @Test func wrongRecipeVersionRejected() {
        let y = hotelYAML.replacingOccurrences(of: "recipeVersion: 1", with: "recipeVersion: 2")
        #expect(throws: PRLError.unsupportedVersion(2)) { try PRLCodec.parse(yaml: y) }
    }

    @Test func duplicateKeyRejected() {
        let y = "recipeVersion: 1\nrecipeVersion: 1\nname: x\nnetwork: {ssid: x}\nstages: []\n"
        #expect(throws: (any Error).self) { try PRLCodec.parse(yaml: y) }
    }

    @Test func emptyTargetRejected() {
        let y = hotelYAML.replacingOccurrences(of: "role: checkbox\n            labelAny: [Datenschutz, Privacy, Terms]", with: "{}")
        #expect(throws: (any Error).self) { try PRLCodec.parse(yaml: y) }
    }

    @Test func garbageRejected() {
        #expect(throws: (any Error).self) { try PRLCodec.parse(yaml: "::: [") }
        #expect(throws: (any Error).self) { try PRLCodec.parse(yaml: "- a\n- b") }
    }

    @Test func codableRoundTripThroughJSON() throws {
        let r = try PRLCodec.parse(yaml: hotelYAML)
        let data = try JSONEncoder().encode(r)
        #expect(try JSONDecoder().decode(Recipe.self, from: data) == r)
    }
}

@Suite struct RecipeValidatorTests {
    @Test func duplicateStageIdsAndEmptyStages() {
        let r = Recipe(name: "n", ssid: "s", stages: [
            Stage(id: "a", actions: [.submit]), Stage(id: "a", actions: []),
        ])
        let msgs = RecipeValidator.errors(r).map(\.message)
        #expect(msgs.contains { $0.contains("doppelte Stage-ID") })
        #expect(msgs.contains { $0.contains("mindestens eine Aktion") })
    }

    @Test func unknownKeychainReference() throws {
        let r = try PRLCodec.parse(yaml: hotelYAML)
        let ctx = ValidationContext(knownKeychainKeys: ["other.key"])
        #expect(RecipeValidator.errors(r, context: ctx).contains { $0.message.contains("hotel.lastName") })
        let ok = ValidationContext(knownKeychainKeys: ["hotel.lastName"])
        #expect(RecipeValidator.errors(r, context: ok).isEmpty)
    }

    @Test func limitsEnforced() {
        let many = (0..<30).map { _ in Action.submit }
        let r = Recipe(name: "n", ssid: "s", stages: [Stage(id: "a", actions: many)])
        #expect(RecipeValidator.errors(r).contains { $0.message.contains("mehr als 20") })
    }
}

@Suite struct SchemaTests {
    @Test func schemaIsValidJSON() throws {
        let obj = try JSONSerialization.jsonObject(with: Data(PRLSchema.json.utf8)) as? [String: Any]
        #expect(obj?["title"] as? String == "Portal Recipe Language v1")
        let props = obj?["properties"] as? [String: Any]
        #expect(Set(props?.keys.map { $0 } ?? []) == ["recipeVersion", "profileId", "name", "network", "stages", "success"])
    }

    @Test func schemaFileMirrorsConstant() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() } // CaptiveCoreTests, Tests, CaptiveCore, Packages
        url.deleteLastPathComponent()
        let file = url.appendingPathComponent("docs/schema/prl-v1.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text == PRLSchema.json + "\n")
    }
}

@Suite struct ProfileTests {
    @Test func networkMatcherIsExact() {
        let m = NetworkMatcher(ssidExact: "Hotel_Guest")
        #expect(m.matches(ssid: "Hotel_Guest"))
        #expect(!m.matches(ssid: "hotel_guest"))
        #expect(!m.matches(ssid: "Hotel_Guest2"))
        #expect(!NetworkMatcher(ssidExact: "").matches(ssid: ""))
    }

    @Test func bssidAllowList() {
        let m = NetworkMatcher(ssidExact: "A", bssidAllowList: ["aa:bb:cc:dd:ee:ff"])
        #expect(m.matches(ssid: "A", bssid: "AA:BB:CC:DD:EE:FF"))
        #expect(!m.matches(ssid: "A", bssid: "11:22:33:44:55:66"))
        #expect(!m.matches(ssid: "A"))
    }

    @Test func conceptSensitivity() {
        #expect(ConceptCatalog.sensitivity(of: "password") == .secret)
        #expect(ConceptCatalog.sensitivity(of: "voucherCode") == .secret)
        #expect(ConceptCatalog.sensitivity(of: "roomNumber") == .personal)
        #expect(ConceptCatalog.sensitivity(of: "somethingNew") == .personal)
        #expect(ConceptCatalog.placeholder(for: "password") == "<secret:password>")
    }

    @Test func profileCodableRoundTrip() throws {
        let recipe = try PRLCodec.parse(yaml: hotelYAML)
        let p = PortalProfile(name: "Hotel", network: .init(ssidExact: "Hotel_Guest"),
                              intent: .init(instructions: [.acceptRequiredTerms, .fill(concept: "roomNumber", source: .askWhenMissing), .submit]),
                              recipe: recipe,
                              credentialBindings: [.init(concept: "lastName", keychainKey: "hotel.lastName", prompt: "Nachname", persistence: .rememberInKeychain)])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(PortalProfile.self, from: enc.encode(p))
        #expect(back.recipe == p.recipe)
        #expect(back.intent == p.intent)
        #expect(back.credentialBindings.first?.sensitivity == .personal)
    }
}
