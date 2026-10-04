# CaptiveAI – App-Spezifikation

**Version:** 1.0  
**Stand:** 4. Oktober 2026  
**Ziel:** Implementierungsfähige Spezifikation für eine iPhone-/iPad-App zur automatisierten Captive-Portal-Anmeldung mit lokaler Apple Intelligence, lernenden Recipes, Keychain und optionalem Private-Cloud-Compute-Reparaturmodus.

---

## 1. Produktidee

CaptiveAI ist eine iOS-/iPadOS-App, die wiederkehrende Captive-Portal-Anmeldungen automatisiert.

Der Anwender beschreibt in natürlicher Sprache, was bei einem bestimmten WLAN zu tun ist, zum Beispiel:

> „Bei diesem WLAN immer Datenschutz und Nutzungsbedingungen akzeptieren, dann Zimmernummer und Nachname eintragen und auf Verbinden drücken. Nach der Zimmernummer fragst du mich, wenn du sie noch nicht kennst. Meinen Nachnamen kannst du speichern.“

Aus dieser Beschreibung entsteht ein **Intent**. Beim ersten realen Kontakt mit dem Captive Portal versucht das System, die sichtbaren Formularelemente semantisch zu erkennen, führt die notwendigen Schritte durch und speichert einen erfolgreichen Ablauf als **Portal Recipe**.

Bei späteren Besuchen wird nicht erneut frei „geraten“, sondern möglichst deterministisch das gespeicherte Recipe ausgeführt. Passt das Portal nicht mehr, wird der Ablauf erneut analysiert oder als Reparaturfall protokolliert.

### Leitprinzip

**AI zum Verstehen und Lernen. Deterministische Ausführung für Wiederholungen.**

Das Produkt ist damit kein allgemeiner Browser-Agent, sondern ein stark begrenzter Captive-Portal-Agent.

---

# 2. Verifizierte Apple-Rahmenbedingungen

## 2.1 Hotspot Helper

Für die Teilnahme am Captive-Portal-/Hotspot-Authentifizierungsprozess ist das Apple-Entitlement

```text
com.apple.developer.networking.HotspotHelper
```

erforderlich.

Apple beschreibt es weiterhin als spezielles/verwaltetes Entitlement.

Quelle:

https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.hotspothelper

Apple TN3111 ordnet den Hotspot Helper ausdrücklich dem Anwendungsfall „Navigate an internet hotspot“ zu.

https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview

## 2.2 Neue Architektur statt altem Helper-Handler

Die alte API:

```swift
NEHotspotHelper.register(...)
```

ist deprecated.

Für iOS 27 soll ausschließlich die seit iOS 26 verfügbare extension-basierte Architektur verwendet werden:

```text
NEHotspotManager
├── NEHotspotEvaluationProvider
└── NEHotspotAuthenticationProvider
```

Apple beschreibt die Extensions als sicherer und performanter als die alte Authentifizierung direkt in der App.

Quelle:

https://developer.apple.com/documentation/networkextension/nehotspotmanager

## 2.3 Mehrstufige Authentifizierung ist vorgesehen

Der Authentication Provider verarbeitet unter anderem:

- `authenticate`
- `maintain`
- `presentUI`
- `logoff`

Wenn während `authenticate` Nutzerinteraktion nötig wird, kann der Provider mit:

```swift
.uiRequired
```

antworten. Danach wechselt die Hotspot-State-Machine in den UI-Zustand und der Provider erhält `presentUI`.

Damit passt Apples State Machine grundsätzlich zum gewünschten Modell:

```text
automatisch versuchen
→ fehlender Wert
→ Nutzer fragen
→ mit Wert fortfahren
→ Erfolg
```

Quellen:

https://developer.apple.com/documentation/networkextension/nehotspotauthenticationprovider

https://developer.apple.com/documentation/networkextension/nehotspotmanager

## 2.4 Entwicklungsentitlement

Apple schreibt für Hotspot Provider in TN3134 ausdrücklich:

> Vor Beginn der Entwicklung die Berechtigung für das Hotspot-Helper-Entitlement beantragen.

Ein Managed Entitlement muss im Provisioning Profile des realen Geräts autorisiert sein. Deshalb ist ein vollständiger End-to-End-Test des System-Providers auf realer Hardware ohne Genehmigung nicht realistisch.

Die übrigen Komponenten können dennoch unabhängig entwickelt werden.

Quelle:

https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment

## 2.5 Hotspot Configuration ist etwas anderes

Optional kann zusätzlich:

```text
com.apple.developer.networking.HotspotConfiguration
```

verwendet werden, wenn die App über `NEHotspotConfigurationManager` bekannte WLAN-Konfigurationen anlegen soll.

Dieses Capability ist nicht dasselbe wie Hotspot Helper.

V1 muss keine allgemeine WLAN-Scanner-/Join-App sein. Der Kernfall lautet:

> iOS/iPadOS hat sich mit einem WLAN verbunden bzw. verbindet sich per Auto-Join, und CaptiveAI übernimmt die Portal-Authentifizierung.

Quelle:

https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.hotspotconfiguration

---

# 3. Plattform und technische Mindestanforderungen

## 3.1 Plattform

- iOS 27 oder neuer
- iPadOS 27 oder neuer
- Swift
- SwiftUI
- kein macOS-Ziel
- kein Catalyst-Ziel in V1

## 3.2 AI-Anforderung

Die App darf auf iOS-27-Geräten starten, auch wenn kein lokales Apple-Foundation-Model verfügbar ist.

Funktionalität:

