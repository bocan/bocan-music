import Library
import Persistence
import SwiftUI

// MARK: - SmartPresetPickerView

/// Displays built-in smart playlist presets for the user to start from.
struct SmartPresetPickerView: View {
    let service: SmartPlaylistService
    let onSelect: (SmartPlaylist) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var presets: [SmartPlaylist] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Start from a Preset")
                    .font(Typography.largeTitle)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Button("Cancel") { self.dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()

            if self.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.presets.isEmpty {
                EmptyState(
                    symbol: "sparkles",
                    title: "No Presets",
                    message: "No built-in presets are available."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 12) {
                        ForEach(self.presets, id: \.id) { preset in
                            PresetCard(preset: preset) {
                                self.onSelect(preset)
                            }
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 340)
        .onAppear {
            Task { @MainActor in SmartPlaylistSurfacePrewarmer.prewarmOnce() }
        }
        .task {
            do {
                let playlists = try await self.service.listAll()
                var resolved: [SmartPlaylist] = []
                for playlist in playlists where playlist.smartPresetKey != nil {
                    if let sp = try? await self.service.resolve(id: playlist.id ?? -1) {
                        resolved.append(sp)
                    }
                }
                self.presets = resolved
            } catch {
                // Non-fatal: show empty state
            }
            self.isLoading = false
        }
    }
}

// MARK: - PresetCard

private struct PresetCard: View {
    let preset: SmartPlaylist
    let onSelect: () -> Void

    var body: some View {
        Button(action: self.onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                Text(self.preset.name)
                    .font(Typography.title)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .padding(14)
            .background(Color.bgSecondary)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.separatorAdaptive, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
