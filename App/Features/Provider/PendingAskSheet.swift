import SwiftUI
import UserNotifications
import CaptiveCore

/// Wert für eine wartende Anmeldung (01 §4.5, SPEC §3.2). Der Wert geht in den Keychain,
/// im Pending-Eintrag steht nur die Referenz. Danach setzt der Provider in `presentUI` fort.
struct PendingAskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let pending: PendingAuthentication

    @State private var value = ""
    @State private var remember = false

    private var concept: String { pending.requiredConcept ?? "value" }
    private var prompt: String { pending.prompt ?? concept }
    private var secure: Bool { ConceptCatalog.sensitivity(of: concept) == .secret }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if secure {
                        SecureField(prompt, text: $value).accessibilityIdentifier("pending-value")
                    } else {
                        TextField(prompt, text: $value)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("pending-value")
                    }
                    Toggle("Für dieses Profil merken", isOn: $remember)
                } header: {
                    Text("\(pending.profileName) braucht \(prompt)")
                } footer: {
                    Text("Danach meldet sich das Gerät automatisch an.")
                }
            }
            .navigationTitle("Wert eingeben")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") {
                        model.pendingStore.transition(pending.runId, to: .failed)
                        model.pendingAsk = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Senden") { submit() }.disabled(value.isEmpty).accessibilityIdentifier("pending-submit")
                }
            }
        }
        .presentationDetents([.medium])
        .interactiveDismissDisabled()
    }

    private func submit() {
        let key = PendingAuthentication.valueKey(runId: pending.runId, concept: concept)
        try? model.secrets.write(value, for: key)
        if remember, var p = model.profile(pending.profileId),
           let i = p.credentialBindings.firstIndex(where: { $0.concept == concept }) {
            p.credentialBindings[i].persistence = .rememberInKeychain
            try? model.secrets.write(value, for: p.credentialBindings[i].keychainKey)
            model.save(p)
        }
        model.pendingStore.transition(pending.runId, to: .valueProvided, valueKey: key)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [pending.runId.uuidString])
        model.pendingAsk = nil
        dismiss()
    }
}

/// Öffnet die Wertabfrage, wenn der Nutzer die Benachrichtigung antippt.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    var onValueNeeded: (@Sendable (UUID?) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let id = (response.notification.request.content.userInfo["runId"] as? String).flatMap(UUID.init(uuidString:))
        onValueNeeded?(id)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
