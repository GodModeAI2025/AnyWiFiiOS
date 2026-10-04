# CaptiveAI (Repo: AnyWiFiiOS): Leitdokument für den Coding-Agent

> **Lies zuerst dieses Dokument, dann `docs/spec/01_*` und `docs/spec/02_*`.**
> Die Spezifikationen in `docs/spec/` sind die **fachliche und technische Basis**.
> Dieses Dokument **ergänzt** sie um Anforderungen des Auftraggebers, die dort fehlen, und **entscheidet Konflikte**.
> **Bei Widerspruch gilt dieses Dokument.** Abschnittsverweise wie „01 §21“ meinen `docs/spec/01_CaptiveAI_App_Spezifikation.md`, Abschnitt 21.

Stand: 4. Oktober 2026

---

## 1. Dokumente & Rangfolge

| Rang | Datei | Inhalt |
|---|---|---|
| 1 | `SPEC.md` (dieses Dokument) | Ergänzungen, Konfliktentscheidungen, Build-/Agent-Regeln |
| 2 | `docs/spec/01_CaptiveAI_App_Spezifikation.md` | Produkt & Architektur (NEHotspotManager-Provider, PRL-Recipes, Normalizer, Sicherheit) |
| 3 | `docs/spec/02_CaptiveAI_Spike_und_Testplan.md` | Spike-Gates S0–S12, Fixtures, Testplan |
| – | `docs/spec/00_README.md` | Quellenübersicht |

Geprüfte Apple-Fakten (Apple-Doku, 04.10.2026): `NEHotspotManager`, `NEHotspotEvaluationProvider` und `NEHotspotAuthenticationProvider` gibt es ab iOS/iPadOS 26. Foundation Models gibt es ab iOS 26. Private Cloud Compute ist für Drittanbieter nutzbar, braucht aber das Entitlement `com.apple.developer.private-cloud-compute` und setzt die Teilnahme am App Store Small Business Program voraus (< 2 Mio. Erst-Downloads).

---

## 2. Ursprüngliche Anforderung des Auftraggebers (Abgleich)

| # | Anforderung | Abgedeckt durch | Status |
|---|---|---|---|
| A1 | Nur iOS & iPadOS | 01 §3.1 | ✅ |
| A2 | App beherbergt **WLAN-Profile** | 01 §32 nur als V1.1 | ⚠️ **in V1 gezogen**, siehe §3.1 |
| A3 | Auto-Login für Captive-Portal-WLANs | 01 §2, §26–28 (Hotspot-Provider) | ✅, ⚠️ Fallback ohne Entitlement fehlt → §3.5 |
| A4 | Mit Apple Intelligence (lokal / PCC) **im Chat** besprechen, wie die Anmeldung abläuft | 01 §4.2–4.3 (einmalige Beschreibung + Zusammenfassung) | ⚠️ **zum Dialog erweitert**, siehe §3.2 |
| A5 | System meldet sich selbst an und speichert den Ablauf als Profil | 01 §12–13 | ✅ |
| A6 | Bei Fehlschlag **Debug-Paket**, damit iterativ debuggt werden kann, bis es stabil läuft | 01 §22.3 (Debug Bundle) | ⚠️ **erweitert** um Agent-Lesbarkeit, Re-Import & Stabilitätsmetrik, siehe §3.3 |
| A7 | Profile **teilen** | 01 §21 | ✅ |
| A8 | Zugangsdaten beim Teilen **ausdrücklich erlaubt** | 01 §21.2 schließt Secrets im Export immer aus | ❌ **Konflikt**, entschieden in §3.4 |

---

## 3. Ergänzungen & Konfliktentscheidungen (verbindlich)

### 3.1 WLAN-Konfiguration ist Teil von V1 (überschreibt 01 §32)
- Ein Profil **kann** einen WLAN-Teil enthalten: SSID, Sicherheit (offen / WPA2/WPA3-Personal), Passphrase (Keychain).
- Button „WLAN auf diesem Gerät einrichten“ legt das Netz per `NEHotspotConfigurationManager.apply(_:)` an. Entitlement: `com.apple.developer.networking.HotspotConfiguration` (Self-Service).
- WPA-Enterprise, Scannen und Ortung bleiben Nicht-Ziele (01 §33).
- **KANN:** QR-Code für den WLAN-Teil (`WIFI:T:WPA;S:<ssid>;P:<pw>;;`), nur nach dem Opt-in aus §3.4.

