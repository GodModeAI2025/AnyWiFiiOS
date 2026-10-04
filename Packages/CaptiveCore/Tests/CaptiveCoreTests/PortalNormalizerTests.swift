import Foundation
import XCTest
@testable import CaptiveCore

/// Gate S7 (02 §13) und Normalizer-Grundverhalten (01 §11).
final class PortalNormalizerTests: XCTestCase {
    private let base = URL(string: "http://portal.test/login?mac=02:00:00:00:00:01")!

    private func page(_ html: String) throws -> PortalPage {
        try PortalNormalizer.normalize(html: html, url: base)
    }

    private func fixture(_ name: String) throws -> PortalPage {
        try PortalNormalizer.normalize(html: FakePortal.fixtureHTML(name), url: base)
    }

    func testRoomNumberVariantsMapToSameConcept() throws {
        let variants = [
            #"<form><label for="room">Room Number</label><input id="room" name="room"></form>"#,
            #"<form><input name="room_no" placeholder="Zimmernummer"></form>"#,
            #"<form><div>Room</div><input aria-label="Room number"></form>"#,
        ]
        for html in variants {
            let controls = try page(html).interactiveControls
            XCTAssertEqual(controls.count, 1, html)
            XCTAssertEqual(controls.first?.concept, .roomNumber, html)
        }
    }

    func testNearbyTextDoesNotOverrideOwnAttributes() throws {
        // 09: „Room“-Div steht vor dem Zimmerfeld, das Nachnamefeld hat eigenen Placeholder.
        let page = try fixture("09_multistage_guest")
        let concepts = page.interactiveControls.compactMap(\.concept)
        XCTAssertEqual(concepts, [.roomNumber, .lastName])
    }

    func testHotelFixtureStructure() throws {
        let page = try fixture("05_hotel")
        XCTAssertEqual(page.title, "Hotel Muster – Internet")
        XCTAssertEqual(page.forms.count, 1)
        let form = page.forms[0]
        XCTAssertEqual(form.method, "POST")
        XCTAssertEqual(form.action.absoluteString, "http://portal.test/auth")
        XCTAssertEqual(form.controls.filter(\.isHidden).map(\.name), ["fixture"])
        let visible = page.interactiveControls
        XCTAssertEqual(visible.map(\.elementId), ["e1", "e2", "e3"])
        XCTAssertEqual(visible.map(\.concept), [.roomNumber, .lastName, nil])
        XCTAssertEqual(visible[0].label, "Room number")
        XCTAssertEqual(visible[2].role, .button)
        XCTAssertTrue(visible[2].isSubmit)
        XCTAssertEqual(visible[2].text, "Connect")
    }

    func testCheckboxLabelsFromForAndWrappingLabel() throws {
        let terms = try fixture("03_terms_privacy").interactiveControls.filter { $0.role == .checkbox }
        XCTAssertEqual(terms.map(\.label), ["Ich akzeptiere die Datenschutzerklärung", "Ich akzeptiere die Nutzungsbedingungen"])
        let wrapped = try fixture("02_terms").interactiveControls.first { $0.role == .checkbox }
        XCTAssertEqual(wrapped?.label, "I accept the Terms of Use")
    }

    func testCredentialFieldsAreClassified() throws {
        XCTAssertEqual(try fixture("04_userpass").interactiveControls.compactMap(\.concept), [.username, .password])
        XCTAssertEqual(try fixture("06_voucher").interactiveControls.compactMap(\.concept), [.voucherCode])
        XCTAssertEqual(try fixture("07_email").interactiveControls.compactMap(\.concept), [.email])
        XCTAssertEqual(try fixture("11_hidden_csrf").interactiveControls.compactMap(\.concept), [.username, .password])
    }

    func testMalformedHtmlIsUsable() throws {
        let page = try fixture("15_malformed_html")
        let controls = page.interactiveControls
        XCTAssertEqual(controls.map(\.role), [.checkbox, .textField, .button])
        XCTAssertEqual(controls[0].label, "I accept the Terms")
        XCTAssertEqual(controls[1].concept, .roomNumber)
        XCTAssertEqual(controls[2].text, "Connect")
    }

    func testJavaScriptOnlyPortalsAreDetected() throws {
        XCTAssertTrue(try fixture("14_js_only").requiresJavaScript)
        XCTAssertTrue(try fixture("17_icomera_cna").requiresJavaScript)
        XCTAssertFalse(try fixture("01_clickthrough").requiresJavaScript)
    }

