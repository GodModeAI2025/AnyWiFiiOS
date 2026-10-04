# Projektstand

Stand: 04.10.2026, Branch `phase-2/engine` (baut auf `prep/phase-1-core` auf). CI: Linux (`swift test`), macOS (`swift test`), iOS-Simulator-Build der App.

## Phasen (SPEC.md §5)

| Phase | Stand | Nachweis |
|---|---|---|
| 0 Entitlements | offen, Auftraggeber | `docs/entitlement-antraege.md` |
| 1 Core-Fundament | ✅ | PRL-Modelle, YAML-Codec, Schema, Validator, Tests |
| 2 Normalizer & Engine | ✅ | 19 Fixtures mit Soll-Outcome, Redaction-Test, Trace-Compiler |
| 3 App-Grundgerüst | 🟡 Code fertig, CI-Build | SwiftUI/SwiftData, Profil-Chat, Login, Export/Import, Aktivität, Einstellungen. UI-Tests fehlen |
| 4 Manueller Modus | 🟡 | `URLSessionWiFiTransport`, `LoginService`, App Intent. Gate S13 nur auf Gerät prüfbar |
| 5 AI | 🟡 | Planner-Vertrag, PlanValidator, Lernlauf, Repair, HeuristicPlanner (Tests grün). FoundationModels-Planner und IntentChat kompilieren (macOS-SDK 26), Verhalten nur auf Gerät prüfbar |
| 6 Debug & Stabilisierung | ✅ Core, 🟡 App | Debug-Paket inkl. Agent-README und Schema, Re-Import, Revisionen/Rollback, Stabilitätsmetrik |
| 7 Teilen | ✅ Core, 🟡 App | `.captiveprofile`, Opt-in, AES-GCM/PBKDF2, Import-Konflikte (Keychain nie überschreiben) |
| 8 Spike | offen | braucht Gerät + Entitlement. Vorlage `docs/spikes.md` |
| 9 Provider | 🟡 Quellcode | `Extensions/`, noch nicht im Projekt (Extension-Point-IDs aus Xcode-Vorlage nötig) |
| 10 PCC | offen | optional, Entitlement + Small Business Program |
| 11 Politur | offen | |

## Definition of Done (01 §38 + SPEC §5)

| # | Kriterium | Stand |
|---|---|---|
| 1 | Profil per Text oder Sprache | Text ✅ (Chat + Parser). Sprache: offen (SpeechAnalyzer) |
| 2 | SSID-Zuordnung | ✅ |
| 3 | Evaluation Provider beansprucht nur konfigurierte Netze | Code ✅, Gerät offen |
| 4 | Provider führt Recipe aus | Code ✅, Gerät offen |
| 5–9 | Terms, User/Pass, Hotel, Voucher, zweistufig | ✅ (Fixtures 02–09, 11, 15, 16, 18) |
| 10 | Fehlender Wert → uiRequired | Engine ✅ (`missingUserValue`), Pending-Übergabe ✅, Provider offen |
| 11 | Wert sicher im Keychain | ✅ Code (`KeychainStore`), Gerät offen |
| 12 | Lernlauf → Recipe | ✅ (`LearningRunner` + `TraceCompiler`) |
| 13 | Zweiter Lauf ohne AI | ✅ (`testLearnThenReplayWithoutAI`) |
| 14 | Geändertes Label lokal reparierbar | ✅ (`testChangedLabelIsRepairedLocally`) |
| 15 | Redigiertes Debug-Paket | ✅ |
| 16 | Export/Import ohne Secrets | ✅ |
| 17 | Keine Secrets in Logs | ✅ (Trace- und Bundle-Tests) |
| 18 | Kein Payment-/Marketing-Opt-in ohne Erlaubnis | ✅ (Validator, Runtime, PlanValidator) |
| 19 | AI nur typisierte PRL-Aktionen | ✅ (`PortalPlan` + `PlanValidator`) |
| 20 | iPhone und iPad, iOS 27 | Code universal. CI baut mit iOS-26-SDK (kein 27 auf Runnern) |
| 21 | WLAN-Profil einrichten | Code ✅ (`WiFiConfigurator`), Gerät offen |
| 22 | Intent im mehrstufigen Chat | ✅ Code |
| 23 | Debug-Paket → Patch → Re-Import | ✅ Core + App-Import |
| 24 | Export mit Zugangsdaten nur per Opt-in, verschlüsselt | ✅ |
| 25 | Manueller Modus ohne Entitlement | Code ✅, Gate S13 offen |

## Funde für Spike/Spezifikation

1. **`NEHotspotManager.safariDomains`** (iOS 26): Bis zu 10 Domains, für die die App während der Hotspot-Authentifizierung `SFSafariViewController` nutzen darf. Für JavaScript-Portale (z. B. `login.wifionice.de`) ist das im Provider-Modus der vorgesehene Weg zur manuellen Anmeldung im App-Kontext. Vorschlag: In `presentUI` bei `manualInteractionRequired` das Portal in `SFSafariViewController` öffnen.
2. **`NEHotspotManager.evaluatedSSIDs`**: Bis zu 2 SSIDs, für die das System den Evaluation Provider gar nicht erst fragt. Für die zwei meistgenutzten Profile verwenden.
3. **Extension-Point-IDs** der neuen Provider stehen nicht in der abrufbaren Doku → Spike S0, Xcode-Vorlage „Network Extension“.
4. **CI-Toolchain**: macOS-Runner haben Xcode 26.6 mit iOS-26.5-SDK. Die App wird dort mit `IPHONEOS_DEPLOYMENT_TARGET=26.0` kompiliert, Release-Builds für iOS 27 brauchen ein lokales Xcode 27.

## Was ein Mac mit Gerät als Nächstes tun muss
1. Bundle-ID/Team-ID in `project.yml` und `AuthenticationProvider.swift` (TEAMID) eintragen.
2. `xcodegen generate`, App auf iPhone installieren, Gate S13 (Manueller Modus) gegen `tools/test-portal` im Test-WLAN prüfen.
3. Nach Entitlement: Extension-Targets aus der Xcode-Vorlage anlegen, Quellcode aus `Extensions/` übernehmen, Gates S0–S12.