### 3.2 Chat-Assistent statt Einmal-Beschreibung (erweitert 01 §4.2, §16.1, §29)
Der Nutzer soll mit dem System **im Dialog** klären, wie die Anmeldung abläuft.
- **Profil-Chat** (Haupt-App): mehrstufiges Gespräch per Text oder Sprache (SpeechAnalyzer, 01 §4.3). Das Modell stellt Rückfragen, bis ein vollständiger `PortalIntentDraft` (`@Generable`) vorliegt. Beispiele: „Soll ich die Zimmernummer speichern oder jedes Mal fragen?“, „Es gibt zwei Checkboxen, auch Newsletter? Standard: nein.“
- Nach jeder Runde zeigt die UI die aktuelle Zusammenfassung (Darstellung wie 01 §4.2). „Übernehmen“ speichert den Intent.
- **Portal-Vorschau im Chat (SOLL):** Ist das Gerät gerade im Portal-WLAN, holt die App die Portal-Seite über die **gleiche HTTP-Engine** (kein WKWebView, kein JS). Sie normalisiert die Seite (01 §11) und gibt dem Chat die Elementliste als Kontext. So kann der Nutzer auf konkrete Elemente verweisen („der zweite Haken“). Die Elementliste ist als native Liste sichtbar.
- **Reparatur-Chat:** Im Repair Center (01 §15, §29) startet der Chat mit dem redigierten Fehler-Trace als Kontext und erzeugt einen `RecipePatch`.
- **Modellwahl:** `AssistantModel`-Protokoll mit den Implementierungen `OnDeviceAssistant` (Foundation Models, Standard) und `PCCAssistant` (optional, nur mit Entitlement und Internet, nie im Live-Login, 01 §15). Für die UI gilt: Kein Modell verfügbar → Chat ist deaktiviert, der Erweitert-Editor (01 §29) bleibt nutzbar.
- **Datenschutz:** Werte sensibler Konzepte (01 §20.3) gehen nie in den Prompt. Der Chat fragt sie über ein **separates sicheres Eingabefeld** ab und speichert sie direkt im Keychain. Das Modell sieht nur Platzhalter (`<secret:…>`, `<personal:…>`).

### 3.3 Debug-Paket & Stabilisierungs-Schleife (erweitert 01 §22.3)
Ziel: Fehlschlag → Paket → Reparatur (in der App per Chat **oder** extern durch einen Menschen/KI-Coding-Agenten) → Re-Import → erneuter Test, bis das Recipe stabil ist.
- Wird nach jedem Lauf mit Outcome ≠ `success` automatisch erzeugt (zusätzlich manuell). Teilen per `ShareLink`.
- Datei `CaptiveAI-Debug-<profil>-<yyyyMMdd-HHmm>.zip`:
  ```
  README.md            Anleitung für Mensch + KI-Agent (Vorlage unten)
  summary.json         outcome (01 §23), fehlgeschlagene Stage/Aktion, Zeitstempel, recipeRevision
  intent.json          PortalIntent (redigiert)
  recipe.yaml          verwendetes Recipe
  trace.jsonl          redigierter Lern-/Replay-Trace (01 §12.3), eine Zeile pro Schritt
  pages/NN.yaml        normalisierte Seitenzustände (01 §11)
  pages/NN.html        Roh-HTML, redigiert (Formularwerte, Hidden-Values, Cookies entfernt), max. 1 MB
  network.json         Redirect-Kette, Statuscodes, Hosts, Header ohne Cookie/Authorization
  environment.json     App-/OS-Version, Gerät, Modellverfügbarkeit, Provider- vs. Manuell-Modus
  chat.json            Chatverlauf, falls vorhanden (nur Platzhalter)
  schema/prl-v1.json   JSON-Schema der PRL, damit ein externer Agent valide Patches erzeugen kann
  ```
- `README.md`-Vorlage (aus `Resources/DebugBundleREADME.md`, mit Feldern gefüllt):
  > Dieses Paket beschreibt einen fehlgeschlagenen Captive-Portal-Login. Lies `summary.json`, dann `trace.jsonl` und die Seiten in `pages/`. Erzeuge eine korrigierte `recipe.yaml` nach `schema/prl-v1.json`. Ändere nur die Stages/Targets, die den Fehler verursachen. Verwende keine Literal-Werte für Konzepte, die als `<secret:…>`/`<personal:…>` markiert sind. Gib die Datei als `recipe.yaml` zurück. Sie wird in CaptiveAI über „Recipe importieren“ geladen.
