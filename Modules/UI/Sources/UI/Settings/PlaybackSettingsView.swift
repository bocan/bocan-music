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
            Section("Speed") {
                HStack {
                    Text("Default speed")
                    Spacer()
                    Slider(value: self.$rate, in: 0.5 ... 2.0, step: 0.05)
                        .frame(width: 160)
                    Text(String(format: "%.2g×", self.rate))
                        .monospacedDigit()
                        .frame(width: 40)
                }
                Button("Reset to 1×") { self.rate = 1.0 }
                    .controlSize(.small)
            }

            Section("Gapless Playback") {
                HStack {
                    Text("Preroll (seconds)")
                    Spacer()
                    Slider(value: self.$prerollSeconds, in: 1 ... 15, step: 1)
                        .frame(width: 120)
                    Text("\(Int(self.prerollSeconds)) s")
                        .monospacedDigit()
                        .frame(width: 32)
                }
                Toggle("Allow gapless across different albums", isOn: self.$crossAlbumGapless)
            }

            Section("Sleep Timer") {
                Toggle("Fade out audio in last 30 seconds", isOn: self.$sleepTimerFadeOut)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Playback")
    }
}
