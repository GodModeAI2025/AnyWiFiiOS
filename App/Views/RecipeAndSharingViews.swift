import CaptiveCore
import CaptiveCoreApple
import SwiftData
import SwiftUI

/// Erweitert-Modus (01 §29): YAML ansehen/bearbeiten. Gespeichert wird nur nach Parse, Schema und Security-Prüfung.
struct RecipeEditorView: View {
    @Bindable var profile: ProfileRecord
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var issues: [String] = []
    @State private var validated = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: text) { validated = false }
                if !issues.isEmpty {
                    List(issues, id: \.self) { Label($0, systemImage: "xmark.octagon").foregroundStyle(.red) }
                        .frame(maxHeight: 180)
                } else if validated {
                    Label("Gültig", systemImage: "checkmark.circle").foregroundStyle(.green).padding()
                }
            }
            .navigationTitle("Recipe (Revision \(profile.recipeRevision))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Validieren") { _ = validate() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") {
                        if let recipe = validate() {
                            try? profile.replaceRecipe(recipe)
                            try? context.save()
                            dismiss()
                        }
                    }
                }
            }
            .onAppear { text = profile.recipeYAML ?? "" }
        }
    }

    private func validate() -> Recipe? {
        do {
            let recipe = try PRLCodec.decode(yaml: text)
            let found = RecipeValidator(keychainBindings: profile.keychainBindings).validate(recipe)
            issues = found.map(\.description)
            validated = found.isEmpty
            return found.isEmpty ? recipe : nil
        } catch let error as PRLError {
            issues = [error.description]
        } catch {
            issues = ["YAML nicht lesbar: \(error.localizedDescription)"]
        }
        validated = false
        return nil
    }
}

/// Export mit Opt-in für Zugangsdaten (SPEC §3.4).
struct ExportProfileView: View {
    let profile: ProfileRecord
    @Environment(\.dismiss) private var dismiss
    @State private var includeCredentials = false
    @State private var encrypt = true
    @State private var passphrase = ""
    @State private var confirmCredentials = false
    @State private var confirmUnencrypted = false
    @State private var exportURL: URL?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Zugangsdaten mitteilen", isOn: Binding(
                        get: { includeCredentials },
                        set: { newValue in if newValue { confirmCredentials = true } else { includeCredentials = false } }))
                } footer: {
                    Text("Standard: Das Profil enthält nur den Ablauf. Empfänger werden nach eigenen Werten gefragt.")
                }
                if includeCredentials {
                    Section {
                        Toggle("Mit Passphrase verschlüsseln", isOn: Binding(
                            get: { encrypt },
                            set: { newValue in if newValue { encrypt = true } else { confirmUnencrypted = true } }))
                        if encrypt { SecureField("Passphrase (mind. 8 Zeichen)", text: $passphrase) }
                    } footer: {
                        Text(encrypt ? "Gib die Passphrase auf einem anderen Weg weiter." : "Unverschlüsselt: Jeder mit der Datei sieht die Zugangsdaten.")
                    }
                }
                Section {
                    Button("Datei erstellen") { build() }
                        .disabled(includeCredentials && encrypt && passphrase.count < 8)
                    if let exportURL {
                        ShareLink(item: exportURL) { Label("Teilen …", systemImage: "square.and.arrow.up") }
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Profil teilen")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } } }
            .alert("Zugangsdaten mitteilen?", isPresented: $confirmCredentials) {
                Button("Mitteilen", role: .destructive) { includeCredentials = true }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Empfänger erhalten: " + profile.credentialSlots.map(\.label).joined(separator: ", ") + ".")
            }
            .alert("Unverschlüsselt teilen?", isPresented: $confirmUnencrypted) {
                Button("Unverschlüsselt teilen", role: .destructive) { encrypt = false }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Die Zugangsdaten stehen dann im Klartext in der Datei.")
            }
        }
    }

    private func build() {
        guard let recipe = profile.recipe else {
            error = "Das Profil hat noch keinen gelernten Ablauf. Melde dich einmal im Portal-WLAN an und teile es danach."
            return
        }
        let slots = profile.credentialSlots
        var credentials: ProfilePackage.Credentials = .none
        if includeCredentials {
            var values: [String: String] = [:]
            for slot in slots { if let v = try? AppConfig.keychain.get(slot.key) { values[slot.key] = v } }
            credentials = encrypt ? .encrypted(values, passphrase: passphrase) : .plain(values)
        }
        do {
            let data = try ProfilePackage.export(profileName: profile.name, recipe: recipe, wifi: profile.wifi, slots: slots,
                                                 intentJSON: profile.intentJSON, credentials: credentials)
            let safe = profile.name.map { $0.isLetter || $0.isNumber ? $0 : "-" }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(String(safe)).captiveprofile")
            try data.write(to: url, options: [.atomic])
            exportURL = url
            error = nil
        } catch {
            self.error = "Export fehlgeschlagen: \(error.localizedDescription)"
        }
    }

}

