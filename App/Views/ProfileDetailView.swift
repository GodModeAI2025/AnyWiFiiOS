import CaptiveCore
import CaptiveCoreApple
import SafariServices
import SwiftData
import SwiftUI

struct ProfileDetailView: View {
    @Bindable var profile: ProfileRecord
    @Environment(\.modelContext) private var context
    @State private var login = LoginService()
    @State private var showRecipeEditor = false
    @State private var showExport = false
    @State private var showRecipeImporter = false
    @State private var message: String?
    @State private var safariURL: URL?
    @Query private var runs: [RunRecord]

    init(profile: ProfileRecord) {
        self.profile = profile
        let id = profile.id
        _runs = Query(filter: #Predicate<RunRecord> { $0.profileId == id }, sort: \RunRecord.startedAt, order: .reverse)
    }

    var body: some View {
        Form {
            statusSection
            Section("Ablauf") {
                ForEach(profile.intent?.summaryLines ?? [], id: \.self) { Text($0) }
                if !profile.originalInstruction.isEmpty {
                    Text("„\(profile.originalInstruction)“").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Recipe") {
                if let recipe = profile.recipe {
                    LabeledContent("Revision", value: "\(profile.recipeRevision)")
                    ForEach(recipe.stages, id: \.id) { stage in
                        LabeledContent(stage.id, value: stage.actions.map(\.opcode.rawValue).joined(separator: " → "))
                    }
                    Button("YAML ansehen und bearbeiten") { showRecipeEditor = true }
                    if !profile.previousRecipes.isEmpty {
                        Button("Vorherige Revision wiederherstellen") { profile.rollback(); try? context.save() }
                    }
                } else {
                    Text("Noch nicht gelernt. Beim ersten Login im Portal-WLAN wird der Ablauf aufgezeichnet.")
                        .foregroundStyle(.secondary)
                }
                Button("Recipe importieren …") { showRecipeImporter = true }
            }
            if let wifi = profile.wifi {
                Section("WLAN") {
                    LabeledContent("SSID", value: wifi.ssid)
                    LabeledContent("Sicherheit", value: wifi.security == .open ? "Offen" : "WPA-Personal")
                    Button("WLAN auf diesem Gerät einrichten") { Task { await installWiFi(wifi) } }
                }
            }
            Section("Teilen") {
                Button("Profil exportieren …") { showExport = true }
            }
            debugSection
        }
        .navigationTitle(profile.name)
        .toolbar { Toggle("Aktiv", isOn: $profile.enabled) }
        .sheet(isPresented: $showRecipeEditor) { RecipeEditorView(profile: profile) }
        .sheet(isPresented: $showExport) { ExportProfileView(profile: profile) }
        .sheet(item: $safariURL) { url in SafariView(url: url).ignoresSafeArea() }
        .sheet(item: needsValueBinding) { request in
            ValueRequestView(concept: request.concept, profileName: profile.name) { value, remember in
                login.provide(value, for: request.concept, remember: remember, profile: profile)
                Task { await login.login(profile, context: context) }
            } onCancel: {
                login.reset()
            }
        }
        .fileImporter(isPresented: $showRecipeImporter, allowedContentTypes: [.recipeYAML, .plainText]) { result in
            if case .success(let url) = result { importRecipe(from: url) }
        }
        .alert("Hinweis", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }

    // MARK: Status & Login

    private var statusSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading) {
                    Text(profile.isStable ? "Stabil" : "Noch nicht stabil").font(.headline)
                    Text("\(profile.successCount) von \(profile.runCount) Anmeldungen erfolgreich")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 3) {
                    ForEach(Array(profile.recentOutcomes.prefix(10).enumerated()), id: \.offset) { _, raw in
                        Circle().fill(RunOutcome(rawValue: raw)?.tint ?? .gray).frame(width: 8, height: 8)
                    }
                }
                .accessibilityLabel("Letzte Ergebnisse")
            }
            switch login.state {
            case .idle, .needsValue:
                Button { Task { await login.login(profile, context: context) } } label: {
                    Label("Jetzt im WLAN anmelden", systemImage: "wifi")
                }
                .accessibilityIdentifier("detail.login")
            case .running(let text):
                HStack { ProgressView(); Text(text) }
            case .finished(let outcome, let reason):
                Label(outcome.title, systemImage: outcome.symbol).foregroundStyle(outcome.tint)
                    .accessibilityIdentifier("detail.outcome")
                Text(reason).font(.subheadline)
                if outcome == .manualInteractionRequired, let url = login.lastPortalURL {
                    Button("Portal im Browser öffnen") { safariURL = url }
                }
                Button("Erneut versuchen") { Task { await login.login(profile, context: context) } }
            }
        }
    }

    private struct ValueRequest: Identifiable {
        var concept: Concept
        var id: String { concept.rawValue }
    }

    private var needsValueBinding: Binding<ValueRequest?> {
        Binding(get: {
            if case .needsValue(let concept) = login.state { return ValueRequest(concept: concept) }
            return nil
        }, set: { _ in })
    }

    // MARK: Debug

    private var debugSection: some View {
        Section("Debug-Pakete") {
            let bundles = runs.compactMap { run -> (RunRecord, URL)? in
                guard let file = run.debugBundleFile else { return nil }
                let url = AppConfig.debugBundleDirectory.appendingPathComponent(file)
                return FileManager.default.fileExists(atPath: url.path) ? (run, url) : nil
            }
            if bundles.isEmpty {
                Text("Keine. Bei einem Fehlschlag entsteht automatisch ein Paket ohne Passwörter.")
                    .foregroundStyle(.secondary)
            }
            ForEach(bundles, id: \.0.id) { run, url in
                ShareLink(item: url) {
                    VStack(alignment: .leading) {
                        Text(run.outcome.title)
                        Text(run.startedAt, style: .date).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Aktionen

    private func installWiFi(_ wifi: WiFiConfig) async {
        let passphrase = wifi.passphraseKey.flatMap { try? AppConfig.keychain.get($0) }
        do {
            try await WiFiConfigurator.install(wifi, passphrase: passphrase)
            message = "WLAN „\(wifi.ssid)“ ist eingerichtet."
        } catch {
            message = "WLAN konnte nicht eingerichtet werden: \(error.localizedDescription)"
        }
    }

    /// Re-Import eines (z. B. von einem Agenten) korrigierten Recipes (SPEC §3.3).
    private func importRecipe(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let recipe = try PRLCodec.decode(data: Data(contentsOf: url))
            try profile.replaceRecipe(recipe)
            try context.save()
            message = "Recipe übernommen (Revision \(profile.recipeRevision))."
        } catch let error as PRLError {
            message = "Recipe ungültig: \(error.description)"
        } catch {
            message = "Recipe abgelehnt: \(error.localizedDescription)"
        }
    }
}

/// Sichere Eingabe eines fehlenden Werts (01 §4.5). Der Wert geht nie in Chat oder Logs.
struct ValueRequestView: View {
    let concept: Concept
    let profileName: String
    let onSubmit: (String, Bool) -> Void
    let onCancel: () -> Void
    @State private var value = ""
    @State private var remember = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(concept.displayName, text: $value)
                        .textContentType(concept == .password ? .password : nil)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("\(profileName) benötigt \(concept.displayName). Der Wert wird nur an das Anmeldeformular übergeben.")
                }
                Toggle("Für dieses Profil merken (Schlüsselbund)", isOn: $remember)
            }
            .navigationTitle(concept.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { onCancel(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anmelden") { onSubmit(value, remember); dismiss() }.disabled(value.isEmpty)
                }
            }
        }
    }
}

/// Manuelle Anmeldung für Portale, die JavaScript brauchen (01 §17.3). Im Provider-Modus entspricht das
/// `NEHotspotManager.safariDomains` + `SFSafariViewController` bei `presentUI`.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
