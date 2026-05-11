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

    /// The source that produced ``document``: `"user"`, `"sidecar"`, `"embedded"`, `"lrclib"`, or `nil`.
    @Published public private(set) var documentSource: String?

    /// Index into `syncedLines` that corresponds to the current playback position.
    @Published public private(set) var currentLineIndex: Int?

    /// Whether the lyrics pane is visible.
    @AppStorage("lyrics.paneVisible") public var paneVisible = false

    @AppStorage("lyrics.autoShowPane") private var autoShowPane = false
    @AppStorage("lyrics.embedOnSave") private var embedOnSave = false

    /// Display font size bucket for the lyrics pane.
    @AppStorage("lyrics.fontSize") public var fontSizeKey: LyricsFontSize = .medium

    /// Per-track playback offset (in milliseconds) on top of any embedded `[offset:]` tag.
    @Published public var userOffsetMS = 0

    /// `true` while an auto-fetch or force-fetch is in progress.
    @Published public private(set) var isFetching = false

    /// Controls whether the lyrics editor sheet is visible.
    /// Set to `true` from external callers (menu bar, context menu) to open the editor.
    @Published public var isEditorPresented = false {
        didSet {
            // When the editor closes, restore observation to the now-playing track if
            // we temporarily overrode it to edit a non-playing track.
            if !self.isEditorPresented {
                if let nowPlaying = self.nowPlayingTrackID, nowPlaying != self.currentTrackID {
                    self.currentTrackID = nowPlaying
                    self.document = nil
                    self.documentSource = nil
                    self.currentLineIndex = nil
                    self.observeTask?.cancel()
                    self.startObserving(trackID: nowPlaying)
                }
                self.nowPlayingTrackID = nil
            }
        }
    }

    /// Whether LRClib fetching is enabled (mirrors `lyrics.lrclibEnabled` in Settings).
    @AppStorage("lyrics.lrclibEnabled") public private(set) var lrclibEnabled = false

    // MARK: - Internal

    private let service: LyricsService
    private let log = AppLogger.make(.ui)

    private var observeTask: Task<Void, Never>?
    private var positionTask: Task<Void, Never>?
    private var currentTrackID: Int64?
    /// Stores the now-playing track ID when the editor is temporarily overridden
    /// to show a non-playing track via `openEditor(for:)`.
    private var nowPlayingTrackID: Int64?

    // MARK: - Init

    public init(service: LyricsService) {
        self.service = service
    }

    // MARK: - Public API

    /// Human-readable label for ``documentSource``, suitable for a badge in the UI.
    ///
    /// Returns `nil` when no lyrics are loaded.
    public var documentSourceLabel: String? {
        switch self.documentSource {
        case "embedded":
            "Embedded"

        case "sidecar":
            "Sidecar"

        case "lrclib":
            "LRClib"

        case "user":
            "Edited"

        default:
            nil
        }
    }

    /// Called whenever the now-playing track changes.  Loads lyrics and wires observation.
    public func trackDidChange(trackID: Int64?) {
        // If the editor is open for a non-playing track, close it before switching context.
        if self.isEditorPresented {
            self.isEditorPresented = false
        }
        self.nowPlayingTrackID = nil
        self.currentTrackID = trackID
        self.document = nil
        self.documentSource = nil
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

    /// Unconditionally fetches lyrics from LRClib for the current track, replacing
    /// any existing lyrics regardless of source.  Does nothing when LRClib is not
    /// enabled in Settings or no track is loaded.
    public func forceFetch() {
        guard let trackID = currentTrackID, !isFetching, lrclibEnabled else { return }
        self.isFetching = true
        Task {
            defer { self.isFetching = false }
            do {
                _ = try await self.service.forceFetch(for: trackID)
            } catch {
                self.log.error("lyrics.forceFetch.failed", ["error": String(reflecting: error)])
            }
        }
    }

    /// Fetches lyrics from LRClib for any given track ID, replacing existing lyrics.
    /// Caller is responsible for checking whether LRClib is enabled.
    public func forceFetch(for trackID: Int64) {
        guard !self.isFetching else { return }
        self.isFetching = true
        Task {
            defer { self.isFetching = false }
            do {
                _ = try await self.service.forceFetch(for: trackID)
            } catch {
                self.log.error("lyrics.forceFetch.failed", ["error": String(reflecting: error)])
            }
        }
    }

    /// Opens the lyrics pane (if not already visible) and presents the editor sheet
    /// for the currently observed (now-playing) track.
    public func openEditor() {
        self.paneVisible = true
        self.isEditorPresented = true
    }

    /// Opens the lyrics editor for a specific track, regardless of what is currently
    /// playing.  When the editor is dismissed the pane reverts to the now-playing track.
    public func openEditor(for trackID: Int64) {
        guard trackID != self.currentTrackID else {
            // Already observing the right track — just open the sheet.
            self.openEditor()
            return
        }
        // Remember the now-playing track so we can restore after editing.
        self.nowPlayingTrackID = self.currentTrackID
        self.currentTrackID = trackID
        self.document = nil
        self.documentSource = nil
        self.currentLineIndex = nil
        self.observeTask?.cancel()
        self.startObserving(trackID: trackID)
        self.paneVisible = true
        self.isEditorPresented = true
    }

    /// Deletes stored lyrics for any given track ID.
    public func clearLyrics(for trackID: Int64) {
        Task {
            do {
                try await self.service.setLyrics(nil, for: trackID)
            } catch {
                self.log.error("lyrics.clear.failed", ["error": String(reflecting: error)])
            }
        }
    }

    /// Saves user-edited lyrics text for the current track.
    /// Detects LRC-formatted input (lines with `[mm:ss.xx]` timestamps) and stores
    /// it as `.synced`; plain text is stored as `.unsynced`.
    public func save(text: String) {
        guard let trackID = currentTrackID else { return }
        let doc = LRCParser.parseDocument(text)
        let embed = self.embedOnSave
        Task {
            do {
                try await self.service.setLyrics(doc, for: trackID, source: "user", persistToFile: embed)
            } catch {
                self.log.error("lyrics.save.failed", ["error": String(reflecting: error)])
            }
        }
    }

    /// Saves a fully-formed ``LyricsDocument`` (from the editor's synced wizard).
    public func save(document: LyricsDocument) {
        guard let trackID = currentTrackID else { return }
        let embed = self.embedOnSave
        Task {
            do {
                try await self.service.setLyrics(document, for: trackID, source: "user", persistToFile: embed)
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
            let stream = await self.service.observeWithSource(trackID)
            do {
                for try await (doc, source) in stream {
                    try Task.checkCancellation()
                    await MainActor.run {
                        self.document = doc
                        self.documentSource = source
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

    /// Full name used in tooltips and accessibility labels.
    public var fullName: String {
        switch self {
        case .small:
            "Small"

        case .medium:
            "Medium"

        case .large:
            "Large"

        case .extraLarge:
            "Extra Large"
        }
    }
}
