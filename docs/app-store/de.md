# App Store, Deutsch

**Name:** CaptiveAI
**Untertitel (30 Zeichen):** Automatisch im WLAN anmelden

## Beschreibung

Hotel, Zug, Messe, Café: Bei vielen WLANs musst du dich jedes Mal auf einer Anmeldeseite durchklicken. CaptiveAI erledigt das für dich.

Du legst ein Profil für ein WLAN an und beschreibst in ein, zwei Sätzen, was zu tun ist. Zum Beispiel: Datenschutz und Nutzungsbedingungen akzeptieren, Zimmernummer erfragen, Nachname eintragen, verbinden. Ein lokales Modell auf deinem Gerät stellt Rückfragen, bis alles klar ist. Der Ablauf wird danach gespeichert und bei jedem Besuch ohne KI abgespielt, schnell und reproduzierbar.

**Was die App kann**
- Anmeldeseiten mit Zustimmung, Benutzer und Passwort, Zimmernummer und Nachname, Gutscheincode oder E-Mail
- Mehrstufige Portale
- Fehlende Werte fragt die App gezielt ab, Passwörter liegen im Schlüsselbund
- Ändert ein Portal seine Beschriftung, repariert die App den Ablauf und fragt vorher nach
- Profile teilen, auf Wunsch mit verschlüsselten Zugangsdaten
- Kurzbefehle, Siri und Control Center

**Was die App nicht tut**
- Keine Captchas lösen, nichts kaufen, keine Newsletter abonnieren
- Keine WLANs scannen, keine Standortdaten, keine Analytics, keine eigenen Server

Alle Daten bleiben auf deinem Gerät. Private Cloud Compute ist optional und nur für die Reparatur gedacht, ausschließlich mit redigierten Daten und deiner Zustimmung.

Voraussetzung: iPhone oder iPad mit iOS 27. Der Chat braucht Apple Intelligence.

## Schlüsselwörter (100 Zeichen)

WLAN,Hotspot,Captive Portal,Login,Hotel,Anmeldung,Gast,Zugang,Automatisierung,Kurzbefehle

## Datenschutz (App Privacy)

- Daten, die zum Tracking verwendet werden: keine
- Daten, die mit dir verknüpft sind: keine
- Erhobene Daten: keine. Profile, Werte und Protokolle bleiben auf dem Gerät.

## Hinweise für die App-Prüfung

- Die App meldet an Captive Portals an, die Nutzer selbst als Profil einrichten. Sie beansprucht nur Netze (exakte SSID) mit aktivem Profil.
- Hotspot Helper wird ausschließlich für die Portal-Anmeldung genutzt, nicht für Standort oder Scanning.
- HTTP ohne TLS: Captive Portals sprechen vor der Anmeldung nur HTTP. Deshalb ist `NSAllowsArbitraryLoads` gesetzt.
- Mikrofon und Spracherkennung dienen nur dem Diktat im Profil-Chat. Die Erkennung läuft auf dem Gerät.
- Test ohne Entitlement: Profil anlegen, im Portal-WLAN "Jetzt anmelden" tippen (Manueller Modus).
