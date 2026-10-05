import Foundation
import SwiftSoup

/// Reduziert HTML deterministisch auf das für Captive-Portal-Automation Relevante (01 §11).
/// Kein Produktcode außerhalb dieser Datei hängt von SwiftSoup-Typen ab (01 §17.2).
public enum PortalNormalizer {
    public static let maxHTMLBytes = 1_048_576
    public static let maxTextLength = 2000

    public static func normalize(html: String, url: URL, status: Int = 200,
                                 redirectChain: [String] = []) -> NormalizedPage {
        let clipped = html.utf8.count > maxHTMLBytes
            ? String(decoding: Array(html.utf8.prefix(maxHTMLBytes)), as: UTF8.self) : html
        guard let doc = try? SwiftSoup.parse(clipped, url.absoluteString) else {
            return NormalizedPage(url: url.absoluteString, host: url.host ?? "", title: "", status: status,
                                  forms: [], links: [], text: "", hasScripts: false, hasCaptcha: false,
                                  redirectChain: redirectChain)
        }
        let lower = clipped.lowercased()
        let hasCaptcha = lower.contains("g-recaptcha") || lower.contains("h-captcha")
            || lower.contains("hcaptcha") || lower.contains("cf-turnstile") || lower.contains("captcha")
        let scripts = (try? doc.select("script"))?.size() ?? 0
        let hasScripts = scripts > 0

        let title = (try? doc.title()) ?? ""

        // Label-Index
        var labelFor: [String: String] = [:]
        for l in (try? doc.select("label[for]"))?.array() ?? [] {
            if let f = try? l.attr("for"), let t = try? l.text(), !f.isEmpty { labelFor[f] = collapse(t) }
        }

        var counter = 0
        var typeCounts: [String: Int] = [:]
        var controlsByForm: [(formEl: Element?, control: NormalizedControl)] = []
        let all = (try? doc.select("input, button, select, textarea"))?.array() ?? []
        for el in all {
            let tag = el.tagName().lowercased()
            let type = ((try? el.attr("type")) ?? "").lowercased()
            guard let role = role(tag: tag, type: type) else { continue }
            if tag == "input", ["image", "reset"].contains(type) { continue }
            counter += 1
            let name = nonEmpty(try? el.attr("name"))
            let htmlId = nonEmpty(try? el.attr("id"))
            let aria = ariaLabel(el, doc: doc)
            let label = labelText(el, htmlId: htmlId, labelFor: labelFor)
            let placeholder = nonEmpty(try? el.attr("placeholder"))
            let autocomplete = nonEmpty(try? el.attr("autocomplete"))
            let isButton = role == .button
            let btnText: String? = {
                guard isButton else { return nil }
                if tag == "button" { return nonEmpty(try? el.text()) ?? nonEmpty(try? el.attr("value")) }
                return nonEmpty(try? el.attr("value"))
            }()
            let nearby = role == .hidden || isButton ? nil : nearbyText(el, hasLabel: label != nil)
            var options: [SelectOption] = []
            if tag == "select" {
                for o in (try? el.select("option"))?.array() ?? [] {
                    let text = collapse((try? o.text()) ?? "")
                    let v = (try? o.attr("value")).flatMap { o.hasAttr("value") ? $0 : nil } ?? text
                    options.append(SelectOption(value: v, text: text, selected: o.hasAttr("selected")))
                }
            }
            let key = role == .hidden ? "hidden" : role.rawValue
            let ordinal = typeCounts[key, default: 0]
            typeCounts[key] = ordinal + 1
            let value: String? = {
                if tag == "textarea" { return (try? el.text()) }
                return el.hasAttr("value") ? (try? el.attr("value")) : nil
            }()
            var control = NormalizedControl(
                elementId: "e\(counter)", role: role, tag: tag, inputType: type.isEmpty ? nil : type,
                name: name, htmlId: htmlId, label: label, text: btnText, placeholder: placeholder,
                ariaLabel: aria, autocomplete: autocomplete, nearbyText: nearby, value: value,
                required: el.hasAttr("required") || (try? el.attr("aria-required")) == "true",
                checked: el.hasAttr("checked"),
                submit: isButton && (tag == "button" ? (type.isEmpty || type == "submit") : type == "submit"),
                options: options, concept: nil, selector: selector(el, tag: tag, name: name, htmlId: htmlId),
                ordinal: ordinal)
            control.concept = ConceptInference.concept(for: control)
            controlsByForm.append((enclosingForm(el), control))
        }

        // Formulare in Dokumentreihenfolge; Controls außerhalb eines Formulars landen in "_page".
        var forms: [NormalizedForm] = []
        var formIndex: [ObjectIdentifier: Int] = [:]
        var orphan: [NormalizedControl] = []
        for f in (try? doc.select("form"))?.array() ?? [] {
            formIndex[ObjectIdentifier(f)] = forms.count
            let id = nonEmpty(try? f.attr("id")) ?? nonEmpty(try? f.attr("name")) ?? "form\(forms.count + 1)"
            let method = ((try? f.attr("method")) ?? "get").lowercased()
            forms.append(NormalizedForm(id: id, method: method == "post" ? "POST" : "GET",
                                        action: (try? f.attr("action")) ?? "",
                                        enctype: nonEmpty(try? f.attr("enctype")), controls: []))
        }
        for (formEl, c) in controlsByForm {
            if let formEl, let i = formIndex[ObjectIdentifier(formEl)] { forms[i].controls.append(c) }
            else { orphan.append(c) }
        }
        forms = forms.filter { !$0.controls.isEmpty }
        if !orphan.isEmpty {
            forms.append(NormalizedForm(id: "_page", method: "GET", action: "", enctype: nil, controls: orphan))
        }

        var links: [NormalizedLink] = []
        for a in (try? doc.select("a[href]"))?.array() ?? [] {
            let href = (try? a.attr("href")) ?? ""
            let text = collapse((try? a.text()) ?? "")
            guard !href.isEmpty, !href.lowercased().hasPrefix("javascript:"), !href.hasPrefix("#") else { continue }
            counter += 1
            links.append(NormalizedLink(elementId: "e\(counter)", text: text, href: href))
        }

        _ = try? doc.select("script, style, noscript, svg").remove()
        var text = collapse((try? doc.body()?.text()) ?? "")
        if text.count > maxTextLength { text = String(text.prefix(maxTextLength)) }

        return NormalizedPage(url: url.absoluteString, host: url.host ?? "", title: collapse(title), status: status,
                              forms: forms, links: links, text: text, hasScripts: hasScripts,
                              hasCaptcha: hasCaptcha, redirectChain: redirectChain)
    }

