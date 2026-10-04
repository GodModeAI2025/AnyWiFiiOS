import SwiftUI
import CaptiveCore

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
                    List {
                        Section("Stabilität") {
                            ForEach(model.profiles) { p in
                                let m = StabilityMetrics(logs: model.runLogs.filter { $0.profileId == p.id })
                                if m.totalRuns > 0 { StabilityRow(name: p.name, metrics: m) }
                            }
                        }
                        Section("Läufe") {
                            ForEach(model.runLogs) { log in
                                RunRow(log: log, bundle: model.debugBundleURL(for: log))
                            }
                        }
                    }
                    .accessibilityIdentifier("activity-list")
                }
            }
            .navigationTitle("Aktivität")
            .onAppear { model.reload() }
        }
    }
}

struct StabilityRow: View {
    let name: String
    let metrics: StabilityMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(name).font(.headline)
                Spacer()
                if metrics.isStable {
                    Label("Stabil", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.subheadline)
                } else {
                    Text("\(metrics.streak) von \(StabilityMetrics.stableThreshold) Erfolgen in Folge")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 4) {
                ForEach(Array(metrics.lastOutcomes.enumerated()), id: \.offset) { _, o in
                    Circle().fill(o == .success ? Color.green : Color.orange).frame(width: 10, height: 10)
                }
            }
            .accessibilityHidden(true)
            Text("\(metrics.totalRuns) Läufe, \(Int((metrics.successRate * 100).rounded())) % erfolgreich")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct RunRow: View {
    let log: RunLog
    let bundle: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(log.profileName).font(.headline)
                Spacer()
                Image(systemName: log.outcome == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(log.outcome == .success ? .green : .orange)
                    .accessibilityHidden(true)
            }
            Text(log.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption).foregroundStyle(.secondary)
            Text(LocalizedStringKey(log.outcome.explanation)).font(.subheadline)
            if let r = log.reason, log.outcome != .success { Text(r).font(.caption).foregroundStyle(.secondary) }
            if log.repaired { Label("Automatisch repariert", systemImage: "wrench.and.screwdriver").font(.caption) }
            if let bundle {
                ShareLink(item: bundle) { Label("Debug-Paket teilen", systemImage: "square.and.arrow.up") }
                    .font(.footnote)
            }
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
