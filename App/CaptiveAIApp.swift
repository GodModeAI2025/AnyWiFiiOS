import SwiftUI
import CaptiveCore

@main
struct CaptiveAIApp: App {
    @State private var model = AppModel.make()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { url in model.openRecipeFile(url) }
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
    }
}
