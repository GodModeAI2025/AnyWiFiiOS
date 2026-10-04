# CaptiveAI – Spike- und Test-Spezifikation

**Version:** 1.0  
**Stand:** 4. Oktober 2026  
**Dauerempfehlung:** 3–5 Entwicklungstage nach Verfügbarkeit des Hotspot-Helper-Entitlements  
**Ziel:** Vor der Vollimplementierung die wenigen wirklich kritischen technischen Annahmen auf einem echten iPhone/iPad validieren.

---

# 1. Warum dieser Spike zwingend ist

Die Produktidee hängt nicht daran, ob man HTML-Felder parsen oder YAML speichern kann. Das ist Standardtechnik.

Die kritischen Fragen sind:

1. Läuft der neue Hotspot-Provider-End-to-End wie erwartet?
2. Kann der Authentication Provider die Portal-HTTP-Kommunikation zuverlässig durchführen?
3. Kann `FoundationModels` innerhalb dieses Providers importiert und zur Laufzeit sinnvoll verwendet werden?
4. Reicht das reale Zeit-/Speicherbudget für einen kleinen Observe → Plan → Act Loop?
5. Funktioniert `uiRequired → presentUI` mit einer modernen App/Extension-Struktur so, wie das Produkt es benötigt?
6. Können App und Provider sicher über App Group und Shared Keychain zusammenarbeiten?

Wenn diese sechs Punkte funktionieren, ist der Rest der App hauptsächlich Engineering.

---

# 2. Entitlement vor dem Spike

Benötigt:

```text
com.apple.developer.networking.HotspotHelper
```

Apple empfiehlt für Hotspot Provider, die Berechtigung vor Beginn der Entwicklung zu beantragen.

Primärer aktueller Weg für Managed Capabilities:

```text
developer.apple.com
→ Account
→ Certificates, Identifiers & Profiles
→ Identifiers
→ App ID
→ Capability Requests
→ Hotspot Helper
→ Request
```

Apple-Hilfe:

https://developer.apple.com/help/account/capabilities/capability-requests

Hotspot-Helper-Request:

https://developer.apple.com/contact/request/hotspot-helper/

Dokumentation:

https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.hotspothelper

---

# 3. Was bereits vor Genehmigung gebaut werden kann

Ohne Hotspot-Entitlement:

```text
✓ SwiftUI Host App
✓ PortalIntent
✓ PRL Schema
✓ Recipe Parser
✓ Recipe Validator
✓ Recipe Interpreter gegen Test-HTML
✓ DOM Normalizer
✓ HTTP Client in normaler App/Test Harness
✓ Foundation Models Tests in normaler App
✓ @Generable Datenmodelle
✓ SpeechAnalyzer
✓ Keychain Abstraction
✓ App Group Datenmodell
✓ Import / Export
✓ Log Redaction
```

Nicht vollständig realistisch testbar:

```text
✗ echter Hotspot Evaluation Provider
✗ echter Authentication Provider auf realem iPhone
✗ Systemevent Evaluate/Authenticate
✗ echtes uiRequired/presentUI End-to-End
✗ Foundation Models im tatsächlichen Hotspot Provider
```

Ein iOS-Simulator ist hierfür kein Ersatz für die reale Provisioning-/Hotspot-Umgebung.

---

# 4. Spike-Projekt

Eigenes minimales Xcode-Projekt:

```text
CaptiveAISpike/
├── SpikeApp
├── SpikeEvaluationProvider
├── SpikeAuthenticationProvider
└── SpikeShared
```

Kein Produktions-UI.

App Screen:

```text
Hotspot Manager: Enabled / Disabled
Evaluation Provider: Ready / Error
Authentication Provider: Ready / Error
Foundation Model in App: Available / Unavailable
Foundation Model in Provider: Unknown / Passed / Failed
Shared Keychain: Passed / Failed
App Group: Passed / Failed
Last command:
Last result:
```

---

# 5. Testumgebung

## 5.1 Geräte

Mindestens:

- ein Apple-Intelligence-fähiges iPhone mit iOS 27
- optional ein iPad mit iPadOS 27

Keine ausschließliche Simulatorprüfung.

## 5.2 Kontrolliertes Test-WLAN

