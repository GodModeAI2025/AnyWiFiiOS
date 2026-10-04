import SwiftUI
import CaptiveCore
import CaptiveCoreApple

struct ProfileDetailView: View {
    @Environment(AppModel.self) private var model
    let profileID: UUID

    @State private var draft: PortalProfile?
    @State private var showCredential = false
    @State private var wifiPassphrase = ""
    @State private var wifiStatus: String?
    @State private var showAdvanced = false
    @State private var showChat = false
    @State private var loginStatus: String?
    @State private var askConcept: String?

    var body: some View {
        Group {
            if let binding = Binding($draft) {
                Form {
                    loginSection(binding)
                    generalSection(binding)
                    credentialSection(binding)
                    wifiSection(binding)
                    recipeSection(binding)
                }
                .navigationTitle(binding.wrappedValue.name)
                .navigationBarTitleDisplayMode(.inline)
                .onChange(of: draft) { _, new in if let new { model.save(new) } }
            } else {
                ProgressView()
            }
        }
        .onAppear { draft = model.profile(profileID) }
        .onChange(of: profileID) { _, id in draft = model.profile(id) }
        .sheet(isPresented: $showCredential) {
            if let d = draft {
                CredentialSheet(profile: d) { binding, value in
                    var p = d
                    p.credentialBindings.removeAll { $0.concept == binding.concept }
                    p.credentialBindings.append(binding)
                    if binding.persistence == .rememberInKeychain, !value.isEmpty {
                        try? model.secrets.write(value, for: binding.keychainKey)
                    }
                    draft = p
                }
            }
        }
        .sheet(item: Binding(get: { askConcept.map(AskItem.init) }, set: { askConcept = $0?.concept })) { item in
            AskValueSheet(concept: item.concept, prompt: promptText(item.concept), secure: ConceptCatalog.sensitivity(of: item.concept) == .secret) { value in
                runLogin(askValues: [item.concept: value])
            }
        }
        .sheet(isPresented: $showChat) {
            if let d = draft {
                ChatView(profile: d) { updated in draft = updated }
            }
        }
        .sheet(isPresented: $showAdvanced) {
            if let d = draft {
                RecipeEditorView(profile: d) { updated in draft = updated }
            }
        }
    }

    struct AskItem: Identifiable { var concept: String; var id: String { concept } }

    @ViewBuilder private func loginSection(_ p: Binding<PortalProfile>) -> some View {
        Section {
            Button {
                runLogin(askValues: [:])
            } label: {
                if model.running.contains(profileID) {
                    HStack { ProgressView(); Text("Melde an …") }
                } else {
                    Label("Jetzt anmelden", systemImage: "wifi.router")
                }
            }
            .disabled(model.running.contains(profileID))
            .accessibilityIdentifier("login-now")
            if let loginStatus {
                Text(loginStatus).font(.footnote)
                    .accessibilityIdentifier("login-status")
            }
        } header: {
            Text("Anmeldung")
        } footer: {
            Text("Manueller Modus: Die App öffnet die Anmeldeseite des aktuellen WLANs und führt den gelernten Ablauf aus.")
        }
    }

    private func promptText(_ concept: String) -> String {
        draft?.credentialBindings.first { $0.concept == concept }?.prompt ?? concept
    }

    private func runLogin(askValues: [String: String]) {
        Task {
            guard let report = await model.login(profileID, askValues: askValues) else { return }
            draft = model.profile(profileID)
            switch report.result.outcome {
            case .success:
                loginStatus = report.learned
                    ? String(localized: "Angemeldet. Der Ablauf wurde gelernt (Revision \(report.profile.recipeRevision)).")
                    : String(localized: "Angemeldet.")
            case .missingUserValue:
                askConcept = report.result.requiredConcept
                loginStatus = nil
            default:
                loginStatus = String(localized: "\(report.result.outcome.explanation)")
            }
        }
    }

