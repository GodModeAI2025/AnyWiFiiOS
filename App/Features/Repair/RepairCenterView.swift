import SwiftUI
import CaptiveCore
import CaptiveCoreApple

/// Repair Center (01 §15, §29): Wenn ein Recipe nicht mehr zum Portal passt, schlägt ein Modell einen
/// kleinen Patch vor. Lokal ist der Standard, Private Cloud Compute ist optional und braucht Zustimmung.
struct RepairCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let log: RunLog

    enum Engine: String, CaseIterable, Identifiable {
        case local, pcc
        var id: String { rawValue }
    }

    @State private var engine: Engine = .local
    @State private var pccConsent = false
    @State private var localAvailable = false
    @State private var pccAvailable = false
    @State private var busy = false
    @State private var proposal: RepairProposal?
    @State private var message: String?

    private var profile: PortalProfile? { model.profile(log.profileId) }
    private var context: RepairContext? { model.repairContext(for: log) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Problem") {
                    Text(LocalizedStringKey(log.outcome.explanation))
                    if let r = log.reason { Text(r).font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    Picker("Modell", selection: $engine) {
                        Text("Auf diesem Gerät").tag(Engine.local)
                        Text("Private Cloud Compute").tag(Engine.pcc)
                    }
                    .pickerStyle(.segmented)
                    if engine == .pcc {
                        if pccAvailable {
                            Toggle("Redigierte Daten senden", isOn: $pccConsent).accessibilityIdentifier("pcc-consent")
                        } else {
                            Label("Private Cloud Compute ist hier nicht verfügbar.", systemImage: "icloud.slash")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else if !localAvailable {
                        Label("Auf diesem Gerät ist kein lokales Modell verfügbar.", systemImage: "sparkles.slash")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Reparatur")
                } footer: {
                    if engine == .pcc {
                        Text("Gesendet werden nur das Recipe und die Elementliste der Portalseite, ohne Passwörter, persönliche Werte, Cookies oder Hidden-Felder. Das Ergebnis läuft durch dieselben Prüfungen wie ein lokaler Vorschlag.")
                    } else {
                        Text("Die Daten verlassen das Gerät nicht.")
                    }
                }
                if let context {
                    Section("Elemente der Portalseite") {
                        ForEach(context.page.visibleControls, id: \.elementId) { c in
                            HStack {
                                Text(c.role.rawValue).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                                Text(c.displayText.isEmpty ? c.elementId : c.displayText)
                            }
                        }
                    }
                }
                Section {
                    Button {
                        Task { await propose() }
                    } label: {
                        if busy { HStack { ProgressView(); Text("Prüfe …") } } else { Label("Vorschlag erzeugen", systemImage: "wand.and.stars") }
                    }
                    .disabled(busy || !canPropose)
                    .accessibilityIdentifier("repair-propose")
                    if let message { Text(message).font(.footnote).foregroundStyle(.orange) }
                }
                if let proposal {
                    Section {
                        ForEach(Array(proposal.diff.enumerated()), id: \.offset) { _, l in
                            Text((l.kind == .added ? "+ " : l.kind == .removed ? "- " : "  ") + l.text)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(l.kind == .added ? .green : l.kind == .removed ? .red : .primary)
                        }
                        Button("Übernehmen", systemImage: "checkmark.circle") { apply(proposal) }
                            .accessibilityIdentifier("repair-apply")
                    } header: {
                        Text("Vorschlag")
                    } footer: {
                        Text("Der Vorschlag wurde geprüft. Er ändert nur eine Beschriftung und wird erst nach deiner Bestätigung gespeichert.")
                    }
                }
            }
            .navigationTitle("Repair Center")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } } }
            .task {
                localAvailable = await AppEnvironment.localAssistant()?.availability.isAvailable ?? false
                pccAvailable = await AppEnvironment.pccAssistant()?.availability.isAvailable ?? false
            }
        }
    }

    private var canPropose: Bool {
        guard profile?.recipe != nil, context != nil else { return false }
        return engine == .local ? localAvailable : (pccAvailable && pccConsent)
    }

    private func propose() async {
        guard let profile, let context else { return }
        message = nil
        proposal = nil
        busy = true
        defer { busy = false }
        let assistant = engine == .local ? AppEnvironment.localAssistant() : AppEnvironment.pccAssistant()
        guard let assistant else { message = String(localized: "Das Modell ist nicht verfügbar."); return }
        do {
            proposal = try await RepairService.propose(profile: profile, context: context, model: assistant)
        } catch RepairError.noProposal {
            message = String(localized: "Das Modell hat keinen passenden Vorschlag gefunden.")
        } catch RepairError.rejected {
            message = String(localized: "Der Vorschlag wurde aus Sicherheitsgründen abgelehnt.")
        } catch {
            message = String(localized: "Die Reparatur ist nicht möglich.")
        }
    }

    private func apply(_ proposal: RepairProposal) {
        guard let profile else { return }
        model.save(RepairService.apply(proposal, to: profile))
        dismiss()
    }
}
