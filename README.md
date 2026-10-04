# CaptiveAI (AnyWiFiiOS)

iOS/iPadOS-App, die Captive-Portal-Anmeldungen (Hotel, Bahn, Café …) lernt und automatisch ausführt.
Lokal mit Apple Intelligence, mit teilbaren WLAN-Profilen.

**Spezifikation:** [`SPEC.md`](SPEC.md) (Leitdokument) → [`docs/spec/`](docs/spec/) (Basis)
**Stand:** siehe [`docs/status.md`](docs/status.md) (Phasen, DoD, offene Gerätetests)

## Was schon da ist

| Pfad | Inhalt | Läuft auf |
|---|---|---|
| `Packages/CaptiveCore` | PRL-Modelle, YAML-Codec, Security-Validator + Tests | Linux & macOS (`swift test`) |
| `Packages/CaptiveCore/Tests/Fixtures/portals` | 15 Testportale (02 §21) + `manifest.json` mit Sollergebnissen | – |
| `Packages/CaptiveCore/Tests/Fixtures/recipes` | Beispiel-Recipes: gültig, Schema-ungültig, Policy-ungültig | – |
| `Schemas/prl-v1.schema.json` | JSON-Schema der Recipe-Sprache (für Debug-Pakete/externe Agenten) | – |
| `tools/test-portal` | lokales Fake-Captive-Portal mit Server-Log | Python 3, ohne Abhängigkeiten |
| `tools/prl/validate_recipes.py` | Recipes gegen das Schema prüfen | Python 3 + pyyaml, jsonschema |
| `docs/entitlement-antraege.md` | Checkliste für die Apple-Anträge | – |
| `Packages/CaptiveCore/Sources/CaptiveCoreApple` | Foundation-Models-Planner, Chat, Keychain, WLAN-/Hotspot-Transport | iOS/macOS |
| `App/` | SwiftUI-App (Profile, Chat, Login, Teilen, Aktivität, Kurzbefehl) | iOS (XcodeGen: `project.yml`) |
| `Extensions/` | Hotspot-Provider (noch nicht im Projekt, Spike S0) | iOS |
| `UITests/` | End-to-End-Test: Chat → Lernen → Login gegen `tools/test-portal` | iOS-Simulator |

## Schnellstart

```bash
# App erzeugen und öffnen (macOS mit Xcode)
xcodegen generate && open CaptiveAI.xcodeproj

# Kernlogik testen
cd Packages/CaptiveCore && swift test

# Fake-Portal starten (Apple-Probe: http://127.0.0.1:8080/hotspot-detect.html)
python3 tools/test-portal/test_portal.py --port 8080 --portal 05_hotel --log portal.jsonl

# Recipe prüfen (z. B. aus einem Debug-Paket)
pip install pyyaml jsonschema
python3 tools/prl/validate_recipes.py pfad/zu/recipe.yaml
```