    @ViewBuilder private func generalSection(_ p: Binding<PortalProfile>) -> some View {
        Section("Allgemein") {
            TextField("Profilname", text: p.name)
                .accessibilityIdentifier("detail-name")
            TextField("WLAN (SSID)", text: p.network.ssidExact)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Toggle("Profil aktiv", isOn: p.enabled)
        }
    }

    @ViewBuilder private func credentialSection(_ p: Binding<PortalProfile>) -> some View {
        Section {
            ForEach(p.wrappedValue.credentialBindings, id: \.concept) { b in
                HStack {
                    VStack(alignment: .leading) {
                        Text(b.prompt)
                        Text(persistenceText(b.persistence)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: model.secrets.contains(b.keychainKey) ? "lock.fill" : "lock.open")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(model.secrets.contains(b.keychainKey) ? "Gespeichert" : "Nicht gespeichert")
                }
            }
            .onDelete { idx in
                for i in idx {
                    let b = p.wrappedValue.credentialBindings[i]
                    try? model.secrets.delete(b.keychainKey)
                }
                p.wrappedValue.credentialBindings.remove(atOffsets: idx)
            }
            Button("Wert hinzufügen", systemImage: "plus") { showCredential = true }
                .accessibilityIdentifier("add-credential")
        } header: {
            Text("Werte für die Anmeldung")
        } footer: {
            Text("Passwörter und persönliche Werte liegen im Schlüsselbund, nie im Profil.")
        }
    }

    @ViewBuilder private func wifiSection(_ p: Binding<PortalProfile>) -> some View {
        Section {
            Toggle("WLAN-Zugang speichern", isOn: Binding(
                get: { p.wrappedValue.wifi != nil },
                set: { on in
                    p.wrappedValue.wifi = on ? WiFiConfiguration(ssid: p.wrappedValue.network.ssidExact, security: .open) : nil
                }))
            if p.wrappedValue.wifi != nil {
                Picker("Sicherheit", selection: Binding(
                    get: { p.wrappedValue.wifi?.security ?? .open },
                    set: { p.wrappedValue.wifi?.security = $0 })) {
                    Text("Offen").tag(WiFiConfiguration.Security.open)
                    Text("WPA2/WPA3 Personal").tag(WiFiConfiguration.Security.wpaPersonal)
                }
                if p.wrappedValue.wifi?.security == .wpaPersonal {
                    SecureField("Passphrase", text: $wifiPassphrase)
                        .onSubmit { storeWiFiPassphrase(p) }
                }
                Button("WLAN auf diesem Gerät einrichten", systemImage: "wifi") { setUpWiFi(p) }
                    .accessibilityIdentifier("setup-wifi")
                if let wifiStatus { Text(wifiStatus).font(.footnote).foregroundStyle(.secondary) }
            }
        } header: {
            Text("WLAN-Konfiguration")
        } footer: {
            Text("Optional. Legt das Netz auf diesem Gerät an. WPA-Enterprise wird nicht unterstützt.")
        }
    }

    @ViewBuilder private func recipeSection(_ p: Binding<PortalProfile>) -> some View {
        Section("Ablauf") {
            LabeledContent("Recipe", value: p.wrappedValue.recipe == nil ? String(localized: "Noch keins") : String(localized: "Revision \(p.wrappedValue.recipeRevision)"))
            Button("Mit Assistent einrichten", systemImage: "sparkles") { showChat = true }
                .accessibilityIdentifier("open-chat")
            Button("Erweitert (YAML)", systemImage: "curlybraces") { showAdvanced = true }
                .accessibilityIdentifier("open-advanced")
        }
    }

    private func persistenceText(_ p: PersistencePolicy) -> String {
        switch p {
        case .askEveryTime: String(localized: "Jedes Mal fragen")
        case .rememberInKeychain: String(localized: "Im Schlüsselbund merken")
        case .useOnce: String(localized: "Nur einmal verwenden")
        }
    }

    private func storeWiFiPassphrase(_ p: Binding<PortalProfile>) {
        guard !wifiPassphrase.isEmpty else { return }
        let key = AppModel.wifiKey(profile: p.wrappedValue.id)
        try? model.secrets.write(wifiPassphrase, for: key)
        p.wrappedValue.wifi?.passphraseKeychainKey = key
    }

    private func setUpWiFi(_ p: Binding<PortalProfile>) {
        storeWiFiPassphrase(p)
        guard var wifi = p.wrappedValue.wifi else { return }
        wifi.ssid = p.wrappedValue.network.ssidExact
        p.wrappedValue.wifi = wifi
        #if os(iOS)
        let secrets = model.secrets
        Task {
            do {
                try await WiFiConfigurator().apply(wifi, secrets: secrets)
                wifiStatus = String(localized: "WLAN wurde eingerichtet.")
            } catch WiFiConfigError.missingPassphrase {
                wifiStatus = String(localized: "Bitte eine Passphrase eingeben.")
            } catch WiFiConfigError.invalidPassphrase {
                wifiStatus = String(localized: "Die Passphrase muss 8 bis 63 Zeichen lang sein.")
            } catch {
                wifiStatus = String(localized: "Einrichtung nicht möglich: \(error.localizedDescription)")
            }
        }
        #endif
    }
}

struct CredentialSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profile: PortalProfile
    var onSave: (CredentialBinding, String) -> Void

