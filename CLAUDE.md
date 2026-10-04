# AnyWiFi (iOS/iPadOS)

Die vollständige Spezifikation steht in `SPEC.md`. Lies sie vor jeder Arbeit.

Arbeitsregeln:
- Arbeite die Phasen aus `SPEC.md` §10 der Reihe nach ab. Starte mit Phase 0 (Spikes) und dokumentiere das Ergebnis in `docs/spikes.md`.
- Eine Phase ist erst fertig, wenn ihre Abnahmekriterien belegt sind (Tests grün, Nachweis im PR).
- Secrets (Passwörter, Voucher, persönliche Werte) nie loggen, nie in LLM-Prompts, nie unverschlüsselt außerhalb des Keychains.
- Recipes enthalten nie beliebiges JavaScript.
- Nur iOS/iPadOS. Keine macOS-/Catalyst-Targets.
- Das Xcode-Projekt wird aus `project.yml` (XcodeGen) erzeugt. Die `.xcodeproj` nicht von Hand pflegen.
