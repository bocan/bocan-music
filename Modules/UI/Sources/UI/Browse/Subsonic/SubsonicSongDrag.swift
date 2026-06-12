import AppKit
import SwiftUI

// MARK: - SubsonicSongDragPayload

/// The drag payload for a streamed Subsonic song. Carries enough metadata to
/// rebuild a `.subsonic` queue item on drop without re-fetching from the server
/// (#332). A drag of multiple selected rows carries an array of these.
public struct SubsonicSongDragPayload: Codable, Sendable, Hashable {
    public let serverID: UUID
    public let songID: String
    public let title: String
    public let artist: String
    public let album: String
    public let genre: String
    /// Track duration in whole seconds (0 when unknown).
    public let durationSeconds: Int

    public init(
        serverID: UUID,
        songID: String,
        title: String,
        artist: String,
        album: String,
        genre: String,
        durationSeconds: Int
    ) {
        self.serverID = serverID
        self.songID = songID
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.durationSeconds = durationSeconds
    }
}

/// Pasteboard types used by Bòcan's drag-and-drop.
public extension NSPasteboard.PasteboardType {
    /// App-private drag type for one or more `SubsonicSongDragPayload`s, JSON-encoded.
    static let bocanSubsonicSong = NSPasteboard.PasteboardType("io.cloudcauldron.bocan.subsonic-song")
}

/// Encoding/decoding helpers for the Subsonic-song drag pasteboard payload (#332).
public enum SubsonicSongDrag {
    /// Encodes payloads onto a single `NSPasteboardItem` under `.bocanSubsonicSong`.
    public static func pasteboardItem(for payloads: [SubsonicSongDragPayload]) -> NSPasteboardItem? {
        guard !payloads.isEmpty, let data = try? JSONEncoder().encode(payloads) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: .bocanSubsonicSong)
        return item
    }

    /// Reads any `SubsonicSongDragPayload`s carried by a dragging session.
    @MainActor
    public static func payloads(from info: NSDraggingInfo) -> [SubsonicSongDragPayload] {
        self.payloads(from: info.draggingPasteboard.pasteboardItems ?? [])
    }

    /// Reads payloads from pasteboard items (the decode half, testable without a
    /// live `NSDraggingInfo`).
    public static func payloads(from items: [NSPasteboardItem]) -> [SubsonicSongDragPayload] {
        items.flatMap { item -> [SubsonicSongDragPayload] in
            guard let data = item.data(forType: .bocanSubsonicSong),
                  let decoded = try? JSONDecoder().decode([SubsonicSongDragPayload].self, from: data) else { return [] }
            return decoded
        }
    }
}

// MARK: - SubsonicSongDropTargetNSView

/// Transparent AppKit overlay that accepts `SubsonicSongDragPayload` drops,
/// mirroring `DropTargetNSView` (the local track-ID drop target). Used to make
/// the Up Next queue accept streamed Subsonic songs dragged from a server's
/// song table (#332).
///
/// `hitTest` returns `self` only during a live drag so normal clicks/scrolls in
/// the underlying SwiftUI view are unaffected.
public final class SubsonicSongDropTargetNSView: NSView {
    public var onReceive: (([SubsonicSongDragPayload]) -> Void)?

    private var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    override public init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.bocanSubsonicSong])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard NSApp.currentEvent?.type == .leftMouseDragged else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    // MARK: NSDraggingDestination

    override public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !SubsonicSongDrag.payloads(from: sender).isEmpty else { return [] }
        self.isHighlighted = true
        return .copy
    }

    override public func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !SubsonicSongDrag.payloads(from: sender).isEmpty else {
            self.isHighlighted = false
            return []
        }
        return .copy
    }

    override public func draggingExited(_ sender: (any NSDraggingInfo)?) {
        self.isHighlighted = false
    }

    override public func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !SubsonicSongDrag.payloads(from: sender).isEmpty
    }

    override public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let payloads = SubsonicSongDrag.payloads(from: sender)
        guard !payloads.isEmpty else { return false }
        self.isHighlighted = false
        self.onReceive?(payloads)
        return true
    }

    override public func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        self.isHighlighted = false
    }

    // MARK: Drawing

    override public func draw(_ dirtyRect: NSRect) {
        guard self.isHighlighted else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }
}

// MARK: - SubsonicSongDropTarget

/// `NSViewRepresentable` wrapper. Apply as an `.overlay` on any SwiftUI view to
/// make it accept Subsonic-song drops.
public struct SubsonicSongDropTarget: NSViewRepresentable {
    public let onReceive: ([SubsonicSongDragPayload]) -> Void

    public init(onReceive: @escaping ([SubsonicSongDragPayload]) -> Void) {
        self.onReceive = onReceive
    }

    public func makeNSView(context: Context) -> SubsonicSongDropTargetNSView {
        let view = SubsonicSongDropTargetNSView()
        view.onReceive = self.onReceive
        return view
    }

    public func updateNSView(_ view: SubsonicSongDropTargetNSView, context: Context) {
        view.onReceive = self.onReceive
    }
}
