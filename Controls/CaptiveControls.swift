import SwiftUI
import WidgetKit
import AppIntents

@main
struct CaptiveControlsBundle: WidgetBundle {
    var body: some Widget { LoginControl() }
}

/// Control-Center-Steuerelement "Im WLAN anmelden" (SPEC §3.5).
struct LoginControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.example.captiveai.login") {
            ControlWidgetButton(action: LoginIntent(profile: nil)) {
                Label("Im WLAN anmelden", systemImage: "wifi")
            }
        }
        .displayName("Im WLAN anmelden")
        .description("Meldet dich am Captive Portal des aktuellen WLANs an.")
    }
}
