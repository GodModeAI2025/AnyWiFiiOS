import SwiftData
import SwiftUI

@main
struct CaptiveAIApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [ProfileRecord.self, RunRecord.self], inMemory: AppConfig.useInMemoryStore)
    }
}

/// Hauptnavigation (01 §4.1): Profile, Aktivität, Import/Export, Einstellungen.
/// iPad: Sidebar + Detail, iPhone: Stack.
struct RootView: View {
    enum Section: Hashable {
        case profile(UUID)
        case activity
        case settings
    }

    @Environment(\.modelContext) private var context
    @Query(sort: \ProfileRecord.name) private var profiles: [ProfileRecord]
    @State private var selection: Section?
    @State private var showSetup = false
    @State private var importURL: URL?
    @State private var showImporter = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                SwiftUI.Section("WLAN-Profile") {
                    if profiles.isEmpty {
                        Text("Noch keine Profile. Tippe auf +, um eine Anmeldung im Chat einzurichten.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(profiles) { profile in
                        NavigationLink(value: Section.profile(profile.id)) {
                            ProfileRow(profile: profile)
                        }
                    }
                    .onDelete(perform: delete)
                }
                SwiftUI.Section {
                    NavigationLink(value: Section.activity) { Label("Aktivität", systemImage: "clock.arrow.circlepath") }
                    NavigationLink(value: Section.settings) { Label("Einstellungen", systemImage: "gear") }
                }
            }
            .navigationTitle("CaptiveAI")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showSetup = true } label: { Label("Neues Profil", systemImage: "plus") }
                        .accessibilityIdentifier("root.newProfile")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button { showImporter = true } label: { Label("Importieren", systemImage: "square.and.arrow.down") }
                }
            }
        } detail: {
            switch selection {
            case .profile(let id)?:
                if let profile = profiles.first(where: { $0.id == id }) {
                    ProfileDetailView(profile: profile)
                } else {
                    ContentUnavailableView("Profil nicht gefunden", systemImage: "wifi.exclamationmark")
                }
            case .activity?:
                ActivityView()
            case .settings?:
                SettingsView()
            case nil:
                ContentUnavailableView("Kein Profil ausgewählt", systemImage: "wifi",
                                       description: Text("Wähle ein Profil oder lege ein neues an."))
            }
        }
        .sheet(isPresented: $showSetup) {
            ProfileSetupView { profile in
                selection = .profile(profile.id)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.captiveProfile]) { result in
            if case .success(let url) = result { importURL = url }
        }
        .onOpenURL { url in importURL = url }
        .onAppear { SharedProfileMirror.write(profiles) }
        .onChange(of: profiles.map(\.updatedAt)) { SharedProfileMirror.write(profiles) }
        .sheet(item: $importURL) { url in
            ImportProfileView(fileURL: url) { profile in selection = .profile(profile.id) }
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let profile = profiles[index]
            for slot in profile.credentialSlots { try? AppConfig.keychain.delete(slot.key) }
            context.delete(profile)
        }
        try? context.save()
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

struct ProfileRow: View {
    let profile: ProfileRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(profile.name).font(.headline)
                if profile.isStable {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        .accessibilityLabel("Stabil")
                }
            }
            Text(profile.ssid).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
