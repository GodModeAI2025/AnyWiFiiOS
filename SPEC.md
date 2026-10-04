# AnyWiFi für iOS: Spezifikation für den Coding-Agent

> **Zweck dieses Dokuments:** Ein Coding-Agent soll die App ohne Rückfragen umsetzen können.
> Alles, was technisch unsicher ist, steht in **Phase 0 (Spikes)** und muss *vor* der Feature-Arbeit geklärt werden.
> Abschnitte mit **MUSS** sind verbindlich, **SOLL** ist empfohlen, **KANN** ist optional.

---

## 1. Ursprüngliche Anforderung (bereinigt)

Original des Auftraggebers, Diktierfehler korrigiert:

> Eine App nur für **iOS und iPadOS**. Die App verwaltet **WLAN-Profile** und bietet **Auto-Login für Captive-Portal-WLANs** (Hotel, Bahn, Café, Flughafen …).
> Über **Apple Intelligence** (lokal bzw. Private Cloud Compute) bespricht der Nutzer im **Chat**, wie die Anmeldung im aktuellen WLAN abläuft, z. B. „Drücke Button X“, „Trage A und B in die Felder ein“, „Hake die AGB an“. Das System führt die Anmeldung dann selbst aus.
> Klappt es, speichert das System den Ablauf als **Profil** und meldet sich künftig automatisch an.
> Klappt es nicht, erzeugt die App ein **Debug-Paket**, mit dem man weiter debuggen kann, bis der Ablauf stabil läuft.
> Profile sollen **teilbar** sein. Enthalten sie Benutzername/Passwort, ist das Teilen **ausdrücklich erlaubt** (Opt-in).

Glossar: *Recipe* = gespeicherter, deterministischer Login-Ablauf. *Profil* = WLAN-Daten + Recipe + Variablen. *Portal* = Captive-Portal-Webseite.

---

## 2. Technische Realität: verbindliche Leitplanken

Diese Punkte entscheiden die Architektur. Der Agent darf sie **nicht** ignorieren.

### 2.1 Apple Intelligence / Private Cloud Compute
- Drittanbieter-Apps haben über das **Foundation Models Framework** (ab iOS 26) Zugriff auf das **On-Device-Sprachmodell** (`LanguageModelSession`, `@Generable`, Tool Calling).
- **Private Cloud Compute ist für Drittanbieter-Apps (Stand Wissensstand des Autors) nicht direkt per API ansprechbar.** → In Phase 0 prüfen, ob das aktuelle SDK das inzwischen erlaubt.
- **MUSS:** Die LLM-Anbindung liegt hinter einem Protokoll `AssistantModel`. Standardimplementierung: `FoundationModelsAssistant` (on-device). Eine spätere PCC- oder andere Implementierung lässt sich dann ohne Umbau einhängen.
- **MUSS:** Das On-Device-Modell hat ein **kleines Kontextfenster (ca. 4k Tokens)**. Deshalb gehen keine rohen HTML-Seiten in den Prompt, sondern nur ein komprimierter Snapshot (siehe 5.3).
- **MUSS:** Läuft das Gerät ohne Apple Intelligence (`SystemLanguageModel.default.availability != .available`), gibt es einen **manuellen Recipe-Editor** (Schritt-Liste per Tippen/Auswählen) und einen **Aufzeichnungsmodus** (Nutzer klickt selbst, die App zeichnet auf). Die App bleibt so voll nutzbar.

### 2.2 Captive-Portal-Login: zwei Ausbaustufen
iOS erlaubt nicht ohne Weiteres, dass eine App den systemeigenen Captive-Portal-Dialog (Captive Network Assistant, CNA) übernimmt. Darum gibt es zwei Stufen:

| | **Stufe A: MVP (ohne Sonder-Entitlement)** | **Stufe B: echter Auto-Login** |
|---|---|---|
| API | `NEHotspotConfigurationManager` (WLAN speichern/beitreten) + `WKWebView` in der App | `NEHotspotHelper` |
| Entitlement | `com.apple.developer.networking.HotspotConfiguration` (Self-Service in Xcode) | `com.apple.developer.networking.HotspotHelper`, **muss bei Apple beantragt werden**, Genehmigung unsicher |
| Ablauf | Nutzer öffnet App / Kurzbefehl / Widget → App erkennt Portal → führt Recipe im WebView aus | System ruft App bei Netzwechsel im Hintergrund auf (`evaluate`/`authenticate`) → App loggt sich headless per HTTP ein, CNA erscheint nicht |
| Recipe-Typ | DOM-Recipe (Klicks/Eingaben im WebView) | HTTP-Recipe (Requests per `NSMutableURLRequest.bind(to: command)`) |

- **MUSS:** Zuerst Stufe A komplett umsetzen. Stufe B als eigenes Modul `HotspotHelperExtension`, hinter Feature-Flag, aktiv nur wenn das Entitlement vorhanden ist.
- **MUSS:** Das Recipe-Format unterstützt beide Typen. Beim Lernen im WebView zeichnet die App zusätzlich den **finalen Login-Request** auf (Methode, URL, Formfelder) und leitet daraus ein HTTP-Recipe ab, damit Stufe B später ohne Neu-Lernen funktioniert.
- Hinweis: Die in iOS 14 eingeführte Unterstützung für die Captive-Portal-API (RFC 8908/8910) betrifft Netzbetreiber, die die Portal-URL per DHCP/RA melden. Sie liefert **keinen** App-Auto-Login, kann aber die Portal-Erkennung verbessern, wenn das Netz sie unterstützt.

### 2.3 Weitere Plattform-Fakten
- SSID/BSSID auslesen (`NEHotspotNetwork.fetchCurrent`) braucht das Entitlement **Access WiFi Information** *und* entweder Standortfreigabe oder ein Netz, das die App selbst per `NEHotspotConfiguration` angelegt hat.
- Im **Simulator gibt es kein WLAN**. Recipe-Engine und Chat werden gegen lokale Test-Portale getestet (Abschnitt 9), echte WLAN-Funktionen nur auf Gerät.
- Solange das WLAN im Captive-Zustand ist, kann iOS App-Traffic über Mobilfunk leiten. → Phase-0-Spike: sicherstellen, dass Portal-Requests über WLAN gehen (`URLSessionConfiguration.allowsCellularAccess = false`, prüfen, wie sich `WKWebView` verhält).

---

## 3. Zielplattform & Tech-Stack (MUSS)

| Thema | Vorgabe |
|---|---|
| Plattformen | iPhone + iPad (Universal-App). **Kein** macOS/Catalyst/visionOS. |
| Minimum | iOS/iPadOS 26.0 (Foundation Models). Apple-Intelligence-fähige Geräte für den Chat; Rest läuft auch ohne. |
| Sprache | Swift 6, Strict Concurrency an |
| UI | SwiftUI, `NavigationSplitView` (iPad: Sidebar, iPhone: Stack) |
| Persistenz | SwiftData für Profile; **Secrets ausschließlich im Keychain** |
| Abhängigkeiten | Keine Third-Party-Pakete ohne Begründung. ZIP: `AppleArchive` oder eine minimale eigene ZIP-Schreibroutine |
| Sprachen | Deutsch (primär), Englisch; String Catalog (`Localizable.xcstrings`) |
| Projekt | Xcode-Projekt per **XcodeGen** (`project.yml` im Repo), damit es reproduzierbar ist |
| CI | GitHub Actions auf `macos-latest`: Build + Unit-Tests + UI-Tests gegen Test-Portale |

---

## 4. Funktionsumfang