- **Re-Import:** „Recipe importieren“ im Profil (Datei-Picker, Share-Extension-frei über `onOpenURL`, Drag & Drop auf dem iPad). Danach Parse → Schema → Security-Validator (01 §24, §29) → Diff-Ansicht alt/neu → Bestätigen → neue Revision (01 §30).
- **Stabilitätsmetrik pro Profil:** Läufe gesamt, Erfolgsquote, letzte 10 Outcomes. Status „stabil“ ab 5 Erfolgen in Folge ohne Repair. Sichtbar in der Aktivitätsansicht (01 §23).
- **Redaction-Test (MUSS):** Ein automatisierter Test erzeugt ein Debug-Paket mit den Testwerten aus 02 §18 und prüft byteweise, dass keiner davon in irgendeiner Datei des ZIPs vorkommt.

### 3.4 Teilen mit Zugangsdaten (überschreibt 01 §20.1 „Export“ und §21.2)
Der Auftraggeber erlaubt ausdrücklich, Zugangsdaten mitzuteilen.
- Standardexport bleibt **ohne** Secrets und personenbezogene Werte (wie 01 §21.2).
- Im Export-Dialog gibt es den Schalter **„Zugangsdaten mitteilen“** (Standard: aus). Einschalten löst einen Bestätigungsdialog aus, der die betroffenen Werte nach Konzept auflistet, ohne Klartext („Passwort, Nachname werden mitgeteilt“).
- Mit Opt-in kommt `credentials.json` in den `.captiveprofile`-Container (01 §21.1), standardmäßig **verschlüsselt**:
  - Passphrase-Schutz ist vorausgewählt: AES-256-GCM (CryptoKit), Schlüssel per PBKDF2-HMAC-SHA256 (CommonCrypto), ≥ 600 000 Iterationen, zufälliger 16-Byte-Salt. Salt, Iterationen und Nonce stehen im `manifest.json`.
  - Der Nutzer **darf** die Verschlüsselung abwählen (zweite Bestätigung „Unverschlüsselt teilen“).
- `manifest.json` enthält `containsCredentials: true|false` und `credentialsEncrypted: true|false`.
- Import: Vorschau zeigt „Enthält Zugangsdaten“ → Passphrase abfragen → Werte landen im Keychain. Der Grundsatz „Keychain-Werte werden niemals überschrieben“ (01 §31) bleibt bestehen: Bei Konflikt fragt die App pro Wert „Behalten / Ersetzen“.
- Logs, Debug-Pakete und Notifications enthalten weiterhin **nie** Secrets (01 §20.1 bleibt für diese Kanäle unverändert).

### 3.5 Betrieb ohne Hotspot-Helper-Entitlement: „Manueller Modus“ (ergänzt 02 §25)
Lehnt Apple das Entitlement ab oder ist es noch nicht erteilt, bleibt die App trotzdem auf echten Geräten nutzbar:
- **Auslöser:** App öffnen, App Intent „Im WLAN anmelden“ (Kurzbefehle-Automation „Wenn mit WLAN X verbunden“), Control-Center-Steuerelement.
- **Ablauf:** Captive-Erkennung per `http://captive.apple.com/hotspot-detect.html` (enthält die Antwort „Success“, ist das Gerät online). Danach läuft dieselbe `CaptiveCore`-Engine (Replay, Lernen, Repair) in der Haupt-App über `URLSession` mit `allowsCellularAccess = false`.
- Der Unterschied zum Provider-Modus liegt nur im **Transport-Adapter** (`PortalTransport`-Protokoll: `HotspotCommandTransport` vs. `URLSessionWiFiTransport`). Die Engine kennt den Modus nicht.
- **Neues Spike-Gate S13:** Klären, ob im Captive-Zustand Requests aus der App mit `allowsCellularAccess = false` zuverlässig über das WLAN-Interface laufen, ob der System-CNA-Dialog stört und ob ein Login aus der App den CNA-Zustand auflöst. Ergebnis in den Spike-Bericht.
- **Ergebnis E** (Erweiterung 02 §25): Entitlement abgelehnt → Produkt = Manueller Modus + alle übrigen Features. Kein Abbruchkriterium.

### 3.7 Portal-Adapter & Runtime-Regeln (ergänzt 01 §9, §17; Details: ADR 0001)
- Bekannte Portalsysteme ohne verwertbares HTML-Formular (DB ICE/Icomera JSON, SNCF, MikroTik CHAP) bedient ein fest eingebauter **Portal-Adapter**. Das Recipe verweist nur per `- adapter: { id: … }` darauf.
- Die Engine übernimmt Query-Parameter der Portal-URL, wählt vorausgewählte Marketing-Haken ab, blockiert kommerzielle Elemente und prüft vor dem Login, ob das Gerät schon online ist.
- Recherche-Grundlage: `docs/research/portale-bahn-hotel.md`.

