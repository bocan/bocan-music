import SwiftUI

// MARK: - PlaybackSettingsView

public struct PlaybackSettingsView: View {
    @AppStorage("playback.rate") private var rate = 1.0
    @AppStorage("playback.gaplessPrerollSeconds") private var prerollSeconds = 5.0
    @AppStorage("playback.sleepTimerFadeOut") private var sleepTimerFadeOut = false
    @AppStorage("playback.crossAlbumGapless") private var crossAlbumGapless = false

    public init() {}

    public var body: some View {
        Form {
            Section(L10n.string("Speed")) {
                HStack {
                    Text(localized: "Default speed")
                    Spacer()
                    Slider(value: self.$rate, in: 0.5 ... 2.0, step: 0.05)
                        .frame(width: 160)
                        .accessibilityLabel(L10n.string("Default playback speed"))
                        .help(L10n.string(
                            "Sets the playback speed for all tracks. 1× is normal speed; 0.5× is half speed; 2× is double speed."
                        ))
                    Text(String(format: "%.2g×", self.rate))
                        .monospacedDigit()
                        .frame(width: 40)
                }
                Button(L10n.string("Reset to 1×")) { self.rate = 1.0 }
                    .controlSize(.small)
                    .help(L10n.string("Reset playback speed to normal (1×)"))
            }

            Section(L10n.string("Gapless Playback")) {
                HStack {
                    Text(localized: "Preroll (seconds)")
                    Spacer()
                    Slider(value: self.$prerollSeconds, in: 1 ... 15, step: 1)
                        .frame(width: 120)
                        .accessibilityLabel(L10n.string("Gapless preroll duration"))
                        .help(L10n.string(
                            "How many seconds before a track ends that Bòcan pre-decodes the next one. Increase if you hear gaps."
                        ))
                    Text(localized: "\(Int(self.prerollSeconds)) s")
                        .monospacedDigit()
                        .frame(width: 32)
                }
                Toggle(L10n.string("Allow gapless across different albums"), isOn: self.$crossAlbumGapless)
                    .help(L10n.string(
                        "When off, gapless only applies within the same album. Turn on for seamless transitions between any tracks."
                    ))
            }

            Section(L10n.string("Sleep Timer")) {
                Toggle(L10n.string("Fade out audio in last 30 seconds"), isOn: self.$sleepTimerFadeOut)
                    .help(L10n.string(
                        "Gradually fades the volume to silence in the final 30 seconds before the sleep timer stops playback."
                    ))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.string("Playback"))
    }
}
