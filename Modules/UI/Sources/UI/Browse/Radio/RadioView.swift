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
    @State private var infoStation: RadioStation?
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
        .loadErrorAlert(L10n.string("Station Error"), message: self.$vm.errorMessage)
        .sheet(item: self.$sheetMode) { mode in
            RadioStationSheet(vm: self.vm, mode: mode)
        }
        .sheet(item: self.$infoStation) { station in
            RadioStationInfoSheet(station: station) { self.infoStation = nil }
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
        List {
            ForEach(self.vm.stations) { station in
                RadioStationRow(
                    station: station,
                    onPlay: { self.play(station) },
                    onInfo: { self.infoStation = station }
                )
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

// MARK: - RadioStationInfoSheet

/// Station metadata, including the machine-owned profile fields (27-1) that
/// get backfilled on a successful connect (27-5). Stream URL is copyable;
/// the homepage opens in the default browser.
struct RadioStationInfoSheet: View {
    let station: RadioStation
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Text(self.station.name)
                    .font(Typography.title)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
            }

            self.field(label: L10n.string("Stream URL"), value: self.station.streamURL, copyable: true)

            if let home = station.homePageURL, !home.isEmpty, let url = URL(string: home) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized: "Homepage")
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                    Link(home, destination: url)
                        .font(Typography.subheadline)
                        .lineLimit(2)
                }
            }

            if let genre = station.genre, !genre.isEmpty {
                self.field(label: L10n.string("Genre"), value: genre, copyable: false)
            }
            if let description = station.stationDescription, !description.isEmpty {
                self.field(label: L10n.string("Description"), value: description, copyable: false)
            }
            if let format = self.formatLine {
                self.field(label: L10n.string("Format"), value: format, copyable: false)
            }
            if let connectedAt = station.lastConnectedAt {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized: "Last Connected")
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                    Text(
                        Date(timeIntervalSince1970: TimeInterval(connectedAt)),
                        format: .dateTime.day().month().year().hour().minute()
                    )
                    .font(Typography.subheadline)
                    .foregroundStyle(Color.textPrimary)
                }
            }

            HStack {
                Spacer()
                Button(L10n.string("Close"), action: self.onDismiss)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 480)
    }

    /// "mp3, 128 kbps" from whatever profile parts exist; nil when neither does.
    private var formatLine: String? {
        var parts: [String] = []
        if let codec = self.station.lastCodec, !codec.isEmpty { parts.append(codec) }
        if let kbps = self.station.lastBitrateKbps { parts.append(L10n.string("\(kbps) kbps")) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func field(label: String, value: String, copyable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(Typography.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                if copyable {
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(value, forType: .string)
                    } label: {
                        Label(L10n.string("Copy"), systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
            Text(value)
                .font(Typography.subheadline)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }
}
