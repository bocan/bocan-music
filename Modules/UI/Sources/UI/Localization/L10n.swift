import SwiftUI

// MARK: - Localization helpers

/// Helpers that resolve user-facing copy against the UI module's String Catalog
/// (`Resources/Localizable.xcstrings`).
///
/// SwiftUI's `LocalizedStringKey` lookups — `Text("…")`, `.navigationTitle("…")`,
/// `.help("…")`, `Button("…")` and friends — resolve against `Bundle.main` by
/// default. Because this UI lives in an SPM module whose catalog ships in
/// `Bundle.module`, literals must be resolved against `.module` explicitly or a
/// translated locale never takes effect. These helpers centralise that so call
/// sites stay readable and localization actually works (#314).
///
/// Usage:
/// - `Text(localized: "Albums")` for SwiftUI text.
/// - `L10n.string("Play \(count) Albums")` for APIs that take a plain `String`
///   or a bundle-less `LocalizedStringKey` (`.navigationTitle`, `.help`, alerts).
enum L10n {
    /// Resolves `key` from the module catalog to a `String`.
    static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }
}

extension Text {
    /// A `Text` whose key is resolved against the UI module's String Catalog (#314).
    init(localized key: LocalizedStringKey) {
        self.init(key, bundle: .module)
    }
}
