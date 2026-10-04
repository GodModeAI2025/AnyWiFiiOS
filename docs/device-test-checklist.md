# Geräte-Testcheckliste

Punkte, die sich nur auf echter Hardware prüfen lassen (SPEC.md §7 Nr. 5). Pro Lauf: Gerät, OS-Version,
Datum, Ergebnis und ein redigiertes Debug-Paket in `docs/device-tests/<datum>-<netz>/` ablegen.

## Manueller Modus (ohne Hotspot-Entitlement)
- [ ] S13: Captive-Probe erkennt das Portal im Test-WLAN
- [ ] S13: App-Requests mit `allowsCellularAccess = false` laufen über WLAN, nicht Mobilfunk
- [ ] S13: Login aus der App löst den System-Captive-Dialog auf
- [ ] App Intent „Im WLAN anmelden“ per Kurzbefehl-Automation
- [ ] WLAN-Profil einrichten über `NEHotspotConfigurationManager` (SPEC.md §3.1)

## Provider-Modus (nach Entitlement, Gates S0–S12 aus 02)
- [ ] S0 Signing & Provider-Installation
- [ ] S1 Foundation Models im Authentication Provider (Latenzen messen)
- [ ] S2 Hotspot-gebundenes HTTP
- [ ] S4 uiRequired → presentUI mit Runtime-Wert

## Reale Netze (02 §24)
- [ ] Hotel
- [ ] Öffentlicher Guest-Hotspot
- [ ] Enterprise-/Event-Guest-WLAN
