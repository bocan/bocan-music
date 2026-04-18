/// All log categories used across the application.
/// Centralised here so every phase can import `Observability` and refer to
/// the typed enum rather than raw strings.
public enum LogCategory: String, Sendable, CaseIterable {
    case app, audio, library, metadata, persistence, ui, network, playback, cast, scrobble
}