### 4.1 Profile verwalten (MUSS)
- Liste aller Profile mit Status (zuletzt erfolgreich, Fehlerquote, Stufe A/B-fähig).
- Profil anlegen, bearbeiten, duplizieren, löschen.
- WLAN-Teil: SSID, Sicherheit (offen / WPA2/3-Personal; WPA-Enterprise **KANN** später), Passwort → per `NEHotspotConfiguration` im System hinterlegen (Button „WLAN installieren“).
- Portal-Teil: Recipe, Variablen (z. B. `roomNumber`, `lastName`, `voucher`, `username`, `password`), Erfolgs-Check.
- Matching: Ein Profil passt zu einem Netz über SSID (exakt oder Muster, z. B. `WIFIonICE*`) und optional Portal-Host.

### 4.2 Portal erkennen & einloggen (MUSS)
1. Trigger: App-Start, Rückkehr in den Vordergrund, App Intent „Im WLAN anmelden“ (für Kurzbefehle/Automationen, z. B. „Wenn mit WLAN X verbunden“), Widget/Control-Center-Steuerelement.
2. Erkennung: HTTP-GET auf `http://captive.apple.com/hotspot-detect.html`. Antwort mit `Success` → online. Sonst Redirect/HTML → Portal-URL ermitteln (letzte Redirect-URL bzw. Meta-Refresh/JS-Redirect im WebView).
3. Passendes Profil gefunden → Recipe ausführen (Abschnitt 6) → Erfolgs-Check → Ergebnis anzeigen (Erfolg / Fehler + Debug-Paket).
4. Kein Profil → Angebot: „Anmeldung im Chat einrichten“.

### 4.3 Chat-Assistent zum Einrichten (MUSS, mit Fallback aus 2.1)
- Split-Ansicht: oben/links das **Portal im WebView**, unten/rechts der **Chat**.
- Der Nutzer beschreibt in natürlicher Sprache, was zu tun ist. Das Modell sieht einen komprimierten Seiten-Snapshot und ruft **Tools** auf (Abschnitt 5.2). Jede Aktion wird im WebView sichtbar ausgeführt und hervorgehoben.
- Bei Unklarheit fragt das Modell nach („Meinst du ‚Kostenlos verbinden‘ oder ‚Premium‘?“).
- Werte wie Zimmernummer oder Passwort fragt die App über ein **separates, sicheres Eingabefeld** ab. Sie landen als Variable im Keychain und **nie im Prompt** (siehe 5.4).
- Nach erfolgreichem Login: Zusammenfassung des Recipes anzeigen („1. Checkbox AGB anhaken, 2. Nachname eintragen, 3. ‚Verbinden‘ tippen“) → Nutzer bestätigt → Profil speichern.
- **SOLL:** Aufzeichnungsmodus („Ich zeig’s dir“): Nutzer bedient das Portal selbst, die App protokolliert Klicks/Eingaben als Recipe-Schritte.

### 4.4 Fehlschlag → Debug-Paket & Reparatur (MUSS)
- Schlägt ein Login fehl, erzeugt die App automatisch ein **Debug-Paket** (Abschnitt 7).
- Aktionen: „Teilen“ (Share Sheet), „Im Chat reparieren“ (Chat startet mit Fehlerkontext: welcher Schritt, welcher Selektor fehlte, aktueller Snapshot), „Erneut versuchen“.
- Das Debug-Paket ist so aufgebaut, dass ein **externer Coding-/KI-Agent** (z. B. Claude Code) es lesen und daraus ein korrigiertes Recipe-JSON erzeugen kann. Dieses JSON lässt sich wieder importieren. Dieser Kreislauf läuft, bis das Recipe stabil ist.
- Stabilitäts-Metrik pro Profil: Anzahl Ausführungen, Erfolge, letzte 10 Ergebnisse. Ein Profil gilt als „stabil“ ab 5 Erfolgen in Folge.

