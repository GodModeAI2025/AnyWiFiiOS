# Entitlement-Anträge bei Apple: Checkliste für den Auftraggeber

Diese Schritte kann nur der **Account Holder** des Apple-Developer-Teams erledigen (01 §35).
Ohne sie lassen sich der Hotspot-Provider (Phase 9) und PCC (Phase 10) nicht auf echten Geräten testen.
Die Phasen 1–7 laufen unabhängig davon weiter.

## 1. Vorbereitung
- [ ] Team-ID notieren: developer.apple.com → Account → Membership details
- [ ] Bundle-ID festlegen (Vorschlag: `<reverse-domain>.captiveai`), dazu für die Extensions:
  - `<bundle-id>.HotspotEvaluationProvider`
  - `<bundle-id>.HotspotAuthenticationProvider`
- [ ] App-IDs anlegen: Certificates, Identifiers & Profiles → Identifiers → „+“ → App IDs
- [ ] App Group anlegen: `group.<bundle-id>`

## 2. Hotspot Helper (Pflicht für den Auto-Login im Hintergrund)
- [ ] Identifiers → App-ID der Haupt-App → Tab **Capability Requests** → „Hotspot Helper“ → Request
- [ ] Falls dort auf den Fragebogen verwiesen wird: https://developer.apple.com/contact/request/hotspot-helper/
- [ ] Text zum Einfügen (englisch, aus 01 §35.2):

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
Keychain. The app only claims networks for which the user has explicitly
enabled a matching profile.

We intend to use the current extension-based Hotspot Helper architecture with
NEHotspotManager, NEHotspotEvaluationProvider, and
NEHotspotAuthenticationProvider.
```

  > Hinweis: Der Originaltext in 01 §35.2 sagt zusätzlich „Sensitive values … are not included in shared profiles“. Das stimmt nach `SPEC.md` §3.4 nicht mehr uneingeschränkt (Opt-in-Export). Deshalb ist der Satz hier weggelassen.

- [ ] Datum des Antrags in `docs/spikes.md` eintragen

## 3. Private Cloud Compute (optional, nur für den Reparaturmodus)
- [ ] Prüfen: Ist das Team im **App Store Small Business Program**, mit weniger als 2 Mio. Erst-Downloads? Wenn nein, entfällt Phase 10.
- [ ] Wenn ja: Entitlement `com.apple.developer.private-cloud-compute` beantragen (https://developer.apple.com/private-cloud-compute/ → „Get the entitlement“)

## 4. Self-Service-Capabilities (kein Antrag nötig, nur in Xcode aktivieren)
- Hotspot Configuration (WLAN-Profile einrichten, `SPEC.md` §3.1)
- App Groups, Keychain Sharing, Push/Local Notifications
- Speech Recognition + Mikrofon (Info.plist-Texte)
