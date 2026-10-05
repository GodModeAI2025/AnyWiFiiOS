import SwiftUI
import UniformTypeIdentifiers
import CaptiveCore
import CaptiveCoreApple

extension UTType {
    static let captiveProfile = UTType(exportedAs: "de.mobilebox.captiveai.profile")
}

struct ImportExportView: View {
    @Environment(AppModel.self) private var model
    @State private var showImporter = false
    @State private var exporting: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Profil importieren", systemImage: "square.and.arrow.down") { showImporter = true }
                        .accessibilityIdentifier("import-profile-file")
                } footer: {
                    Text("Öffnet eine .captiveprofile-Datei. Du siehst vorher, was sie enthält.")
                }
                Section("Profil teilen") {
                    if model.profiles.isEmpty { Text("Noch kein Profil.").foregroundStyle(.secondary) }
                    ForEach(model.profiles) { p in
                        Button {
                            exporting = p.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(p.name).foregroundStyle(.primary)
                                    Text(p.network.ssidExact).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "square.and.arrow.up")
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("export-\(p.name)")
                    }
                }
            }
            .navigationTitle("Import / Export")
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.captiveProfile, .zip, .data]) { result in
                if case .success(let url) = result { model.open(url) }
            }
            .sheet(item: Binding(get: { exporting.map(ID.init) }, set: { exporting = $0?.id })) { item in
                ExportSheet(profileID: item.id)
            }
        }
    }

    struct ID: Identifiable { var id: UUID }
}

/// Export (SPEC §3.4): Standard ohne Zugangsdaten. Der Schalter "Zugangsdaten mitteilen" löst
/// einen Bestätigungsdialog aus, der die Werte nach Konzept nennt, nie im Klartext.
struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let profileID: UUID

    @State private var shareCredentials = false
    @State private var confirmCredentials = false
    @State private var encrypt = true
    @State private var passphrase = ""
    @State private var confirmUnencrypted = false
    @State private var unencryptedConfirmed = false
    @State private var fileURL: URL?
    @State private var error: String?

    private var profile: PortalProfile? { model.profile(profileID) }
    private var concepts: [String] { profile.map(ProfileExporter.credentialSummary) ?? [] }

    private var canCreate: Bool {
        guard shareCredentials else { return true }
        return encrypt ? passphrase.count >= ExportOptions.minPassphraseLength : unencryptedConfirmed
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Ablauf und Einstellungen werden geteilt, keine Werte.", systemImage: "checkmark.shield")
                }
                if !concepts.isEmpty {
                    Section {
                        Toggle("Zugangsdaten mitteilen", isOn: Binding(
                            get: { shareCredentials },
                            set: { on in if on { confirmCredentials = true } else { shareCredentials = false; encrypt = true; unencryptedConfirmed = false } }))
                            .accessibilityIdentifier("share-credentials")
                        if shareCredentials {
                            Toggle("Mit Passphrase verschlüsseln", isOn: Binding(
                                get: { encrypt },
                                set: { on in if on { encrypt = true; unencryptedConfirmed = false } else { confirmUnencrypted = true } }))
                            if encrypt {
                                SecureField("Passphrase (mindestens 8 Zeichen)", text: $passphrase)
                                    .accessibilityIdentifier("export-passphrase")
                            } else {
                                Label("Unverschlüsselt: Jeder mit der Datei sieht die Werte.", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange).font(.footnote)
                            }
                        }
                    } footer: {
                        Text("Standardmäßig bleiben Passwörter und persönliche Werte auf diesem Gerät.")
                    }
                }
                Section {
                    if let fileURL {
                        ShareLink(item: fileURL) { Label("Datei teilen", systemImage: "square.and.arrow.up") }
                            .accessibilityIdentifier("share-file")
                    } else {
                        Button("Datei erzeugen", systemImage: "doc.badge.plus") { create() }
                            .disabled(!canCreate)
                            .accessibilityIdentifier("create-export")
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle(profile?.name ?? "Teilen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } } }
            .onChange(of: shareCredentials) { _, _ in fileURL = nil }
            .onChange(of: encrypt) { _, _ in fileURL = nil }
            .onChange(of: passphrase) { _, _ in fileURL = nil }
            .alert("Zugangsdaten mitteilen?", isPresented: $confirmCredentials) {
                Button("Mitteilen", role: .destructive) { shareCredentials = true }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Folgende Werte werden in die Datei geschrieben: \(concepts.map(label).joined(separator: ", ")).")
            }
            .alert("Unverschlüsselt teilen?", isPresented: $confirmUnencrypted) {
                Button("Unverschlüsselt teilen", role: .destructive) { encrypt = false; unencryptedConfirmed = true }
                Button("Abbrechen", role: .cancel) { encrypt = true }
            } message: {
                Text("Ohne Passphrase kann jeder die Werte lesen, der die Datei bekommt.")
            }
        }
    }

    private func create() {
        error = nil
        do {
            fileURL = try model.exportFile(profileID: profileID, includeCredentials: shareCredentials,
                                           passphrase: shareCredentials && encrypt ? passphrase : nil,
                                           unencryptedConfirmed: unencryptedConfirmed)
        } catch SharingError.passphraseTooShort {
            error = String(localized: "Die Passphrase ist zu kurz.")
        } catch SharingError.noCredentialsToShare {
            error = String(localized: "Es sind keine gespeicherten Werte vorhanden.")
        } catch {
            self.error = String(localized: "Export nicht möglich.")
        }
    }

    func label(_ concept: String) -> String {
        switch concept {
        case "username": String(localized: "Benutzername")
        case "password": String(localized: "Passwort")
        case "lastName": String(localized: "Nachname")
        case "roomNumber": String(localized: "Zimmernummer")
        case "email": String(localized: "E-Mail")
        case "voucherCode": String(localized: "Gutscheincode")
        case "accessCode": String(localized: "Zugangscode")
        case "phoneNumber": String(localized: "Telefonnummer")
        case "wifiPassphrase": String(localized: "WLAN-Passphrase")
        default: concept
        }
    }
}

