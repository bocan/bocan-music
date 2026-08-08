import Library
import Persistence
import SwiftUI

// MARK: - RadioStationSheetMode

/// Which job the sheet is doing; drives its title and primary button.
enum RadioStationSheetMode: Identifiable {
    case add
    case edit(RadioStation)

    var id: String {
        switch self {
        case .add:
            "add"

        case let .edit(station):
            "edit-\(station.id ?? -1)"
        }
    }
}

// MARK: - RadioStationSheet

/// Add / edit form for a radio station (phase 27-3). Pasting a playlist URL
/// (`.pls` / `.m3u` / `.m3u8`) into the add form switches the sheet to a
/// found-stations list so the whole dial can be added in one go; an HLS or
/// otherwise-unparseable body keeps the pasted URL as the stream itself.
struct RadioStationSheet: View {
    @ObservedObject var vm: RadioViewModel
    let mode: RadioStationSheetMode

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var streamURL = ""
    @State private var homePage = ""
    @State private var found: [RemotePlaylistStation]?
    @State private var isBusy = false

    var body: some View {
        Group {
            if let found {
                self.foundList(found)
            } else {
                self.form
            }
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 520)
        .onAppear(perform: self.prefill)
        .onDisappear { self.vm.sheetErrorMessage = nil }
    }

    // MARK: - Form stage

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(self.title)
                .font(Typography.title)
                .foregroundStyle(Color.textPrimary)

            Form {
                TextField(L10n.string("Station Name"), text: self.$name, prompt: nil)
                TextField(self.streamURLLabel, text: self.$streamURL)
                    .autocorrectionDisabled()
                if case .add = self.mode {
                    Text(localized: "Paste a .m3u or .pls link and every station inside will be offered.")
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
                TextField(L10n.string("Homepage"), text: self.$homePage)
                    .autocorrectionDisabled()
            }
            .formStyle(.columns)

            if let message = self.vm.sheetErrorMessage {
                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(Color.red)
            }

            HStack {
                Spacer()
                Button(L10n.string("Cancel")) { self.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(self.primaryButtonTitle) {
                    Task { await self.submit() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(self.isBusy || self.streamURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Found-stations stage

    private func foundList(_ stations: [RemotePlaylistStation]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.string("Found \(stations.count) stations in this playlist."))
                .font(Typography.title)
                .foregroundStyle(Color.textPrimary)

            List(Array(stations.enumerated()), id: \.offset) { _, station in
                VStack(alignment: .leading, spacing: 2) {
                    Text(station.name ?? Self.host(of: station.streamURL))
                        .font(Typography.subheadline)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                    Text(station.streamURL)
                        .font(Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, 1)
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button(L10n.string("Cancel")) { self.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string("Add All")) {
                    Task {
                        self.isBusy = true
                        await self.vm.addStations(stations)
                        self.dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(self.isBusy)
            }
        }
    }

    // MARK: - Actions

    private func submit() async {
        self.isBusy = true
        defer { self.isBusy = false }
        self.vm.sheetErrorMessage = nil
        switch self.mode {
        case .add:
            switch await self.vm.submitAdd(
                name: self.name,
                streamURL: self.streamURL,
                homePage: self.homePage
            ) {
            case .saved:
                self.dismiss()

            case let .found(stations):
                self.found = stations

            case .invalid:
                break // sheetErrorMessage renders inline
            }

        case let .edit(station):
            if await self.vm.updateStation(
                station,
                name: self.name,
                streamURL: self.streamURL,
                homePage: self.homePage
            ) {
                self.dismiss()
            }
        }
    }

    private func prefill() {
        guard case let .edit(station) = self.mode else { return }
        self.name = station.name
        self.streamURL = station.streamURL
        self.homePage = station.homePageURL ?? ""
    }

    // MARK: - Helpers

    private var title: String {
        switch self.mode {
        case .add:
            L10n.string("Add Station")

        case .edit:
            L10n.string("Edit Station")
        }
    }

    /// Only the add path resolves playlist URLs, so only the add label
    /// advertises them; edit keeps the literal truth.
    private var streamURLLabel: String {
        switch self.mode {
        case .add:
            L10n.string("Stream or Playlist URL")

        case .edit:
            L10n.string("Stream URL")
        }
    }

    private var primaryButtonTitle: String {
        switch self.mode {
        case .add:
            L10n.string("Add")

        case .edit:
            L10n.string("Save")
        }
    }

    private static func host(of raw: String) -> String {
        URL(string: raw)?.host ?? raw
    }
}
