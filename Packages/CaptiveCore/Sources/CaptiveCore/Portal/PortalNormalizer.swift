import Foundation
import SwiftSoup

/// Reduziert eine Portalseite deterministisch auf das, was für Captive-Portal-Automation relevant ist (01 §11).
/// Einziger Ort, der den HTML-Parser kennt (01 §17.2).
public enum PortalNormalizer {
    public static let maxTextLength = 4000
    public static let maxNearbyTextLength = 80
    public static let maxMetaRefreshDelay = 5.0

    public static func normalize(html: String, url: URL) throws -> PortalPage {
        let doc = try SwiftSoup.parse(html, url.absoluteString)

        var labelFor: [String: String] = [:]
        for label in try doc.select("label").array() {
            let target = (try? label.attr("for")) ?? ""
            if !target.isEmpty, let text = clean(try? label.text()) {
                labelFor[target] = text
            }
        }

        var ids = IDCounter()
        var forms: [PortalForm] = []
        for (index, formElement) in try doc.select("form").array().enumerated() {
            let method = ((try? formElement.attr("method")) ?? "").uppercased() == "POST" ? "POST" : "GET"
            let action = resolve((try? formElement.attr("action")) ?? "", base: url) ?? url
            var controls: [PortalControl] = []
            for element in try formElement.select("input, button, select, textarea").array() {
                if let control = makeControl(element, formIndex: index, labelFor: labelFor, base: url, ids: &ids) {
                    controls.append(control)
                }
            }
            forms.append(PortalForm(index: index, htmlId: clean(formElement.id()), method: method,
                                    action: action, controls: controls))
        }

        var links: [PortalControl] = []
        for anchor in try doc.select("a[href]").array() where !isInsideForm(anchor) {
            let href = (try? anchor.attr("href")) ?? ""
            guard let target = resolve(href, base: url), let text = clean(try? anchor.text()) else { continue }
            var link = PortalControl(elementId: ids.nextVisible(), tag: "a", role: .link,
                                     htmlId: clean(anchor.id()), text: text, href: target)
            link.ariaLabel = clean(try? anchor.attr("aria-label"))
            links.append(link)
        }

        let title = clean(try? doc.title()) ?? ""
        let bodyText = (try? doc.body()?.text()) ?? nil
        let text = String((clean(bodyText) ?? "").prefix(maxTextLength))
        let scriptCount = (try? doc.select("script").array().count) ?? 0

        return PortalPage(url: url, title: title, forms: forms, links: links, text: text,
                          scriptCount: scriptCount, metaRefresh: metaRefreshTarget(doc, base: url))
    }

    // MARK: - Controls

    private static func makeControl(_ element: Element, formIndex: Int, labelFor: [String: String],
                                    base: URL, ids: inout IDCounter) -> PortalControl? {
        let tag = element.tagName().lowercased()
        let type = ((try? element.attr("type")) ?? "").lowercased()

        var role: ElementRole?
        var isSubmit = false
        switch tag {
        case "input":
            switch type {
            case "hidden": role = nil
            case "checkbox": role = .checkbox
            case "radio": role = .radio
            case "submit", "image": role = .button; isSubmit = true
            case "button", "reset": role = .button
            case "password": role = .passwordField
            case "file": return nil
            default: role = .textField
            }
        case "button":
            role = .button
            isSubmit = type.isEmpty || type == "submit"
        case "select":
            role = .select
        case "textarea":
            role = .textField
        default:
            return nil
        }

        let htmlId = clean(element.id())
        var control = PortalControl(
            elementId: role == nil ? ids.nextHidden() : ids.nextVisible(),
            tag: tag, role: role,
            inputType: tag == "input" ? (type.isEmpty ? "text" : type) : nil,
            name: clean(try? element.attr("name")),
            htmlId: htmlId,
            checked: element.hasAttr("checked"),
            required: element.hasAttr("required"),
            disabled: element.hasAttr("disabled"),
            formIndex: formIndex,
            isSubmit: isSubmit
        )

        if tag == "select" {
            control.options = options(of: element)
            control.value = (control.options.first(where: \.selected) ?? control.options.first)?.value
        } else if tag == "textarea" {
            control.value = (try? element.text()) ?? ""
        } else if element.hasAttr("value") {
            control.value = (try? element.attr("value")) ?? ""
        }

        if role != nil {
            control.label = htmlId.flatMap { labelFor[$0] } ?? enclosingLabelText(element)
            control.ariaLabel = clean(try? element.attr("aria-label"))
            control.placeholder = clean(try? element.attr("placeholder"))
            control.autocomplete = clean(try? element.attr("autocomplete"))
            if tag == "button" {
                control.text = clean(try? element.text())
            } else if isSubmit || type == "button" {
                control.text = clean(control.value)
            }
            control.nearbyText = nearbyText(element)
            control.concept = ConceptClassifier.classify(control)
        }
        return control
    }

