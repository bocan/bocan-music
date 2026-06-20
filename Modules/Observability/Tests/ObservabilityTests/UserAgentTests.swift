import Foundation
import Testing
@testable import Observability

@Suite("UserAgent")
struct UserAgentTests {
    @Test("UA starts with the ASCII Bocan product token and the app version")
    func productToken() {
        #expect(UserAgent.string.hasPrefix("Bocan/\(UserAgent.appVersion)"))
    }

    @Test("UA references the GitHub project, then the app website")
    func pointsAtGitHubThenWebsite() throws {
        let ua = UserAgent.string
        let github = try #require(ua.range(of: "https://github.com/bocan/bocan-music"))
        let website = try #require(ua.range(of: "https://bocan.app"))
        #expect(github.lowerBound < website.lowerBound, "GitHub URL must come before the app website")
    }

    @Test("UA never references cloudcauldron or the old Podcast-Reader token")
    func noLegacyReferences() {
        #expect(!UserAgent.string.contains("cloudcauldron"))
        #expect(!UserAgent.string.contains("Podcast-Reader"))
    }

    @Test("UA is pure ASCII so it survives HTTP header transport")
    func isASCII() {
        let allASCII = UserAgent.string.allSatisfy(\.isASCII)
        #expect(allASCII)
        // The accented display name must not leak onto the wire.
        #expect(!UserAgent.string.contains("Bòcan"))
    }

    @Test("UA follows the Name/Version ( contact ) shape required by MusicBrainz")
    func musicBrainzShape() {
        let ua = UserAgent.string
        #expect(ua.contains("/"))
        #expect(ua.contains(" ( "))
        #expect(ua.hasSuffix(" )"))
    }
}
