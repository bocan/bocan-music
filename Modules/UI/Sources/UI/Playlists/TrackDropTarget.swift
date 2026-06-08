import AppKit
import SwiftUI

// MARK: - DropTargetNSView

/// Transparent AppKit overlay that acts as a drag destination for track-ID
/// payloads produced by `TrackTableCoordinator.pasteboardWriterForRow`.
///
/// The coordinator writes comma-separated Int64 IDs using
/// `NSPasteboard.PasteboardType.string`, so we read back with the same type
/// — no UTI mismatch.
///
/// `hitTest` returns `self` only during a live drag (leftMouseDragged) so that
/// AppKit's drag-destination lookup finds this view.  All other events (clicks,
/// scrolls, right-clicks) fall through to the underlying NSTableView so that
/// normal row selection and context menus are unaffected.
public final class DropTargetNSView: NSView {
    /// Set to `false` to silently decline every incoming drag (e.g. smart
    /// playlists and folders are not valid drop targets).
    public var isActive = true

    /// Called on the main thread when the user completes a valid drop.
    public var onReceive: (([Int64]) -> Void)?

    /// When `true` this view draws its own accent border highlight. Set `false`
    /// to let SwiftUI draw the highlight instead (via `onHighlightChange`), which
    /// can extend beyond the tight row bounds for a less cramped target.
    public var drawsHighlight = true

    /// Reports highlight on/off to SwiftUI so a `.background`/`.overlay` can react.
    public var onHighlightChange: ((Bool) -> Void)?

    private var isHighlighted = false {
        didSet {
            guard self.isHighlighted != oldValue else { return }
            self.needsDisplay = self.drawsHighlight
            self.onHighlightChange?(self.isHighlighted)
        }
    }

    override public init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Only claim the hit during an active drag (leftMouseDragged) so AppKit's
    /// drag-destination routing can find this view.  For all other events —
    /// clicks, scrolls, right-clicks — return nil so the underlying NSTableView
    /// receives them normally.  Forwarding via `nextResponder` is insufficient
    /// because this view and the table are SwiftUI siblings, not parent/child.
    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard NSApp.currentEvent?.type == .leftMouseDragged else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    // MARK: - NSDraggingDestination

    override public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard self.isActive else { return [] }
        let ids = self.trackIDs(from: sender)
        guard !ids.isEmpty else { return [] }
        self.isHighlighted = true
        return .copy
    }

    override public func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard self.isActive, !self.trackIDs(from: sender).isEmpty else {
            self.isHighlighted = false
            return []
        }
        return .copy
    }

    override public func draggingExited(_ sender: (any NSDraggingInfo)?) {
        self.isHighlighted = false
    }

    override public func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        self.isActive && !self.trackIDs(from: sender).isEmpty
    }

    override public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let ids = self.trackIDs(from: sender)
        guard !ids.isEmpty else { return false }
        self.isHighlighted = false
        self.onReceive?(ids)
        return true
    }

    override public func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        self.isHighlighted = false
    }

    // MARK: - Drawing

    override public func draw(_ dirtyRect: NSRect) {
        guard self.isHighlighted, self.drawsHighlight else { return }
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: 4,
            yRadius: 4
        )
        NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
        path.fill()
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 1.5
        path.stroke()
    }

    // MARK: - Private

    private func trackIDs(from info: NSDraggingInfo) -> [Int64] {
        guard let items = info.draggingPasteboard.pasteboardItems else { return [] }
        return items.compactMap { $0.string(forType: .string) }.compactMap { Int64($0) }
    }
}

// MARK: - TrackDropTarget

/// `NSViewRepresentable` wrapper around `DropTargetNSView`.
///
/// Apply as an `.overlay` on any SwiftUI view to make it accept track-ID
/// drops dragged from the tracks table:
///
/// ```swift
/// PlaylistRow(...)
///     .overlay(TrackDropTarget(isActive: node.kind == .manual) { ids in
///         Task { await vm.addTracks(ids, to: node.id) }
///     })
/// ```
public struct TrackDropTarget: NSViewRepresentable {
    public let isActive: Bool
    public let onReceive: ([Int64]) -> Void
    /// When supplied, the view stops drawing its own AppKit border and instead
    /// reports its highlight state here so the caller can draw a SwiftUI
    /// highlight (e.g. a roomier, bleeding `.background`).
    public let onTargetedChange: ((Bool) -> Void)?

    public init(
        isActive: Bool = true,
        onTargetedChange: ((Bool) -> Void)? = nil,
        onReceive: @escaping ([Int64]) -> Void
    ) {
        self.isActive = isActive
        self.onTargetedChange = onTargetedChange
        self.onReceive = onReceive
    }

    public func makeNSView(context: Context) -> DropTargetNSView {
        let view = DropTargetNSView()
        self.apply(to: view)
        return view
    }

    public func updateNSView(_ view: DropTargetNSView, context: Context) {
        self.apply(to: view)
    }

    private func apply(to view: DropTargetNSView) {
        view.isActive = self.isActive
        view.onReceive = self.onReceive
        view.onHighlightChange = self.onTargetedChange
        view.drawsHighlight = self.onTargetedChange == nil
    }
}