    @State private var concept = "roomNumber"
    @State private var persistence: PersistencePolicy = .rememberInKeychain
    @State private var value = ""

    private let concepts = ["username", "password", "lastName", "roomNumber", "email", "voucherCode", "accessCode", "phoneNumber"]

    var body: some View {
        NavigationStack {
            Form {
                Picker("Art des Werts", selection: $concept) {
                    ForEach(concepts, id: \.self) { Text(label(for: $0)).tag($0) }
                }
                Picker("Speichern", selection: $persistence) {
                    Text("Im Schlüsselbund merken").tag(PersistencePolicy.rememberInKeychain)
                    Text("Jedes Mal fragen").tag(PersistencePolicy.askEveryTime)
                    Text("Nur einmal verwenden").tag(PersistencePolicy.useOnce)
                }
                if persistence == .rememberInKeychain {
                    // Eigenes, sicheres Eingabefeld: der Wert geht nie an ein Modell (SPEC §3.2).
                    SecureField("Wert", text: $value)
                        .textContentType(.password)
                        .accessibilityIdentifier("credential-value")
                }
            }
            .navigationTitle("Wert hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        let key = AppModel.secretKey(profile: profile.id, concept: concept)
                        onSave(CredentialBinding(concept: concept, keychainKey: key, prompt: label(for: concept), persistence: persistence), value)
                        dismiss()
                    }
                    .disabled(persistence == .rememberInKeychain && value.isEmpty)
                    .accessibilityIdentifier("save-credential")
                }
            }
        }
    }

    private func label(for concept: String) -> String {
        switch concept {
        case "username": String(localized: "Benutzername")
        case "password": String(localized: "Passwort")
        case "lastName": String(localized: "Nachname")
        case "roomNumber": String(localized: "Zimmernummer")
        case "email": String(localized: "E-Mail")
        case "voucherCode": String(localized: "Gutscheincode")
        case "accessCode": String(localized: "Zugangscode")
        case "phoneNumber": String(localized: "Telefonnummer")
        default: concept
        }
    }
}

struct AskValueSheet: View {
    @Environment(\.dismiss) private var dismiss
    let concept: String
    let prompt: String
    let secure: Bool
    var onSubmit: (String) -> Void
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Eigenes Eingabefeld: der Wert geht nie an ein Modell (SPEC §3.2).
                    if secure {
                        SecureField(prompt, text: $value).accessibilityIdentifier("ask-value")
                    } else {
                        TextField(prompt, text: $value)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("ask-value")
                    }
                } footer: {
                    Text("Das Portal braucht diesen Wert für die Anmeldung.")
                }
            }
            .navigationTitle(prompt)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anmelden") { onSubmit(value); dismiss() }
                        .disabled(value.isEmpty)
                        .accessibilityIdentifier("ask-submit")
                }
            }
        }
        .presentationDetents([.medium])
    }
}
