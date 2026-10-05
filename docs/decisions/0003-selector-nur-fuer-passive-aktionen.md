# ADR 0003: Selector-Fallback nur für Eingaben

Status: angenommen (Phase 2)

01 §10 nennt den letzten bekannten Selector als Fallback vor der AI-Reparatur. Ein reiner Selector-Treffer (kein Label, Name, Konzept) ist bei Buttons und Checkboxen riskant: Ein generischer Selector wie `button[name=action]` trifft nach einer Portaländerung womöglich "Abbrechen" statt "Verbinden".

Entscheidung: `fill` darf auf einen Selector-Treffer zurückfallen (das Konzept-Veto schützt vor falschen Feldern). `tap`, `check`, `uncheck` melden bei reinem Selector-Treffer `recipeMismatch`. Damit greift Szenario P10 (geändertes Label → Mismatch → Reparatur → Revision +1). Test: `changedLabelCausesMismatchNotGuessing`.