### 4.5 Teilen & Import (MUSS)
- Export als Datei `*.anywifi` (eigener `UTType` `com.anywifi.profile`, konform zu `public.json`), Weitergabe per `ShareLink` (AirDrop, Nachrichten, Mail, Dateien).
- Import: Datei öffnen / „Öffnen mit AnyWiFi“ / Drag & Drop (iPad) → Vorschau mit Übersicht der Schritte und Hinweis auf enthaltene Zugangsdaten → „Importieren“.
- **Zugangsdaten:** Standardmäßig **nicht** im Export. Schalter „Zugangsdaten mitteilen“ mit Bestätigungsdialog („Empfänger können dein Passwort sehen“). Der Auftraggeber erlaubt das ausdrücklich, das Opt-in bleibt aber pro Export erhalten.
- **SOLL:** Optionaler Passwortschutz für die Exportdatei (AES-GCM via CryptoKit, Schlüssel per PBKDF2 aus Passphrase, ≥ 200 000 Iterationen, Salt in der Datei).
- **KANN:** QR-Code für den WLAN-Teil (`WIFI:T:WPA;S:<ssid>;P:<pw>;;`) und für kleine Profile (komprimiert).
- **MUSS:** Importierte Recipes werden validiert (Schema, erlaubte Aktionen, keine Fremd-Domains außer Portal-Host-Liste). Vor der ersten Ausführung eines importierten Recipes fragt die App einmal nach Bestätigung.

---

## 5. KI-Assistent: Design

### 5.1 Ablauf einer Chat-Runde
```
Nutzernachricht
  → PageSnapshotter erzeugt Snapshot (≤ ~1 500 Tokens)
  → LanguageModelSession(instructions: Systemprompt, tools: [...])
  → Modell ruft Tools auf → RecipeEngine führt im WebView aus → Tool-Ergebnis (neuer Kurz-Snapshot / Fehler)
  → Modell antwortet dem Nutzer
  → alle ausgeführten Aktionen werden als Recipe-Entwurf mitgeschrieben
```

### 5.2 Tools (Foundation Models `Tool`-Protokoll, Argumente als `@Generable`)
| Tool | Argumente | Wirkung |
|---|---|---|
| `get_page` | – | Liefert aktuellen Snapshot |
| `tap` | `elementId` | Klick auf Element |
| `fill` | `elementId`, `value` **oder** `variable` | Feld füllen; bei sensiblen Daten nur Variablenname |
| `set_checkbox` | `elementId`, `checked` | Checkbox/Radio setzen |
| `select_option` | `elementId`, `optionText` | Dropdown |
| `wait_for` | `text` oder `elementId`, `timeoutSec` | Warten auf Element/Text/Navigation |
| `ask_user_secret` | `variable`, `label`, `isSecret` | Öffnet sichere Eingabe beim Nutzer |
| `check_online` | – | Connectivity-Probe |
| `finish_recipe` | `summary` | Recipe-Entwurf abschließen → Bestätigungs-UI |

### 5.3 Seiten-Snapshot (MUSS)
Per injiziertem JavaScript nur **interaktive und beschriftende** Elemente extrahieren: `input`, `button`, `a`, `select`, `textarea`, `[role=button]`, `label`, Überschriften, sichtbarer Fließtext gekürzt auf 300 Zeichen. Pro Element:
```
[e7] button "Kostenlos verbinden"
[e8] checkbox "Ich akzeptiere die AGB" (unchecked)
[e9] input:text name=lastname placeholder="Nachname"
```
- `elementId` ist session-lokal. Für das gespeicherte Recipe erzeugt die Engine einen **robusten Locator** (Abschnitt 6.2).
- iframes (same-origin) einbeziehen. Cross-origin iframes im Snapshot markieren und im Debug-Paket vermerken.

### 5.4 Datenschutz-Regeln für das Modell (MUSS)
- Passwörter, Voucher und personenbezogene Werte gehen **nie** in den Prompt oder ins Transcript. Das Modell kennt nur `{{password}}`.
- Werte in Passwortfeldern sind im Snapshot maskiert (`value=***`).
- Alles bleibt on-device. Kein eigener Server, keine Analytics.