### 3.6 Plattform & Name
- Mindestversion **iOS/iPadOS 27** (wie 01 §3.1).
- Produkt-/Target-Name **CaptiveAI** (wie 01 §6). Das Repo heißt weiterhin `AnyWiFiiOS`. Bundle-ID-Präfix liefert der Auftraggeber (§8). Bis dahin gilt der Platzhalter `com.example.captiveai`.

---

## 4. Build- & Repo-Vorgaben (ergänzt 01 §6)

### 4.1 Struktur
```
AnyWiFiiOS/
├─ SPEC.md, CLAUDE.md
├─ docs/spec/                 Basis-Spezifikation (nicht ändern, nur per PR mit Begründung)
├─ docs/spikes.md             Spike-Ergebnisbericht (Vorlage 02 §28, + S13)
├─ docs/decisions/            ADRs (eine Datei pro Architekturentscheidung)
├─ project.yml                XcodeGen: Targets CaptiveAIApp, HotspotEvaluationProvider,
│                             HotspotAuthenticationProvider, CaptiveUITests
├─ Packages/CaptiveCore/      Swift Package
│  ├─ Sources/CaptiveCore/        plattformneutral: PRL-Modelle, YAML-Codec, Validator,
│  │                              Normalizer, Matcher, Recipe-Interpreter, Trace-Compiler,
│  │                              Redaction, Debug-Bundle-Builder, Export-Format
│  ├─ Sources/CaptiveCoreApple/   Apple-only: Keychain, App Group Store, FoundationModels-
│  │                              Adapter, PCC-Adapter, Transport-Adapter, CryptoKit-Export
│  └─ Tests/CaptiveCoreTests/     inkl. Fixtures 02 §21 unter Tests/Fixtures/
├─ App/                       SwiftUI-App (Features: Profiles, Chat, Activity, ImportExport,
│                             RepairCenter, Settings, ManualMode)
├─ Extensions/                Evaluation- & Authentication-Provider
└─ tools/test-portal/         lokaler Testportal-Server (Routen 02 §5.3 + Fixtures), Python 3, ohne Abhängigkeiten
```

### 4.2 Regeln
- **`CaptiveCore` muss auf Linux mit `swift test` bauen und testen** (`#if canImport(...)` nur in `CaptiveCoreApple`). So kann ein Cloud-Agent ohne Mac den Großteil der Logik entwickeln und testen. Erlaubte Abhängigkeiten: `SwiftSoup` (HTML), `Yams` (YAML). Beide laufen auf Linux.
- App, Extensions und UI-Tests brauchen macOS + Xcode (CI: GitHub Actions `macos-latest`). Ein Agent ohne Mac implementiert diese Teile, kennzeichnet sie im PR aber als „nicht lokal gebaut“.
- Swift 6, Strict Concurrency. SwiftUI mit `NavigationSplitView` (iPad) bzw. Stack (iPhone).
- Lokalisierung: Deutsch (primär), Englisch, String Catalog.
- Keine Analytics, keine eigenen Server.

### 4.3 CI
- Job `core-linux`: `swift test` in `Packages/CaptiveCore` (ubuntu-latest, offizielles Swift-Image).
- Job `app-macos`: `xcodegen generate` → `xcodebuild build test` (Simulator), startet vorher `tools/test-portal`.

---

## 5. Umsetzungsreihenfolge (ersetzt 01 §37 im Detail)

| Phase | Inhalt | Abnahme |
|---|---|---|
| **0** Entitlements (Auftraggeber) | Bundle-ID, Hotspot Helper beantragen (Text: 01 §35.2), optional PCC | Antrag gestellt, Datum in `docs/spikes.md` |
| **1** Core-Fundament | Package-Gerüst, PRL-Modelle + YAML, Schema-Export `prl-v1.json`, Parser/Validator, Unit-Tests 02 §22 | `swift test` grün auf Linux, CI-Job `core-linux` |
| **2** Normalizer & Engine | Normalizer, Matcher (01 §10, 02 §13), Interpreter gegen Fixtures, Trace-Compiler, Security-Validator (01 §24–25), Consent-Regeln (01 §19) | Fixtures 01–15 mit erwarteten Outcomes, Redaction-Test (§3.3) |
| **3** App-Grundgerüst | XcodeGen, Profile-UI, Keychain, App Group, WLAN-Konfiguration (§3.1), Erweitert-Editor | UI-Test „Profil anlegen“ |
| **4** Manueller Modus | Transport-Adapter, Captive-Probe, App Intent, Control | Replay gegen `tools/test-portal` im Simulator. Gate S13 auf Gerät |
| **5** AI | Foundation-Models-Adapter, Profil-Chat (§3.2), Lernlauf in App, Adaptive Repair | Fake-Model-Tests in CI. Auf Gerät P1–P8 per Chat lernbar |
| **6** Debug & Stabilisierung | Debug-Paket (§3.3), Re-Import, Diff, Revisionen, Stabilitätsmetrik | P10 per externem Patch reparierbar (Roundtrip-Test) |
| **7** Teilen | `.captiveprofile`, Opt-in Zugangsdaten + Verschlüsselung (§3.4), Import-Konflikte (01 §31) | Roundtrip-Tests: ohne / mit verschlüsselt / mit unverschlüsselt / falsche Passphrase |
| **8** Spike | Gates S0–S12 (02) + S13, sobald das Entitlement da ist | `docs/spikes.md` vollständig, ADR zur Architekturentscheidung (02 §25) |
| **9** Provider-Integration | Evaluation/Authentication Provider, `uiRequired`/`presentUI`, Pending Session | DoD-Punkte 01 §38 Nr. 3, 4, 10 auf Gerät |
| **10** PCC-Repair (optional) | `PCCAssistant` im Repair Center | Nur mit Entitlement. Patch durchläuft denselben Validator |
| **11** Politur | Accessibility, iPad-Layout, Privacy Manifest (01 §34), App-Store-Texte | Accessibility-Audit ohne kritische Befunde |

