/// Controls how the scanner treats the existing DB state.
public enum ScanMode: Sendable {
    /// Only re-import files whose `mtime` or `size` has changed.
    case quick
    /// Re-read every file regardless of stored state.
    case full
}