| Gerät | Verhalten |
|---|---|
| Apple Foundation Model verfügbar | Lernen, semantische Analyse, Recipe-Reparatur lokal möglich |
| Modell nicht verfügbar | bestehende Recipes funktionieren deterministisch; neues automatisches Lernen ist deaktiviert oder eingeschränkt |
| Internet + PCC verfügbar | optionaler Reparaturmodus mit stärkerem Modell |

Damit bleibt ein bereits gelerntes Profil auch ohne aktuelle AI-Verfügbarkeit nutzbar.

---

# 4. User Experience

## 4.1 Hauptnavigation

Die App besitzt vier Hauptbereiche:

1. **WLAN-Profile**
2. **Aktivität**
3. **Import / Export**
4. **Einstellungen**

## 4.2 Profil anlegen

Flow:

```text
Neues Profil
→ Profilname
→ WLAN/SSID angeben
→ „Was soll ich bei der Anmeldung tun?“
→ Sprache oder Text
→ AI erstellt verständliche Zusammenfassung
→ Nutzer bestätigt
→ Profil aktivieren
```

Beispiel:

```text
Profil:
Hotel Muster

SSID:
Hotel_Guest

Anweisung:
„Datenschutz und Nutzungsbedingungen akzeptieren.
Danach Zimmernummer und Nachname eintragen.
Nach der Zimmernummer fragst du mich bei jedem Aufenthalt.
Nachname darf gespeichert werden.
Dann auf Verbinden drücken.“
```

Die App zeigt daraus:

```text
✓ Pflicht-Einwilligungen akzeptieren
? Zimmernummer bei Bedarf abfragen
🔐 Nachname sicher speichern
→ Verbindung absenden
```

Der Anwender muss für einen normalen Fall **kein YAML, keinen CSS Selector und keine Formularstruktur kennen**.

## 4.3 Spracheingabe

Für Sprache wird bevorzugt verwendet:

- `SpeechAnalyzer`
- `SpeechTranscriber`

Die Spracheingabe findet nur in der Haupt-App statt, nicht im Network-Extension-Hintergrundprozess.

Die Transkription wird anschließend durch Foundation Models in einen strukturierten `PortalIntent` überführt.

## 4.4 Laufzeit

Wenn das Gerät das konfigurierte WLAN erkennt bzw. verbindet:

```text
Evaluation Provider
→ Ist dieses Netz in unseren Profilen?
→ ja
→ Authentication Provider
→ vorhandenes Recipe vorhanden?
   ├── ja → Recipe deterministisch ausführen
   └── nein → Lernlauf
```

## 4.5 Nutzerabfrage während der Anmeldung

Benötigt der Provider einen Wert, der nicht vorhanden ist:

```text
Room Number fehlt
→ .uiRequired
→ lokale Notification
→ App zeigt:
   „Hotel Muster benötigt deine Zimmernummer.“
→ Benutzer gibt 417 ein
→ optional:
   [ ] nur diesmal verwenden
   [x] für dieses Profil merken
→ Authentication Provider setzt Ablauf fort
```

Secrets und persönliche Werte werden niemals in der Notification angezeigt.

---

# 5. Architektur

```text
┌──────────────────────────────────────────┐
│              CaptiveAI App               │
│ SwiftUI                                  │
│                                          │
│ Profile UI                               │
│ Voice / SpeechAnalyzer                   │
│ Foundation Models Intent Compiler        │
│ Recipe Editor                            │
│ Import / Export                          │
│ Repair Center (On-device / PCC)          │
└──────────────────┬───────────────────────┘
                   │
           App Group / Keychain
                   │
       ┌───────────┴───────────┐
       │                       │
┌──────▼──────────┐   ┌────────▼───────────┐
│ Evaluation      │   │ Authentication      │
│ Provider        │   │ Provider            │
│                 │   │                     │
│ SSID matching   │   │ HTTP session        │
│ confidence      │   │ Portal normalizer   │
│ filtering       │   │ Recipe runtime      │
│                 │   │ Local AI planner*   │
└─────────────────┘   │ Result verification │
                      └─────────┬───────────┘
                                │
                       Captive Portal HTTP(S)

* Verwendung von Foundation Models direkt im Provider
  wird im Spike zwingend verifiziert.
```

---

# 6. Xcode-Projektstruktur

Empfohlene Targets:

```text
CaptiveAI/
├── CaptiveAIApp
├── HotspotEvaluationProvider
├── HotspotAuthenticationProvider
├── CaptiveCore
├── CaptiveCoreTests
└── CaptiveUITests
```

`CaptiveCore` ist ein Swift Package oder Shared Framework ohne UI-Abhängigkeiten.

Enthalten:

```text
Models/
PortalRecipe/
PortalDOM/
PortalHTTP/
Matching/
Credentials/
Logging/
AIContracts/
Security/
```

Vorteil:

Fast die gesamte Logik kann bereits gebaut und getestet werden, bevor das Hotspot-Entitlement genehmigt wurde.

---

# 7. Datenmodell

## 7.1 PortalProfile

```swift
struct PortalProfile: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var enabled: Bool
    var network: NetworkMatcher
    var intent: PortalIntent
    var recipe: PortalRecipe?
    var credentialBindings: [CredentialBinding]
    var createdAt: Date
    var updatedAt: Date
    var recipeRevision: Int
}
```

## 7.2 NetworkMatcher

V1:

```swift
struct NetworkMatcher: Codable, Sendable {
    var ssidExact: String
    var bssidAllowList: [String]?
    var portalHostHints: [String]
}
```

V1 beansprucht niemals pauschal alle WLANs.

