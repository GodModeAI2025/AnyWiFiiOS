import Foundation

/// Normalisierte Portalseite (01 §11). Alles, was Engine, Matcher und AI sehen, kommt aus diesem Modell.
/// Kein Produktcode außerhalb des Normalizers kennt den HTML-Parser (01 §17.2).
public struct PortalPage: Sendable, Equatable {
    public var url: URL
    public var title: String
    public var forms: [PortalForm]
    /// Links außerhalb von Formularen.
    public var links: [PortalControl]
    /// Sichtbarer Text, Whitespace zusammengefasst, gekürzt.
    public var text: String
    public var scriptCount: Int
    /// Ziel eines `<meta http-equiv="refresh">` mit kurzer Verzögerung.
    public var metaRefresh: URL?

    public init(url: URL, title: String = "", forms: [PortalForm] = [], links: [PortalControl] = [],
                text: String = "", scriptCount: Int = 0, metaRefresh: URL? = nil) {
        self.url = url
        self.title = title
        self.forms = forms
        self.links = links
        self.text = text
        self.scriptCount = scriptCount
        self.metaRefresh = metaRefresh
    }

    /// Alle bedienbaren Elemente (ohne Hidden Fields), in Dokumentreihenfolge der Formulare, dann Links.
    public var interactiveControls: [PortalControl] {
        forms.flatMap { $0.controls.filter { !$0.isHidden } } + links
    }

    public func control(id elementId: String) -> PortalControl? {
        for form in forms {
            if let c = form.controls.first(where: { $0.elementId == elementId }) { return c }
        }
        return links.first { $0.elementId == elementId }
    }

    public func form(containing elementId: String) -> PortalForm? {
        forms.first { form in form.controls.contains { $0.elementId == elementId } }
    }

    /// Keine bedienbaren Elemente, aber Skripte: Das Portal braucht JavaScript (01 §17.3, Gate S11).
    public var requiresJavaScript: Bool {
        interactiveControls.isEmpty && metaRefresh == nil && scriptCount > 0
    }

    /// Text inklusive Titel, kleingeschrieben, für Stage-Erkennung.
    public var searchableText: String { (title + " " + text).lowercased() }
}

public struct PortalForm: Sendable, Equatable {
    public var index: Int
    public var htmlId: String?
    public var method: String
    public var action: URL
    public var controls: [PortalControl]

    public init(index: Int, htmlId: String? = nil, method: String, action: URL, controls: [PortalControl]) {
        self.index = index
        self.htmlId = htmlId
        self.method = method
        self.action = action
        self.controls = controls
    }

    public var submitButtons: [PortalControl] { controls.filter(\.isSubmit) }
}

public struct PortalControl: Sendable, Equatable, Identifiable {
    public struct Option: Sendable, Equatable {
        public var label: String
        public var value: String
        public var selected: Bool

        public init(label: String, value: String, selected: Bool) {
            self.label = label
            self.value = value
            self.selected = selected
        }
    }

    /// Seitenlokale ID (`e1`, `e2`, … für bedienbare Elemente, `h1`, … für Hidden Fields).
    public var elementId: String
    public var tag: String
    /// `nil` für Hidden Fields.
    public var role: ElementRole?
    public var inputType: String?
    public var name: String?
    public var htmlId: String?
    public var value: String?
    public var checked: Bool
    public var required: Bool
    public var disabled: Bool
    public var label: String?
    public var ariaLabel: String?
    public var placeholder: String?
    public var autocomplete: String?
    /// Sichtbarer Text von Buttons und Links.
    public var text: String?
    public var href: URL?
    public var options: [Option]
    public var nearbyText: String?
    public var formIndex: Int?
    public var isSubmit: Bool
    public var concept: Concept?

    public var id: String { elementId }
    public var isHidden: Bool { role == nil }

    public init(elementId: String, tag: String, role: ElementRole?, inputType: String? = nil, name: String? = nil,
                htmlId: String? = nil, value: String? = nil, checked: Bool = false, required: Bool = false,
                disabled: Bool = false, label: String? = nil, ariaLabel: String? = nil, placeholder: String? = nil,
                autocomplete: String? = nil, text: String? = nil, href: URL? = nil, options: [Option] = [],
                nearbyText: String? = nil, formIndex: Int? = nil, isSubmit: Bool = false, concept: Concept? = nil) {
        self.elementId = elementId
        self.tag = tag
        self.role = role
        self.inputType = inputType
        self.name = name
        self.htmlId = htmlId
        self.value = value
        self.checked = checked
        self.required = required
        self.disabled = disabled
        self.label = label
        self.ariaLabel = ariaLabel
        self.placeholder = placeholder
        self.autocomplete = autocomplete
        self.text = text
        self.href = href
        self.options = options
        self.nearbyText = nearbyText
        self.formIndex = formIndex
        self.isSubmit = isSubmit
        self.concept = concept
    }

    /// Alle für Menschen sichtbaren Beschriftungen (für Matcher und Consent-Prüfung).
    public var captions: [String] {
        var result: [String] = []
        for caption in [label, ariaLabel, text, placeholder] {
            if let caption, !caption.isEmpty { result.append(caption) }
        }
        if isSubmit, tag == "input", let value, !value.isEmpty { result.append(value) }
        return result
    }

    /// Beschriftungen plus technische Namen.
    public var descriptors: [String] {
        var result = captions
        for extra in [name, htmlId, nearbyText] {
            if let extra, !extra.isEmpty { result.append(extra) }
        }
        return result
    }
}
