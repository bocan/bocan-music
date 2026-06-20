import Foundation
import Testing
@testable import UI

@Suite("FundingLink")
struct FundingLinkTests {
    @Test("nil, empty, and whitespace input yield nil")
    func emptyInputs() {
        #expect(FundingLink(rawURL: nil, label: nil) == nil)
        #expect(FundingLink(rawURL: "", label: nil) == nil)
        #expect(FundingLink(rawURL: "   ", label: nil) == nil)
    }

    @Test("non-http schemes are rejected (the trust boundary)")
    func rejectsNonHTTP() {
        #expect(FundingLink(rawURL: "javascript:alert(1)", label: nil) == nil)
        #expect(FundingLink(rawURL: "file:///etc/passwd", label: nil) == nil)
        #expect(FundingLink(rawURL: "ftp://host/x", label: nil) == nil)
        #expect(FundingLink(rawURL: "mailto:a@b.com", label: nil) == nil)
    }

    @Test("http and https with a host are accepted; host is lowercased")
    func acceptsWebURLs() throws {
        let http = try #require(FundingLink(rawURL: "http://example.com/give", label: nil))
        #expect(http.host == "example.com")
        let https = try #require(FundingLink(rawURL: "HTTPS://Example.COM/give", label: nil))
        #expect(https.host == "example.com")
    }

    @Test("a hostless URL is rejected")
    func rejectsHostless() {
        #expect(FundingLink(rawURL: "https:///path", label: nil) == nil)
    }

    @Test("label is carried verbatim when present, normalized to nil when empty")
    func labelNormalization() throws {
        let withLabel = try #require(FundingLink(rawURL: "https://example.com", label: "Support us"))
        #expect(withLabel.label == "Support us")
        let emptyLabel = try #require(FundingLink(rawURL: "https://example.com", label: ""))
        #expect(emptyLabel.label == nil)
    }
}