Das ist wichtig, weil Apple ausdrücklich verlangt, dass ein Hotspot Helper nicht einfach jedes Netz mit hoher Confidence für sich beansprucht.

## 7.3 PortalIntent

Der Intent enthält die semantische Nutzerabsicht, noch keine DOM-spezifische Implementierung.

Beispiel:

```yaml
intentVersion: 1

goal: authenticate

instructions:
  - acceptRequiredTerms
  - acceptRequiredPrivacy
  - fill:
      concept: roomNumber
      source: askWhenMissing
  - fill:
      concept: lastName
      source: keychain
  - submit

policy:
  allowOptionalMarketingConsent: false
  allowPaidUpgrade: false
```

Die gesprochene Originalanweisung wird separat gespeichert:

```text
„Setz Datenschutz und Nutzungsbedingungen,
trag Zimmernummer und Nachname ein und drück auf Verbinden.“
```

## 7.4 CredentialBinding

```swift
struct CredentialBinding: Codable, Sendable {
    var concept: String
    var keychainKey: String
    var prompt: String
    var persistence: PersistencePolicy
    var sensitivity: Sensitivity
}
```

Beispiele für `concept`:

```text
username
password
lastName
roomNumber
email
voucherCode
accessCode
phoneNumber
otp
```

---

# 8. Portal Recipe Language – PRL v1

## 8.1 Ziel

Die Recipe-Sprache muss gleichzeitig:

- menschenlesbar,
- AI-editierbar,
- strikt validierbar,
- sicher,
- versionsfähig,
- deterministisch interpretierbar

sein.

Sie ist **keine Skriptsprache**.

Kein JavaScript.  
Keine Shell-Kommandos.  
Kein beliebiger Swift-Code.  
Keine frei eingebetteten HTTP-Skripte.

## 8.2 Format

Persistenzformat: **YAML**

Laufzeitmodell: Swift `Codable` / typisierte Enums.

AI erzeugt intern nach Möglichkeit direkt typisierte `@Generable`-Strukturen. Erst danach werden diese als YAML serialisiert.

Das Modell muss daher nicht zuverlässig „korrektes YAML schreiben“.

## 8.3 Struktur

```yaml
recipeVersion: 1
profileId: 4FA8...
name: Hotel Muster

network:
  ssid: Hotel_Guest

stages:
  - id: terms
    match:
      anyText:
        - Datenschutz
        - Privacy
        - Terms
    actions:
      - check:
          target:
            role: checkbox
            labelAny:
              - Datenschutz
              - Privacy
              - Terms
      - tap:
          target:
            role: button
            labelAny:
              - Weiter
              - Continue
              - Accept

  - id: guest
    match:
      fields:
        - roomNumber
        - lastName
    actions:
      - fill:
          target:
            concept: roomNumber
          value:
            ask: roomNumber

      - fill:
          target:
            concept: lastName
          value:
            keychain: hotel.lastName

      - tap:
          target:
            role: button
            labelAny:
              - Verbinden
              - Connect
              - Login

success:
  internetAccess: true
```

---

# 9. Primitive der Recipe Engine

V1 bleibt bewusst klein.

## 9.1 `fill`

Text-/Passwort-/Codefeld setzen.

```yaml
- fill:
    target:
      concept: username
    value:
      keychain: portal.username
```

Wertquellen:

```text
literal
profile
keychain
ask
runtime
```

## 9.2 `check`

Checkbox aktivieren.

```yaml
- check:
    target:
      labelAny:
        - Datenschutz akzeptieren
        - I agree
```

## 9.3 `uncheck`

Checkbox deaktivieren.

Typischer Fall:

```text
Newsletter
Marketing
Werbung
Promotions
```

## 9.4 `select`

Für:

- `<select>`
- Radio-Buttons
- Choice Groups

## 9.5 `tap`

Semantischer Klick auf:

- Button
- Link
- Submit-Control

## 9.6 `submit`

Formular explizit absenden.

Die Runtime übernimmt automatisch:

- `action`
- `method`
- Hidden Fields
- Submit-Button-Name/Value
- Cookies
- CSRF-Werte

## 9.7 `requestValue`

Fordert fehlenden Wert beim Benutzer an.

Laufzeitwirkung:

```text
authentication provider
→ uiRequired
→ App
→ Wert
→ Shared Store / Keychain
→ presentUI / Fortsetzung
```

## 9.8 `waitFor`

Wartet auf einen definierten Portalzustand:

- Redirect
- neue URL
- neues Formular
- Element vorhanden
- Seitentext vorhanden

## 9.9 `verify`

Prüft einen erwarteten Zustand:

```yaml
- verify:
    internetAccess: true
```

oder:

```yaml
- verify:
    pageContainsAny:
      - Connected
      - Success
```

## 9.10 `stop`

Terminale Zustände:

```text
success
temporaryFailure
unsupported
requiresManualInteraction
```

Damit sind die typischen Captive-Portal-Aktionen vollständig abbildbar, ohne eine allgemeine Automationssprache zu schaffen.

---

# 10. Semantische Elementidentifikation

Der zentrale Fehler eines klassischen Captive-Portal-Skripts wäre:

```css
#content > div:nth-child(3) > input
```

Das ist zu fragil.

Stattdessen wird ein Element als semantischer Descriptor gespeichert:

```yaml
target:
  role: textField
  concept: roomNumber
  labelAny:
    - Zimmernummer
    - Zimmer
    - Room number
    - Room
  nameAny:
    - room
    - roomNumber
    - room_no
  placeholderAny:
    - Zimmernummer
    - Room number
```

