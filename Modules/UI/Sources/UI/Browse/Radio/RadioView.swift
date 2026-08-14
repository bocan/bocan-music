import Persistence
import SwiftUI

// MARK: - RadioView

/// The local Radio destination (phase 27-3): the user-curated station
/// catalog. Mirrors `SubsonicInternetRadioView`'s interaction model (hover
/// play / info, double-click to play, rotor actions) and adds what the
/// read-only original never needed: add, edit, and delete.
public struct RadioView: View {
    public let library: LibraryViewModel

    @StateObject private var vm: RadioViewModel
    @State private var infoContext: LibraryViewModel.RadioStationInfoContext?
    @State private var sheetMode: RadioStationSheetMode?
    @State private var stationToDelete: RadioStation?

    public init(library: LibraryViewModel) {
        self.library = library
        self._vm = StateObject(wrappedValue: RadioViewModel(repository: library.radioStations))
    }

    public var body: some View {
        Group {
            if self.vm.stations.isEmpty {
                self.emptyState
            } else {
                self.stationList
            }
        }
        .navigationTitle(L10n.string("Radio"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { self.sheetMode = .add } label: {
                    Label(L10n.string("Add Station"), systemImage: "plus")
                }
                .accessibilityIdentifier(A11y.Radio.addButton)
            }
        }
        .onAppear { self.vm.startObserving() }
        .onChange(of: self.library.nowPlaying.nowPlayingRadioStreamURL) { _, newValue in
            self.vm.syncSelection(nowPlayingStreamURL: newValue)
        }
        // Keyed on the count, not the array itself (`RadioStation` isn't
        // Equatable): re-syncs once the catalog has actually loaded, for
        // when this view appears after radio is already playing (a
        // restored queue, or navigating here mid-stream) rather than only
        // reacting to a later change in what's playing.
        .task(id: self.vm.stations.count) {
            self.vm.syncSelection(nowPlayingStreamURL: self.library.nowPlaying.nowPlayingRadioStreamURL)
        }
        .loadErrorAlert(L10n.string("Station Error"), message: self.$vm.errorMessage)
        .sheet(item: self.$sheetMode) { mode in
            RadioStationSheet(vm: self.vm, mode: mode)
        }
        .sheet(item: self.$infoContext) { context in
            RadioStationInfoSheet(
                station: context.station,
                liveDetails: context.liveDetails
            ) { self.infoContext = nil }
        }
        .confirmationDialog(
            L10n.string("Delete Station"),
            isPresented: Binding(
                get: { self.stationToDelete != nil },
                set: { if !$0 { self.stationToDelete = nil } }
            ),
            presenting: self.stationToDelete
        ) { station in
            Button(L10n.string("Delete"), role: .destructive) {
                Task { await self.vm.delete(station) }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: { station in
            Text(L10n.string("\u{201C}\(station.name)\u{201D} will be removed from your stations."))
        }
    }

    // MARK: - Pieces

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.string("No Stations"), systemImage: "dot.radiowaves.left.and.right")
        } description: {
            Text(localized: "Add your first internet radio station to start listening.")
        } actions: {
            Button(L10n.string("Add Station")) { self.sheetMode = .add }
                .accessibilityIdentifier(A11y.Radio.emptyStateAddButton)
        }
        .accessibilityIdentifier(A11y.Radio.emptyState)
    }

    private var stationList: some View {
        List(selection: Binding(
            get: { self.vm.selectedStationID },
            set: { self.vm.selectedStationID = $0 }
        )) {
            ForEach(self.vm.stations) { station in
                RadioStationRow(
                    station: station,
                    onPlay: { self.play(station) },
                    onInfo: { self.showInfo(station) }
                )
                .tag(station.id)
                .accessibilityIdentifier(A11y.Radio.row(station.id))
                .contextMenu {
                    Button(L10n.string("Edit")) { self.sheetMode = .edit(station) }
                    Button(L10n.string("Delete"), role: .destructive) {
                        self.stationToDelete = station
                    }
                }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier(A11y.Radio.list)
    }

    private func play(_ station: RadioStation) {
        Task { await self.library.play(radioStation: station) }
    }

    /// Opens the info sheet, carrying live decoder facts when this station
    /// is the one currently playing (phase 27-5).
    private func showInfo(_ station: RadioStation) {
        Task {
            let details = await self.library.liveRadioDetails(for: station.streamURL)
            self.infoContext = .init(station: station, liveDetails: details)
        }
    }
}

// MARK: - RadioStationRow

/// One row in the station list. Double-clicking plays; the hover-revealed
/// Play and Info buttons offer the same actions with explicit affordances.
private struct RadioStationRow: View {
    let station: RadioStation
    let onPlay: () -> Void
    let onInfo: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(self.station.name)
                    .font(Typography.subheadline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                if let subtitle = self.subtitle {
                    Text(subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if self.hovering {
                Button(action: self.onInfo) {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain)
                .help(L10n.string("Show station details"))

                Button(action: self.onPlay) {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.plain)
                .help(L10n.string("Play this station"))
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { self.hovering = $0 }
        .onTapGesture(count: 2, perform: self.onPlay)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.station.name)
        .accessibilityHint(L10n.string("Double-tap to play"))
        // The Play / Info buttons only appear on hover and the row combines its
        // children, so VoiceOver cannot reach them; expose both as rotor actions.
        .accessibilityAction(named: L10n.string("Play this station")) { self.onPlay() }
        .accessibilityAction(named: L10n.string("Show station details")) { self.onInfo() }
    }

    private var subtitle: String? {
        if let home = self.station.homePageURL, !home.isEmpty { return home }
        return URL(string: self.station.streamURL)?.host
    }
}

// The station info sheet lives in RadioStationInfoSheet.swift (phase 27-5):
// it grew live stream facts and is shared with the Now Playing strip.
