import SwiftUI

// Platzhalter für Bereiche, die in späteren Phasen gefüllt werden (SPEC §5).

struct ActivityView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if model.runLogs.isEmpty {
                    ContentUnavailableView("Noch keine Aktivität", systemImage: "clock",
                                           description: Text("Hier erscheinen Anmeldeversuche und ihr Ergebnis."))
                } else {
                    List(model.runLogs) { log in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(log.profileName).font(.headline)
                                Spacer()
                                Image(systemName: log.outcome == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(log.outcome == .success ? .green : .orange)
                            }
                            Text(log.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(LocalizedStringKey(log.outcome.explanation)).font(.subheadline)
                            if let r = log.reason, log.outcome != .success {
                                Text(r).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .accessibilityIdentifier("activity-list")
                }
            }
            .navigationTitle("Aktivität")
            .onAppear { model.reload() }
        }
    }
}

struct ImportExportView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Import und Export", systemImage: "square.and.arrow.up.on.square",
                                   description: Text("Profile teilen und Recipes importieren folgt in einer späteren Version."))
                .navigationTitle("Import / Export")
        }
    }
}

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            Form {
                Section("Datenschutz") {
                    Text("Alle Daten bleiben auf dem Gerät. Es gibt keine Analytics und keine eigenen Server.")
                        .font(.footnote)
                }
                Section("Version") {
                    LabeledContent("CaptiveAI", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
                }
            }
            .navigationTitle("Einstellungen")
        }
    }
}