    private static func options(of select: Element) -> [PortalControl.Option] {
        guard let elements = try? select.select("option").array() else { return [] }
        return elements.map { option in
            let label = clean(try? option.text()) ?? ""
            let value = option.hasAttr("value") ? ((try? option.attr("value")) ?? "") : label
            return PortalControl.Option(label: label, value: value, selected: option.hasAttr("selected"))
        }
    }

    /// Text eines umschließenden `<label>` (z. B. `<label><input type=checkbox> Ich akzeptiere …</label>`).
    private static func enclosingLabelText(_ element: Element) -> String? {
        var current = element.parent()
        var depth = 0
        while let node = current, depth < 4 {
            if node.tagName().lowercased() == "label" { return clean(try? node.text()) }
            if node.tagName().lowercased() == "form" { return nil }
            current = node.parent()
            depth += 1
        }
        return nil
    }

    /// Unmittelbar vorangehendes Nicht-Formular-Element mit kurzem Text (01 §10 „nearbyText“, Gate S7 Variante C).
    private static func nearbyText(_ element: Element) -> String? {
        guard let previous = (try? element.previousElementSibling()) ?? nil else { return nil }
        let tag = previous.tagName().lowercased()
        guard !["input", "select", "textarea", "button", "label", "br", "script", "style"].contains(tag) else {
            return nil
        }
        guard let text = clean(try? previous.text()), text.count <= maxNearbyTextLength else { return nil }
        return text
    }

    private static func isInsideForm(_ element: Element) -> Bool {
        var current = element.parent()
        while let node = current {
            if node.tagName().lowercased() == "form" { return true }
            current = node.parent()
        }
        return false
    }

    // MARK: - Hilfen

    private static func metaRefreshTarget(_ doc: Document, base: URL) -> URL? {
        guard let metas = try? doc.select("meta").array() else { return nil }
        for meta in metas where ((try? meta.attr("http-equiv")) ?? "").lowercased() == "refresh" {
            let content = (try? meta.attr("content")) ?? ""
            let parts = content.split(separator: ";", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let delay = Double(parts.first ?? ""), delay <= maxMetaRefreshDelay, parts.count == 2 else { continue }
            var target = parts[1]
            if target.lowercased().hasPrefix("url=") { target = String(target.dropFirst(4)) }
            target = target.trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
            if let url = resolve(target, base: base) { return url }
        }
        return nil
    }

    /// Löst relative URLs auf. Nur http/https, kein `javascript:` oder `data:`.
    static func resolve(_ raw: String, base: URL) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return base }
        if trimmed.hasPrefix("#") { return nil }
        let escaped = trimmed.replacingOccurrences(of: " ", with: "%20")
        guard let url = URL(string: escaped, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// Whitespace zusammenfassen, leere Strings → nil.
    static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    struct IDCounter {
        private var visible = 0
        private var hidden = 0
        mutating func nextVisible() -> String { visible += 1; return "e\(visible)" }
        mutating func nextHidden() -> String { hidden += 1; return "h\(hidden)" }
    }
}