Empfohlen:

- OpenWrt-Router,
- Raspberry Pi als AP,
- oder dedizierter Test-Access-Point.

Es muss möglich sein, Captive-Portal-Seiten gezielt auszutauschen.

## 5.3 Testportal

Kleine lokale HTTP-Anwendung mit folgenden Routen:

```text
/terms
/login
/hotel
/multistage/1
/multistage/2
/dynamic
/changed-label
/js-required
/success
```

Das Portal schreibt selbst ein Serverlog, damit Client-Aktion und tatsächlicher HTTP-Request verglichen werden können.

---

# 6. Gate S0 – Signing und Provider-Installation

## Ziel

Beweisen, dass die genehmigte Capability korrekt in Provisioning und Extensions landet.

## Schritte

1. App ID und Provider IDs konfigurieren.
2. Hotspot Helper Capability aktivieren.
3. automatische oder manuelle Signierung aktualisieren.
4. App auf physischem Gerät installieren.
5. `NEHotspotManager` konfigurieren.
6. Provider aktivieren.
7. Signing Entitlements des Builds prüfen.

## Pass

- App startet auf realem Gerät.
- Provider werden vom System geladen.
- keine `invalid entitlement`-/Provisioning-Fehler.
- Manager kann Provider aktivieren/deaktivieren.

## Fail

- Capability nicht im Provisioning Profile.
- Extension wird nicht geladen.
- App kann Manager-Konfiguration nicht speichern.

---

# 7. Gate S1 – Foundation Models im Authentication Provider

**Das ist der wichtigste Test des gesamten Spikes.**

## Hypothese

`FoundationModels` lässt sich innerhalb des Hotspot Authentication Providers verwenden und eine kleine strukturierte Generierung kann innerhalb des realen Provider-Lebenszyklus abgeschlossen werden.

## Testmodell

```swift
@Generable
enum TestAction {
    case tapContinue
    case fillUsername
    case requestValue
}

@Generable
struct TestPlan {
    var action: TestAction
}
```

Prompt:

```text
The current captive portal has a required Terms checkbox
and a Continue button. Return the next action.
```

## Test

Während eines echten `.authenticate`-Commands:

```text
1. SystemLanguageModel availability prüfen.
2. LanguageModelSession erzeugen.
3. strukturierte Ausgabe `TestPlan` erzeugen.
4. Dauer messen.
5. Ergebnis loggen.
6. Provider sauber antworten lassen.
```

## Erfassen

```text
availability
initialization latency
generation latency
peak memory soweit messbar
error type
provider lifetime
thermal state
```

## Pass A

Foundation Models funktioniert stabil im Provider.

Dann:

```text
Produktarchitektur wie Hauptspezifikation.
```

## Pass B – technisch möglich, aber zu langsam/instabil

Dann:

```text
AI nur im seltenen Lern-/Repair-Pfad,
Replay rein deterministisch.
```

## Fail

Framework in diesem Extension-Kontext nicht verwendbar oder nicht zuverlässig.

Dann Produktarchitektur ändern:

```text
Provider:
nur deterministische Recipe Engine

AI Learning:
über presentUI / Haupt-App

oder:
kleines Core-AI-Modell als lokaler Klassifikator
```

Wichtig: Ein Fail beendet nicht automatisch das Produkt. Er ändert nur den Ort, an dem die AI läuft.

---

# 8. Gate S2 – Hotspot-gebundene HTTP-Kommunikation

## Hypothese

Authentication Provider kann während Captivity die Portal-Seite laden und POSTs/Redirects korrekt über das zugehörige Hotspot-Interface abwickeln.

## Testportal

```html
<form method="post" action="/auth">
  <input type="hidden" name="csrf" value="abc123">
  <input name="username">
  <input name="password" type="password">
  <button name="action" value="login">Login</button>
</form>
```

## Test

Provider:

```text
GET Portal
→ parse
→ POST username/password + csrf + button value
→ Cookie erhalten
→ Redirect
→ Erfolg
```

## Pass

Serverlog zeigt korrekte:

- Cookies
- Hidden Fields
- POST-Werte
- Redirect-Folge

und anschließend kann Internetfreiheit verifiziert werden.

---

# 9. Gate S3 – Multi-Page Loop

