# ADR 0004: Assistent-Modelle und Fallbacks

Status: angenommen (Phase 5)

- Das iOS-27-SDK enthält `PrivateCloudComputeLanguageModel` als öffentliche API (`LanguageModelSession(model:)`). `PCCAssistant` nutzt sie direkt. Entitlement und Teilnahmebedingungen bleiben Voraussetzung (SPEC §1, §8 Punkt 3). Verfügbarkeit läuft über `availability`, ohne Entitlement bleibt PCC aus.
- `OnDeviceAssistant` und `PCCAssistant` sind dieselbe generische Implementierung (`FoundationModelsAssistant`). Unterschiede liegen nur im Modell und in der Verfügbarkeitsabbildung.
- Das Modell wählt nur aus geschlossenen Mengen (elementIds, Konzepte, Auswahl-Enums). Targets und Wertquellen baut die Runtime aus Intent und Bindings. Dadurch kann das Modell weder Werte erfinden noch Quellen vertauschen.
- `FallbackPlanner` und `FallbackRepairer`: Gibt das Modell auf (`stop`), wirft einen Fehler oder liefert einen unzulässigen Plan, übernimmt die regelbasierte Variante. Ein Login scheitert nie allein an einem Modellausfall.
- Chat: Der Prompt enthält nur Platzhalter. `PromptSanitizer` maskiert bekannte Werte und typische Formulierungen ("mein Passwort ist …"). Sensible Werte gibt der Nutzer im separaten sicheren Feld ein.
- UI-Tests laufen ohne Modell (`-uitest`), außer `-useModel` ist gesetzt.
