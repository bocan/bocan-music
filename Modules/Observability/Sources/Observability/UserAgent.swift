import Foundation

/// The single source of truth for the `User-Agent` header on every first-party
/// Bòcan HTTP request (feed fetches, podcast search, artwork, MusicBrainz, Cover
/// Art Archive, AcoustID, LRClib, episode downloads).
///
/// Design rules, applied consistently everywhere:
/// - The version is the app's real marketing version (`CFBundleShortVersionString`),
///   read at runtime, never hardcoded.
/// - It points at the GitHub project first, then the app website. It references
///   no other domain.
/// - The product token is ASCII `Bocan`, not the display name `Bòcan`. HTTP header
///   field values are US-ASCII (RFC 9110); a non-ASCII byte gets dropped or mangled
///   by proxies and strict servers (MusicBrainz being the notable one), so the
///   accented name is unsafe on the wire even though the app is "Bòcan" in the UI.
/// - The shape is `Name/Version ( contact )`, which satisfies the MusicBrainz /
///   Cover Art Archive User-Agent policy, so one string is valid for every caller.
public enum UserAgent {
    /// The app's marketing version, e.g. "1.10.0".
    ///
    /// Falls back to "dev" outside an app bundle (unit tests, SwiftUI previews),
    /// so the token is never an empty or "0" version.
    public static let appVersion: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    /// The canonical `User-Agent` header value for all first-party requests.
    ///
    /// Example: `Bocan/1.10.0 ( https://github.com/bocan/bocan-music https://bocan.app )`.
    public static let string =
        "Bocan/\(Self.appVersion) ( https://github.com/bocan/bocan-music https://bocan.app )"
}