Zusätzliche Eigenschaften:

```text
id
name
type
role
label
placeholder
autocomplete
nearbyText
formAction
formMethod
ordinal
lastKnownSelector
```

Matching-Reihenfolge:

1. `concept`
2. explizite Label-/Name-Hits
3. HTML-Semantik
4. Nähe zu beschreibendem Text
5. letzter bekannter Selector
6. AI-Reparatur

Der gespeicherte CSS-Selector ist nur Fallback, niemals Hauptidentität.

---

# 11. Portal Normalizer

Die AI bekommt nicht blind das komplette HTML.

Der Provider reduziert die Seite deterministisch auf das, was für Captive-Portal-Automation relevant ist.

## 11.1 Extrahieren

- URL
- Host
- Titel
- Formulare
- Form `action`
- Form `method`
- `input`
- `button`
- `select`
- `option`
- `textarea`
- relevante Links
- Labels
- ARIA-Labels
- Placeholder
- Input Type
- Hidden Fields
- Checkboxen
- Radio-Groups
- kurze Textblöcke in direkter Umgebung
- HTTP Status
- Redirect-Historie

## 11.2 Nicht an das Modell schicken

- CSS
- große Script-Blöcke
- Base64
- Bilder
- Tracking-Pixel
- SVG
- Fonts
- komplette Datenschutzerklärung
- beliebige Layout-Struktur

Beispiel des normalisierten Zustands:

```yaml
url: https://portal.example/login
title: Guest Wi-Fi

forms:
  - id: login
    method: POST
    action: /authenticate

    controls:
      - elementId: e1
        role: checkbox
        name: privacy
        label: Ich akzeptiere die Datenschutzerklärung
        required: true

      - elementId: e2
        role: button
        text: Weiter
        submit: true
```

Das reduziert Tokenbedarf und macht die Aufgabe semantisch eindeutig.

---

# 12. Lernlauf

## 12.1 Ablauf

```text
Authenticate event
→ Profil laden
→ noch kein Recipe
→ Portal-Seite abrufen
→ normalisieren
→ Intent + PageState an lokales Modell
→ Modell liefert typisierte Aktionen
→ Aktionen validieren
→ ausführen
→ neue Antwort
→ normalisieren
→ erneut planen
→ ...
→ Internetzugang verifiziert
→ Trace in Recipe kompilieren
→ Recipe speichern
→ success
```

## 12.2 Keine „riesige Einmalplanung“

Das Modell plant **maximal den nächsten kleinen Schritt bzw. eine kleine sichere Aktionsgruppe**.

Beispiel:

Seite 1:

```text
Checkbox Datenschutz
Button Weiter
```

Plan:

```text
check Datenschutz
tap Weiter
```

Danach wird die neue Seite wirklich geladen.

Seite 2:

```text
Zimmernummer
Nachname
Verbinden
```

Dann entsteht erst der nächste Plan.

So funktionieren auch unbekannte mehrstufige Portale.

## 12.3 Lerntrace

Während des erfolgreichen Erstlaufs wird gespeichert:

```text
Portalzustand vorher
Aktion
Ergebnis
Portalzustand danach
HTTP-Redirect
Element-Match
Konfidenz
Dauer
```

Secrets werden im Trace ersetzt durch:

```text
<secret:hotel.lastName>
<runtime:roomNumber>
```

## 12.4 Recipe-Kompilierung

Nach Erfolg:

```text
Trace
→ wiederholbare Schritte erkennen
→ volatile Daten entfernen
→ Hidden/CSRF-Werte nicht hart speichern
→ semantische Targets speichern
→ Stages erzeugen
→ Recipe validieren
→ Revision N+1
```

---

# 13. Replay-Modus

Bei einer späteren Verbindung:

```text
PortalState
→ passendes Stage im Recipe suchen
→ Targets matchen
→ Aktionen ausführen
→ erwarteten Zustand prüfen
```

AI wird zunächst **nicht** verwendet.

Nur wenn:

- Stage nicht erkannt,
- Target nicht gefunden,
- HTTP-Flow abweicht,
- Validierung fehlschlägt,

wird Adaptive Repair gestartet.

Vorteile:

- schneller
- weniger Energieverbrauch
- weniger Modellaufrufe
- besser testbar
- reproduzierbar

---

# 14. Live Adaptive Repair

Wenn ein Recipe fast passt:

```text
Expected:
Button „Connect“

Actual:
Button „Join Wi-Fi“
```

kann das lokale Modell einen sehr kleinen Repair-Vorschlag erzeugen:

```text
old target → new target
```

Der Patch wird erst nach erfolgreichem Login dauerhaft gespeichert.

Beispiel:

```yaml
patch:
  stage: guest
  action: submit-login
  replace:
    labelAny:
      - Connect
  with:
    labelAny:
      - Connect
      - Join Wi-Fi
```

---

# 15. Private Cloud Compute Repair

## 15.1 Wann PCC verwendet wird

Nicht im primären Live-Login.

PCC wird nur eingesetzt, wenn:

1. ein Lauf fehlgeschlagen ist,
2. die App später wieder Internet hat,
3. der Anwender „Recipe reparieren“ wählt oder automatische Reparatur erlaubt.

## 15.2 Input

An PCC gehen nur redigierte Daten:

```text
gesprochener Intent
aktuelles Recipe
normalisierte Seitenzustände
Fehler
Aktionsfolge
HTTP-Status
Redirects
```

Nicht senden:

```text
Passwort
OTP
Voucher
Zimmernummer
Nachname
E-Mail
Session Cookie
CSRF Secret
Authorization Header
```

