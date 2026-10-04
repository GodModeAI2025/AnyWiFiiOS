import CaptiveCore
import CaptiveCoreApple
import SwiftData
import SwiftUI

/// Aktivität (01 §23): jeder Lauf mit konkretem Grund, Debug-Paket zum Teilen.
struct ActivityView: View {
    @Query(sort: \RunRecord.startedAt, order: .reverse) private var runs: [RunRecord]
    @Environment(\.modelContext) private var context

    var body: some View {
        List {
            if runs.isEmpty {
                ContentUnavailableView("Noch keine Anmeldungen", systemImage: "clock")
            }
            ForEach(runs) { run in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(run.outcome.title, systemImage: run.outcome.symbol).foregroundStyle(run.outcome.tint)
                        Spacer()
                        Text(run.startedAt, format: .dateTime.day().month().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(run.profileName).font(.headline)
                    Text(run.reasonText).font(.subheadline).foregroundStyle(.secondary)
                    if let file = run.debugBundleFile {
                        ShareLink(item: AppConfig.debugBundleDirectory.appendingPathComponent(file)) {
                            Label("Debug-Paket teilen", systemImage: "ladybug")
                        }
                        .font(.footnote)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            .onDelete { offsets in
                for index in offsets { context.delete(runs[index]) }
                try? context.save()
            }
        }
        .navigationTitle("Aktivität")
    }
}

/// Einstellungen: KI-Verfügbarkeit, Provider-Modus, Datenschutz-Hinweise.
struct SettingsView: View {
    @State private var providerMessage: String?

    var body: some View {
        Form {
            Section("Assistent") {
                LabeledContent("Modell", value: PlannerFactory.modelDescription)
                Text("Der Assistent sieht nur die Struktur der Anmeldeseite, nie Passwörter, Namen oder Zimmernummern.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("Automatische Anmeldung im Hintergrund aktivieren") { Task { await enableProvider() } }
                if let providerMessage { Text(providerMessage).font(.footnote) }
            } header: {
                Text("Hintergrund-Modus")
            } footer: {
                Text("Benötigt die Apple-Freigabe „Hotspot Helper“. Ohne sie meldest du dich über die App, einen Kurzbefehl oder das Kontrollzentrum an.")
            }
            Section("Datenschutz") {
                Text("Alle Daten bleiben auf diesem Gerät. Zugangsdaten liegen im Schlüsselbund. Es gibt keine Analyse und keinen Server.")
                    .font(.footnote)
            }
            Section("Info") {
                LabeledContent("Version", value: AppConfig.appVersion)
            }
        }
        .navigationTitle("Einstellungen")
    }

    private func enableProvider() async {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            do {
                try await HotspotProviderSetup.enable(
                    evaluationBundleID: "com.example.captiveai.HotspotEvaluationProvider",
                    authenticationBundleID: "com.example.captiveai.HotspotAuthenticationProvider",
                    safariDomains: ["login.wifionice.de"])
                providerMessage = "Hintergrund-Modus aktiviert."
            } catch {
                providerMessage = "Nicht möglich: \(error.localizedDescription). Wahrscheinlich fehlt die Apple-Freigabe."
            }
        }
        #endif
    }
}
