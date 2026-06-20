import AppKit
import Foundation

/// A validated funding link parsed from a show's Podcasting 2.0 `podcast:funding`
/// URL.
///
/// The failable initializer is the trust boundary: the URL is untrusted feed
/// content, so only `http`/`https` links with a host produce a value. Parsing and
/// the external open both live here, so the view stays declarative and this logic
/// is unit-testable without a view tree.
struct FundingLink: Equatable {
    /// Already validated as `http`/`https` with a non-empty host.
    let url: URL
    /// The lowercased host, shown in the confirmation dialog (not the full URL).
    let host: String
    /// The feed-supplied label (`fundingText`), rendered verbatim; nil when absent.
    let label: String?

    /// Fails for nil/empty/whitespace input, unparseable URLs, or any scheme that
    /// is not `http`/`https`.
    init?(rawURL: String?, label: String?) {
        guard let rawURL else { return nil }
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty else { return nil }
        self.url = url
        self.host = host.lowercased()
        self.label = (label?.isEmpty == false) ? label : nil
    }

    /// Opens the link in the user's default browser. UI already opens external
    /// links this way; no new entitlement is required.
    @MainActor
    func open() {
        NSWorkspace.shared.open(self.url)
    }
}