Werte werden durch semantische Platzhalter ersetzt.

## 15.3 Output

PCC erzeugt keinen frei ausführbaren Code.

Nur:

```swift
@Generable
struct RecipePatch { ... }
```

Der Patch muss dieselben Schema- und Sicherheitsvalidatoren passieren wie ein lokales Modellresultat.

## 15.4 PCC-Entitlement

PCC besitzt ein eigenes Managed Entitlement:

```text
com.apple.developer.private-cloud-compute
```

Apple nennt aktuell zusätzliche Eligibility-Bedingungen.

Quelle:

https://developer.apple.com/private-cloud-compute/

Daher muss PCC als optionale Capability implementiert werden und darf kein hartes Produkt-Requirement für die Basisauthentifizierung sein.

---

# 16. Foundation Models

## 16.1 Haupt-App

Sichere Verwendung:

### Intent Compiler

Input:

```text
„Setz Datenschutz und AGB, Zimmernummer fragen,
Nachname speichern, dann verbinden.“
```

Output:

```swift
@Generable
struct PortalIntentDraft
```

### Recipe Repair

Input:

```text
Intent + Redacted Failure Trace + Existing Recipe
```

Output:

```swift
@Generable
struct RecipePatch
```

## 16.2 Authentication Provider

Zielarchitektur:

```text
NormalizedPortalState
+
PortalIntent
+
ShortHistory
→
@Generable NextPortalPlan
```

Beispiel:

```swift
@Generable
struct NextPortalPlan {
    var reasoningSummary: String
    var actions: [PortalAction]
    var expectedResult: ExpectedResult
    var requiresUserValue: String?
}
```

Die tatsächliche Verwendbarkeit von `FoundationModels` in genau diesem Extension-Kontext ist **Spike Gate S1**.

Die Spezifikation darf das Ergebnis nicht voraussetzen.

Falls Foundation Models im Provider nicht zulässig oder nicht zuverlässig genug ist:

Fallback-Architektur:

```text
deterministische Recipe-Ausführung im Provider
+
Lernlauf nur über presentUI / Haupt-App
```

oder:

```text
kleines eigenes Core-AI-Modell für Elementklassifikation
```

Diese Entscheidung wird erst nach dem Spike getroffen.

---

# 17. HTTP Engine

## 17.1 Anforderungen

Die HTTP Engine muss:

- Requests an das Hotspot-Interface binden
- Cookies erhalten
- Redirects verfolgen
- HTTP GET/POST unterstützen
- `application/x-www-form-urlencoded` unterstützen
- Multipart nur bei realem Bedarf
- Hidden Inputs erhalten
- Submit-Button-Werte korrekt übertragen
- Timeouts kurz halten
- Response-Größe limitieren

Apple bietet für Hotspot Helper APIs explizite Mechanismen, Netzwerkverkehr mit dem entsprechenden Hotspot-Interface zu verbinden.

## 17.2 HTML Parser

Empfohlen:

- kleiner, geprüfter HTML5-Parser als Swift Package, z. B. SwiftSoup,
- hinter eigenem `PortalDocument`-Interface abstrahiert.

Kein Produktcode darf direkt von Parser-spezifischen Typen abhängig sein.

## 17.3 JavaScript-lastige Portale

V1 verspricht **keine allgemeine Headless-Browser-Automation**.

Wenn ein Portal zwingend benötigt:

- Captcha
- JavaScript Challenge
- WebAuthn
- komplexes OAuth/Social SSO
- Payment Provider
- Browser Fingerprinting

wird klassifiziert:

```text
requiresManualInteraction
```

Das ist besser als heimlich eine unsichere Vollbrowser-Engine zu bauen.

---

# 18. Die zehn Test-Portal-Muster für V1

Diese zehn Muster bilden die reale Zielklasse gut ab.

## P1 – Click Through

```text
[Continue]
```

Erwartung:

```text
tap → verify internet
```

## P2 – Terms Only

```text
[ ] I accept Terms
[Continue]
```

## P3 – Privacy + Terms

```text
[ ] Privacy
[ ] Terms
[Connect]
```

## P4 – Username + Password

```text
Username
Password
[Login]
```

## P5 – Room Number + Last Name

```text
Room number
Last name
[Connect]
```

## P6 – Voucher / Access Code

```text
Voucher code
[Connect]
```

## P7 – E-Mail + Required Consent

```text
Email
[ ] Terms
[Continue]
```

## P8 – Multi-Stage

```text
Seite 1:
[ ] Terms
[Continue]

Seite 2:
Room
Last name
[Connect]
```

## P9 – Runtime Missing Value

```text
Room number fehlt in Keychain
→ uiRequired
→ fragen
→ fortsetzen
```

## P10 – Changed Portal

Gespeichert:

```text
„Connect“
```

Neue Seite:

```text
„Join Wi-Fi“
```

Erwartung:

```text
Replay mismatch
→ Local Repair
→ Login
→ Recipe revision++
```

Branchen-Dokumentationen zeigen genau solche wiederkehrenden Muster: Click-through, Terms, E-Mail/Formulare, Checkboxen, mehrstufige Data-Capture-Flows, Voucher und Hotel-Login.

Beispiele:

https://www.cisco.com/c/en/us/td/docs/wireless/spaces/captive-portal/b_cisco-spaces-captive-portal-app-guide/m-authentication-steps-for-customers.html

https://documentation.meraki.com/Wireless/Operate_and_Maintain/User_Guides/MR_Splash_Page/Splash_Page_Traffic_Flow_and_Troubleshooting

---

# 19. Consent- und Sicherheitsregeln

