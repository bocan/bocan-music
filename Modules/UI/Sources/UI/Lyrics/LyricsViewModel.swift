import Combine
import Foundation
import Library
import Metadata
import Observability
import SwiftUI

// MARK: - LyricsViewModel

/// Drives lyrics display: resolves the document for the current track, tracks playback
/// position to highlight the current line, and exposes offset and editor state.
@MainActor
public final class LyricsViewModel: ObservableObject {
    // MARK: - Published state

    /// The resolved lyrics for the current track, or `nil` when unavailable.
    @Published public private(set) var document: LyricsDocument?

    /// Index into `syncedLines` that corresponds to the current playback position.
    @Published public private(set) var currentLineIndex: Int?

    /// Whether the lyrics pane is visible.
    @AppStorage("lyrics.paneVisible") public var paneVisible = false

    @AppStorage("lyrics.autoShowPane") private var autoShowPane = false

    /// Display font size bucket for the lyrics pane.
    @AppStorage("lyrics.fontSize") public var fontSizeKey: LyricsFontSize = .medium

    /// Per-track playback offset (in milliseconds) on top of any embedded `[offset:]` tag.
    @Published public var userOffsetMS = 0

    /// `true` while an auto-fetch is in progress.
    @Published public private(set) var isFetching = false

    // MARK: - Internal

    private let service: LyricsService
    private let log = AppLogger.make(.ui)

    private var observeTask: Task<Void, Never>?
    private var positionTask: Task<Void, Never>?
    private var currentTrackID: Int64?

    // MARK: - Init

    public init(service: LyricsService) {
        self.service = service
    }

    // MARK: - Public API

    /// Called whenever the now-playing track changes.  Loads lyrics and wires observation.
    public func trackDidChange(trackID: Int64?) {
        self.currentTrackID = trackID
        self.document = nil
        self.currentLineIndex = nil
        self.userOffsetMS = 0
        self.observeTask?.cancel()
        self.positionTask?.cancel()

        guard let trackID else { return }
        self.startObserving(trackID: trackID)
        self.fetchIfMissing()
    }

    /// Updates `currentLineIndex` from the engine's playback position.
    public func positionDidChange(_ position: TimeInterval) {
        guard case let .synced(lines, offsetMS) = document, !lines.isEmpty else {
            self.currentLineIndex = nil
            return
        }

        let adjusted = position - TimeInterval(offsetMS + self.userOffsetMS) / 1000.0
        let idx = lines.lastIndex { $0.start <= adjusted }
        if idx != self.currentLineIndex {
            self.currentLineIndex = idx
        }
    }

    /// Triggers an opt-in LRClib fetch if the current track has no lyrics.
    public func fetchIfMissing() {
        guard let trackID = currentTrackID, !isFetching else { return }
        self.isFetching = true
        Task {
            defer { self.isFetching = false }
            do {
                _ = try await self.service.autoFetchIfMissing(for: trackID)
            } catch {
                self.log.error("lyrics.fetch.failed", ["error": String(reflecting: error)])
            }
        }
    }

    /// Saves user-edited lyrics text for the current track.
    public func save(text: String) {
        guard let trackID = currentTrackID else { return }
        let doc: LyricsDocument = .unsynced(text)
        Task {
            do {
                try await self.service.setLyrics(doc, for: trackID, source: "user")
            } catch {
                self.log.error("lyrics.save.failed", ["error": String(reflecting: error)])
            }
        }
    }

    /// Saves a fully-formed ``LyricsDocument`` (from the editor's synced wizard).
    public func save(document: LyricsDocument) {
        guard let trackID = currentTrackID else { return }
        Task {
            do {
                try await self.service.setLyrics(document, for: trackID, source: "user")
            } catch {
                self.log.error("lyrics.save.failed", ["error": String(reflecting: error)])
            }
        }
    }

    /// Deletes stored lyrics for the current track.
    public func deleteLyrics() {
        guard let trackID = currentTrackID else { return }
        Task {
            do {
                try await self.service.setLyrics(nil, for: trackID)
            } catch {
                self.log.error("lyrics.delete.failed", ["error": String(reflecting: error)])
            }
        }
    }

    // MARK: - Private

    private func startObserving(trackID: Int64) {
        self.observeTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.service.observe(trackID)
            do {
                for try await doc in stream {
                    try Task.checkCancellation()
                    await MainActor.run {
                        self.document = doc
                        self.currentLineIndex = nil
                        if doc != nil, self.autoShowPane {
                            self.paneVisible = true
                        }
                    }
                }
            } catch is CancellationError {
                // Expected on track change.
            } catch {
                self.log.error("lyrics.observe.failed", ["error": String(reflecting: error)])
            }
        }
    }
}

// MARK: - LyricsFontSize

/// Named font size presets for the lyrics display.
public enum LyricsFontSize: String, CaseIterable, Sendable {
    case small, medium, large, extraLarge

    /// The resolved `Font` to use in `LyricsView`.
    public var font: Font {
        switch self {
        case .small:
            .body

        case .medium:
            .title3

        case .large:
            .title2

        case .extraLarge:
            .title
        }
    }

    /// Short display label shown in the size picker.
    public var label: String {
        switch self {
        case .small:
            "S"

        case .medium:
            "M"

        case .large:
            "L"

        case .extraLarge:
            "XL"
        }
    }
}
