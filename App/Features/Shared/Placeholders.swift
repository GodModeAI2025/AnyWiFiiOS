import SwiftUI

// Platzhalter für Bereiche, die in späteren Phasen gefüllt werden (SPEC §5).

struct ActivityView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Noch keine Aktivität", systemImage: "clock",
                                   description: Text("Hier erscheinen Anmeldeversuche und ihr Ergebnis."))
                .navigationTitle("Aktivität")
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