Die gesprochene Anweisung:

> „Setz alle Haken.“

darf nicht blind zu unerwünschten Folgen führen.

Interpretation in V1:

```text
setze alle notwendigen, nicht-kommerziellen
Checkboxen, die für den Verbindungsaufbau nötig sind.
```

Nicht automatisch setzen:

- Newsletter
- Werbung
- Tracking-Einwilligung, wenn optional
- Partnerangebote
- kostenpflichtige Upgrades
- Abonnements
- Käufe
- Datenteilung mit Dritten

Diese benötigen eine explizite Anweisung.

Eine Aktion, die einen Preis, Kauf, Subscription oder Premium-Tarif auslöst, ist in V1 grundsätzlich nicht automatisierbar.

---

# 20. Keychain

## 20.1 Grundsatz

Secrets nie in:

- YAML Recipe
- App Group JSON
- UserDefaults
- Log
- Export
- Notification

## 20.2 Shared Keychain

App und Authentication Provider benötigen eine gemeinsame Keychain Access Group.

Empfohlener Schutz:

```text
kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
```

Begründung:

- Hintergrundzugriff nach erstem Unlock möglich
- kein Transfer auf andere Geräte
- keine Klartext-Persistenz

## 20.3 Datenklassifikation

### Secret

- Password
- Voucher
- Access Code
- Token

### Personal

- Nachname
- Zimmernummer
- E-Mail
- Telefonnummer

### Public/Profile

- SSID
- Labels
- Formularstruktur
- Recipe

Auch persönliche Werte können auf Nutzerwunsch in Keychain statt im Profil liegen.

---

# 21. Profil-Export und Sharing

## 21.1 Dateiformat

```text
*.captiveprofile
```

Technisch ein ZIP-Container:

```text
manifest.json
recipe.yaml
intent.json
README.txt
```

## 21.2 Standardexport

Enthält:

- Profilname
- SSID
- Portal-Hints
- Intent
- Recipe
- Credential-Slots
- Recipe-Version

Enthält nicht:

- Keychain-Werte
- Cookies
- personenbezogene Laufzeitwerte
- Logs

Beispiel:

```yaml
value:
  keychain: hotel.lastName
```

Beim Freund nach Import:

```text
„Dieses Profil benötigt einen Nachnamen.
Möchtest du ihn jetzt sicher speichern?“
```

## 21.3 Signed Profiles

V2 optional:

- Ed25519-Signatur
- Publisher
- SHA-256 Content Hash

V1 benötigt dies nicht zwingend.

---

# 22. Logging

## 22.1 Laufprotokoll

```swift
struct RunLog {
    let id: UUID
    let profileId: UUID
    let startedAt: Date
    let duration: TimeInterval
    let outcome: Outcome
    let stages: [StageLog]
    let redactedEvents: [LogEvent]
}
```

## 22.2 Redaction

Vor Speicherung:

```text
password → <secret>
cookie → <cookie>
voucher → <secret>
surname → <personal:lastName>
room → <personal:roomNumber>
```

## 22.3 Debug Bundle

Der Nutzer kann ein Debug Bundle erzeugen.

Enthält:

```text
recipe
intent
redacted trace
normalized DOM states
app version
OS version
model availability
provider events
```

Kein Secret.

---

# 23. Fehlerzustände

Definierte Outcomes:

```text
success
temporaryFailure
unsupportedPortal
missingUserValue
recipeMismatch
networkError
timeout
aiUnavailable
aiRejectedPlan
manualInteractionRequired
```

Kein generisches „Es ging nicht“.

Die Aktivitätsansicht zeigt z. B.:

```text
Hotel Muster
Heute, 16:31

Nicht verbunden

Grund:
Zimmernummer war nicht verfügbar.

Aktion:
[Wert hinterlegen] [Recipe ansehen]
```

---

# 24. Sicherheit der AI-Ausführung

Jede AI-Antwort muss vor Ausführung validiert werden.

Validator:

```text
✓ Opcode erlaubt?
✓ Target existiert?
✓ URL bleibt im zulässigen Portal-Flow?
✓ kein Payment?
✓ kein externer Credential-Exfiltration-Host?
✓ kein JavaScript?
✓ kein freier Code?
✓ kein unbekannter Secret-Key?
✓ Aktionsanzahl innerhalb Limit?
```

Das Modell ist **Planer**, nicht Security Authority.

Die Runtime besitzt immer die letzte Entscheidung.

---

# 25. Netzwerk-/Host-Sicherheitsmodell

Während eines Captive Flows wird eine Host-Menge aufgebaut:

```text
initial redirect hosts
+
form action hosts
+
explicit redirect hosts
```

Neue, unerwartete Drittanbieter-Domains werden nicht automatisch mit Credentials bedient.

Credential Rule:

```text
Ein Secret darf nur in das Formular eingesetzt werden,
für dessen semantischen Zweck es angefordert wurde.
```

Beispiel:

```text
hotel.password
```

darf nicht in einem plötzlich auftauchenden:

```text
marketing.example.com/email
```

verwendet werden.

---

# 26. Evaluation Provider

Der Evaluation Provider ist absichtlich simpel.

Pseudocode:

```swift
func handleCommand(_ command: NEHotspotHelperCommand) async
    -> NEHotspotHelperResponse {

    switch command.commandType {

    case .filterScanList:
        let matches = command.networkList?
            .filter { profileStore.matches(ssid: $0.ssid) }
        return response(with: matches)

    case .evaluate:
        guard let ssid = command.network?.ssid else {
            return .none
        }

        guard profileStore.hasEnabledProfile(ssid: ssid) else {
            return confidence(.none)
        }

        return confidence(.high)

    default:
        return .commandNotRecognized
    }
}
```

