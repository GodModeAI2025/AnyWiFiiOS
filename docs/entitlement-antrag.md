# Antrag Hotspot Helper (Phase 0)

Stand: 4. Oktober 2026. Den Antrag kann nur der Account Holder stellen. Das Team kann ihn nicht für den Auftraggeber einreichen.

## Wo

1. developer.apple.com, Account, Certificates, Identifiers & Profiles, Identifiers.
2. App ID auswählen (Platzhalter bis zur Freigabe: `com.example.captiveai`, vorher durch die echte Bundle-ID ersetzen).
3. Capability Requests, Hotspot Helper, Request.
4. Verweist Apple dort auf den Fragebogen, diesen nutzen: https://developer.apple.com/contact/request/hotspot-helper/

Entitlement: `com.apple.developer.networking.HotspotHelper`

## Angaben zum Unternehmen

- Website: https://www.mobilebox-consulting.de (Firmen-URL für das Formular und für die Support-URL im App-Store-Eintrag)
- Kontakt: Account Holder des Developer-Accounts

## Text für das Formular (Englisch, direkt einfügbar)

> CaptiveAI is an iPhone and iPad app that signs users in to Wi-Fi networks behind a captive portal, for example hotel, train, event and guest networks. These sign-ins are repetitive: accept the terms, type a room number and last name, or enter a voucher, and tap Connect. The app does this for the user, so the sign-in no longer has to be repeated on every visit.
>
> How it works: The user creates a profile for one specific network name (SSID) and describes the steps in a short chat, for example "accept the terms, ask me for the room number, use my saved last name, then connect". The app stores these steps as a small, declarative recipe. It contains no scripts and no executable code. When the device joins that network, the app replays the recipe against the portal's HTML form.
>
> Why Hotspot Helper: We need to take part in the system's hotspot authentication state machine (NEHotspotManager with NEHotspotEvaluationProvider and NEHotspotAuthenticationProvider) so the sign-in can run when iOS joins the configured network, without the user opening the app. If the portal needs a value we do not have, the provider returns uiRequired and the app asks the user.
>
> What we do not do: The helper claims only networks for which the user has explicitly enabled a profile with an exact SSID match. It never claims other networks. We do not scan for networks, we do not use Wi-Fi information for location, we do not discover accessories, and we do not collect analytics or run our own servers. We never automate payments, purchases or optional marketing consents, and we stop and hand over to the user for captchas and JavaScript-only portals.
>
> Data handling: Passwords and other sensitive values are stored in the iOS Keychain. Profiles that users share contain no credentials unless the user explicitly opts in, and then only encrypted with a passphrase. Debug logs are redacted. Everything stays on the device.
>
> We use only the current extension-based APIs, not the deprecated NEHotspotHelper.register.

## Kurzfassung (falls das Feld begrenzt ist)

> CaptiveAI automates repeat captive-portal sign-ins (terms, room number, voucher) for networks the user has explicitly configured. We need Hotspot Helper to run the sign-in when iOS joins such a network, via NEHotspotEvaluationProvider and NEHotspotAuthenticationProvider. The helper claims only user-enabled profiles with an exact SSID match. No scanning, no location use, no analytics. Credentials stay in the Keychain.

## Mögliche Rückfragen von Apple

**Welche Netze beansprucht die App?**
Nur exakte SSIDs aus aktivierten Nutzerprofilen. Alles andere bekommt confidence none.

**Nutzt ihr die Daten für Standort oder Tracking?**
Nein. Keine Standortbestimmung, kein Scanning, keine Analytics, keine eigenen Server.

**Warum nicht ein normaler Browser oder ein Kurzbefehl?**
Beides läuft nicht automatisch beim Verbinden. Ohne den Helper muss der Nutzer die App öffnen oder eine Automation auslösen. Genau diese Lücke schließt der Helper.

**Was passiert bei Captcha oder Zahlung?**
Die App bricht ab und übergibt an den Nutzer. Zahlungen und optionale Marketing-Einwilligungen werden nie automatisch bestätigt.

**Funktioniert die App ohne das Entitlement?**
Ja, im manuellen Modus (App öffnen, App Intent, Kurzbefehl, Control Center). Das Entitlement macht den Ablauf automatisch, es ist keine Voraussetzung für die App.

## Vor dem Absenden prüfen

- Bundle-ID und Team-ID sind eingetragen (SPEC §8, Punkt 1).
- Der Antrag kommt vom Account Holder.
- Die Beschreibung stimmt mit dem App-Store-Eintrag und der Privacy-Manifest-Angabe überein (01 §34).
- Das Entitlement `com.apple.developer.networking.HotspotConfiguration` (WLAN einrichten) braucht keinen Antrag, es ist Self-Service.