### 5.5 Systemprompt (Ausgangsversion, als Datei `Resources/Prompts/assistant.de.txt`)
```
Du hilfst, sich in einem WLAN-Anmeldeportal anzumelden. Du siehst eine vereinfachte Liste der
Seitenelemente mit IDs wie [e7]. Führe Aktionen ausschließlich über die Tools aus.
Regeln:
- Erfinde keine Element-IDs. Rufe get_page auf, wenn du unsicher bist.
- Sensible Werte (Passwort, Zimmernummer, Nachname, Voucher) nie selbst ausdenken:
  nutze ask_user_secret und danach fill mit variable.
- Nach dem letzten Schritt check_online aufrufen. Bei Erfolg finish_recipe.
- Antworte kurz auf Deutsch. Frage nach, wenn die Anweisung mehrdeutig ist.
```

---

## 6. Recipe-Format & Engine

### 6.1 Schema (JSON, versioniert; Schema-Datei `Schemas/recipe.v1.schema.json` MUSS mitgeliefert werden)
```json
{
  "schemaVersion": 1,
  "id": "UUID",
  "name": "ICE WLAN",
  "match": { "ssidPatterns": ["WIFIonICE"], "portalHosts": ["login.wifionice.de"] },
  "variables": [
    { "key": "lastName", "label": "Nachname", "secret": false, "required": true },
    { "key": "password", "label": "Passwort", "secret": true, "required": true }
  ],
  "dom": {
    "steps": [
      { "action": "waitFor", "locator": { "text": "Kostenlos" }, "timeoutSec": 15 },
      { "action": "setCheckbox", "locator": { "css": "#terms", "label": "AGB" }, "checked": true },
      { "action": "fill", "locator": { "css": "input[name=lastname]" }, "variable": "lastName" },
      { "action": "tap", "locator": { "role": "button", "text": "Verbinden" } }
    ]
  },
  "http": {
    "derivedFromDom": true,
    "requests": [
      { "method": "POST", "url": "https://login.example/connect",
        "form": { "terms": "1", "lastname": "{{lastName}}" },
        "extract": [{ "from": "html", "css": "input[name=csrf]", "attr": "value", "as": "csrf" }] }
    ]
  },
  "success": { "probe": "apple", "alsoAcceptText": ["Sie sind online"] },
  "meta": { "createdAt": "ISO8601", "createdBy": "chat|recording|manual|import", "appVersion": "1.0" }
}
```
Erlaubte `action`-Werte (abschließend): `waitFor`, `tap`, `fill`, `setCheckbox`, `selectOption`, `navigate` (nur Portal-Hosts), `sleep` (≤ 10 s), `assertText`. **Kein beliebiges JavaScript im Recipe.**

### 6.2 Locator-Strategie (MUSS)
Jeder Locator speichert mehrere Merkmale. Die Engine probiert sie in dieser Reihenfolge: `id` → `name` → `css` → `label`/`ariaLabel` → `role+text` → `text`. Treffen mehrere Elemente zu, ist das ein Fehler (Ambiguität), kein Raten.

### 6.3 Engine-Verhalten
- Deterministisch, ohne LLM zur Laufzeit. Das LLM wird nur beim Erstellen und Reparieren gebraucht.
- Jeder Schritt hat Timeout (Default 10 s) und **einen** Retry.
- Nach jedem Schritt: Log-Eintrag + Screenshot (`WKWebView.takeSnapshot`) im Ringpuffer.
- Erfolgs-Check nach dem letzten Schritt (bis 20 s Polling, alle 2 s).
- WebView mit nicht-persistentem `WKWebsiteDataStore`, damit Sessions sauber starten.
- Stufe B: `HTTPRecipeRunner` mit `URLSession` bzw. `bind(to:)`, Cookie-Handling, Extraktion versteckter Felder (CSRF).