Keine AI in Evaluation.

Keine HTTP-Portalanalyse, wenn ein exakter Profilmatch bereits genügt.

Dadurch bleibt dieser Pfad schnell.

---

# 27. Authentication Provider State Machine

Eigene interne Zustände:

```text
idle
loadingProfile
probingPortal
replayingRecipe
learning
awaitingUser
verifying
success
failed
```

## `authenticate`

```text
load profile
→ fetch current portal
→ recipe?
   yes → replay
   no  → learn
→ if user input missing:
   uiRequired
→ verify
→ response
```

## `presentUI`

```text
read response from App Group
→ continue pending run
→ verify
→ return success/failure
```

## `maintain`

```text
probe general connectivity
→ online → success
→ captive again → authenticationRequired
```

---

# 28. Timeout-Budget

Historisch dokumentiert Apple für Authenticate/Evaluate kurze Systemzeitfenster; die Implementierung muss deshalb streng zeitbudgetiert sein.

Interne Zielwerte:

```text
Portal Fetch:             < 3 s
DOM Normalize:            < 150 ms
AI Plan:                  Ziel < 3 s
HTTP Action:              < 3 s
Max AI rounds:            5
Max redirects:            10
Max response HTML:        1 MB
```

Provider bricht kontrolliert ab, bevor das System ihn beendet.

`presentUI` ist der Pfad für Nutzerinteraktion, nicht „ewiges Warten“ in `authenticate`.

---

# 29. Recipe Editor

Der Nutzer erhält zwei Modi.

## Einfach

```text
Anweisung:
„Datenschutz akzeptieren, Zimmernummer fragen,
Nachname benutzen, verbinden.“
```

AI überarbeitet Intent/Recipe.

## Erweitert

YAML-Ansicht:

```yaml
stages:
  ...
```

Buttons:

```text
Validieren
Mit AI erklären
Mit AI reparieren
Vorherige Revision
```

Eine manuell geänderte Datei wird nie ausgeführt, bevor:

```text
Parse
→ Schema Validation
→ Security Validation
```

erfolgreich waren.

---

# 30. Versionierung

Jede erfolgreiche Änderung erzeugt:

```text
recipeRevision += 1
```

Aufbewahren:

- aktuelle Revision
- letzte fünf erfolgreiche Revisionen

Rollback:

```text
„Seit Version 7 schlägt Hotel Muster fehl.“
→ Version 6 wiederherstellen
```

---

# 31. Import-Konflikte

Beim Import:

```text
SSID-Profil existiert bereits
```

Optionen:

```text
Abbrechen
Als Kopie importieren
Recipe ersetzen
Vergleichen
```

Keychain-Werte werden niemals überschrieben.

---

# 32. Optionale WLAN-Konfiguration

Optionaler V1.1-Baustein:

`NEHotspotConfigurationManager`

Zweck:

```text
SSID-Konfiguration für ein bekanntes WLAN anlegen.
```

Nicht als Versprechen formulieren:

```text
„App scannt im Hintergrund beliebige WLANs und verbindet
sich autonom mit jedem davon.“
```

iOS stellt dafür keine allgemeine Drittanbieter-API bereit.

---

# 33. Nicht-Ziele V1

- allgemeiner Webbrowser-Agent
- CAPTCHA lösen
- Bezahlschranken automatisieren
- Premium-WLAN kaufen
- Social Login automatisieren
- WebAuthn automatisieren
- beliebiges JavaScript ausführen
- WLAN-Ortung
- WLAN-Scanner
- Access-Point-Management
- macOS
- Android

---

# 34. App-Store-/Privacy-Anforderungen

Privacy Manifest und App-Store-Texte müssen klar beschreiben:

- WLAN-Authentifizierung ist Kernfunktion
- Daten bleiben standardmäßig auf dem Gerät
- Secrets liegen in Keychain
- Profile enthalten standardmäßig keine Secrets
- PCC ist optional
- Logs werden redigiert
- kein Verkauf von WLAN-/Standortdaten
- keine Verwendung des Hotspot APIs zur Standortbestimmung

---

# 35. Entitlement beantragen

## 35.1 Aktueller Apple-Weg

Für Managed Capabilities dokumentiert Apple:

```text
Apple Developer
→ Certificates, Identifiers & Profiles
→ Identifiers
→ gewünschte App ID
→ Capability Requests
→ gewünschte Capability
→ Request
```

Bei Organisationsaccounts muss der **Account Holder** die Anfrage stellen.

Quelle:

https://developer.apple.com/help/account/capabilities/capability-requests

Für Hotspot Helper verweist Apple zusätzlich auf den Request-Link:

https://developer.apple.com/contact/request/hotspot-helper/

Entitlement:

```text
com.apple.developer.networking.HotspotHelper
```

Empfehlung: zuerst im aktuellen App-ID-Portal unter `Capability Requests` prüfen; falls Apple dort auf den separaten Hotspot-Helper-Fragebogen verweist, diesen verwenden.

## 35.2 Formulierungsvorschlag für Apple

Die Anfrage sollte eng beim von Apple vorgesehenen Hotspot-Anwendungsfall bleiben.

### Suggested use-case text

