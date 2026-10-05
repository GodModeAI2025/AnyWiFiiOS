import SwiftUI
import CaptiveCore

/// Re-Import (SPEC §3.3): Parse, Schema, Security-Validator, Diff alt/neu, Bestätigen, neue Revision.
struct RecipeImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let pending: AppModel.PendingImport

    @State private var profileID: UUID?

    private var profile: PortalProfile? { profileID.flatMap { model.profile($0) } }
    private var preview: ImportPreview? { profile.map { RecipeImporter.prepare(yaml: pending.yaml, for: $0) } }

    var body: some View {
        NavigationStack {
            List {
                Section("Profil") {
                    Picker("Importieren in", selection: $profileID) {
                        Text("Auswählen").tag(UUID?.none)
                        ForEach(model.profiles) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                    .accessibilityIdentifier("import-profile")
                    if let preview, !preview.matchesProfile {
                        Label("Die Datei gehört offenbar zu einem anderen WLAN.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.footnote)
                    }
                }
                if let preview {
                    if !preview.issues.isEmpty {
                        Section("Probleme") {
                            ForEach(preview.issues, id: \.self) { Text($0).font(.footnote).foregroundStyle(.red) }
                        }
                    } else {
                        Section {
                            ForEach(Array(preview.diff.enumerated()), id: \.offset) { _, line in
                                Text(prefix(line.kind) + line.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(color(line.kind))
                                    .listRowBackground(background(line.kind))
                            }
                        } header: {
                            Text("Änderungen")
                        } footer: {
                            Text("Das Recipe wurde geprüft. Es enthält nur erlaubte Aktionen und keine Werte.")
                        }
                    }
                }
            }
            .navigationTitle("Recipe importieren")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Übernehmen") {
                        if let p = profile, let preview, let updated = try? RecipeImporter.apply(preview, to: p) {
                            model.save(updated)
                            dismiss()
                        }
                    }
                    .disabled(!(preview?.isValid ?? false))
                    .accessibilityIdentifier("import-apply")
                }
            }
        }
        .onAppear { profileID = pending.profileID ?? (model.profiles.count == 1 ? model.profiles.first?.id : nil) }
    }

    private func prefix(_ k: DiffLine.Kind) -> String { k == .added ? "+ " : k == .removed ? "- " : "  " }
    private func color(_ k: DiffLine.Kind) -> Color { k == .added ? .green : k == .removed ? .red : .primary }
    private func background(_ k: DiffLine.Kind) -> Color { k == .added ? .green.opacity(0.12) : k == .removed ? .red.opacity(0.12) : .clear }
}

struct RevisionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let profileID: UUID

    var body: some View {
        NavigationStack {
            List {
                if let p = model.profile(profileID) {
                    Section("Aktuell") {
                        LabeledContent("Revision", value: "\(p.recipeRevision)")
                    }
                    Section {
                        if p.revisionHistory.isEmpty {
                            Text("Noch keine früheren Revisionen.").foregroundStyle(.secondary)
                        }
                        ForEach(p.revisionHistory.reversed(), id: \.revision) { r in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("Revision \(r.revision)").font(.headline)
                                    Text("\(r.note), \(r.savedAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Wiederherstellen") {
                                    var updated = p
                                    if (try? updated.rollback(to: r.revision)) != nil { model.save(updated) }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    } header: {
                        Text("Frühere Revisionen")
                    } footer: {
                        Text("Aufbewahrt werden die letzten fünf. Beim Wiederherstellen entsteht eine neue Revision mit dem alten Inhalt.")
                    }
                }
            }
            .navigationTitle("Revisionen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }
}
