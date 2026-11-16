import AppKit
import Foundation
import Jellyfin
import SwiftUI

// MARK: - JellyfinSongDragPayload

/// The drag payload for a streamed Jellyfin song. It carries enough to rebuild a
/// `.jellyfin` queue item on drop without asking the server again, as the
/// Subsonic payload does (#332). A drag of several selected rows carries an array.
///
/// The song table writes it when a row is dragged out, and the Up Next queue
/// reads it back (`JellyfinSongDropTarget`). The play path builds its queue
/// items from the same fields (`QueueItem.makeJellyfin`).
public struct JellyfinSongDragPayload: Codable, Sendable, Hashable {
    public let serverID: UUID
    public let songID: String
    public let title: String
    public let artist: String
    public let album: String
    public let genre: String
    /// Track length in whole seconds (0 when unknown).
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

    /// The payload for one song of one server. A field the server did not send
    /// is empty, and an unknown length is 0.
    public init(song: JellyfinSong, serverID: UUID) {
        self.init(
            serverID: serverID,
            songID: song.id,
            title: song.title,
            artist: song.artistName ?? "",
            album: song.albumTitle ?? "",
            genre: song.genre ?? "",
            durationSeconds: Int(song.durationSeconds ?? 0)
        )
    }
}

/// Pasteboard types used by Bòcan's Jellyfin drag and drop.
public extension NSPasteboard.PasteboardType {
    /// App-private drag type for one or more `JellyfinSongDragPayload`s, JSON-encoded.
    static let bocanJellyfinSong = NSPasteboard.PasteboardType("io.cloudcauldron.bocan.jellyfin-song")
}

/// Encoding and decoding of the Jellyfin song drag payload.
public enum JellyfinSongDrag {
    /// Encodes payloads onto one `NSPasteboardItem` under `.bocanJellyfinSong`.
    /// Returns `nil` for no payloads or an encoding failure (which is logged by the caller's table).
    public static func pasteboardItem(for payloads: [JellyfinSongDragPayload]) -> NSPasteboardItem? {
        guard !payloads.isEmpty else { return nil }
        do {
            let data = try JSONEncoder().encode(payloads)
            let item = NSPasteboardItem()
            item.setData(data, forType: .bocanJellyfinSong)
            return item
        } catch {
            return nil
        }
    }

    /// Reads payloads from pasteboard items. An item that does not decode is skipped.
    public static func payloads(from items: [NSPasteboardItem]) -> [JellyfinSongDragPayload] {
        items.flatMap { item -> [JellyfinSongDragPayload] in
            guard let data = item.data(forType: .bocanJellyfinSong) else { return [] }
            do {
                return try JSONDecoder().decode([JellyfinSongDragPayload].self, from: data)
            } catch {
                return []
            }
        }
    }

    /// Reads payloads from a live drag.
    static func payloads(from info: NSDraggingInfo) -> [JellyfinSongDragPayload] {
        self.payloads(from: info.draggingPasteboard.pasteboardItems ?? [])
    }

    /// `true` while the drag in progress carries Jellyfin songs.
    static var dragInProgressCarriesSongs: Bool {
        NSPasteboard(name: .drag).types?.contains(.bocanJellyfinSong) ?? false
    }
}

// MARK: - JellyfinSongDropTargetNSView

/// Transparent AppKit overlay that accepts `JellyfinSongDragPayload` drops, the
/// twin of `SubsonicSongDropTargetNSView`. It makes the Up Next queue accept
/// streamed Jellyfin songs dragged from a server's song table.
///
/// It sits above the Subsonic overlay on the same view, so `hitTest` returns
/// `self` only while the drag carries Jellyfin songs. Any other drag, and every
/// click and scroll, passes through to what lies below.
public final class JellyfinSongDropTargetNSView: NSView {
    public var onReceive: (([JellyfinSongDragPayload]) -> Void)?

    private var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    override public init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.bocanJellyfinSong])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard NSApp.currentEvent?.type == .leftMouseDragged, JellyfinSongDrag.dragInProgressCarriesSongs else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    // MARK: NSDraggingDestination

    override public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !JellyfinSongDrag.payloads(from: sender).isEmpty else { return [] }
        self.isHighlighted = true
        return .copy
    }

    override public func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !JellyfinSongDrag.payloads(from: sender).isEmpty else {
            self.isHighlighted = false
            return []
        }
        return .copy
    }

    override public func draggingExited(_ sender: (any NSDraggingInfo)?) {
        self.isHighlighted = false
    }

    override public func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !JellyfinSongDrag.payloads(from: sender).isEmpty
    }

    override public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let payloads = JellyfinSongDrag.payloads(from: sender)
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

// MARK: - JellyfinSongDropTarget

/// `NSViewRepresentable` wrapper. Apply as an `.overlay` on any SwiftUI view to
/// make it accept Jellyfin-song drops.
public struct JellyfinSongDropTarget: NSViewRepresentable {
    public let onReceive: ([JellyfinSongDragPayload]) -> Void

    public init(onReceive: @escaping ([JellyfinSongDragPayload]) -> Void) {
        self.onReceive = onReceive
    }

    public func makeNSView(context: Context) -> JellyfinSongDropTargetNSView {
        let view = JellyfinSongDropTargetNSView()
        view.onReceive = self.onReceive
        return view
    }

    public func updateNSView(_ view: JellyfinSongDropTargetNSView, context: Context) {
        view.onReceive = self.onReceive
    }
}