```text
Our app helps users authenticate to Wi-Fi hotspot networks that require
interaction with a captive portal before general Internet access becomes
available.

Users explicitly create a profile for a named Wi-Fi network/SSID and describe
the authentication steps they want the app to perform, for example accepting
required terms, entering a hotel room number, username, password, or voucher,
and submitting the portal form.

The app uses the Hotspot Helper authentication state machine only for Wi-Fi
hotspot authentication. It does not use Wi-Fi information for location
tracking, accessory discovery, analytics, or general-purpose Wi-Fi scanning.

Authentication data is stored locally. Sensitive values are kept in the iOS
Keychain and are not included in shared profiles. The app only claims networks
for which the user has explicitly enabled a matching profile.

We intend to use the current extension-based Hotspot Helper architecture with
NEHotspotManager, NEHotspotEvaluationProvider, and
NEHotspotAuthenticationProvider.
```

### Falls nach dem konkreten Kundennutzen gefragt wird

```text
The purpose is to make recurring captive-portal authentication accessible and
reliable for users who frequently visit the same hotels, guest networks,
transportation Wi-Fi, event venues, or corporate guest networks. After a user
has configured and successfully used a profile, subsequent authentications can
be performed automatically when the device rejoins that same network.
```

### Falls nach Netzwerkabdeckung gefragt wird

Nicht schreiben:

```text
We handle every Wi-Fi network automatically.
```

Besser:

```text
The helper only claims networks that match user-configured profiles.
```

Das passt zu Apples eigener Hotspot-Helper-Guideline, nicht jedes Netz pauschal zu beanspruchen.

---

# 36. Weitere Capabilities

Voraussichtlich:

```text
Hotspot Helper                managed / approval required
App Groups                    required
Keychain Sharing              required
Notifications                 required
Speech Recognition            required for voice UI
Microphone usage              required for voice UI
Private Cloud Compute         optional, separately managed
Hotspot Configuration         optional
Access WiFi Information       only if feature design really requires it
```

Capabilities so minimal wie möglich halten.

---

# 37. Implementierungsreihenfolge

## Phase 0 – Entitlement

Sofort:

```text
Bundle ID festlegen
→ Hotspot Helper beantragen
```

## Phase 1 – Core ohne Entitlement

Implementieren:

```text
PortalIntent
PRL
Parser
HTTP simulator
Normalizer
Recipe interpreter
Keychain abstraction
Logs
FoundationModels contracts
Speech UI
Import / Export
```

## Phase 2 – Spike

Siehe separates Dokument.

## Phase 3 – Provider Integration

Nach Entitlement:

```text
Evaluation Provider
Authentication Provider
NEHotspotManager setup
App Group
shared Keychain
uiRequired flow
```

## Phase 4 – Learning

```text
Local AI planner
trace compiler
adaptive repair
```

## Phase 5 – PCC Repair

Nur optional und getrennt.

---

# 38. Definition of Done V1

V1 ist fertig, wenn folgende Abnahmekriterien erfüllt sind:

1. Profil per Text oder Sprache anlegbar.
2. Exakte SSID kann einem Profil zugeordnet werden.
3. Evaluation Provider beansprucht nur konfigurierte Netze.
4. Authentication Provider kann ein vorhandenes Recipe ausführen.
5. Terms-/Privacy-Checkboxen funktionieren.
6. Username/Password funktioniert.
7. Hotel Room + Last Name funktioniert.
8. Voucher funktioniert.
9. Zweistufiges Portal funktioniert.
10. Fehlender Wert löst `uiRequired` aus.
11. Wert kann sicher in Keychain gespeichert werden.
12. Nach Erfolg wird ein Lernlauf als Recipe gespeichert.
13. Zweiter Lauf funktioniert ohne AI, wenn Portal unverändert ist.
14. Geändertes Label kann lokal repariert werden.
15. Fehler erzeugt redigiertes Debug Bundle.
16. Profil lässt sich ohne Secrets exportieren/importieren.
17. Keine Secrets erscheinen in Logs.
18. Kein Payment-/Marketing-Opt-in erfolgt ohne explizite Erlaubnis.
19. AI kann nur typisierte PRL-Aktionen erzeugen.
20. App funktioniert auf iPhone und iPad mit iOS/iPadOS 27.

---

# 39. Architekturentscheidung in einem Satz

**Die App speichert nicht „wie ein Browser geklickt hat“, sondern warum und auf welches semantische Formularelement eine begrenzte Aktion ausgeführt wurde.**

Genau dadurch kann das Recipe menschenlesbar bleiben und trotzdem robust genug für reale Captive Portals werden.

---

# 40. Quellen

Apple:

- https://developer.apple.com/documentation/networkextension/hotspot-helper
- https://developer.apple.com/documentation/networkextension/nehotspotmanager
- https://developer.apple.com/documentation/networkextension/nehotspotevaluationprovider
- https://developer.apple.com/documentation/networkextension/nehotspotauthenticationprovider
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.hotspothelper
- https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview
- https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment
- https://developer.apple.com/help/account/capabilities/capability-requests
- https://developer.apple.com/contact/request/hotspot-helper/
- https://developer.apple.com/documentation/foundationmodels
- https://developer.apple.com/documentation/foundationmodels/generable
- https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling
- https://developer.apple.com/private-cloud-compute/
- https://developer.apple.com/documentation/speech/speechanalyzer
- https://developer.apple.com/documentation/speech/speechtranscriber

Captive-Portal-Muster:

- https://www.cisco.com/c/en/us/td/docs/wireless/spaces/captive-portal/b_cisco-spaces-captive-portal-app-guide/m-authentication-steps-for-customers.html
- https://documentation.meraki.com/Wireless/Operate_and_Maintain/User_Guides/MR_Splash_Page/Splash_Page_Traffic_Flow_and_Troubleshooting
