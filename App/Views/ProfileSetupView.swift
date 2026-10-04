import CaptiveCore
import CaptiveCoreApple
import SwiftData
import SwiftUI

/// Profil im Dialog einrichten (01 §4.2, SPEC §3.2).
struct ProfileSetupView: View {
    struct Message: Identifiable, Equatable {
        enum Author { case user, assistant }
        let id = UUID()
        let author: Author
        let text: String
    }

    let onCreated: (ProfileRecord) -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var ssid = ""
    @State private var hasWiFi = false
    @State private var security: WiFiSecurity = .wpaPersonal
    @State private var wifiPassphrase = ""

    @State private var messages: [Message] = [
        .init(author: .assistant, text: "Beschreib mir, was im Anmeldeportal zu tun ist. Zum Beispiel: „Datenschutz akzeptieren, Zimmernummer jedes Mal fragen, Nachname speichern, dann Verbinden.“"),
    ]
    @State private var input = ""
    @State private var draft = IntentDraft()
    @State private var instructions: [String] = []
    @State private var secrets: [Concept: String] = [:]
    @State private var busy = false
    @State private var chat: AnyObject?

    var body: some View {
        NavigationStack {
            Form {
                Section("Netzwerk") {
                    TextField("Profilname, z. B. Hotel Muster", text: $name)
                    TextField("WLAN-Name (SSID)", text: $ssid)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("WLAN-Zugang mitspeichern", isOn: $hasWiFi)
                    if hasWiFi {
                        Picker("Sicherheit", selection: $security) {
                            Text("Offen").tag(WiFiSecurity.open)
                            Text("WPA-Personal").tag(WiFiSecurity.wpaPersonal)
                        }
                        if security == .wpaPersonal {
                            SecureField("WLAN-Passwort", text: $wifiPassphrase)
                        }
                    }
                }

                Section {
                    ForEach(messages) { message in
                        HStack {
                            if message.author == .user { Spacer(minLength: 40) }
                            Text(message.text)
                                .padding(10)
                                .background(message.author == .user ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 12))
                            if message.author == .assistant { Spacer(minLength: 40) }
                        }
                        .listRowSeparator(.hidden)
                    }
                    HStack {
                        TextField("Anweisung …", text: $input, axis: .vertical)
                            .lineLimit(1...4)
                        if busy { ProgressView() }
                        Button { Task { await send() } } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                            .accessibilityLabel("Senden")
                    }
                } header: {
                    Text("Anmeldung beschreiben")
                } footer: {
                    Text(PlannerFactory.modelDescription)
                }

                if !draft.fields.isEmpty || draft.acceptTerms {
                    Section("So verstehe ich es") {
                        let intent = draft.makeIntent(keychainPrefix: "preview", originalInstruction: "")
                        ForEach(intent.summaryLines, id: \.self) { Text($0) }
                    }
                }

                let remembered = draft.fields.filter { $0.storage == .remember }
                if !remembered.isEmpty {
                    Section {
                        ForEach(remembered, id: \.concept) { field in
                            SecureField(field.concept.displayName, text: Binding(
                                get: { secrets[field.concept] ?? "" },
                                set: { secrets[field.concept] = $0 }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    } header: {
                        Text("Werte sicher speichern")
                    } footer: {
                        Text("Diese Werte landen nur im Schlüsselbund dieses Geräts, nie im Chat. Leer lassen, um später gefragt zu werden.")
                    }
                }
            }
            .navigationTitle("Neues Profil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Speichern") { save() }
                        .disabled(name.isEmpty || ssid.isEmpty || (draft.fields.isEmpty && !draft.acceptTerms))
                }
            }
        }
    }

    private func send() async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        messages.append(.init(author: .user, text: text))
        instructions.append(text)
        busy = true
        defer { busy = false }

        var updated: IntentDraft?
        if #available(iOS 26.0, *), IntentChat.isAvailable {
            let session = (chat as? IntentChat) ?? IntentChat()
            chat = session
            updated = try? await session.send(text)
        }
        // Ohne Apple Intelligence oder bei Modellfehler: regelbasiert, kumulativ über alle Nachrichten.
        draft = updated ?? InstructionParser.parse(instructions.joined(separator: ". "))

        if let question = draft.followUpQuestion {
            messages.append(.init(author: .assistant, text: question))
        } else {
            messages.append(.init(author: .assistant, text: "Verstanden. Prüfe die Zusammenfassung und speichere das Profil."))
        }
    }

    private func save() {
        let original = instructions.joined(separator: " ")
        let profile = ProfileRecord(name: name, ssid: ssid, wifiSecurity: hasWiFi ? security : nil,
                                    intent: PortalIntent(instructions: [], bindings: [:], originalInstruction: original))
        let intent = draft.makeIntent(keychainPrefix: profile.keychainPrefix, originalInstruction: original)
        profile.intent = intent
        for field in draft.fields where field.storage == .remember {
            if let value = secrets[field.concept], !value.isEmpty {
                try? AppConfig.keychain.set(value, for: "\(profile.keychainPrefix).\(field.concept.rawValue)")
            }
        }
        if hasWiFi, security == .wpaPersonal, !wifiPassphrase.isEmpty {
            try? AppConfig.keychain.set(wifiPassphrase, for: profile.wifiPassphraseKey)
        }
        context.insert(profile)
        try? context.save()
        onCreated(profile)
        dismiss()
    }
}
