import AudioEngine

// MARK: - EQPreset display name

extension EQPreset {
    /// Localized display name. Built-in factory presets translate through the
    /// module catalog, keyed on their persisted English name ("Flat", "Rock",
    /// ...); user presets render their stored name verbatim. The persisted
    /// `name` stays English so preset data is locale-stable.
    var displayName: String {
        self.isBuiltIn ? L10n.string(String.LocalizationValue(self.name)) : self.name
    }
}