    func testEmptyActionUsesPageUrlIncludingQuery() throws {
        let page = try page(#"<form method="post"><button>Go</button></form>"#)
        XCTAssertEqual(page.forms[0].action, base)
    }

    func testMetaRefreshAndLinks() throws {
        let page = try page("""
        <meta http-equiv="refresh" content="0; url=/portal/start">
        <a href="javascript:void(0)">Nope</a>
        <a href="/terms">Terms</a>
        """)
        XCTAssertEqual(page.metaRefresh?.absoluteString, "http://portal.test/portal/start")
        XCTAssertEqual(page.links.map(\.text), ["Terms"])
    }

    func testTextIsCollapsedAndScriptsExcluded() throws {
        let page = try page("<p>Hello   \n  World</p><script>var secret = 1;</script>")
        XCTAssertEqual(page.text, "Hello World")
        XCTAssertEqual(page.scriptCount, 1)
    }

    func testSelectOptions() throws {
        let page = try page("""
        <form><select name="plan"><option value="free" selected>Kostenlos</option><option value="p">Premium 4,99 €</option></select></form>
        """)
        let select = page.interactiveControls[0]
        XCTAssertEqual(select.role, .select)
        XCTAssertEqual(select.value, "free")
        XCTAssertEqual(select.options.map(\.label), ["Kostenlos", "Premium 4,99 €"])
    }
}

final class ElementMatcherTests: XCTestCase {
    private func page(_ html: String) throws -> PortalPage {
        try PortalNormalizer.normalize(html: html, url: URL(string: "http://portal.test/")!)
    }

    func testAmbiguousButtonsAreAnErrorUnlessOrdinalGiven() throws {
        let p = try page("<form><button>Continue</button><button>Continue</button></form>")
        let target = Target(role: .button, labelAny: ["Continue"])
        XCTAssertEqual(ElementMatcher.resolve(target, in: p), .failure(.ambiguous(["e1", "e2"])))
        var withOrdinal = target
        withOrdinal.ordinal = 1
        XCTAssertEqual(try ElementMatcher.resolve(withOrdinal, in: p).get().control.elementId, "e2")
    }

    func testConceptMismatchExcludesCandidate() throws {
        let p = try page(#"<form><input name="room" placeholder="Room"><input name="lastname" placeholder="Last name"></form>"#)
        let target = Target(concept: .lastName, labelAny: ["Room"])
        XCTAssertEqual(try ElementMatcher.resolve(target, in: p).get().control.name, "lastname")
    }

    func testSelectorIsOnlyAFallback() throws {
        let p = try page(#"<form><input type="checkbox" id="agb"> <button>OK</button></form>"#)
        let target = Target(role: .checkbox, labelAny: ["Gibt es nicht"], lastKnownSelector: "#agb")
        XCTAssertEqual(try ElementMatcher.resolve(target, in: p).get().control.htmlId, "agb")
    }

    func testUnknownLabelIsNotFound() throws {
        let p = try page("<form><button>Join Wi-Fi</button></form>")
        XCTAssertEqual(ElementMatcher.resolve(Target(role: .button, labelAny: ["Connect"]), in: p), .failure(.notFound))
    }
}

final class PortalHTTPTests: XCTestCase {
    func testFormEncodingRoundTrip() {
        let pairs = [("a b", "c&d=e"), ("umlaut", "ü"), ("empty", "")]
        let encoded = FormEncoding.encode(pairs)
        XCTAssertEqual(encoded, "a+b=c%26d%3De&umlaut=%C3%BC&empty=")
        let decoded = FormEncoding.decode(encoded)
        XCTAssertEqual(decoded.map(\.0), pairs.map(\.0))
        XCTAssertEqual(decoded.map(\.1), pairs.map(\.1))
    }

    func testCookieJarScopesByDomain() {
        var jar = CookieJar()
        let portal = URL(string: "http://login.portal.test/x")!
        jar.store(setCookieHeaders: ["sid=1; Path=/; HttpOnly", "wide=2; Domain=.portal.test", "evil=3; Domain=other.test"], from: portal)
        XCTAssertEqual(jar.headerValue(for: portal), "sid=1; wide=2")
        XCTAssertEqual(jar.headerValue(for: URL(string: "http://cdn.portal.test/")!), "wide=2")
        XCTAssertNil(jar.headerValue(for: URL(string: "http://other.test/")!))
        jar.store(setCookieHeaders: ["sid=; Max-Age=0"], from: portal)
        XCTAssertEqual(jar.headerValue(for: portal), "wide=2")
    }

    func testFormDataIncludesOnlyTheSubmitter() throws {
        let page = try PortalNormalizer.normalize(html: FakePortal.fixtureHTML("13_paid_upgrade"),
                                                  url: URL(string: "http://portal.test/")!)
        let form = page.forms[0]
        let free = form.submitButtons.first { $0.text == "Continue with free Wi-Fi" }
        let terms = form.controls.first { $0.name == "terms" }!
        let pairs = RecipeRunner.formData(form, values: [:], checks: [terms.elementId: true], submitter: free)
        XCTAssertEqual(pairs.map(\.0), ["fixture", "terms", "tier"])
        XCTAssertEqual(pairs.last?.1, "free")
    }
}
