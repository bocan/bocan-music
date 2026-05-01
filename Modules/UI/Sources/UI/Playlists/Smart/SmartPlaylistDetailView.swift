import Library
import Persistence
import SwiftUI

// MARK: - SmartPlaylistDetailView

/// Detail view for a smart playlist — shows header, live track list, and an
/// "Edit Rules" button that opens `RuleBuilderView` as a sheet.
public struct SmartPlaylistDetailView: View {
    @StateObject private var vm: SmartPlaylistDetailViewModel
    @ObservedObject public var library: LibraryViewModel
    public let playlistID: Int64

    @State private var isEditingRules = false

    public init(playlistID: Int64, library: LibraryViewModel, service: SmartPlaylistService) {
        self.playlistID = playlistID
        self.library = library
        self._vm = StateObject(wrappedValue: SmartPlaylistDetailViewModel(service: service))
    }

    public var body: some View {
        VStack(spacing: 0) {
            self.header
            Divider()

            if self.vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.vm.tracks.isEmpty {
                EmptyState(
                    symbol: "sparkles",
                    title: "No Matching Tracks",
                    message: "Adjust the rules to find tracks in your library."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TracksView(
                    vm: self.library.tracks,
                    library: self.library,
                    sortable: false
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(A11y.SmartPlaylistDetail.view)
        .task(id: self.playlistID) {
            // Load smart playlist tracks into the shared TracksViewModel so
            // TracksView can render them with full context-menu support.
            await self.vm.load(playlistID: self.playlistID)
            self.library.tracks.setTracks(self.vm.tracks)
        }
        .onChange(of: self.vm.tracks.map(\.id)) { _, _ in
            self.library.tracks.setTracks(self.vm.tracks)
        }
        .sheet(isPresented: self.$isEditingRules) {
            if let sp = self.vm.smartPlaylist {
                RuleBuilderView(
                    smartPlaylist: sp,
                    service: self.library.smartPlaylistService,
                    playlistService: self.library.playlistService
                ) { _ in
                    Task { await self.vm.load(playlistID: self.playlistID) }
                }
            }
        }
        .alert("Error", isPresented: Binding(
            get: { self.vm.lastError != nil },
            set: { if !$0 { self.vm.lastError = nil } }
        )) {
            Button("OK") { self.vm.lastError = nil }
                .help("Dismiss this error")
        } message: {
            Text(self.vm.lastError ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.85))
                .overlay(
                    Image(systemName: "sparkles")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.white.opacity(0.9))
                )
                .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 4) {
                Text(self.vm.title)
                    .font(Typography.largeTitle)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Text(self.subtitle)
                    .font(Typography.subheadline)
                    .foregroundStyle(Color.textSecondary)
                if !self.vm.isLive, let snapshotText = self.snapshotSubtitle {
                    Text(snapshotText)
                        .font(Typography.caption)
                        .foregroundStyle(Color.textTertiary)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    Task { await self.library.play(tracks: self.vm.tracks) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(self.vm.tracks.isEmpty)
                .help("Play the current smart playlist in order")
                .accessibilityHint("Starts playback from the first matching track")

                Button {
                    Task { await self.playShuffled() }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(self.vm.tracks.isEmpty)
                .help("Shuffle and play the matching tracks")
                .accessibilityHint("Starts playback in shuffled order")

                if !self.vm.isLive {
                    Button {
                        Task { await self.vm.refresh() }
                    } label: {
                        Label("Refresh now", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Re-run the rules and update the saved snapshot")
                    .keyboardShortcut("r", modifiers: [.command])
                    .accessibilityIdentifier(A11y.SmartPlaylistDetail.refreshButton)
                }

                if self.vm.smartPlaylist?.limitSort.sortBy == .random {
                    Button {
                        Task { await self.reshuffle() }
                    } label: {
                        Label("Reshuffle", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Pick a new random order")
                }

                Button {
                    self.isEditingRules = true
                } label: {
                    Label("Edit Rules", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Open the rule builder to edit this smart playlist")
                .accessibilityHint("Opens criteria, limit, and sort controls")
                .accessibilityIdentifier(A11y.SmartPlaylistDetail.editButton)
            }
        }
        .padding(20)
        .background(Color.bgPrimary)
        .accessibilityIdentifier(A11y.SmartPlaylistDetail.header)
    }

    private var subtitle: String {
        let count = self.vm.trackCount
        let countText = count == 1 ? "1 song" : "\(count) songs"
        let mins = Int(self.vm.totalDuration / 60)
        let durationText = mins < 60
            ? "\(mins) min"
            : "\(mins / 60) hr \(mins % 60) min"
        return "\(countText) · \(durationText)"
    }

    private var snapshotSubtitle: String? {
        guard let unix = self.vm.lastSnapshottedAt else {
            return "Snapshot not created yet"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let text = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
        return "Snapshotted at \(text)"
    }

    // MARK: - Actions

    private func playShuffled() async {
        guard !self.vm.tracks.isEmpty else { return }
        await self.library.play(tracks: self.vm.tracks, shuffle: true)
    }

    private func reshuffle() async {
        do {
            _ = try await self.library.smartPlaylistService.shuffleSeed(id: self.playlistID)
            if self.vm.isLive {
                await self.vm.load(playlistID: self.playlistID)
            } else {
                await self.vm.refresh()
            }
        } catch {
            self.vm.lastError = "Could not reshuffle playlist."
        }
    }
}
