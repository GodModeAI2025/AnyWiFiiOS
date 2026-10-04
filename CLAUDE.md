# CaptiveAI (Repo AnyWiFiiOS), iOS/iPadOS

Pflichtlektüre vor jeder Arbeit, in dieser Reihenfolge:
1. `SPEC.md`: Leitdokument, Ergänzungen und Konfliktentscheidungen. **Gilt bei Widerspruch.**
2. `docs/spec/01_CaptiveAI_App_Spezifikation.md`: Produkt & Architektur.
3. `docs/spec/02_CaptiveAI_Spike_und_Testplan.md`: Spike-Gates, Fixtures, Tests.

Arbeitsregeln:
- Phasen aus `SPEC.md` §5 der Reihe nach. Eine Phase pro Branch/PR, Abnahmekriterien im PR belegen.
- `Packages/CaptiveCore` (Target `CaptiveCore`) muss auf Linux mit `swift test` laufen. Apple-only-Code gehört nach `CaptiveCoreApple`.
- Secrets/persönliche Werte nie in Logs, Prompts, Debug-Paketen, Notifications oder Fixtures. Export nur per Opt-in (`SPEC.md` §3.4).
- Recipes (PRL) enthalten nie JavaScript oder freien Code. Jede AI-Ausgabe läuft durch den Security-Validator.
- Nur iOS/iPadOS. Keine macOS-/Catalyst-Targets.
- Xcode-Projekt nur über `project.yml` (XcodeGen). `.xcodeproj` nicht einchecken.
- Abweichungen von der Spezifikation → ADR in `docs/decisions/`.
- `docs/spec/` nicht stillschweigend ändern.