---

## 7. Debug-Paket (MUSS)

Datei: `AnyWiFi-Debug-<profil>-<datum>.zip`
```
README.md            ← Anleitung für Mensch & KI-Agent: Was ist passiert, wie repariert man das Recipe
summary.json         ← Ergebnis, fehlgeschlagener Schritt, Fehlertyp, Zeitstempel
recipe.json          ← verwendetes Recipe (Secrets entfernt)
steps.log            ← Schritt-Log mit Timings
snapshots/NN.txt     ← Seiten-Snapshot vor jedem Schritt (Format aus 5.3)
dom/NN.html          ← bereinigtes HTML (Formularwerte entfernt)
screens/NN.png       ← Screenshots
network.json         ← Redirect-Kette, Statuscodes, Header (Cookies/Authorization geschwärzt)
environment.json     ← iOS-Version, Gerät, App-Version, Stufe A/B, SSID (optional)
chat.json            ← Chat-Verlauf (falls vorhanden; Secrets sind ohnehin nur Platzhalter)
```
- Fehlertypen (Enum): `portalNotDetected`, `elementNotFound`, `elementAmbiguous`, `timeout`, `navigationBlocked`, `stillCaptiveAfterSubmit`, `httpError`, `crossOriginFrame`, `unknown`.
- **Redaction-Pflicht:** Ein Unit-Test stellt sicher, dass kein Keychain-Wert in irgendeiner Datei des Pakets vorkommt.
- `README.md` im Paket enthält eine fertige Anweisung, z. B.: „Lies summary.json und snapshots/. Erzeuge ein korrigiertes recipe.json nach Schema v1. Ändere nur die Locator/Schritte, die den Fehler verursachen.“
- Import eines korrigierten `recipe.json` (oder `.anywifi`) überschreibt nach Bestätigung das Recipe des Profils (alte Version wird als Historie behalten, **SOLL** max. 5 Versionen).

---

## 8. Architektur & Projektstruktur

```
AnyWiFi/
├─ project.yml                     (XcodeGen)
├─ App/                            AnyWiFiApp, Navigation, Settings
├─ Features/
│  ├─ Profiles/                    Liste, Detail, Editor (inkl. manueller Recipe-Editor)
│  ├─ Connect/                     Portal-Erkennung, Login-Ausführung, Ergebnis-UI
│  ├─ Assistant/                   Chat-UI, AssistantModel-Protokoll, FoundationModelsAssistant, Tools
│  ├─ Recorder/                    Aufzeichnungsmodus
│  ├─ Sharing/                     Export/Import, Verschlüsselung, UTType
│  └─ Debug/                       DebugPackageBuilder, Redactor
├─ Core/
│  ├─ Model/                       SwiftData-Modelle, Recipe (Codable), Schema-Validierung
│  ├─ Engine/                      DOMRecipeRunner (WKWebView), HTTPRecipeRunner, Locator
│  ├─ Network/                     CaptiveProbe, HotspotConfigurator, CurrentNetwork
│  ├─ Secrets/                     KeychainStore
│  └─ Snapshot/                    PageSnapshotter + snapshot.js
├─ Intents/                        App Intents „Anmelden“, „Profil wählen“, Control Widget
├─ HotspotHelper/                  Stufe B (Feature-Flag)
├─ Resources/                      Prompts, Localizable.xcstrings, JS-Dateien
├─ Schemas/recipe.v1.schema.json
├─ Tests/  UnitTests/, UITests/
└─ tools/test-portals/             lokale Fake-Portale (siehe 9)
```
Architekturregeln: Features hängen nur von `Core` ab. `Core` kennt keine SwiftUI-Views. Alle WebView-/Netzwerkzugriffe laufen über Protokolle, damit sie in Tests ersetzbar sind.

---

## 9. Teststrategie (MUSS)

