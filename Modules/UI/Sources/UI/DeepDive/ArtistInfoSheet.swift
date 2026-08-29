import Library
import Persistence
import SwiftUI

// MARK: - ArtistInfoRequest

/// What `LibraryViewModel.showArtistInfo` publishes; `Identifiable` for `.sheet(item:)`.
public struct ArtistInfoRequest: Identifiable, Equatable, Sendable {
    public let id: Int64

    public init(id: Int64) {
        self.id = id
    }
}

// MARK: - ArtistInfoSheet

/// Get Info for an artist (#413): an Info tab over the local row and a Deep
/// Dive tab built from MusicBrainz and Wikipedia.
public struct ArtistInfoSheet: View {
    @ObservedObject private var library: LibraryViewModel

    @StateObject private var deepDive: DeepDiveArtistViewModel

    @State private var artist: Artist?
    @State private var albumCount = 0
    @State private var trackCount = 0
    @State private var tab: Tab = .info

    private let artistID: Int64
    private let dismiss: () -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case info, deepDive

        var id: String {
            self.rawValue
        }

        var label: String {
            switch self {
            case .info:
                L10n.string("Info")

            case .deepDive:
                L10n.string("Deep Dive")
            }
        }
    }

    public init(artistID: Int64, library: LibraryViewModel, dismiss: @escaping () -> Void) {
        self.artistID = artistID
        self.library = library
        self.dismiss = dismiss
        self._deepDive = StateObject(wrappedValue: DeepDiveArtistViewModel(service: library.deepDiveService, artistID: artistID))
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker(L10n.string("Tab"), selection: self.$tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 12)
            Divider().padding(.top, 8)

            switch self.tab {
            case .info:
                self.infoTab

            case .deepDive:
                DeepDiveArtistView(vm: self.deepDive)
            }

            Divider()
            HStack {
                Spacer()
                Button(L10n.string("Done"), action: self.dismiss)
                    .keyboardShortcut(.defaultAction)
                    .help(L10n.string("Close"))
            }
            .padding(12)
        }
        .frame(minWidth: 640, idealWidth: 760, minHeight: 520, idealHeight: 640)
        .task { await self.loadInfo() }
    }

    private var infoTab: some View {
        Form {
            if let artist {
                Section(L10n.string("Artist")) {
                    LabeledContent(L10n.string("Name"), value: artist.name)
                    LabeledContent(L10n.string("Sort name"), value: artist.sortName ?? artist.name)
                    if let disambiguation = artist.disambiguation {
                        LabeledContent(L10n.string("Disambiguation"), value: disambiguation)
                    }
                    ReadOnlyIDRow(label: L10n.string("Artist MBID"), value: artist.musicbrainzArtistID ?? "")
                }
                Section(L10n.string("In your library")) {
                    LabeledContent(L10n.string("Albums"), value: String(self.albumCount))
                    LabeledContent(L10n.string("Tracks"), value: String(self.trackCount))
                }
            } else {
                ProgressView()
            }
        }
        .formStyle(.grouped)
    }

    private func loadInfo() async {
        self.artist = try? await self.library.artistRepo.fetch(id: self.artistID)
        self.albumCount = await (try? self.library.artistRepo.fetchAlbumCounts()[self.artistID]) ?? 0
        self.trackCount = await (try? self.library.artistRepo.fetchTrackCounts()[self.artistID]) ?? 0
    }
}