## Ziel

Beweisen, dass nicht nur ein einzelnes Formular funktioniert.

Portal:

```text
Stage 1
[ ] Terms
[Continue]

Stage 2
Room Number
Last Name
[Connect]

Stage 3
Success
```

Algorithmus:

```text
fetch
→ normalize
→ AI plan
→ execute
→ fetch
→ normalize
→ AI plan
→ execute
→ verify
```

## Pass

Kompletter Flow läuft innerhalb des Systembudgets.

Zusätzlich messen:

```text
Anzahl Model Calls
Gesamtdauer
HTTP-Dauer
Model-Dauer
```

---

# 10. Gate S4 – `uiRequired` und Runtime-Wert

## Portal

```text
Room Number required
```

Im Profil existiert kein Room-Number-Wert.

## Erwarteter Ablauf

```text
authenticate
→ Engine erkennt missing roomNumber
→ Notification
→ .uiRequired
→ presentUI
→ App fragt:
   „Zimmernummer?“
→ User: 417
→ App Group schreibt PendingInput
→ Provider liest 417
→ Form Submit
→ success
```

## Pass

- kein App-Absturz
- kein verlorener State
- keine zweite unnötige Anmeldung
- Wert gelangt korrekt in Pending Session
- optionales „merken“ schreibt in Keychain
- Notification enthält keinen sensiblen Wert

---

# 11. Gate S5 – Shared Keychain

## Setup

Host App schreibt:

```text
key: test.username
value: spike-user
```

Authentication Provider liest denselben Key.

Danach:

Provider schreibt:

```text
test.providerValue
```

App liest ihn.

## Pass

Bidirektional erfolgreich.

## Sicherheitsprüfung

- Keychain Access Group korrekt.
- Secret nicht in App Group.
- Secret nicht im Providerlog.

---

# 12. Gate S6 – App Group / Pending Session

Datenmodell:

```swift
struct PendingAuthentication: Codable {
    var runId: UUID
    var profileId: UUID
    var requiredConcept: String?
    var status: Status
}
```

Test:

```text
Provider schreibt Pending
→ App liest
→ App ergänzt Value Reference
→ Provider liest Update
```

Pass:

- atomare Speicherung
- keine beschädigten Dateien
- Konfliktstrategie vorhanden

Empfehlung:

```text
kleine JSON-Dateien + atomic write
```

Keine komplexe Datenbank im Spike.

---

# 13. Gate S7 – DOM Normalizer

Folgende HTML-Varianten müssen auf dieselbe Semantik abgebildet werden:

### Variante A

```html
<label for="room">Room Number</label>
<input id="room" name="room">
```

### Variante B

```html
<input name="room_no" placeholder="Zimmernummer">
```

### Variante C

```html
<div>Room</div>
<input aria-label="Room number">
```

Erwartet:

```text
concept = roomNumber
```

Normalisierte Repräsentation muss kompakt bleiben.

---

# 14. Gate S8 – Recipe Replay ohne AI

Nach einem erfolgreichen Lernlauf wird das entstandene Recipe gespeichert.

Dann:

1. Foundation-Model-Zugriff im Testcode bewusst deaktivieren.
2. WLAN erneut verbinden.
3. Gleiches Portal ausführen.

## Pass

Login funktioniert vollständig ohne AI.

Dieses Gate ist entscheidend für die Produktqualität.

---

# 15. Gate S9 – Kleine Portaländerung

Version 1:

```text
Button: Connect
```

Version 2:

```text
Button: Join Wi-Fi
```

## Erwartung

Replay findet alten Target nicht.

Dann:

```text
Local repair
→ neues Target
→ Aktion
→ Erfolg
→ Recipe Revision +1
```

Pass:

Kein komplettes Neulernen nötig.

---

# 16. Gate S10 – Sicherheitsablehnung

Testportal enthält:

```text
[ ] Subscribe to newsletter
[ ] Buy Premium Wi-Fi – € 9.99
[ ] Accept required Terms
```

Anweisung:

```text
„Setz alle Haken und geh weiter.“
```

Erwartung V1:

```text
required Terms → darf
newsletter → nicht automatisch
paid upgrade → blockiert
```

Pass:

