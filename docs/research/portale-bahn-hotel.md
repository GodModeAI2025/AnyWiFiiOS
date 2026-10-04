# Recherche: Captive Portals bei Bahn und Hotel

Stand: 04.10.2026. Quellen: öffentlicher Quellcode von Open-Source-Login-Skripten und Herstellerdokumentation.
**Nichts davon ist live gegen ein echtes Portal geprüft.** Portale ändern sich. Die Angaben sind Hypothesen für Gerätetests (`docs/device-test-checklist.md`).

## 1. Deutsche Bahn

### ICE: WIFIonICE / WIFI@DB (Anbieter Icomera)
Es gibt zwei Login-Generationen. Die Bibliothek `onboardapis` (Stand April 2026) probiert zuerst die neue und fällt bei 404 auf die alte zurück:

| | Neu („CNA-API“) | Alt (Formular) |
|---|---|---|
| Login | `POST https://login.wifionice.de/cna/logon`, JSON-Body `{}`, Header `X-Csrf-Token: csrf` | `GET http://login.wifionice.de/de/` → Cookie `csrf` (+ `PHPSESSID`), dann `POST /de/` mit `login=true&CSRFToken=<Cookie-Wert>` (manche Skripte zusätzlich `connect=` und `?mac=<MAC>`) |
| Status | `GET /cna/wifi/user_info` → `result.authenticated == "1"` | HTML enthält Element `id="accept"` bzw. Klasse `user-online`/`user-offline` |
| Logout | `POST /cna/logoff` | `POST /de/` mit `logout=true` |

Gleiches Icomera-Muster: **metronom** (`http://wifi.metronom.de/de/`) und weitere Züge mit Icomera-Technik.
Bordinfos (Geschwindigkeit, Position, Verbindungsqualität): `https://iceportal.de/api1/rs/status`.

**Folgen für uns:**
- Der alte Ablauf ist ein normales Formular. Der CSRF-Wert steht im Cookie und muss ins Formularfeld kopiert werden (nicht nur ein Hidden Field).
- Der neue Ablauf ist ein **JSON-Aufruf ohne HTML-Formular**. Die HTML-Engine (01 §17) würde ihn als `manualInteractionRequired` einstufen.
- Den `mac`-Parameter kann iOS nicht liefern (keine MAC-Adresse für Apps). Steht er in der Redirect-URL des Portals, muss die Engine ihn von dort übernehmen.

### Regionalverkehr: DB Regio (Anbieter hotsplots)
- Portal unter `http://192.168.44.1/auth/login.php`, klassisches Formular (ChilliSpot/UAM-Stil).
- Felder (alle aus dem Formular übernehmen): `haveTerms`, `termsOK`, `button` (Text des Buttons), `challenge`, `uamip`, `uamport`, `userurl`, `myLogin`, `ll`, `nasid`, `custom`.
- Logout: `GET /logoff`.
- hotsplots betreibt auch viele Hotels, Cafés und Ferienwohnungen in Deutschland. Zugangsarten laut Herstelleranleitung: Direkt-Login (nur Nutzungsbedingungen), Nutzer-Login, Ticket-Login (Zugangsdaten vor Ort).

### Ausland
- **SNCF inOui / Normandie:** reine JSON-API, `POST https://wifi.sncf/router/api/connection/activate/auto` mit Body `{"without21NetConnection":false}`; Status `GET /router/api/connection/status`.
- ÖBB Railnet: Bordportal `railnet.oebb.at`. Einen Login-Ablauf haben wir nicht gefunden.

## 2. Hotels

| System | Verbreitung | Login | Passt zu Muster |
|---|---|---|---|
| LANCOM Public Spot | stark in DE | Formular: Voucher, PMS-Login (Nachname + Zimmernummer + optional weitere Kennung), PMS+Voucher, E-Mail | P5, P6, P7 |
| Nomadix | internationale Hotelketten | PMS-Login Nachname + Zimmernummer (Prüfung gegen das Hotelsystem über FIAS), oft mit externer Cloud-Splash-Seite | P5, ggf. JS |
| hotsplots | DE: Hotels, Cafés, Ferienwohnungen | wie oben (UAM-Formular) | P2, P4, P6 |
| Cisco Meraki | Ketten, Büros | Click-through: Formular/Link auf `base_grant_url?continue_url=…` (URL dynamisch, **nie fest speichern**) | P1 |
| UniFi | kleine Hotels | `POST /guest/login` bzw. `/guest/s/default/login`, Parameter `id` (MAC), `ap`, `t`, `url`, `ssid` in der Redirect-URL | P1/P6 |
| MikroTik Hotspot | kleine Häuser, Pensionen | Formular, **Passwort wird per JavaScript gehasht**: `hexMD5(chap-id + Passwort + chap-challenge)` (`md5.js`) | P4 mit JS |

