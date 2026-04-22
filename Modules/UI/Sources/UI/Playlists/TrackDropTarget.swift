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
/// All ordinary mouse/scroll events are forwarded to `nextResponder` so the
/// SwiftUI content beneath (row text, context menus, list scroll) behaves
/// exactly as if the overlay were not there.  `hitTest` returns `self` so
/// AppKit's drag-destination lookup (which walks from the deepest hit-tested
/// view upward) finds this view before any parent.
public final class DropTargetNSView: NSView {
    /// Set to `false` to silently decline every incoming drag (e.g. smart
    /// playlists and folders are not valid drop targets).
    public var isActive = true

    /// Called on the main thread when the user completes a valid drop.
    public var onReceive: (([Int64]) -> Void)?

    private var isHighlighted = false {
        didSet { needsDisplay = true }
    }

    override public init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.string])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Pass right-clicks through so SwiftUI context menus on underlying rows work.
    /// Drag-destination lookup uses a separate code path and is unaffected.
    override public func hitTest(_ point: NSPoint) -> NSView? {
        guard NSApp.currentEvent?.type != .rightMouseDown else { return nil }
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

    // MARK: - Mouse / scroll passthrough

    /// Not a first responder — never steals keyboard focus.
    override public var acceptsFirstResponder: Bool {
        false
    }

    /// Forward all pointer and scroll events so the content underneath
    /// (row selection, context menus, list scrolling) is unaffected.
    override public func mouseDown(with event: NSEvent) {
        nextResponder?.mouseDown(with: event)
    }

    override public func mouseUp(with event: NSEvent) {
        nextResponder?.mouseUp(with: event)
    }

    override public func mouseDragged(with event: NSEvent) {
        nextResponder?.mouseDragged(with: event)
    }

    /// rightMouseDown/rightMouseUp are not forwarded — hitTest returns nil for right-click
    /// events so they never arrive here; the underlying SwiftUI rows handle them directly.
    override public func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    // MARK: - Drawing

    override public func draw(_ dirtyRect: NSRect) {
        guard self.isHighlighted else { return }
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

    public init(
        isActive: Bool = true,
        onReceive: @escaping ([Int64]) -> Void
    ) {
        self.isActive = isActive
        self.onReceive = onReceive
    }

    public func makeNSView(context: Context) -> DropTargetNSView {
        let view = DropTargetNSView()
        view.isActive = self.isActive
        view.onReceive = self.onReceive
        return view
    }

    public func updateNSView(_ view: DropTargetNSView, context: Context) {
        view.isActive = self.isActive
        view.onReceive = self.onReceive
    }
}