Keine kommerzielle Aktion ohne explizite, gesonderte Freigabe.

---

# 17. Gate S11 – Unsupported JavaScript Portal

Portal rendert Login-Felder ausschließlich durch JavaScript.

HTTP-HTML enthält keine verwertbaren Controls.

Erwartung:

```text
classification:
manualInteractionRequired
```

Nicht:

```text
endlose AI-Schleife
```

Pass:

Sauberer Fehlerzustand und verständliches Log.

---

# 18. Gate S12 – Log Redaction

Testwerte:

```text
username = mark
password = SuperSecret123
room = 417
surname = Example
cookie = SESSION=abcdef
```

Nach Fehlversuch Debug Bundle öffnen.

Pass:

Keiner dieser Klartextwerte darf enthalten sein.

Erwartet:

```text
<personal:username>
<secret:password>
<personal:roomNumber>
<personal:lastName>
<cookie>
```

---

# 19. Performance-Kriterien

Zielwerte, keine Apple-Garantien:

| Operation | Ziel |
|---|---:|
| HTML normalize | < 150 ms |
| Recipe stage match | < 50 ms |
| Keychain read | < 100 ms |
| App Group read | < 50 ms |
| lokaler Modellplan | < 3 s bevorzugt |
| HTTP page step | < 3 s bevorzugt |
| Multi-stage learning | deutlich innerhalb des Systemlimits |

Wenn Foundation Models wiederholt mehrere Sekunden pro Mini-Schritt benötigt, soll der Planner mehrere sichere Aktionen einer Seite gemeinsam liefern.

Nicht jedoch mehrere unbekannte Seiten im Voraus.

---

# 20. AI-Contract für den Spike

## Input

```swift
struct PortalPlanningInput {
    var intent: PortalIntent
    var page: NormalizedPortalPage
    var completedActions: [CompletedAction]
}
```

## Output

```swift
@Generable
struct PortalPlan {
    @Guide(.maximumCount(4))
    var actions: [PortalAction]

    var expectedTransition: ExpectedTransition
    var missingValue: MissingValue?
}
```

Maximal vier Aktionen pro Runde.

Beispiel:

```text
check terms
fill username
fill password
tap login
```

Kein freier Code.

---

# 21. Testportal-Fälle

Mindestens folgende Fixtures in Git einchecken:

```text
01_clickthrough.html
02_terms.html
03_terms_privacy.html
04_userpass.html
05_hotel.html
06_voucher.html
07_email.html
08_multistage_terms.html
09_multistage_guest.html
10_changed_labels.html
11_hidden_csrf.html
12_optional_marketing.html
13_paid_upgrade.html
14_js_only.html
15_malformed_html.html
```

Damit kann `CaptiveCore` ohne echtes WLAN vollständig unit-getestet werden.

---

# 22. Unit Tests

## Recipe Parser

```text
valid YAML accepted
unknown opcode rejected
unknown field rejected
wrong recipeVersion rejected
```

## Security Validator

```text
payment action rejected
external credential host rejected
unknown keychain reference rejected
action count limit enforced
```

## Matcher

```text
label
name
placeholder
aria
nearby text
selector fallback
```

## Trace Compiler

```text
hidden token removed
cookie removed
runtime value replaced
stable actions retained
```

---

# 23. Integration Tests

```text
Intent
→ Fixture HTML
→ Normalizer
→ AI Plan
→ Executor
→ mock HTTP response
→ next page
→ success
→ recipe
→ replay
```

Der Test gilt nur dann als erfolgreich, wenn Replay ohne AI funktioniert.

---

# 24. Echte WLAN-Abnahmetests

Nach Spike-Erfolg mindestens drei reale Netztypen testen:

```text
Hotel
öffentlicher Guest-Hotspot
Enterprise-/Event-Guest-WLAN
```

Dabei keine Passwörter oder Portalinhalte in Analytics hochladen.

---

# 25. Entscheidungsmatrix nach dem Spike

## Ergebnis A

```text
Foundation Models im Provider: JA
Performance: JA
uiRequired: JA
```

→ Hauptspezifikation unverändert bauen.

## Ergebnis B

```text
Foundation Models im Provider: JA
Performance: grenzwertig
```

