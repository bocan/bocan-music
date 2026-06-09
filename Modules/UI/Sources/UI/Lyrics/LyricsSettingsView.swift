import Library
import SwiftUI

// MARK: - LyricsSettingsView

/// Settings tab for all lyrics-related preferences.
public struct LyricsSettingsView: View {
    // MARK: - Preferences

    @AppStorage("lyrics.autoShowPane") private var autoShowPane = false
    @AppStorage("lyrics.fontSize") private var fontSizeDefault: LyricsFontSize = .medium
    @AppStorage("lyrics.sourcePriority") private var sourcePriority: LyricsSourcePriority = .preferSynced
    @AppStorage("lyrics.lrclibEnabled") private var lrclibEnabled = false
    @AppStorage("lyrics.embedOnSave") private var embedOnSave = false

    public init() {}

    // MARK: - Body

    public var body: some View {
        Form {
            Section(L10n.string("Display")) {
                Toggle(L10n.string("Show lyrics pane when a track has lyrics"), isOn: self.$autoShowPane)

                Picker(L10n.string("Default font size"), selection: self.$fontSizeDefault) {
                    ForEach(LyricsFontSize.allCases, id: \.self) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(L10n.string("Source priority")) {
                Picker(L10n.string("When multiple sources exist"), selection: self.$sourcePriority) {
                    ForEach(LyricsSourcePriority.allCases, id: \.self) { priority in
                        Text(Self.label(for: priority)).tag(priority)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section(L10n.string("LRClib (opt-in)")) {
                Toggle(L10n.string("Fetch lyrics from LRClib.net"), isOn: self.$lrclibEnabled)
                Text(self.lrclibFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.string("Saving")) {
                Toggle(L10n.string("Write lyrics back into audio files when saving"), isOn: self.$embedOnSave)
                    .help(L10n.string("Embeds user-edited lyrics as USLT / Vorbis LYRICS tags. Requires file write access."))
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 400, minHeight: 340)
    }

    /// Multi-sentence footer as sentence keys joined in code (#314).
    private var lrclibFooter: String {
        L10n.string("Fetched lyrics may be copyrighted; opt-in use is your responsibility.")
            + " " + L10n.string("LRClib is a community-maintained database.")
    }

    /// UI-side localized labels for the Library-owned priority enum, so the
    /// Library module stays free of UI catalog lookups (#314).
    private static func label(for priority: LyricsSourcePriority) -> String {
        switch priority {
        case .preferEmbedded:
            L10n.string("Prefer embedded tags")

        case .preferSynced:
            L10n.string("Prefer synced (sidecar .lrc)")

        case .preferUser:
            L10n.string("Prefer my edits")
        }
    }
}
