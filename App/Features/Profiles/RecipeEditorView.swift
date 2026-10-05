import SwiftUI
import CaptiveCore

/// Erweitert-Editor (01 §29). Eine geänderte Datei wird nie übernommen, bevor
/// Parse, Schema- und Security-Validierung erfolgreich waren.
struct RecipeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: PortalProfile
    var onSave: (PortalProfile) -> Void

    @State private var text = ""
    @State private var issues: [String] = []
    @State private var validated = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("recipe-text")
                    .onChange(of: text) { _, _ in validated = false }
                if !issues.isEmpty {
                    List(issues, id: \.self) { Text($0).font(.footnote).foregroundStyle(.red) }
                        .frame(maxHeight: 140)
                } else if validated {
                    Label("Gültig", systemImage: "checkmark.seal").padding().foregroundStyle(.green)
                }
            }
            .navigationTitle("Recipe (YAML)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Validieren") { _ = validate() }.accessibilityIdentifier("validate-recipe")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Übernehmen") {
                        guard let recipe = validate() else { return }
                        var p = profile
                        p.commit(recipe, note: "Editor")
                        onSave(p)
                        dismiss()
                    }
                    .accessibilityIdentifier("apply-recipe")
                }
            }
        }
        .onAppear {
            text = profile.recipe.flatMap { try? PRLCodec.serialize($0) } ?? Self.template(for: profile)
        }
    }

    private func validate() -> Recipe? {
        do {
            let recipe = try PRLCodec.parse(yaml: text)
            let found = SecurityValidator.errors(recipe, bindings: profile.credentialBindings)
            issues = found.map(\.description)
            validated = found.isEmpty
            return found.isEmpty ? recipe : nil
        } catch {
            issues = [String(describing: error)]
            validated = false
            return nil
        }
    }

    static func template(for profile: PortalProfile) -> String {
        """
        recipeVersion: 1
        name: \(profile.name)
        network:
          ssid: \(profile.network.ssidExact)
        stages:
          - id: s1_step
            actions:
              - tap:
                  target:
                    role: button
                    labelAny: [Continue, Weiter, Connect, Verbinden]
        success:
          internetAccess: true

        """
    }
}
