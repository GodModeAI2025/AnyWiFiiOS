import Foundation
import SwiftSoup

/// Ersetzt sensible Werte durch Platzhalter (01 §22.2). Bekannte Werte aus dem Lauf werden in
/// allen gängigen Kodierungen entfernt, zusätzlich Cookie-/Authorization-Zeilen.
public struct Redactor: Sendable {
    private let replacements: [(needle: String, placeholder: String)]

    public init(values: [SensitiveValue]) {
        var list: [(String, String)] = []
        for v in values where !v.value.isEmpty {
            var variants: Set<String> = [v.value]
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._*")
            if let enc = v.value.addingPercentEncoding(withAllowedCharacters: allowed) {
                variants.insert(enc)
                variants.insert(enc.replacingOccurrences(of: "%20", with: "+"))
            }
            variants.insert(v.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v.value)
            variants.insert(Self.htmlEscape(v.value))
            variants.insert(Self.jsonEscape(v.value))
            if v.placeholder == "<cookie>", let eq = v.value.firstIndex(of: "=") {
                let rest = String(v.value[v.value.index(after: eq)...])
                if !rest.isEmpty { variants.insert(rest) }
            }
            for variant in variants where !variant.isEmpty { list.append((variant, v.placeholder)) }
        }
        // Längste zuerst, damit Teilstrings längere Treffer nicht zerlegen.
        replacements = list.sorted { $0.0.count > $1.0.count }
    }

    public static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    static func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    public func redact(_ text: String) -> String {
        var out = Self.scrubHeaderLines(text)
        for r in replacements { out = out.replacingOccurrences(of: r.needle, with: r.placeholder) }
        return out
    }

    private static let headerPattern = try! NSRegularExpression(
        pattern: #"(?im)^\s*(set-cookie|cookie|authorization|proxy-authorization)\s*[:=].*$"#)

    static func scrubHeaderLines(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return headerPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "$1: <cookie>")
    }

    /// Roh-HTML für das Debug-Paket: Formularwerte, Hidden-Werte und Cookies entfernt, max. 1 MB.
    public func redactHTML(_ html: String) -> String {
        let clipped = html.utf8.count > 1_048_576 ? String(decoding: Array(html.utf8.prefix(1_048_576)), as: UTF8.self) : html
        guard let doc = try? SwiftSoup.parse(clipped) else { return redact(clipped) }
        for el in (try? doc.select("input"))?.array() ?? [] {
            let type = ((try? el.attr("type")) ?? "").lowercased()
            if ["submit", "button", "checkbox", "radio", "reset", "image"].contains(type) { continue }
            if el.hasAttr("value") { _ = try? el.attr("value", type == "hidden" ? "<hidden>" : "") }
        }
        for el in (try? doc.select("textarea"))?.array() ?? [] { _ = try? el.text("") }
        for el in (try? doc.select("meta[name~=(?i)csrf|token]"))?.array() ?? [] { _ = try? el.attr("content", "<hidden>") }
        let out = (try? doc.outerHtml()) ?? clipped
        return redact(out)
    }
}