- **Test-Portale** in `tools/test-portals/` (kleiner Python- oder Node-Server, per Skript startbar, in CI genutzt). Mindestens diese Szenarien:
  1. Nur Button „Verbinden“
  2. AGB-Checkbox + Button
  3. Formular Nachname + Zimmernummer
  4. Benutzername + Passwort + CSRF-Token
  5. Voucher-Code
  6. Zweistufig (Seite 1 → Seite 2)
  7. Formular in iframe
  8. JS-gerenderte Seite (Button erscheint nach 2 s)
  9. Fehlerfall: Button-Text ändert sich (für Reparatur-Flow)
  Jedes Portal stellt einen Endpunkt bereit, der den „online“-Zustand simuliert (Ersatz für den Apple-Probe in Tests, Probe-URL konfigurierbar).
- **Unit-Tests:** Recipe-Codable/Schema, Locator-Auflösung, Redaction, Export/Import inkl. Verschlüsselung, Matching.
- **Integrationstests:** DOMRecipeRunner gegen alle Test-Portale (Simulator).
- **Assistant-Tests:** Tools mit Fake-`AssistantModel` (skriptierte Tool-Aufrufe) testen. Echte Foundation-Models-Läufe nur als manuelle Gerätetests mit Protokoll.
- **Geräte-Testprotokoll** `docs/device-test-checklist.md`: echtes Hotel-/Bahn-/Café-WLAN, Ergebnis + Debug-Paket ablegen.

---

## 10. Umsetzungsphasen & Abnahmekriterien

| Phase | Inhalt | Abnahme (Definition of Done) |
|---|---|---|
| **0 Spikes** | (a) Foundation Models: Tool Calling + `@Generable` auf Gerät; PCC-Zugang prüfen. (b) WebView im Captive-Zustand: Läuft Traffic über WLAN? (c) `NEHotspotConfiguration` apply/remove. (d) Entitlement-Antrag HotspotHelper vorbereiten (Text für Auftraggeber). | Kurzbericht `docs/spikes.md` mit Ergebnis je Punkt; Architektur ggf. angepasst |
| **1 Fundament** | XcodeGen-Projekt, CI, SwiftData-Modelle, Keychain, Recipe-Schema + Validierung | CI grün, Unit-Tests für Modell/Schema |
| **2 Engine** | CaptiveProbe, DOMRecipeRunner, Locator, Test-Portale 1–9 | Portale 1–8 per handgeschriebenem Recipe erfolgreich, 9 scheitert sauber mit `elementNotFound` |
| **3 Profile-UI** | Liste, Detail, manueller Editor, WLAN installieren, Login ausführen | Profil anlegen → Login gegen Test-Portal per UI-Test |
| **4 Debug-Paket** | Builder, Redaction, Share, Recipe-Import | Redaction-Test grün, Paket für Portal 9 vollständig |
| **5 Assistent** | Chat-UI, Tools, Snapshotter, Secret-Eingabe, Recipe-Entwurf | Auf Gerät: Portale 1–6 per Chat einrichtbar; Fake-Model-Tests in CI |
| **6 Recorder** | Aufzeichnungsmodus | Portale 1–6 per Aufzeichnung einrichtbar |
| **7 Teilen** | `.anywifi`, Opt-in Zugangsdaten, Verschlüsselung, Import-Validierung | Roundtrip-Tests mit/ohne Zugangsdaten und Passwort |
| **8 Automatisierung** | App Intents, Control Widget, Kurzbefehl-Vorlage „Bei Verbindung mit WLAN X“ | Login per Kurzbefehl auf Gerät |
| **9 Reparatur** | „Im Chat reparieren“ mit Fehlerkontext, Recipe-Historie, Stabilitätsmetrik | Portal 9 per Chat reparierbar |
| **10 Stufe B** | HotspotHelper (nur mit Entitlement), HTTP-Recipes | Hinter Flag; Unit-Tests HTTPRecipeRunner gegen Test-Portale 1–5 |
| **11 Politur** | Lokalisierung, Barrierefreiheit (VoiceOver, Dynamic Type), iPad-Layout, App-Store-Texte, Datenschutzangaben | Accessibility-Audit ohne kritische Befunde |

