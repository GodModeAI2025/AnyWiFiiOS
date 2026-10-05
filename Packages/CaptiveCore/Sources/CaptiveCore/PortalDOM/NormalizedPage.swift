import Foundation

public enum ControlRole: String, Codable, Sendable {
    case textField, password, checkbox, radio, select, textArea, button, hidden
}

public struct SelectOption: Codable, Equatable, Sendable {
    public var value: String
    public var text: String
    public var selected: Bool
}

public struct NormalizedControl: Codable, Equatable, Sendable {
    public var elementId: String
    public var role: ControlRole
    public var tag: String
    public var inputType: String?
    public var name: String?
    public var htmlId: String?
    public var label: String?
    public var text: String?
    public var placeholder: String?
    public var ariaLabel: String?
    public var autocomplete: String?
    public var nearbyText: String?
    public var value: String?
    public var required: Bool
    public var checked: Bool
    public var submit: Bool
    public var options: [SelectOption]
    public var concept: String?
    public var selector: String
    /// Position unter gleichartigen Controls des Dokuments (0-basiert).
    public var ordinal: Int

    /// Beste sichtbare Beschriftung (für Anzeige, Consent-Klassifikation und Matching).
    public var displayText: String {
        [label, text, ariaLabel, placeholder].compactMap { $0 }.first { !$0.isEmpty } ?? name ?? ""
    }
}

public struct NormalizedForm: Codable, Equatable, Sendable {
    public var id: String
    public var method: String
    public var action: String
    public var enctype: String?
    public var controls: [NormalizedControl]
}

public struct NormalizedLink: Codable, Equatable, Sendable {
    public var elementId: String
    public var text: String
    public var href: String
}

public struct NormalizedPage: Codable, Equatable, Sendable {
    public var url: String
    public var host: String
    public var title: String
    public var status: Int
    public var forms: [NormalizedForm]
    public var links: [NormalizedLink]
    /// Kurzer sichtbarer Text (ohne Script/Style), maximal ~2000 Zeichen.
    public var text: String
    public var hasScripts: Bool
    public var hasCaptcha: Bool
    public var redirectChain: [String]

    public var allControls: [NormalizedControl] { forms.flatMap(\.controls) }

    public func form(containing elementId: String) -> NormalizedForm? {
        forms.first { $0.controls.contains { $0.elementId == elementId } }
    }

    public func control(_ elementId: String) -> NormalizedControl? {
        allControls.first { $0.elementId == elementId }
    }

    public var visibleControls: [NormalizedControl] { allControls.filter { $0.role != .hidden } }

    /// Seite ohne jede verwertbare Interaktion bei vorhandenen Scripts (S11).
    public var looksJavaScriptOnly: Bool {
        visibleControls.isEmpty && links.isEmpty && hasScripts
    }
}
