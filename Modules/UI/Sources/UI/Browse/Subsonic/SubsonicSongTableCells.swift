import AppKit
import Foundation
import Subsonic

// MARK: - SubsonicCoverArtCell

/// `NSTableCellView` that asynchronously loads cover art for a Subsonic entity.
///
/// First resolves the `coverArtURL` via `SubsonicCoverArtProvider`, then
/// downloads and caches the `NSImage`.  Cancels in-flight work when reused.
final class SubsonicCoverArtCell: NSTableCellView {
    private let imageContainer = NSView()
    private let artImageView = NSImageView()
    private var loadTask: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("sArtCell")

        self.imageContainer.translatesAutoresizingMaskIntoConstraints = false
        self.imageContainer.wantsLayer = true
        self.imageContainer.layer?.cornerRadius = 3
        self.imageContainer.layer?.masksToBounds = true
        addSubview(self.imageContainer)

        self.artImageView.translatesAutoresizingMaskIntoConstraints = false
        self.artImageView.imageScaling = .scaleProportionallyUpOrDown
        self.artImageView.imageAlignment = .alignCenter
        self.artImageView.animates = false
        self.imageContainer.addSubview(self.artImageView)

        NSLayoutConstraint.activate([
            self.imageContainer.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            self.imageContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            self.imageContainer.widthAnchor.constraint(equalTo: self.imageContainer.heightAnchor),
            self.imageContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            self.artImageView.leadingAnchor.constraint(equalTo: self.imageContainer.leadingAnchor),
            self.artImageView.trailingAnchor.constraint(equalTo: self.imageContainer.trailingAnchor),
            self.artImageView.topAnchor.constraint(equalTo: self.imageContainer.topAnchor),
            self.artImageView.bottomAnchor.constraint(equalTo: self.imageContainer.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("unavailable")
    }

    func configure(
        provider: SubsonicCoverArtProvider?,
        serverID: UUID,
        entityID: String?,
        seed: Int,
        title: String
    ) {
        self.loadTask?.cancel()
        self.artImageView.image = nil
        setAccessibilityLabel(entityID == nil ? L10n.string("No artwork") : L10n.string("\(title) artwork"))
        guard let provider, let entityID else { return }
        self.loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let url = try? await provider.coverArtURL(
                serverID: serverID,
                entityID: entityID,
                size: 64
            ) else { return }
            guard !Task.isCancelled else { return }
            let img = await SubsonicImageCache.shared.image(url: url)
            guard !Task.isCancelled else { return }
            self.artImageView.image = img
        }
    }
}

// MARK: - SubsonicStarButtonCell

/// `NSTableCellView` for the star (★) column.
///
/// Manages its own optimistic visual state so taps feel instant, without
/// needing a full SwiftUI re-render cycle.
final class SubsonicStarButtonCell: NSTableCellView {
    private static let starredColor = NSColor.systemYellow
    private static let unstarredColor = NSColor.tertiaryLabelColor

    private let button = NSButton(frame: .zero)
    private var songID: String?
    private var isStarred = false
    private var onToggle: ((String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("sStarCell")
        self.button.translatesAutoresizingMaskIntoConstraints = false
        self.button.isBordered = false
        self.button.bezelStyle = .inline
        self.button.target = self
        self.button.action = #selector(self.tapped)
        addSubview(self.button)
        NSLayoutConstraint.activate([
            self.button.centerXAnchor.constraint(equalTo: centerXAnchor),
            self.button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("unavailable")
    }

    func configure(starred: Bool, action: @escaping (String) -> Void, songID: String) {
        self.songID = songID
        self.isStarred = starred
        self.onToggle = action
        self.updateButton()
    }

    private func updateButton() {
        let bodyFont = NSFont.preferredFont(forTextStyle: .body)
        let color: NSColor = self.isStarred ? Self.starredColor : Self.unstarredColor
        let attrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: color]
        self.button.attributedTitle = NSAttributedString(string: "\u{2605}", attributes: attrs)
        self.button.setAccessibilityLabel(self.isStarred ? L10n.string("Starred") : L10n.string("Not starred"))
        self.button.toolTip = self.isStarred ? L10n.string("Starred — click to unstar") : L10n.string("Click to star")
    }

    @objc private func tapped() {
        guard let id = songID else { return }
        self.isStarred.toggle()
        self.updateButton()
        self.onToggle?(id)
    }
}

// MARK: - SubsonicImageCache

/// Thread-safe NSImage cache for Subsonic cover art URLs.
actor SubsonicImageCache {
    static let shared = SubsonicImageCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 300
        return c
    }()

    /// Returns a decoded `NSImage` for `url`, downloading it if not cached.
    func image(url: URL) async -> NSImage? {
        let key = url.absoluteString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = NSImage(data: data) else { return nil }
        self.cache.setObject(img, forKey: key)
        return img
    }
}
