# CaptiveAI (Repo AnyWiFiiOS)

iPhone- und iPad-App, die Captive-Portal-Anmeldungen automatisiert. Ein lokales Modell lernt den Ablauf im Gespräch, danach läuft er deterministisch ohne KI. Spezifikation: [`SPEC.md`](SPEC.md) und [`docs/spec/`](docs/spec/).

## Bauen und testen

```bash
# Core (läuft auch auf Linux)
cd Packages/CaptiveCore && swift test

# App (Simulator, iOS 27)
brew install xcodegen
xcodegen generate
python3 tools/test-portal/server.py --port 8099 &        # Testportal für die UI-Tests
xcodebuild -project CaptiveAI.xcodeproj -scheme CaptiveAI \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' CODE_SIGNING_ALLOWED=NO test
```

Schemes: `CaptiveAI` (Simulator und CI, ohne Hotspot-Provider) und `CaptiveAI-Device` (mit beiden Providern, braucht Entitlements).

## Aufbau

| Ordner | Inhalt |
|---|---|
| `Packages/CaptiveCore` | Plattformneutrale Logik: PRL, Normalizer, Engine, Validatoren, Redaction, Teilen, Provider-Kern |
| `Packages/CaptiveCore/Sources/CaptiveCoreApple` | Keychain, Foundation Models, PCC, CryptoKit, Transporte, WLAN-Konfiguration |
| `App` | SwiftUI-App (Profile, Chat, Aktivität, Import/Export, Repair Center, Einstellungen) |
| `Controls` | Control-Center-Steuerelement |
| `Extensions` | Hotspot Evaluation und Authentication Provider |
| `tools/test-portal` | Lokales Testportal ohne Abhängigkeiten |
| `docs` | Spezifikation, ADRs, Spike-Bericht, Geräte-Checkliste, App-Store-Texte, Entitlement-Antrag |

## Stand

Phasen 1 bis 11 sind umgesetzt (siehe `docs/spikes.md`). Offen sind die Punkte, die Hardware und das Hotspot-Entitlement brauchen: `docs/device-test-checklist.md`.
