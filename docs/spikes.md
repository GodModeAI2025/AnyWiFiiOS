# Spike-Ergebnisbericht (Vorlage 02 §28, mit Gate S13)

Stand: 4. Oktober 2026. Status: Entitlement noch nicht beantragt (Phase 0, Datum: offen). Die Gates, die nur Core-Logik betreffen, laufen automatisiert in CI. Gates auf Gerät warten auf Entitlement und Hardware.

Legende: PASS (automatisiert) = durch Test belegt. OFFEN (Gerät) = steht in `docs/device-test-checklist.md`.

| Gate | Inhalt | Status | Beleg |
|---|---|---|---|
| S0 | Signing und Provider-Installation | OFFEN (Gerät) | Extensions bauen im Simulator (`HotspotEvaluationProvider`, `HotspotAuthenticationProvider`). Provisioning mit Hotspot Helper und Network Extension `hotspot-provider` fehlt. |
| S1 | Foundation Models im Authentication Provider | OFFEN (Gerät) | Code vorhanden (`AuthenticationCore` nimmt Modell oder Fallback). Schalter `allowLearningInProvider` für Ergebnis C/D. |
| S2 | Hotspot-gebundene HTTP-Kommunikation | OFFEN (Gerät) | `HotspotCommandTransport` (bindToHotspotHelperCommand). Cookies, Hidden Fields, Redirects in Simulator gegen `tools/test-portal` belegt. |
| S3 | Mehrseiten-Schleife | PASS (automatisiert) | `FixtureFlowTests` (P8 multistage), `multistageProducesTwoStages`. Zeitbudget auf Gerät offen. |
| S4 | `uiRequired` und Runtime-Wert | PASS (Logik), OFFEN (System) | `missingValueFlowEndToEnd`: eine Anmeldung, Notification ohne Wert, Wert nur im Keychain. `presentUI` im System offen. |
| S5 | Shared Keychain | OFFEN (Gerät) | `KeychainSecretStore` mit Access Group. Bidirektionaler Test braucht Team-ID. |
| S6 | App Group und Pending Session | PASS (automatisiert) | `PendingStoreTests`: atomar, monoton, beschädigte Dateien ignoriert, 40 parallele Schreiber. |
| S7 | DOM-Normalizer | PASS (automatisiert) | `roomNumberVariantsMapToSameConcept`, `fixtureConcepts`, `malformedHTMLStillYieldsLoginForm`. |
| S8 | Replay ohne AI | PASS (automatisiert) | `learnCompileReplay` für P1 bis P8, 11, 12, 13, 15 (`modelCalls == 0`). UI-Test `testLearnThenReplayWithoutModel` im Simulator. |
| S9 | Adaptive Repair | PASS (automatisiert) | `changedLabelIsRepairedLocallyAndRevisionBumps` (Revision +1, Folgelauf ohne Reparatur). |
| S10 | Sicherheitsablehnung | PASS (automatisiert) | `marketingAndPaidNeverPosted`, `acceptAllOnlyTakesRequiredNonCommercial`, `rogueRecipeCannotCheckPaidBox`. |
| S11 | JS-only-Fallback | PASS (automatisiert) | `jsOnlyIsManualInteraction`: `manualInteractionRequired`, keine Modellaufrufe. |
| S12 | Log-Redaction | PASS (automatisiert) | `redactionRemovesAllTestValues`: kein Testwert aus 02 §18 in irgendeiner Datei des ZIPs. |
| S13 | Manueller Modus auf Gerät | OFFEN (Gerät) | Fragen laut SPEC §3.5 in der Checkliste. Simulator-Replay gegen Testportal PASS. |

## Gemessene Latenzen

Auf Gerät noch nicht gemessen. Im Simulator läuft ein Lernlauf gegen das Testportal in unter einer Sekunde (UI-Test, ohne Modell).

## Architekturentscheidung (02 §25)

Vorläufig **Ergebnis A bis B**: Der Provider führt Recipes deterministisch aus, Lernen und Reparatur nutzen das Modell mit regelbasiertem Fallback. Die endgültige Entscheidung hängt an S1 und S4 auf Gerät. Bis dahin gilt `allowLearningInProvider = true`. Fällt S1 durch, wird der Schalter auf `false` gestellt (Ergebnis C) und ein ADR dokumentiert die Änderung.

Ergebnis E (SPEC §3.5) ist bereits gebaut: Ohne Hotspot-Entitlement läuft alles im Manuellen Modus.
