# ADR 0002: Debug-README als Swift-Konstante

Status: angenommen (Phase 2)

SPEC §3.3 nennt `Resources/DebugBundleREADME.md`. SwiftPM-Ressourcen unter Linux und in Extensions erzeugen unnötige Bundle-Pfade. Die Vorlage liegt deshalb als `DebugBundleBuilder.template` im Code und wird mit Profil, Outcome, Grund und Stage gefüllt. Der Wortlaut entspricht SPEC §3.3.
