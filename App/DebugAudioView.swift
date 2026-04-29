#if DEBUG
    import AppKit
    import AudioEngine
    import SwiftUI

    /// Phase 1 audit #14: debug-only manual playback harness.
    ///
    /// Exposes a minimal SwiftUI surface to drive the `AudioEngine` directly,
    /// without going through the queue, library, or playback view models.  Used
    /// to verify decoder routing, fade behaviour, and seek correctness when a
    /// regression is suspected to live below the queue layer.
    ///
    /// The window is registered as a separate scene in `BocanApp.body` and is
    /// only compiled into Debug builds.
    struct DebugAudioView: View {
        let engine: AudioEngine

        @State private var lastError: String?
        @State private var loadedURL: URL?
        @State private var positionSec: Double = 0
        @State private var durationSec: Double = 0

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Debug Audio")
                    .font(.title2.bold())

                HStack {
                    Button("Open File…") { Task { await self.pickFile() } }
                    if let url = self.loadedURL {
                        Text(url.lastPathComponent).font(.system(.body, design: .monospaced))
                    }
                }

                HStack {
                    Button("Play") { Task { try? await self.engine.play() } }
                    Button("Pause") { Task { await self.engine.pause() } }
                    Button("Stop") { Task { await self.engine.stop() } }
                }

                HStack {
                    Text(String(format: "%.1f", self.positionSec))
                        .frame(width: 48, alignment: .trailing)
                    Slider(value: self.$positionSec, in: 0 ... max(self.durationSec, 0.1)) { editing in
                        if !editing {
                            Task { try? await self.engine.seek(to: self.positionSec) }
                        }
                    }
                    Text(String(format: "%.1f", self.durationSec))
                        .frame(width: 48)
                }

                if let error = self.lastError {
                    Text(error).foregroundStyle(.red).font(.caption)
                }
            }
            .padding(20)
            .frame(minWidth: 480, minHeight: 200)
            .task {
                // Poll position so the slider tracks playback.
                while !Task.isCancelled {
                    self.positionSec = await self.engine.currentTime
                    self.durationSec = await self.engine.duration
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }

        @MainActor
        private func pickFile() async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.audio]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try await self.engine.load(url)
                self.loadedURL = url
                self.lastError = nil
            } catch {
                self.lastError = "load failed: \(error)"
            }
        }
    }
#endif
