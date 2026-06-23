import Foundation
import Testing
@testable import UI

// MARK: - SafeHTMLRendererTests

/// `SafeHTMLRenderer` is a pure value transform, so it can be exercised directly
/// (no view tree). These cover the real-feed quirks that motivated replacing the
/// `NSAttributedString` importer: entity-escaped inline tags, named entities, and
/// untrusted link schemes.
@Suite("SafeHTMLRenderer")
struct SafeHTMLRendererTests {
    /// Plain text comes through with entities decoded and no stray markup.
    @Test("Decodes named and numeric entities in plain text")
    func decodesEntities() {
        let out = SafeHTMLRenderer.render("Dave &amp; @mitch &mdash; &#39;hi&#39; &#x2026;")
        #expect(String(out.characters) == "Dave & @mitch \u{2014} 'hi' \u{2026}")
    }

    /// The headline bug: tags entity-escaped inside otherwise-real HTML must render
    /// as formatting, not as literal "<b>" text.
    @Test("Renders entity-escaped inline tags as formatting, not literal text")
    func escapedInlineTagsFormat() {
        let out = SafeHTMLRenderer.render("<p>&lt;b&gt;Milestone:&lt;/b&gt; shipped</p>")
        let plain = String(out.characters)
        #expect(plain == "Milestone: shipped")
        #expect(!plain.contains("<b>"))
        // The "Milestone:" run carries strong emphasis; the rest does not.
        let strong = out.runs.first { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        #expect(strong.map { String(out[$0.range].characters) } == "Milestone:")
    }

    /// Real inline tags also format and the tags themselves are removed.
    @Test("Strips real inline tags and applies emphasis")
    func realInlineTags() {
        let out = SafeHTMLRenderer.render("<strong>Bold</strong> and <em>italic</em>")
        #expect(String(out.characters) == "Bold and italic")
        let bold = out.runs.first { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        #expect(bold.map { String(out[$0.range].characters) } == "Bold")
        let italic = out.runs.first { $0.inlinePresentationIntent?.contains(.emphasized) == true }
        #expect(italic.map { String(out[$0.range].characters) } == "italic")
    }

    /// http/https links are kept as links; other schemes are dropped to text.
    @Test("Keeps web links, drops unsafe schemes")
    func linkSafety() {
        let safe = SafeHTMLRenderer.render(#"<a href="https://example.com/x">site</a>"#)
        #expect(safe.runs.contains { $0.link?.absoluteString == "https://example.com/x" })

        let unsafe = SafeHTMLRenderer.render(#"<a href="javascript:alert(1)">click</a>"#)
        #expect(String(unsafe.characters) == "click")
        #expect(!unsafe.runs.contains { $0.link != nil })
    }

    /// Block tags become line breaks; list items get bullet/number prefixes.
    @Test("Lists and paragraphs produce readable line structure")
    func listsAndParagraphs() {
        let out = SafeHTMLRenderer.render("<p>Intro</p><ul><li>one</li><li>two</li></ul>")
        let plain = String(out.characters)
        #expect(plain.contains("Intro"))
        #expect(plain.contains("•  one"))
        #expect(plain.contains("•  two"))
        // No leading or trailing blank lines.
        #expect(!plain.hasPrefix("\n"))
        #expect(!plain.hasSuffix("\n"))
    }

    @Test("Ordered lists number their items")
    func orderedList() {
        let out = SafeHTMLRenderer.render("<ol><li>first</li><li>second</li></ol>")
        let plain = String(out.characters)
        #expect(plain.contains("1. first"))
        #expect(plain.contains("2. second"))
    }

    /// Disallowed tags (scripts, images, styled spans) are dropped, content kept.
    @Test("Drops scripts and unknown tags, keeps their safe text")
    func dropsUnsafeTags() {
        let out = SafeHTMLRenderer.render(
            #"<div><script>evil()</script><span style="color:red">visible</span><img src="x.jpg"></div>"#
        )
        let plain = String(out.characters)
        #expect(plain.contains("visible"))
        #expect(!plain.contains("evil"))
        #expect(out.runs.allSatisfy { $0.foregroundColor == nil })
    }

    @Test("Empty or whitespace-only input yields empty output")
    func emptyInput() {
        #expect(SafeHTMLRenderer.render("").characters.isEmpty)
        #expect(SafeHTMLRenderer.render("   \n  ").characters.isEmpty)
    }
}
