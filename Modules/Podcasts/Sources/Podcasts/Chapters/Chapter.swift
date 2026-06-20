import Foundation

/// A normalized podcast chapter, source-agnostic across chapter formats.
///
/// `title` is feed content, rendered verbatim, never localized.
public struct Chapter: Sendable, Hashable, Identifiable {
    public var id: Int
    public var startTime: TimeInterval
    public var title: String
    public var imageURL: URL?
    public var url: URL?

    public init(id: Int, startTime: TimeInterval, title: String, imageURL: URL? = nil, url: URL? = nil) {
        self.id = id
        self.startTime = startTime
        self.title = title
        self.imageURL = imageURL
        self.url = url
    }
}

public extension [Chapter] {
    /// The chapter active at `position`: the last whose `startTime` is at or before
    /// `position`. Returns nil before the first chapter's start, or when empty.
    func current(at position: TimeInterval) -> Chapter? {
        self.last { $0.startTime <= position }
    }
}
