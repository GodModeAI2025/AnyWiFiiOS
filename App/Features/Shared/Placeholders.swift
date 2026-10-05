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
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Automatisch anmelden", isOn: Binding(
                        get: { model.hotspot.state == .enabled },
                        set: { on in Task { await model.hotspot.apply(enabled: on, profiles: model.profiles) } }))
                        .accessibilityIdentifier("auto-login")
                    statusRow
                    if model.hotspot.notificationsAllowed == false {
                        Label("Benachrichtigungen sind aus. Ohne sie erfährst du nicht, wenn ein Wert fehlt.", systemImage: "bell.slash")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Hotspot-Helper")
                } footer: {
                    Text("Meldet dich an, sobald das Gerät ein WLAN mit aktivem Profil betritt. Nur Netze aus deinen Profilen werden beansprucht. Ohne diese Funktion bleibt der Manuelle Modus (App öffnen, Kurzbefehl, Control Center).")
                }
                Section("Datenschutz") {
                    Text("Alle Daten bleiben auf dem Gerät. Es gibt keine Analytics und keine eigenen Server.")
                        .font(.footnote)
                }
                Section("Version") {
                    LabeledContent("CaptiveAI", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
                }
            }
            .navigationTitle("Einstellungen")
            .task { await model.hotspot.refresh() }
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch model.hotspot.state {
        case .enabled: Label("Aktiv", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .disabled: Label("Aus", systemImage: "circle")
        case .unknown: ProgressView()
        case .unavailable(let reason):
            Label(reason, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
        }
    }
}