Phasen 1–7 hängen **nicht** vom Hotspot-Entitlement ab. Phase 8 startet, sobald es vorliegt, notfalls parallel.

**Definition of Done V1** = 01 §38, ergänzt um:
21. WLAN-Profil lässt sich auf dem Gerät einrichten (§3.1).
22. Profil-Intent ist im mehrstufigen Chat erstellbar, inkl. Rückfragen (§3.2).
23. Debug-Paket → externer Patch → Re-Import → Erfolg (§3.3).
24. Export mit Zugangsdaten nur per Opt-in, standardmäßig verschlüsselt (§3.4).
25. Manueller Modus funktioniert ohne Hotspot-Entitlement (§3.5).

---

## 6. Agenten-Rollen (agency-agents)

Quelle: https://github.com/msitarzewski/agency-agents (die angegebene URL `MichaelSitarzewski/agency-agents` war nicht öffentlich erreichbar).

| Rolle | Persona-Datei | Phasen |
|---|---|---|
| Orchestrierung | `specialized/agents-orchestrator.md`, `project-management/project-manager-senior.md` | alle |
| iOS / Swift | `engineering/engineering-mobile-app-builder.md`, `engineering/engineering-senior-developer.md` | 1–4, 6–9, 11 |
| AI | `engineering/engineering-ai-engineer.md`, `engineering/engineering-prompt-engineer.md` | 5, 10 |
| UX | `design/design-ux-architect.md` | 3, 5, 11 |
| Sicherheit / Datenschutz | `security/security-secrets-credential-engineer.md`, `security/security-appsec-engineer.md`, `engineering/engineering-privacy-engineer.md` | 2, 6, 7 |
| QA | `testing/testing-evidence-collector.md`, `testing/testing-reality-checker.md`, `testing/testing-accessibility-auditor.md` | Abnahme jeder Phase (Dev↔QA-Loop) |
| Release / Doku | `engineering/engineering-mobile-release-engineer.md`, `engineering/engineering-technical-writer.md` | 8, 11 |

---

## 7. Arbeitsregeln für den Agenten
1. Eine Phase pro Branch/PR. Der PR-Text belegt jedes Abnahmekriterium (Testausgabe, Screenshot oder Log).
2. Weicht etwas von `docs/spec/` oder diesem Dokument ab, schreibe ein ADR in `docs/decisions/`. Nicht stillschweigend abweichen.
3. Keine Secrets in Code, Tests (nur die Dummy-Werte aus 02 §18), Logs, Prompts oder Fixtures.
4. Keine Unterstellungen über Apple-APIs: Bei Unsicherheit die Apple-Doku prüfen und im PR verlinken.
5. Nicht testbare Gerätepunkte als offene Checkliste in `docs/device-test-checklist.md` führen.

---

## 8. Offene Punkte für den Auftraggeber
1. **Bundle-ID / Team-ID**. Ohne sie gibt es keinen Entitlement-Antrag.
2. **Hotspot-Helper-Antrag** stellen (Account Holder, 01 §35).
3. **PCC:** Ist das Team im Small Business Program? Wenn ja, Entitlement beantragen. Sonst entfällt Phase 10.
4. Soll der unverschlüsselte Export (§3.4) überhaupt angeboten werden oder nur verschlüsselt?
5. Endgültiger Produktname: CaptiveAI oder AnyWiFi?