---

## 11. Nicht-funktionale Anforderungen
- **Sicherheit:** Secrets nur im Keychain (`kSecAttrAccessibleAfterFirstUnlock`, damit Kurzbefehle/Stufe B im Hintergrund funktionieren). Kein Logging von Secrets. Importierte Recipes laufen ohne JS und nur auf Portal-Hosts.
- **Datenschutz:** Keine Server, kein Tracking. App-Store-Privacy-Label: „Keine Daten erfasst“. Standortberechtigung nur, wenn für SSID nötig, mit klarer Begründung.
- **Performance:** Login mit gespeichertem Recipe ≤ 10 s typisch (ohne Portal-Latenz).
- **Barrierefreiheit:** VoiceOver-Labels, Dynamic Type, ausreichende Kontraste. Gestaltung nach Apple HIG.
- **Robustheit:** Kein Absturz bei fehlender Apple Intelligence, fehlenden Berechtigungen oder fehlendem WLAN. Jeder Zustand hat eine verständliche Meldung.

---

## 12. Agenten-Rollen (aus *agency-agents*)

Quelle: https://github.com/msitarzewski/agency-agents (die angegebene URL `MichaelSitarzewski/agency-agents` war beim Erstellen nicht öffentlich erreichbar; Inhalt ist der Upstream). Pro Phase wird die passende Persona geladen:

| Rolle | Datei | Einsatz |
|---|---|---|
| Orchestrierung | `specialized/agents-orchestrator.md`, `project-management/project-manager-senior.md` | Phasensteuerung, Aufgaben schneiden |
| iOS-Entwicklung | `engineering/engineering-mobile-app-builder.md`, `engineering/engineering-senior-developer.md` | Phasen 1–4, 6–8, 10 |
| KI/Assistent | `engineering/engineering-ai-engineer.md`, `engineering/engineering-prompt-engineer.md` | Phase 5, 9 |
| UX | `design/design-ux-architect.md` | Chat-/Split-View-Flow, iPad-Layout |
| Sicherheit/Datenschutz | `security/security-secrets-credential-engineer.md`, `engineering/engineering-privacy-engineer.md`, `security/security-appsec-engineer.md` | Keychain, Export-Verschlüsselung, Import-Validierung, Redaction |
| QA | `testing/testing-evidence-collector.md`, `testing/testing-reality-checker.md`, `testing/testing-accessibility-auditor.md` | Abnahme jeder Phase (Dev↔QA-Loop: Phase gilt erst als fertig, wenn QA die DoD belegt) |
| Release | `engineering/engineering-mobile-release-engineer.md`, `engineering/engineering-technical-writer.md` | Phase 11, TestFlight, Doku |

---

## 13. Offene Punkte für den Auftraggeber
1. **HotspotHelper-Entitlement** bei Apple beantragen? Ohne das gibt es keinen vollautomatischen Login im Hintergrund, nur per App/Kurzbefehl (Stufe A).
2. **Apple Developer Team / Bundle-ID** (z. B. `com.<firma>.anywifi`) für Entitlements und TestFlight.
3. **Mindest-iOS 26** in Ordnung? (Ohne Foundation Models wäre kein lokaler Chat möglich.)
4. WPA-Enterprise (802.1X) im ersten Release nötig?
5. Soll es eine **öffentliche Profil-Bibliothek** geben (z. B. Profile für Deutsche Bahn, Hotelketten)? Das ist aktuell **nicht** im Umfang, weil es einen Server erfordern würde.

Bis zur Klärung gilt: Stufe A, iOS 26, nur WPA-Personal, keine Bibliothek.
