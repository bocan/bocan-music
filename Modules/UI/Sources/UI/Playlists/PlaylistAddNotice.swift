import Library

// MARK: - PlaylistAddNotice

/// The message for an add to a playlist that left songs out.
///
/// A playlist holds each song once, so an add skips songs it already holds.
/// Before #720 that was silent, and dropping a song onto its own playlist
/// looked broken. Every add path (the Add to Playlist menu, a drop onto a
/// sidebar playlist, a drop onto the open playlist) shows this message.
enum PlaylistAddNotice {
    /// The toast for `result`, or nil when nothing was skipped.
    static func message(for result: PlaylistAddResult) -> ToastMessage? {
        guard result.skipped > 0 else { return nil }
        return ToastMessage(text: L10n.string("\(result.skipped) songs were already in this playlist."))
    }
}
