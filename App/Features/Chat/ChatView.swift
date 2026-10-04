import SwiftUI
import CaptiveCore
import CaptiveCoreApple

/// Profil-Chat (SPEC §3.2): mehrstufiges Gespräch per Text oder Sprache. Das Modell sieht nur
/// Platzhalter. Werte sensibler Konzepte gibt der Nutzer im separaten sicheren Feld ein.
struct ChatView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let profile: PortalProfile
    var onApply: (PortalProfile) -> Void

    struct Bubble: Identifiable { let id = UUID(); var fromUser: Bool; var text: String }

    @State private var assistant: (any AssistantModel)?
    @State private var availability: AssistantAvailability = .unavailable(.other)
    @State private var checked = false
    @State private var session = ProfileChatSession()
    @State private var bubbles: [Bubble] = []
    @State private var input = ""
    @State private var busy = false
    @State private var secureValues: [String: String] = [:]
    @State private var sensitiveHint = false
    @State private var preview: NormalizedPage?
    @State private var previewError: String?
    @State private var dictation = SpeechDictation()

    var body: some View {
        NavigationStack {
            Group {
                if !checked {
                    ProgressView()
                } else if !availability.isAvailable {
                    ContentUnavailableView {
                        Label("Chat nicht verfügbar", systemImage: "sparkles.slash")
                    } description: {
                        Text(unavailableText)
                    }
                } else {
                    content
                }
            }
            .navigationTitle("Mit Assistent einrichten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Übernehmen") { apply() }
                        .disabled(!session.isComplete)
                        .accessibilityIdentifier("chat-apply")
                }
            }
        }
        .task {
            assistant = AppEnvironment.localAssistant()
            availability = await assistant?.availability ?? .unavailable(.deviceNotEligible)
            checked = true
        }
    }

    private var unavailableText: LocalizedStringKey {
        switch availability {
        case .unavailable(.appleIntelligenceDisabled): "Apple Intelligence ist ausgeschaltet. Schalte es in den Einstellungen ein oder nutze den Erweitert-Editor."
        case .unavailable(.modelNotReady): "Das Modell wird noch geladen. Versuche es später erneut oder nutze den Erweitert-Editor."
        default: "Auf diesem Gerät ist kein lokales Modell verfügbar. Der Erweitert-Editor bleibt nutzbar."
        }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List {
                    if bubbles.isEmpty {
                        Section {
                            Text("Beschreibe, was bei der Anmeldung passieren soll. Zum Beispiel: Datenschutz und Nutzungsbedingungen akzeptieren, Zimmernummer und Nachname eintragen, dann verbinden.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(bubbles) { b in
                        HStack {
                            if b.fromUser { Spacer(minLength: 40) }
                            Text(b.text)
                                .padding(10)
                                .background(b.fromUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.15),
                                            in: RoundedRectangle(cornerRadius: 12))
                            if !b.fromUser { Spacer(minLength: 40) }
                        }
                        .listRowSeparator(.hidden)
                        .id(b.id)
                    }
                    if sensitiveHint {
                        Label("Sensible Werte bitte nicht in den Chat schreiben. Trage sie unten im sicheren Feld ein.", systemImage: "lock.shield")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    summarySection
                    previewSection
                }
                .listStyle(.plain)
                .onChange(of: bubbles.count) { _, _ in if let last = bubbles.last { proxy.scrollTo(last.id) } }
            }
            inputBar
        }
    }

    @ViewBuilder private var summarySection: some View {
        let draft = session.draft
        if !draft.summary.isEmpty && !bubbles.isEmpty {
            Section("Zusammenfassung") {
                ForEach(Array(draft.summary.enumerated()), id: \.offset) { _, line in
                    switch line.kind {
                    case .acceptRequired: Label("Pflicht-Einwilligungen akzeptieren", systemImage: "checkmark")
                    case .askWhenNeeded: Label("\(line.prompt ?? line.concept ?? "") bei Bedarf abfragen", systemImage: "questionmark.circle")
                    case .storeSecurely:
                        VStack(alignment: .leading) {
                            Label("\(line.prompt ?? line.concept ?? "") sicher speichern", systemImage: "lock")
                            if let c = line.concept {
                                SecureField("Wert (bleibt im Schlüsselbund)", text: Binding(
                                    get: { secureValues[c] ?? "" }, set: { secureValues[c] = $0 }))
                                    .accessibilityIdentifier("chat-secure-\(c)")
                            }
                        }
                    case .allowMarketing: Label("Marketing-Einwilligungen erlaubt", systemImage: "megaphone")
                    case .submit: Label("Verbindung absenden", systemImage: "arrow.right")
                    }
                }
            }
        }
    }

    @ViewBuilder private var previewSection: some View {
        Section("Portal-Vorschau") {
            Button("Elemente der Portalseite laden", systemImage: "list.bullet.rectangle") { Task { await loadPreview() } }
            if let previewError { Text(previewError).font(.footnote).foregroundStyle(.secondary) }
            if let preview {
                ForEach(preview.visibleControls, id: \.elementId) { c in
                    HStack {
                        Text(c.role.rawValue).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                        Text(c.displayText.isEmpty ? c.elementId : c.displayText)
                        Spacer()
                        if c.required { Text("Pflicht").font(.caption2).foregroundStyle(.orange) }
                    }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    await dictation.toggle()
                    if !dictation.isRecording { let t = dictation.takeTranscript(); if !t.isEmpty { input += (input.isEmpty ? "" : " ") + t } }
                }
            } label: {
                Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic")
                    .font(.title3)
                    .foregroundStyle(dictation.isRecording ? .red : .accentColor)
            }
            .accessibilityLabel(dictation.isRecording ? "Aufnahme beenden" : "Spracheingabe")
            TextField("Nachricht", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("chat-input")
            Button { Task { await send() } } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .disabled(busy || input.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("chat-send")
        }
        .padding(10)
        .background(.bar)
    }

    private func send() async {
        guard let assistant else { return }
        let text = (dictation.isRecording ? input + " " + dictation.takeTranscript() : input).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        input = ""
        bubbles.append(Bubble(fromUser: true, text: text))
        busy = true
        defer { busy = false }
        // Bekannte Werte aus dem Schlüsselbund werden vor dem Prompt maskiert.
        let known: [SensitiveValue] = profile.credentialBindings.compactMap { b in
            guard let v = (try? model.secrets.read(b.keychainKey)) ?? nil else { return nil }
            return SensitiveValue(value: v, placeholder: ConceptCatalog.placeholder(for: b.concept))
        }
        do {
            var working = session
            let r = try await working.send(text, model: assistant, knownSensitive: known)
            session = working
            sensitiveHint = !r.detectedSensitiveConcepts.isEmpty
            bubbles.append(Bubble(fromUser: false, text: r.question ?? r.reply))
        } catch {
            bubbles.append(Bubble(fromUser: false, text: String(localized: "Das hat nicht geklappt. Formuliere es bitte anders.")))
        }
    }

    private func loadPreview() async {
        previewError = nil
        do {
            let client = PortalHTTPClient(transport: URLSessionWiFiTransport())
            let f = try await client.fetch(PortalRequest(url: AppEnvironment.engineConfig().probeURL))
            if CaptiveProbe.isSuccess(f.response) { previewError = String(localized: "Du bist bereits online. Es gibt keine Portalseite."); return }
            let page = PortalNormalizer.normalize(html: f.response.body, url: f.response.url, status: f.response.status)
            preview = page.redactedForModel()
            session.portalContext = preview
        } catch {
            previewError = String(localized: "Die Portalseite ist nicht erreichbar. Bist du im Portal-WLAN?")
        }
    }

    private func apply() {
        var p = profile
        p.intent = session.intent()
        let newBindings = session.draft.bindings(profileId: p.id)
        let concepts = Set(newBindings.map(\.concept))
        p.credentialBindings = p.credentialBindings.filter { !concepts.contains($0.concept) } + newBindings
        for b in newBindings where b.persistence == .rememberInKeychain {
            if let v = secureValues[b.concept], !v.isEmpty { try? model.secrets.write(v, for: b.keychainKey) }
        }
        p.recipe = nil          // neuer Intent: beim nächsten Login wird neu gelernt
        onApply(p)
        dismiss()
    }
}