    // MARK: Helfer

    private static func role(tag: String, type: String) -> ControlRole? {
        switch tag {
        case "button": return .button
        case "select": return .select
        case "textarea": return .textArea
        case "input":
            switch type {
            case "hidden": return .hidden
            case "password": return .password
            case "checkbox": return .checkbox
            case "radio": return .radio
            case "submit", "button": return .button
            case "file": return nil
            default: return .textField
            }
        default: return nil
        }
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0 == "\u{00A0}" }).joined(separator: " ")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s else { return nil }
        let c = collapse(s)
        return c.isEmpty ? nil : c
    }

    private static func enclosingForm(_ el: Element) -> Element? {
        var p = el.parent()
        while let cur = p {
            if cur.tagName().lowercased() == "form" { return cur }
            p = cur.parent()
        }
        return nil
    }

    private static func ariaLabel(_ el: Element, doc: Document) -> String? {
        if let a = nonEmpty(try? el.attr("aria-label")) { return a }
        if let ids = nonEmpty(try? el.attr("aria-labelledby")) {
            let texts = ids.split(separator: " ").compactMap { id -> String? in
                guard let t = try? doc.getElementById(String(id))?.text() else { return nil }
                return nonEmpty(t)
            }
            if !texts.isEmpty { return texts.joined(separator: " ") }
        }
        return nil
    }

    private static func labelText(_ el: Element, htmlId: String?, labelFor: [String: String]) -> String? {
        if let id = htmlId, let t = labelFor[id], !t.isEmpty { return t }
        var p = el.parent()
        while let cur = p {
            if cur.tagName().lowercased() == "label" { return nonEmpty(try? cur.text()) }
            p = cur.parent()
        }
        return nil
    }

    /// Kurzer Text in direkter Umgebung (vorheriges Geschwister, bei Checkboxen auch das nächste).
    private static func nearbyText(_ el: Element, hasLabel: Bool) -> String? {
        var parts: [String] = []
        func text(of node: Node) -> String? {
            if let t = node as? TextNode { return nonEmpty(t.text()) }
            if let e = node as? Element {
                let tag = e.tagName().lowercased()
                if ["input", "button", "select", "textarea", "script", "style"].contains(tag) { return nil }
                return nonEmpty(try? e.text())
            }
            return nil
        }
        var node: Node? = el
        var hops = 0
        // zuerst Geschwister vor dem Element, dann vor dem Elternelement
        while hops < 2, let n = node {
            if let prev = n.previousSibling(), let t = text(of: prev) { parts.append(t); break }
            node = n.parent()
            hops += 1
        }
        if !hasLabel, ((try? el.attr("type")) ?? "") == "checkbox", let next = el.nextSibling(), let t = text(of: next) {
            parts.append(t)
        }
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: " ")
        return joined.count > 80 ? String(joined.prefix(80)) : joined
    }

    private static func selector(_ el: Element, tag: String, name: String?, htmlId: String?) -> String {
        if let htmlId { return "\(tag)#\(htmlId)" }
        if let name { return "\(tag)[name=\(name)]" }
        return tag
    }
}
