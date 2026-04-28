import Library
import SwiftUI

// MARK: - LyricsSettingsView

/// Settings tab for all lyrics-related preferences.
public struct LyricsSettingsView: View {
    // MARK: - Preferences

    @AppStorage("lyrics.autoShowPane") private var autoShowPane = false
    @AppStorage("lyrics.fontSizeDefault") private var fontSizeDefault: LyricsFontSize = .medium
    @AppStorage("lyrics.sourcePriority") private var sourcePriority: LyricsSourcePriority = .preferSynced
    @AppStorage("lyrics.lrclibEnabled") private var lrclibEnabled = false
    @AppStorage("lyrics.embedOnSave") private var embedOnSave = false

    public init() {}

    // MARK: - Body

    public var body: some View {
        Form {
            Section("Display") {
                Toggle("Show lyrics pane when a track has lyrics", isOn: self.$autoShowPane)

                Picker("Default font size", selection: self.$fontSizeDefault) {
                    ForEach(LyricsFontSize.allCases, id: \.self) { size in
                        Text(size.label).tag(size)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Source priority") {
                Picker("When multiple sources exist", selection: self.$sourcePriority) {
                    ForEach(LyricsSourcePriority.allCases, id: \.self) { priority in
                        Text(priority.displayName).tag(priority)
                    }
                }
                .pickerStyle(.radioGroup)
            }

            Section("LRClib (opt-in)") {
                Toggle("Fetch lyrics from LRClib.net", isOn: self.$lrclibEnabled)
                Text("Fetched lyrics may be copyrighted; opt-in use is your responsibility. LRClib is a community-maintained database.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Saving") {
                Toggle("Write lyrics back into audio files when saving", isOn: self.$embedOnSave)
                    .help("Embeds user-edited lyrics as USLT / Vorbis LYRICS tags. Requires file write access.")
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 400, minHeight: 340)
    }
}
