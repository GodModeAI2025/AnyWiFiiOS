import SwiftUI
import UserNotifications
import CaptiveCore

@main
struct CaptiveAIApp: App {
    @State private var model = AppModel.make()
    @Environment(\.scenePhase) private var scenePhase
    private let router = NotificationRouter()

    init() {
        UNUserNotificationCenter.current().delegate = router
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { url in model.open(url) }
                .task {
                    router.onValueNeeded = { id in Task { @MainActor in model.checkPendingAsk(runId: id) } }
                    await model.hotspot.refresh()
                    model.checkPendingAsk()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.checkPendingAsk() }
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            ProfileListView()
                .tabItem { Label("WLAN-Profile", systemImage: "wifi") }
            ActivityView()
                .tabItem { Label("Aktivität", systemImage: "clock") }
            ImportExportView()
                .tabItem { Label("Import / Export", systemImage: "square.and.arrow.up.on.square") }
            SettingsView()
                .tabItem { Label("Einstellungen", systemImage: "gearshape") }
        }
        .sheet(item: Binding(get: { model.pendingImport }, set: { model.pendingImport = $0 })) { pending in
            RecipeImportSheet(pending: pending)
        }
        .sheet(item: Binding(get: { model.pendingAsk }, set: { model.pendingAsk = $0 })) { pending in
            PendingAskSheet(pending: pending)
        }
        .sheet(item: Binding(get: { model.pendingProfileImport }, set: { model.pendingProfileImport = $0 })) { pending in
            ProfileImportSheet(pending: pending)
        }
    }
}
