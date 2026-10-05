# ADR 0007: Bundle-IDs und Team

Status: angenommen

SPEC §3.6 sieht den Platzhalter `de.mobilebox.captiveai` vor, bis der Auftraggeber das Präfix liefert. Entschieden: Präfix `de.mobilebox` (Präfix der bestehenden Apps im Developer-Account (`de.mobilebox.*`)), Team `SP73Z8JWXM` (Mobile Box - App Consulting UG).

| Ziel | ID |
|---|---|
| App | `de.mobilebox.captiveai` |
| Control-Extension | `de.mobilebox.captiveai.controls` |
| Evaluation Provider | `de.mobilebox.captiveai.evaluation` |
| Authentication Provider | `de.mobilebox.captiveai.authentication` |
| UI-Tests | `de.mobilebox.captiveai.uitests` |
| App Group | `group.de.mobilebox.captiveai` |
| Keychain-Gruppe | `SP73Z8JWXM.de.mobilebox.captiveai.shared` |
| Dateityp | `de.mobilebox.captiveai.profile` |

Der Produktname bleibt CaptiveAI (SPEC §8 Punkt 5, Standard aus der Spezifikation).
