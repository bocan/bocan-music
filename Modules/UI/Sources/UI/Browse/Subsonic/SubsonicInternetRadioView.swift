import Foundation
import Observability
import Subsonic
import SwiftSonic
import SwiftUI

// MARK: - SubsonicInternetRadioViewModel

/// Drives the per-server Internet Radio destination (Phase 19 step 11).
///
/// Capability-gated by `SubsonicCapabilities.supportsInternetRadio`.
@MainActor
public final class SubsonicInternetRadioViewModel: ObservableObject {
    public let serverID: UUID

    @Published public private(set) var stations: [InternetRadioStation] = []
    @Published public private(set) var isLoading = false
    @Published public var errorMessage: String?

    private let dataSource: any SubsonicBrowseDataSource
    private let log = AppLogger.make(.ui)

    public init(serverID: UUID, dataSource: any SubsonicBrowseDataSource) {
        self.serverID = serverID
        self.dataSource = dataSource
    }

    public func load() async {
        guard !self.isLoading else { return }
        self.isLoading = true
        defer { self.isLoading = false }
        do {
            self.stations = try await self.dataSource
                .getInternetRadioStations(serverID: self.serverID)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self.errorMessage = nil
        } catch {
            self.log.error("subsonic.radio.load.failed", ["error": String(reflecting: error)])
            self.errorMessage = (error as? LocalizedError)?.errorDescription
                ?? L10n.string("Could not load internet radio stations.")
        }
    }
}

// MARK: - SubsonicInternetRadioView

public struct SubsonicInternetRadioView: View {
    public let serverID: UUID
    public let library: LibraryViewModel

    @StateObject private var vm: SubsonicInternetRadioViewModel
    @State private var infoStation: InternetRadioStation?

    public init(
        serverID: UUID,
        library: LibraryViewModel,
        dataSource: any SubsonicBrowseDataSource
    ) {
        self.serverID = serverID
        self.library = library
        self._vm = StateObject(
            wrappedValue: SubsonicInternetRadioViewModel(serverID: serverID, dataSource: dataSource)
        )
    }

    public var body: some View {
        Group {
            if self.vm.stations.isEmpty, !self.vm.isLoading {
                ContentUnavailableView(
                    L10n.string("No Stations"),
                    systemImage: "dot.radiowaves.left.and.right",
                    description: Text(localized: "This server has no internet radio stations.")
                )
            } else {
                List {
                    ForEach(self.vm.stations, id: \.id) { station in
                        SubsonicInternetRadioRow(
                            station: station,
                            onPlay: { self.play(station) },
                            onInfo: { self.infoStation = station }
                        )
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(L10n.string("Internet Radio"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await self.vm.load() } } label: {
                    Label(L10n.string("Refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(self.vm.isLoading)
            }
        }
        .task(id: self.serverID) {
            if self.vm.stations.isEmpty { await self.vm.load() }
        }
        .loadErrorAlert(L10n.string("Couldn't load stations"), message: self.$vm.errorMessage)
        .sheet(item: self.$infoStation) { station in
            SubsonicInternetRadioInfoSheet(station: station) { self.infoStation = nil }
        }
    }

    private func play(_ station: InternetRadioStation) {
        let sid = self.serverID
        Task { await self.library.play(internetRadioStation: station, serverID: sid) }
    }
}

// MARK: - SubsonicInternetRadioRow

/// One row in the stations list. Double-clicking the row plays the
/// station; the inline Play and Info buttons offer the same actions
/// with explicit affordances.
private struct SubsonicInternetRadioRow: View {
    let station: InternetRadioStation
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
                if let home = station.homePageUrl, !home.isEmpty {
                    Text(home)
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
}

// MARK: - SubsonicInternetRadioInfoSheet

/// Small modal showing the station's metadata. Stream URL is copyable so
/// users can paste it elsewhere; the homepage opens in the default browser.
private struct SubsonicInternetRadioInfoSheet: View {
    let station: InternetRadioStation
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

            self.field(label: L10n.string("Stream URL"), value: self.station.streamUrl, copyable: true)

            if let home = station.homePageUrl, !home.isEmpty, let url = URL(string: home) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized: "Homepage")
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                    Link(home, destination: url)
                        .font(Typography.subheadline)
                        .lineLimit(2)
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
                .font(Typography.subheadline.monospacedDigit())
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Identifiable adapter for `.sheet(item:)`

extension InternetRadioStation: @retroactive Identifiable {}