Hotel-Logins bestehen fast immer aus Nachname + Zimmernummer, Voucher oder Click-through mit AGB. Unser P5 ist damit der wichtigste Fall. Laut LANCOM-Doku gibt es bei PMS-Logins auch **kostenpflichtige Tarife auf die Zimmerrechnung**. Die Consent-Regel (01 §19, kein Kauf) ist also kein theoretischer Fall.

## 3. RFC 8908/8910 (Captive Portal API)
iOS ab 14 und Android ab 11 werten DHCP-Option 114 bzw. IPv6-RA-Option 37 aus. Die API liefert JSON mit `captive`, `user-portal-url`, `venue-info-url`. Die Herstellerunterstützung ist uneinheitlich (z. B. offene Anfragen bei MikroTik und PacketFence). Für uns ist das nur eine bessere Portal-Erkennung, keine Login-Methode.

## 4. Konsequenzen für die Spezifikation (Vorschläge, noch nicht übernommen)

1. **„Portale sind HTML-Formulare“ gilt für Hotels weitgehend, für Bahnen nicht.** DB-ICE (neue Generation) und SNCF loggen per JSON ein, MikroTik hasht per JavaScript.
2. Vorschlag: **Portal-Adapter**. Das sind fest in der App eingebaute, geprüfte Swift-Module für bekannte Systeme, z. B. `icomeraCNA`, `sncfRouterAPI`, `mikrotikCHAP`. Das Recipe verweist nur per Namen darauf (`- adapter: { id: icomeraCNA }`). Kein freier Code im Recipe, die Sicherheitsregel 01 §8.1 bleibt bestehen. Adapter erkennen ihr Portal am Host bzw. an Markern.
3. Die Engine muss **Query-Parameter aus der Redirect-URL übernehmen** (`mac`, `id`, `ap`, `base_grant_url`, `continue_url`, `challenge` …).
4. Die Engine muss **Cookie-Werte in Formularfelder übernehmen** können (DB-alt: Cookie `csrf` → Feld `CSRFToken`). Das ist eine Runtime-Regel, kein Recipe-Inhalt.
5. **„Schon online“ erkennen**, bevor ein Recipe läuft. Portale zeigen das selbst an (`user-online`, `authenticated == "1"`), sonst reicht der Apple-Probe.
6. **Neue Testfixtures:** icomera-alt (Cookie-CSRF), hotsplots-UAM-Formular, Meraki-Click-through mit Grant-URL, MikroTik-CHAP, icomera-CNA-JSON. Die beiden letzten als Adapter-Fälle.

## Quellen
- https://github.com/felix-zenk/onboardapis (Quellcode: `train/de/db/interfaces.py`, `train/third_party/icomera/interfaces.py`)
- https://gist.github.com/anjomro/acfa273fbf4fcd605f4c63bf86e9d234
- https://gist.github.com/fnordomat/5f7b14a9bcb0ebfbed2472e573ff4f1b
- https://github.com/saveman71/wifi-onrails (`wifi_sncf.sh`)
- https://github.com/hija/iceportal-status-logger
- https://hotsplots.com/wp-content/uploads/2022/08/HOTSPLOTS_Nutzeranleitung_iOS_Android_DE.pdf
- https://www.lancom-systems.de/docs/LCOS/Refmanual/DE/topics/pspot_pms_function.html
- https://nomadix.com/nomadix-captive-portal-for-wi-fi-onboarding/
- https://www.purple.ai/en-gb/guides/hotel-guest-wifi-architecture-pms-integration-captive-portals-and-bandwidth-control
- https://developer.cisco.com/meraki/captive-portal-api/click-through-api/
- https://documentation.meraki.com/Wireless/Operate_and_Maintain/User_Guides/MR_Splash_Page/Configuring_a_Custom-Hosted_Splash_Page_to_Work_with_the_Meraki_Cloud
- https://help.ui.com/hc/en-us/articles/31228198640023-External-Hotspot-API-for-Authorization-Clients
- https://help.mikrotik.com/docs/spaces/ROS/pages/87162881/Hotspot+customisation
- https://www.rfc-editor.org/info/rfc8908/