/// Import mit Vorschau, Passphrase und Konfliktbehandlung (01 §31, SPEC §3.4).
struct ImportProfileView: View {
    let fileURL: URL
    let onImported: (ProfileRecord) -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var profiles: [ProfileRecord]
    @State private var manifest: ProfileManifest?
    @State private var data: Data?
    @State private var passphrase = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if let manifest {
                    Section("Profil") {
                        LabeledContent("Name", value: manifest.profileName)
                        if let wifi = manifest.wifi { LabeledContent("WLAN", value: wifi.ssid) }
                        LabeledContent("Zugangsdaten", value: manifest.containsCredentials
                                       ? (manifest.credentialsEncrypted ? "enthalten, verschlüsselt" : "enthalten, unverschlüsselt")
                                       : "nicht enthalten")
                    }
                    if manifest.containsCredentials && manifest.credentialsEncrypted {
                        Section { SecureField("Passphrase", text: $passphrase) }
                    }
                    if profiles.contains(where: { $0.ssid == manifest.wifi?.ssid && manifest.wifi != nil }) {
                        Section {
                            Text("Für dieses WLAN gibt es schon ein Profil. Der Import wird als Kopie angelegt. Vorhandene Schlüsselbund-Werte bleiben unverändert.")
                                .font(.footnote)
                        }
                    }
                    Section { Button("Importieren") { importNow(manifest) } }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Profil importieren")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .onAppear(perform: load)
        }
    }

    private func load() {
        let access = fileURL.startAccessingSecurityScopedResource()
        defer { if access { fileURL.stopAccessingSecurityScopedResource() } }
        do {
            let raw = try Data(contentsOf: fileURL)
            data = raw
            manifest = try ProfilePackage.inspect(raw)
        } catch {
            self.error = "Keine gültige CaptiveAI-Datei."
        }
    }

    private func importNow(_ manifest: ProfileManifest) {
        guard let data else { return }
        do {
            let imported = try ProfilePackage.importProfile(data, passphrase: passphrase.isEmpty ? nil : passphrase)
            let intent = imported.intentJSON.flatMap { try? JSONDecoder().decode(PortalIntent.self, from: $0) }
                ?? PortalIntent(instructions: [.submit], bindings: [:], originalInstruction: "")
            let profile = ProfileRecord(name: manifest.profileName, ssid: manifest.wifi?.ssid ?? imported.recipe.network.ssid,
                                        wifiSecurity: manifest.wifi?.security, intent: intent)
            // Keychain-Schlüssel des Absenders auf dieses Profil umschreiben.
            var mapping: [String: String] = [:]
            var newIntent = intent
            for (concept, binding) in intent.bindings {
                if case .keychain(let oldKey) = binding {
                    let newKey = "\(profile.keychainPrefix).\(concept.rawValue)"
                    mapping[oldKey] = newKey
                    newIntent.bindings[concept] = .keychain(newKey)
                }
            }
            if let wifiKey = manifest.wifi?.passphraseKey { mapping[wifiKey] = profile.wifiPassphraseKey }
            profile.intent = newIntent
            try profile.replaceRecipe(Self.rekey(imported.recipe, mapping: mapping))
            for (oldKey, value) in imported.credentials ?? [:] {
                if let newKey = mapping[oldKey] { try? AppConfig.keychain.setIfAbsent(value, for: newKey) }
            }
            context.insert(profile)
            try context.save()
            onImported(profile)
            dismiss()
        } catch ProfilePackage.Failure.wrongPassphrase {
            error = "Passphrase falsch."
        } catch ProfilePackage.Failure.passphraseRequired {
            error = "Bitte Passphrase eingeben."
        } catch {
            self.error = "Import fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    /// Ersetzt Keychain-Schlüssel im Recipe (`keychain: alt` → `keychain: neu`).
    static func rekey(_ recipe: Recipe, mapping: [String: String]) -> Recipe {
        var copy = recipe
        for s in copy.stages.indices {
            for a in copy.stages[s].actions.indices {
                if case .fill(var fill) = copy.stages[s].actions[a], case .keychain(let key) = fill.value,
                   let newKey = mapping[key] {
                    fill.value = .keychain(newKey)
                    copy.stages[s].actions[a] = .fill(fill)
                }
            }
        }
        return copy
    }
}
