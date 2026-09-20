import Observation

// MARK: - LyricsMenuState

/// The two facts the Track menu gates on, as `@Observable` state.
///
/// `LyricsViewModel` is an `ObservableObject`, and `BocanCommands` holds it as a
/// plain `let`, so a `@Published` value read in the `Commands` body cannot
/// invalidate it: the item freezes at whatever it was when the menu was built
/// (`docs/GOTCHAS.md`, "Gate menu items only on `@AppStorage` or `@Observable`
/// reads"). A `Commands` body does track `@Observable` reads, so the view model
/// mirrors the two values here and the menu reads these instead (#546).
///
/// Writes are guarded to a real change, so a lyric line advancing or a document
/// being replaced by another one does not rebuild the menu bar.
@MainActor
@Observable
public final class LyricsMenuState {
    /// `true` when lyrics are loaded for the view model's current track.
    public private(set) var hasDocument = false

    /// `true` while an auto-fetch or force-fetch is in progress.
    public private(set) var isFetching = false

    public init() {}

    func update(hasDocument: Bool) {
        guard self.hasDocument != hasDocument else { return }
        self.hasDocument = hasDocument
    }

    func update(isFetching: Bool) {
        guard self.isFetching != isFetching else { return }
        self.isFetching = isFetching
    }
}
