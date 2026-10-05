# Geräte-Testcheckliste

Punkte, die sich nicht im Simulator oder in CI prüfen lassen (SPEC §7, Regel 5). Abhaken mit Datum, Gerät, OS.

## Manueller Modus (Phase 4, Gate S13)
- [ ] Im Captive-Zustand laufen Requests aus der App mit `allowsCellularAccess = false` zuverlässig über das WLAN-Interface.
- [ ] Der System-CNA-Dialog stört den Lauf nicht (oder schließt sich nach Erfolg).
- [ ] Ein Login aus der App löst den CNA-Zustand auf: Das Gerät gilt danach als online.
- [ ] App Intent "Im WLAN anmelden" läuft als Kurzbefehl-Automation "Wenn mit WLAN X verbunden".
- [ ] Control-Center-Steuerelement startet den Intent.
- [ ] Keychain-Zugriff durch das Control-Extension-Target (gemeinsame Access Group) funktioniert nach Neustart und Sperre.

## WLAN-Konfiguration (Phase 3)
- [ ] "WLAN auf diesem Gerät einrichten" legt ein offenes und ein WPA2/WPA3-Netz an (Systemdialog erscheint).
- [ ] Falsche Passphrase liefert eine verständliche Meldung.

## KI (Phase 5)
- [ ] Muster P1 bis P8 lassen sich per Chat lernen (Apple-Intelligence-Gerät).
- [ ] Modell nicht verfügbar: Chat deaktiviert, Erweitert-Editor bleibt nutzbar.

## Provider (Phasen 8 und 9, Entitlement nötig)
- [ ] Gates S0 bis S12 laut `docs/spikes.md`.
- [ ] `uiRequired` und `presentUI` mit Zimmernummer, keine zweite Anmeldung, Notification ohne sensible Werte.
- [ ] Drei reale Netztypen: Hotel, öffentlicher Guest-Hotspot, Event-/Enterprise-Guest.

## Politur (Phase 11)
- [ ] VoiceOver-Durchgang: Profil anlegen, anmelden, Wert abfragen, Export, Import.
- [ ] Dynamic Type bis AX5: kein abgeschnittener Text in Listen, Formularen und Sheets.
- [ ] Dark Mode und erhöhter Kontrast.
- [ ] iPad: Seitenleiste und Detail in Hoch- und Querformat, Drag and Drop einer `.yaml` und `.captiveprofile` auf ein Profil.
- [ ] Spracheingabe auf Gerät (Deutsch und Englisch), Mikrofon- und Spracherkennungs-Dialoge.
- [ ] Privacy-Manifest: App-Store-Connect-Validierung ohne Warnung.
- [ ] iPad: Kontrast der Seitenleiste (Material) im Hell- und Dunkelmodus prüfen, der automatische Audit läuft dort ohne Kontrast.
