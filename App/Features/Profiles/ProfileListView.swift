import SwiftUI
import CaptiveCore

struct ProfileListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var showNew = false

    var body: some View {
        NavigationSplitView {
            Group {
                if model.profiles.isEmpty {
                    ContentUnavailableView {
                        Label("Noch kein Profil", systemImage: "wifi.slash")
                    } description: {
                        Text("Lege ein Profil für ein WLAN mit Anmeldeseite an.")
                    } actions: {
                        Button("Neues Profil") { showNew = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(selection: $selection) {
                        ForEach(model.profiles) { p in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.headline)
                                Text(p.network.ssidExact).font(.subheadline).foregroundStyle(.secondary)
                            }
                            .tag(p.id)
                            .accessibilityIdentifier("profile-row-\(p.name)")
                        }
                        .onDelete { idx in
                            for i in idx { model.delete(model.profiles[i].id) }
                        }
                    }
                }
            }
            .navigationTitle("WLAN-Profile")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Neues Profil", systemImage: "plus") { showNew = true }
                        .accessibilityIdentifier("new-profile")
                }
            }
        } detail: {
            if let id = selection, model.profile(id) != nil {
                ProfileDetailView(profileID: id)
            } else {
                ContentUnavailableView("Kein Profil gewählt", systemImage: "wifi")
            }
        }
        .sheet(isPresented: $showNew) {
            NewProfileSheet { name, ssid in
                selection = model.create(name: name, ssid: ssid).id
            }
        }
    }
}

struct NewProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var ssid = ""
    var onCreate: (String, String) -> Void

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !ssid.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Profilname", text: $name)
                        .accessibilityIdentifier("new-profile-name")
                    TextField("WLAN (SSID)", text: $ssid)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("new-profile-ssid")
                } footer: {
                    Text("Die App beansprucht nur dieses eine Netz, nie pauschal alle WLANs.")
                }
            }
            .navigationTitle("Neues Profil")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Anlegen") {
                        onCreate(name, ssid)
                        dismiss()
                    }
                    .disabled(!valid)
                    .accessibilityIdentifier("create-profile")
                }
            }
        }
    }
}
