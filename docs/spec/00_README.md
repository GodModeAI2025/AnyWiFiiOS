# CaptiveAI – Spezifikationspaket

Stand: 4. Oktober 2026  
Zielplattform: iOS 27 / iPadOS 27  
Sprache der Spezifikation: Deutsch

## Inhalt

- `01_CaptiveAI_App_Spezifikation.md` – vollständige Produkt- und technische Spezifikation.
- `02_CaptiveAI_Spike_und_Testplan.md` – fokussierter Spike, um die kritischen Apple-/Extension-/AI-Fragen vor der Vollimplementierung zu verifizieren.

## Wichtigste, recherchierte Ausgangslage

1. Für Hotspot-Helper-Funktionalität ist weiterhin das verwaltete Entitlement  
   `com.apple.developer.networking.HotspotHelper` erforderlich.
2. Seit iOS 26 ist der empfohlene Weg die extension-basierte Architektur mit:
   - `NEHotspotManager`
   - `NEHotspotEvaluationProvider`
   - `NEHotspotAuthenticationProvider`
3. Die alte Registrierung über `NEHotspotHelper.register(...)` ist deprecated; Apple verweist auf `NEHotspotManager`.
4. Die Authentifizierung kann mehrstufig laufen. Wenn Benutzereingabe erforderlich ist, unterstützt der Systemzustand `uiRequired` → `presentUI`.
5. Apple empfiehlt ausdrücklich, das Hotspot-Helper-Entitlement **vor Beginn der Entwicklung** zu beantragen. Ohne genehmigtes Managed Entitlement lässt sich der echte Provider-Pfad auf einem realen iPhone/iPad nicht vollständig testen.
6. Die Kernlogik – HTML-Normalisierung, Recipe-Interpreter, Foundation-Models-Structured-Output, Keychain, Spracheingabe – kann parallel bereits ohne Hotspot-Entitlement als normale App-/Unit-Test-Logik entwickelt werden.
7. Die zentrale technische Unbekannte ist nicht das Recipe-Konzept, sondern ob und unter welchen Laufzeit-/Ressourcenbedingungen `FoundationModels` zuverlässig **innerhalb des Hotspot Authentication Providers** verwendet werden kann. Genau dafür ist der Spike vorgesehen.
8. Private Cloud Compute ist für den Live-Login nicht die richtige Abhängigkeit, weil vor erfolgreicher Captive-Portal-Anmeldung gerade kein freier Internetzugang garantiert ist. PCC ist ideal für nachträgliche Reparatur/Optimierung eines fehlgeschlagenen Recipes, sobald wieder Internet besteht.

## Primäre Apple-Quellen

- Hotspot helper: https://developer.apple.com/documentation/networkextension/hotspot-helper
- NEHotspotManager: https://developer.apple.com/documentation/networkextension/nehotspotmanager
- NEHotspotAuthenticationProvider: https://developer.apple.com/documentation/networkextension/nehotspotauthenticationprovider
- NEHotspotEvaluationProvider: https://developer.apple.com/documentation/networkextension/nehotspotevaluationprovider
- Hotspot Helper Entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.hotspothelper
- TN3111 – iOS Wi-Fi API overview: https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview
- TN3134 – Network Extension provider deployment: https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment
- Capability Requests: https://developer.apple.com/help/account/capabilities/capability-requests
- Direkter Hotspot-Helper-Request: https://developer.apple.com/contact/request/hotspot-helper/
- Foundation Models: https://developer.apple.com/documentation/foundationmodels
- Private Cloud Compute: https://developer.apple.com/private-cloud-compute/
- SpeechAnalyzer: https://developer.apple.com/documentation/speech/speechanalyzer

