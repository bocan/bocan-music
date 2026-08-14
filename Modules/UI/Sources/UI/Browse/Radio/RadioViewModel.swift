import Foundation
import Library
import Observability
import Persistence

// MARK: - RadioViewModel

/// Drives the local Radio destination (phase 27-3): the station catalog list,
/// add/edit/delete, and pasted-playlist-URL resolution for the add sheet.
///
/// The list stays live through `RadioStationRepository.observeAll()`, so
/// stations added by playlist import (27-4) or profile backfills (27-5)
/// appear without a reload.
@MainActor
public final class RadioViewModel: ObservableObject {
    // MARK: - Published state

    @Published public private(set) var stations: [RadioStation] = []
    /// Load / delete errors, surfaced by `RadioView`'s alert. The add/edit
    /// sheet shows `sheetErrorMessage` inline instead, because an alert
    /// cannot present on top of an open sheet.
    @Published public var errorMessage: String?
    @Published public var sheetErrorMessage: String?
    /// The row selected in the catalog list. `RadioView`'s `List(selection:)`
    /// binds directly to this, so a plain click selects a row like any
    /// selectable list; `syncSelection(nowPlayingStreamURL:)` also writes it
    /// so the playing station shows selected without a click.
    @Published public var selectedStationID: Int64?

    // MARK: - Dependencies

    private let repository: RadioStationRepository
    private let resolver: RemotePlaylistResolver
    private let log = AppLogger.make(.ui)
    private nonisolated(unsafe) var observationTask: Task<Void, Never>?

    public init(
        repository: RadioStationRepository,
        resolver: RemotePlaylistResolver = RemotePlaylistResolver()
    ) {
        self.repository = repository
        self.resolver = resolver
    }

    deinit {
        self.observationTask?.cancel()
    }

    // MARK: - Observation

    /// Starts the catalog observation stream. Safe to call repeatedly; only
    /// the first call subscribes.
    public func startObserving() {
        guard self.observationTask == nil else { return }
        let repository = self.repository
        self.observationTask = Task { [weak self] in
            do {
                for try await stations in await repository.observeAll() {
                    guard let self else { return }
                    self.stations = stations
                }
            } catch {
                guard let self else { return }
                self.log.error("radio.observe.failed", ["error": String(reflecting: error)])
                self.errorMessage = L10n.string("Could not load your stations.")
            }
        }
    }

    // MARK: - Add / edit

    /// Outcome of submitting the add sheet.
    public enum AddResolution: Equatable {
        /// A single station was saved; the sheet can dismiss.
        case saved
        /// The URL was a playlist: offer its stream entries as stations.
        case found([RemotePlaylistStation])
        /// Validation or the fetch failed; `sheetErrorMessage` is set.
        case invalid
    }

    /// The add sheet's primary action. A URL with a playlist extension is
    /// fetched and resolved (27-3's indirection); an HLS or non-playlist
    /// body falls back to saving the pasted URL as the stream itself.
    public func submitAdd(name: String, streamURL: String, homePage: String?) async -> AddResolution {
        guard let url = Self.validatedStreamURL(streamURL) else {
            self.sheetErrorMessage = L10n.string("The stream URL must start with http:// or https://.")
            return .invalid
        }
        if RemotePlaylistResolver.looksLikePlaylist(url) {
            do {
                if case let .stations(found) = try await self.resolver.resolve(url) {
                    return .found(found)
                }
            } catch {
                self.log.warning("radio.playlist.fetch.failed", ["error": String(reflecting: error)])
                self.sheetErrorMessage = L10n.string("Could not fetch that playlist.")
                return .invalid
            }
        }
        return await self.addStation(name: name, streamURL: url, homePage: homePage) ? .saved : .invalid
    }

    /// Inserts every resolved playlist entry, skipping ones the catalog
    /// already holds. Returns how many were actually added.
    @discardableResult
    public func addStations(_ found: [RemotePlaylistStation]) async -> Int {
        var added = 0
        let now = Int64(Date().timeIntervalSince1970)
        for entry in found {
            guard let url = Self.validatedStreamURL(entry.streamURL) else { continue }
            let station = RadioStation(
                name: entry.name ?? Self.hostName(of: url),
                streamURL: url.absoluteString,
                addedAt: now
            )
            do {
                if try await self.repository.upsert(station) { added += 1 }
            } catch {
                self.log.warning("radio.import.upsert.failed", ["error": String(reflecting: error)])
            }
        }
        return added
    }

    /// Saves edits to an existing station. Returns true on success.
    @discardableResult
    public func updateStation(
        _ station: RadioStation,
        name: String,
        streamURL: String,
        homePage: String?
    ) async -> Bool {
        guard let url = Self.validatedStreamURL(streamURL) else {
            self.sheetErrorMessage = L10n.string("The stream URL must start with http:// or https://.")
            return false
        }
        var updated = station
        updated.name = Self.resolvedName(name, fallbackFor: url)
        updated.streamURL = url.absoluteString
        updated.homePageURL = Self.normalizedOptional(homePage)
        do {
            try await self.repository.update(updated)
            return true
        } catch {
            self.log.error("radio.update.failed", ["error": String(reflecting: error)])
            self.sheetErrorMessage = L10n.string("A station with this stream URL already exists.")
            return false
        }
    }

    // MARK: - Selection

    /// Moves the list selection onto whichever station's `streamURL` matches
    /// `nowPlayingStreamURL`. Clears selection when radio isn't playing, or
    /// when the playing stream isn't in this catalog (an ephemeral Subsonic
    /// station, say) — a stale selection would point at the wrong row.
    public func syncSelection(nowPlayingStreamURL: String?) {
        guard let url = nowPlayingStreamURL else {
            self.selectedStationID = nil
            return
        }
        self.selectedStationID = self.stations.first { $0.streamURL == url }?.id
    }

    // MARK: - Delete

    public func delete(_ station: RadioStation) async {
        guard let id = station.id else { return }
        do {
            try await self.repository.delete(id: id)
        } catch {
            self.log.error("radio.delete.failed", ["error": String(reflecting: error)])
            self.errorMessage = L10n.string("Could not delete this station.")
        }
    }

    // MARK: - Internals

    private func addStation(name: String, streamURL: URL, homePage: String?) async -> Bool {
        let station = RadioStation(
            name: Self.resolvedName(name, fallbackFor: streamURL),
            streamURL: streamURL.absoluteString,
            addedAt: Int64(Date().timeIntervalSince1970),
            homePageURL: Self.normalizedOptional(homePage)
        )
        do {
            try await self.repository.insert(station)
            return true
        } catch {
            self.log.error("radio.add.failed", ["error": String(reflecting: error)])
            self.sheetErrorMessage = L10n.string("A station with this stream URL already exists.")
            return false
        }
    }

    /// http(s)-with-host or nothing: the only shape validation the sheet does.
    static func validatedStreamURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
    }

    /// The name to store: trimmed input, or the URL host so import and the
    /// sheet can never write an empty name.
    static func resolvedName(_ raw: String, fallbackFor url: URL) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.hostName(of: url) : trimmed
    }

    static func hostName(of url: URL) -> String {
        url.host ?? url.absoluteString
    }

    static func normalizedOptional(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
