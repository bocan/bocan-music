import Foundation
import Library
import Observability
import Persistence

// MARK: - Load state

/// One report's lifecycle in a Deep Dive tab.
public enum DeepDiveState<Report: Sendable & Equatable>: Equatable {
    case idle
    case loading
    case loaded(Report)
    case failed(DeepDiveError)
}

// MARK: - Artist

@MainActor
public final class DeepDiveArtistViewModel: ObservableObject {
    @Published public private(set) var state: DeepDiveState<ArtistReport> = .idle
    private let service: DeepDiveService
    private let artistID: Int64
    private var task: Task<Void, Never>?
    private let log = AppLogger.make(.ui)

    public init(service: DeepDiveService, artistID: Int64) {
        self.service = service
        self.artistID = artistID
    }

    public func load(forceRefresh: Bool = false) {
        self.task?.cancel()
        self.state = .loading
        self.task = Task { [service, artistID] in
            do {
                let report = try await service.artistReport(artistID: artistID, forceRefresh: forceRefresh)
                guard !Task.isCancelled else { return }
                self.state = .loaded(report)
            } catch let error as DeepDiveError {
                self.state = .failed(error)
            } catch {
                self.log.error("deepdive.artist.failed", ["error": String(reflecting: error)])
                self.state = .failed(.notFound)
            }
        }
    }
}

// MARK: - Track

@MainActor
public final class DeepDiveTrackViewModel: ObservableObject {
    @Published public private(set) var state: DeepDiveState<TrackReport> = .idle
    private let service: DeepDiveService
    private let trackID: Int64
    private var task: Task<Void, Never>?
    private let log = AppLogger.make(.ui)

    public init(service: DeepDiveService, trackID: Int64) {
        self.service = service
        self.trackID = trackID
    }

    public func load(forceRefresh: Bool = false) {
        self.task?.cancel()
        self.state = .loading
        self.task = Task { [service, trackID] in
            do {
                let report = try await service.trackReport(trackID: trackID, forceRefresh: forceRefresh)
                guard !Task.isCancelled else { return }
                self.state = .loaded(report)
            } catch let error as DeepDiveError {
                self.state = .failed(error)
            } catch {
                self.log.error("deepdive.track.failed", ["error": String(reflecting: error)])
                self.state = .failed(.notFound)
            }
        }
    }
}

// MARK: - Album

@MainActor
public final class DeepDiveAlbumViewModel: ObservableObject {
    @Published public private(set) var state: DeepDiveState<AlbumReport> = .idle
    private let service: DeepDiveService
    private let albumID: Int64
    private var task: Task<Void, Never>?
    private let log = AppLogger.make(.ui)

    public init(service: DeepDiveService, albumID: Int64) {
        self.service = service
        self.albumID = albumID
    }

    public func load(forceRefresh: Bool = false) {
        self.task?.cancel()
        self.state = .loading
        self.task = Task { [service, albumID] in
            do {
                let report = try await service.albumReport(albumID: albumID, forceRefresh: forceRefresh)
                guard !Task.isCancelled else { return }
                self.state = .loaded(report)
            } catch let error as DeepDiveError {
                self.state = .failed(error)
            } catch {
                self.log.error("deepdive.album.failed", ["error": String(reflecting: error)])
                self.state = .failed(.notFound)
            }
        }
    }
}

// MARK: - Shared formatting

enum DeepDiveFormat {
    /// "1957" from "1957-03", "1969-09-26" from itself; nil stays nil.
    static func year(_ partialDate: String?) -> String? {
        guard let partialDate, partialDate.count >= 4 else { return nil }
        return String(partialDate.prefix(4))
    }

    /// "1960 to 1970", "1960 to present", or nil.
    static func span(begin: String?, end: String?, ended: Bool) -> String? {
        let from = self.year(begin)
        let until = self.year(end)
        switch (from, until, ended) {
        case (nil, nil, _):
            return nil

        case let (from?, until?, _):
            return L10n.string("\(from) to \(until)")

        case let (from?, nil, false):
            return L10n.string("\(from) to present")

        case let (from?, nil, true):
            return from

        case let (nil, until?, _):
            return L10n.string("until \(until)")
        }
    }

    static func errorMessage(_ error: DeepDiveError) -> String {
        switch error {
        case .noIdentifier:
            L10n.string("No MusicBrainz identifier for this item, and no confident match by name.")

        case .offline:
            L10n.string("MusicBrainz could not be reached and nothing is cached yet.")

        case .rateLimited:
            L10n.string("MusicBrainz asked us to slow down. Try again in a moment.")

        case .notFound:
            L10n.string("MusicBrainz has no record for this identifier.")
        }
    }

    static func linkLabel(_ type: String) -> String {
        switch type {
        case "wikidata":
            L10n.string("Wikidata")

        case "wikipedia":
            L10n.string("Wikipedia")

        case "discogs":
            L10n.string("Discogs")

        case "official homepage":
            L10n.string("Official site")

        case "bandcamp":
            L10n.string("Bandcamp")

        case "allmusic":
            L10n.string("AllMusic")

        case "last.fm":
            L10n.string("Last.fm")

        case "youtube":
            L10n.string("YouTube")

        default:
            type.capitalized
        }
    }

    static func releaseKind(_ primary: String?, secondary: [String]) -> String {
        let all = [primary].compactMap(\.self) + secondary
        return all.map { ReleaseKindLabel.string(for: $0.lowercased()) }.joined(separator: " · ")
    }
}