/// Import (SPEC §3.4, 01 §31): Vorschau, Passphrase, Konfliktstrategie, Wertentscheidungen.
struct ProfileImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let pending: AppModel.PendingProfileImport

    @State private var preview: SharedProfilePreview?
    @State private var loadError: String?
    @State private var passphrase = ""
    @State private var credentials: SharedCredentials?
    @State private var passphraseError = false
    @State private var strategy: ConflictStrategy = .importAsCopy
    @State private var decisions: [String: CredentialDecision] = [:]
    @State private var conflicts: [String] = []
    @State private var result: ImportOutcome?
    @State private var showDiff = false

    var body: some View {
        NavigationStack {
            Form {
                if let loadError {
                    Section { Text(loadError).foregroundStyle(.red) }
                } else if let preview {
                    content(preview)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Profil importieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(result == nil ? "Abbrechen" : "Schließen") { dismiss() } }
                if result == nil, let preview {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Importieren") { apply(preview) }
                            .disabled(!canApply(preview))
                            .accessibilityIdentifier("profile-import-apply")
                    }
                }
            }
        }
        .onAppear(perform: load)
    }

    @ViewBuilder private func content(_ p: SharedProfilePreview) -> some View {
        Section {
            LabeledContent("Name", value: p.manifest.profileName)
            LabeledContent("WLAN", value: p.manifest.ssid)
            LabeledContent("Erstellt mit", value: p.manifest.createdWith)
            if p.containsCredentials {
                Label(p.needsPassphrase ? "Enthält Zugangsdaten (verschlüsselt)" : "Enthält Zugangsdaten (unverschlüsselt)",
                      systemImage: p.needsPassphrase ? "lock.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(p.needsPassphrase ? Color.primary : Color.orange)
            }
        }
        if !p.recipeIssues.isEmpty {
            Section("Probleme") { ForEach(p.recipeIssues, id: \.self) { Text($0).font(.footnote).foregroundStyle(.red) } }
        }
        if p.needsPassphrase && credentials == nil {
            Section {
                SecureField("Passphrase", text: $passphrase).accessibilityIdentifier("import-passphrase")
                Button("Entschlüsseln") { decrypt(p) }.disabled(passphrase.isEmpty)
                if passphraseError { Text("Falsche Passphrase.").font(.footnote).foregroundStyle(.red) }
            } footer: { Text("Die Werte landen nach dem Import im Schlüsselbund.") }
        }
        if p.hasConflict, result == nil {
            Section {
                Picker("Profil für dieses WLAN existiert", selection: $strategy) {
                    Text("Als Kopie importieren").tag(ConflictStrategy.importAsCopy)
                    Text("Recipe ersetzen").tag(ConflictStrategy.replaceRecipe)
                    Text("Abbrechen").tag(ConflictStrategy.cancel)
                }
                if let existing = p.existingProfileID.flatMap({ model.profile($0) }), let old = existing.recipe, let new = p.recipe,
                   let o = try? PRLCodec.serialize(old), let n = try? PRLCodec.serialize(new) {
                    Button("Vergleichen", systemImage: "arrow.left.arrow.right") { showDiff.toggle() }
                    if showDiff {
                        ForEach(Array(RecipeDiff.lines(old: o, new: n).enumerated()), id: \.offset) { _, l in
                            Text((l.kind == .added ? "+ " : l.kind == .removed ? "- " : "  ") + l.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(l.kind == .added ? .green : l.kind == .removed ? .red : .primary)
                        }
                    }
                }
            }
        }
        if !conflicts.isEmpty, result == nil || !(result?.credentialConflicts.isEmpty ?? true) {
            Section {
                ForEach(conflicts, id: \.self) { c in
                    Picker(label(c), selection: Binding(get: { decisions[c] ?? .keepExisting }, set: { decisions[c] = $0 })) {
                        Text("Behalten").tag(CredentialDecision.keepExisting)
                        Text("Ersetzen").tag(CredentialDecision.replace)
                    }
                }
            } header: { Text("Vorhandene Werte") } footer: { Text("Bestehende Werte werden nie ohne deine Entscheidung überschrieben.") }
        }
        if let result {
            Section {
                Label("Profil importiert.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                if !result.missingConcepts.isEmpty {
                    Text("Dieses Profil braucht noch: \(result.missingConcepts.map(label).joined(separator: ", ")). Trage die Werte im Profil ein.")
                        .font(.footnote)
                }
            }
        }
    }

    private func canApply(_ p: SharedProfilePreview) -> Bool {
        p.recipeIssues.isEmpty && (!p.needsPassphrase || credentials != nil) && !(p.hasConflict && strategy == .cancel)
    }

    private func load() {
        do { preview = try ProfileImporter.preview(data: pending.data, existing: model.profiles) }
        catch { loadError = String(localized: "Die Datei ist kein gültiges CaptiveAI-Profil.") }
        if let p = preview, !p.needsPassphrase { credentials = try? ProfileImporter.credentials(of: p, passphrase: nil, cipher: nil) }
    }

    private func decrypt(_ p: SharedProfilePreview) {
        do {
            credentials = try ProfileImporter.credentials(of: p, passphrase: passphrase, cipher: CryptoKitCredentialCipher())
            passphraseError = false
        } catch { passphraseError = true }
    }

    private func apply(_ p: SharedProfilePreview) {
        do {
            let out = try ProfileImporter.apply(p, credentials: credentials, strategy: strategy, existing: model.profiles,
                                                secrets: model.secrets, decisions: decisions)
            model.save(out.profile)
            conflicts = out.credentialConflicts
            result = out
            if conflicts.isEmpty { }
        } catch SharingError.cancelled { dismiss() }
        catch { loadError = String(localized: "Import nicht möglich.") }
    }

    private func label(_ concept: String) -> String {
        switch concept {
        case "username": String(localized: "Benutzername")
        case "password": String(localized: "Passwort")
        case "lastName": String(localized: "Nachname")
        case "roomNumber": String(localized: "Zimmernummer")
        case "email": String(localized: "E-Mail")
        case "voucherCode": String(localized: "Gutscheincode")
        case "accessCode": String(localized: "Zugangscode")
        case "phoneNumber": String(localized: "Telefonnummer")
        case "wifiPassphrase": String(localized: "WLAN-Passphrase")
        default: concept
        }
    }
}