→ AI nur beim ersten Lauf / Repair, Replay immer deterministisch.

## Ergebnis C

```text
Foundation Models im Provider: NEIN
uiRequired/presentUI: JA
```

→ AI-Lernmodus in App während PresentUI; Provider bleibt Recipe-Executor.

## Ergebnis D

```text
Foundation Models im Provider: NEIN
PresentUI-Flow für Lernen unpraktisch
```

→ Produkt auf:
- manuell/AI-vorbereitete Recipes
- deterministische Provider-Ausführung

reduzieren oder kleines eigenes Core-AI-Modell evaluieren.

---

# 26. Spike-Abbruchkriterien

Das Produktkonzept wird grundsätzlich neu bewertet, wenn:

1. Authentication Provider keinen praktikablen HTTP-Flow gegen Captive Portals ausführen kann.
2. `uiRequired/presentUI` keine verlässliche Übergabe fehlender Nutzerdaten ermöglicht.
3. Provider und Haupt-App keinen sicheren Shared-State aufrechterhalten können.

Ein Foundation-Models-Fail allein ist **kein** Abbruchkriterium.

---

# 27. Spike-Deliverables

Am Ende müssen vorhanden sein:

```text
1. Xcode-Projekt
2. Ergebnisbericht PASS/FAIL je Gate
3. gemessene Latenzen
4. echte Device Logs, redigiert
5. getestete Entitlements/Provisioning-Konfiguration
6. mindestens ein erfolgreicher Multi-Page-Captive-Login
7. mindestens ein uiRequired-Flow
8. ein gespeichertes Recipe
9. erfolgreicher Replay ohne AI
10. Architekturentscheidung für Produktionsbuild
```

---

# 28. Ergebnisbericht-Vorlage

```markdown
# CaptiveAI Spike Result

Device:
OS:
Xcode:
Date:

## S0 Provider signing
PASS / FAIL

## S1 Foundation Models in Authentication Provider
PASS / FAIL
Latency:
Notes:

## S2 Hotspot-bound HTTP
PASS / FAIL

## S3 Multi-page
PASS / FAIL

## S4 uiRequired
PASS / FAIL

## S5 Shared Keychain
PASS / FAIL

## S6 App Group
PASS / FAIL

## S7 DOM Normalizer
PASS / FAIL

## S8 Replay without AI
PASS / FAIL

## S9 Adaptive Repair
PASS / FAIL

## S10 Safety
PASS / FAIL

## S11 JS-only fallback
PASS / FAIL

## S12 Redaction
PASS / FAIL

## Final architecture decision
...
```

---

# 29. Entitlement-Text für den Spike-/Prototyp-Antrag

Kann als Ausgangstext im Apple-Request verwendet werden:

```text
We are developing an iOS/iPadOS application whose primary function is to help
users authenticate to Wi-Fi hotspot networks that use captive portals.

The user explicitly creates a profile for a specific SSID and describes the
portal interactions needed for authentication, such as accepting required
terms and privacy notices, entering credentials, room information, or a
voucher, and submitting the form.

The Hotspot Helper capability is required so the application can participate
in the system hotspot authentication state machine when that configured
network is joined. We plan to use the current extension-based APIs:
NEHotspotManager, NEHotspotEvaluationProvider, and
NEHotspotAuthenticationProvider.

The helper will not claim arbitrary networks. It will only return confidence
for SSIDs for which the user has explicitly enabled a profile.

The capability will not be used for location tracking, accessory discovery,
general-purpose Wi-Fi scanning, or analytics. Sensitive authentication values
will be stored in the iOS Keychain.
```

---

# 30. Apple-Quellen

- https://developer.apple.com/documentation/networkextension/hotspot-helper
- https://developer.apple.com/documentation/networkextension/nehotspotmanager
- https://developer.apple.com/documentation/networkextension/nehotspotauthenticationprovider
- https://developer.apple.com/documentation/networkextension/nehotspotevaluationprovider
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.hotspothelper
- https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview
- https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment
- https://developer.apple.com/help/account/capabilities/capability-requests
- https://developer.apple.com/contact/request/hotspot-helper/
- https://developer.apple.com/documentation/foundationmodels
- https://developer.apple.com/documentation/foundationmodels/generable
- https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling
