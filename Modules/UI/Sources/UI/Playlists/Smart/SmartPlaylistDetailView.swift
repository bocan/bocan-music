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

                Button {
                    Task { await self.playShuffled() }
                } label: {
                    Label("Shuffle", systemImage: "shuffle")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(self.vm.tracks.isEmpty)

                if !self.vm.isLive {
                    Button {
                        Task { await self.vm.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Re-run the rules and update the saved snapshot")
                    .keyboardShortcut("r", modifiers: [.command])
                    .accessibilityIdentifier(A11y.SmartPlaylistDetail.refreshButton)
                }

                Button {
                    self.isEditingRules = true
                } label: {
                    Label("Edit Rules", systemImage: "slider.horizontal.3")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
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

    // MARK: - Actions

    private func playShuffled() async {
        guard !self.vm.tracks.isEmpty else { return }
        await self.library.play(tracks: self.vm.tracks, shuffle: true)
    }
}
