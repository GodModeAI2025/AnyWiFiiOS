# ADR 0001: Portal-Adapter und zusätzliche Runtime-Regeln der HTTP-Engine

- Status: angenommen
- Datum: 2026-10-04
- Kontext: `docs/research/portale-bahn-hotel.md`

## Kontext
01 §17.3 geht davon aus, dass Captive Portals serverseitig gerenderte HTML-Formulare sind. Portale, die das nicht sind, stuft die Engine als `manualInteractionRequired` ein.
Die Recherche zeigt, dass das für Hotels weitgehend stimmt, für wichtige Bahnportale aber nicht:
- DB ICE (Icomera, neue Generation): `POST /cna/logon` als JSON
- SNCF: `POST /router/api/connection/activate/auto` als JSON
- MikroTik: Das Passwort wird im Browser mit JavaScript MD5-gehasht (CHAP)

Ein allgemeiner HTTP- oder Skript-Opcode im Recipe würde 01 §8.1 verletzen (keine eingebetteten HTTP-Skripte, kein freier Code).

## Entscheidung
1. **Portal-Adapter:** Fest in `CaptiveCore` eingebaute, reviewte Module für bekannte Portalsysteme (`PortalAdapter`-Protokoll). Ein Adapter
   - erkennt sein Portal an Host, URL-Pfad oder HTML-Markern (`detect`),
   - führt den Login über die normale `PortalTransport`-Schicht aus,
   - bekommt Werte nur über denselben `ValueProvider` wie Recipes und unterliegt denselben Host- und Credential-Regeln.
2. **Neuer PRL-Opcode `adapter`** (PRL v1, rückwärtskompatibel, weil v1 nur erweitert wird):
   ```yaml
   - adapter:
       id: icomeraCNA        # muss in der eingebauten Adapter-Registry existieren
   ```
   Der Validator lehnt unbekannte Adapter-IDs ab. Ein Adapter-Schritt nimmt keine weiteren Parameter.
3. **Runtime-Regeln der HTTP-Engine** (gelten für alle Recipes, nicht konfigurierbar):
   - Query-Parameter der Redirect- bzw. Portal-URL bleiben erhalten. Relative Form-Actions werden gegen die aktuelle Seiten-URL aufgelöst.
   - Hidden Fields und Submit-Button-Name/Value werden automatisch übertragen (wie 01 §9.6).
   - Vorausgewählte Marketing-Checkboxen, die das Recipe nicht ausdrücklich aktiviert, werden vor dem Absenden abgewählt. Kommerzielle Checkboxen oder Submitter (Kauf/Upgrade/Preis) blockieren die Ausführung (Outcome `manualInteractionRequired`, Detail `commercialElement`).
   - Secrets und persönliche Werte gehen nur an Form-Actions, deren Host vertrauenswürdig ist: Hosts der Redirect-Kette ab dem Probe, `portalHostHints` des Profils und Hosts, auf die das Portal selbst per HTTP-Redirect weiterleitet (01 §25). Sonst Outcome `manualInteractionRequired`, Detail `credentialHostNotTrusted`.
   - Vor dem Recipe prüft die Engine, ob das Gerät schon online ist (Probe). Dann gibt es keinen Login.
4. Erster Adapter in Phase 2: `icomeraCNA` (DB ICE, JSON). Die alte Icomera-Generation (DB/metronom) enthält `CSRFToken` laut den öffentlichen Skripten auch als Formularfeld. Dafür reicht ein normales Recipe (Fixture `16_icomera_form`), kein Adapter. Später: `sncfRouterAPI`, `mikrotikCHAP`.

## Konsequenzen
- `Schemas/prl-v1.schema.json`, `PortalAction` und `RecipeValidator` werden um `adapter` erweitert.
- Neue Fixtures: `16_icomera_form`, `17_icomera_cna`, `18_hotsplots_uam`, `19_meraki_clickthrough`.
- 01 §17.3 bleibt gültig für Portale ohne Adapter.
- Adapter-Code ist Produktcode mit Tests. Ein Adapter ist **kein** Weg, beliebige Logik per Recipe nachzuladen.
