# ADR 0006: Umfang des automatischen Accessibility-Audits

Status: angenommen (Phase 11)

`XCUIApplication.performAccessibilityAudit` läuft in `AccessibilityUITests` über Profile, Profil-Detail, Aktivität, Import/Export und Einstellungen. Geprüft werden Elementerkennung, Tippflächen, Beschreibungen, Traits und abgeschnittener Text. Bei den ersten Läufen gefundene Mängel sind behoben: zu kleine Tippflächen in Listenzeilen (Zeilen sind jetzt ein kombiniertes Element mit mindestens 44 pt Höhe), Statussymbole ohne eigene Beschreibung.

Kontrast: Er wird auf den Ansichten geprüft, deren Farben wir bestimmen. Auf den Form-Ansichten (Profil-Detail, Einstellungen) meldet das Audit Abschnittsfarben des Systems. Dort wäre die Umgehung eigene Farben, die Dark Mode und erhöhten Kontrast schlechter bedienen. Deshalb entfällt der Kontrastcheck auf diesen zwei Ansichten. "Nearly passed" bei `.secondary` gilt als akzeptiert.

Abgeschnittener Text (`.textClipped`): Dieser Audit-Typ meldete bei Systemkomponenten (`ContentUnavailableView`, Listenzeilen mit einfachem `Label`) wiederholt "may be clipped", obwohl der Text umbricht. Er läuft deshalb nicht automatisch. Stattdessen gilt der manuelle Dynamic-Type-Durchgang bis AX5 in der Checkliste als Abnahme.

Manuell zu prüfen (`docs/device-test-checklist.md`): VoiceOver-Durchgang, Dynamic Type bis AX5, Dark Mode, erhöhter Kontrast, Reduce Motion.
